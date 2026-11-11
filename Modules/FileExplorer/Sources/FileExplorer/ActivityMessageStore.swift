import Foundation
import Events
import Sync

/// Activity's messages, kept across quits: every one that says something happened or failed, never
/// a refusal (`OperationBanner.isRefusal`), which only buries what did happen, nor a note of
/// something still under way (`OperationBanner.isInProgress`). Events draws them beside the runs,
/// and a run's row keeps its own sentence after a relaunch.
///
/// One JSON line per write, appended to `~/sync-cloud-activity.jsonl` beside the history file. A
/// repeat folding into a row appends that row again, and the newest line for an id wins when the
/// file is read, so a write never rewrites the file. The file is rewritten only to trim it (at
/// launch, and once it holds twice what it keeps), to forget the runs' messages when Sync History
/// is cleared, and to clear it; each of those reads the file as it is then, so a newer build's
/// lines survive. Every append and every read-and-rewrite holds an exclusive `flock` on the file,
/// so the installed app and a worktree build beside it never lose each other's lines, and a row
/// another copy cleared or forgot is not written back by this one's next repeat of it.
///
/// What a message's buttons can't do later is not kept: its Undo, whose step numbers start again
/// at every launch, and Download, whose path may name another file by then.
public final class ActivityMessageStore: @unchecked Sendable {
    /// The most kept, newest first, and for how long.
    public static let maxMessages = 500
    public static let maxAge: TimeInterval = 90 * 86_400

    public let fileURL: URL
    /// Every read and write of the file, in order, off the main thread except `load`.
    private let queue = DispatchQueue(label: "com.abhishekgirish.SyncCloud.activity-messages")
    /// Lines appended since the file was last trimmed; read and written only on `queue`.
    private var appendedSinceTrim = 0
    /// The rows this store has written, so a later line for one (a repeat, an amended sentence)
    /// is written only while the file still holds it; read and written only on `queue`.
    private var written: Set<UUID> = []
    /// Runs inside every read-and-rewrite, after the read and before the write, holding the lock:
    /// for a test to act as another copy of the app at the worst moment.
    var beforeRewrite: (@Sendable () -> Void)?

    public init(fileURL: URL = ActivityMessageStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// `SYNCCLOUD_ACTIVITY_FILE`, else a per-process temp file under a test runner, else
    /// `~/sync-cloud-activity.jsonl` beside `~/sync-cloud-history.jsonl`.
    public static func defaultFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["SYNCCLOUD_ACTIVITY_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if Logger.isRunningTests {
            return PerProcessTestFile.url(stem: "sync-cloud-activity-tests", extension: "jsonl")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("sync-cloud-activity.jsonl")
    }

    /// The kept messages, newest first: the newest line for each id, inside ``maxAge`` and
    /// ``maxMessages``, trimming the file as it reads it.
    public func load(now: Date = Date()) -> [ActivityMessage] {
        queue.sync { (withFileLock { _ in trimFile(now: now) } ?? trimFile(now: now)).map(\.restored) }
    }

    /// Appends `message`, unless it is a refusal or a note of something under way. A row this store
    /// wrote before is written again only while the file still holds it: one another copy of the
    /// app cleared or forgot stays gone.
    public func save(_ message: ActivityMessage) {
        guard !message.isRefusal, !message.isInProgress, let line = Self.line(for: message) else { return }
        let id = message.id
        queue.async {
            let appended = self.withFileLock { fd -> Bool in
                if self.written.contains(id), !self.fileHolds(id) { return false }
                self.append(line, to: fd)
                return true
            } ?? false
            guard appended else { return }
            self.written.insert(id)
            self.appendedSinceTrim += 1
            // Past twice the cap, what the next launch reads and decodes is mostly dead lines.
            if self.appendedSinceTrim > Self.maxMessages {
                _ = self.withFileLock { _ in self.trimFile(now: Date()) }
            }
        }
    }

    /// Empties the file: Clear Messages. Everything goes, whichever copy of the app wrote it.
    public func clearAll() {
        queue.async {
            if self.withFileLock({ _ in self.write(Data()) }) == nil { self.write(Data()) }
            self.written.removeAll()
        }
    }

    /// Drops every kept message that reported a run: Sync History was cleared, and each would be a
    /// row with nothing behind it. Reads the file as it is, so another copy's other lines stay.
    public func forgetRunMessages() {
        queue.async {
            _ = self.withFileLock { _ in
                let file = self.read()
                let kept = file.saved.filter { $0.runId == nil }
                self.rewrite(kept.sorted { $0.date < $1.date }, keeping: file.newer)
            }
        }
    }

    /// Waits for every write to reach the disk: at quit.
    public func flush() {
        queue.sync {}
    }

    // MARK: Reading and writing, on `queue`

    static func kept(_ saved: [SavedActivityMessage], now: Date) -> [SavedActivityMessage] {
        Array(saved.filter { now.timeIntervalSince($0.date) <= maxAge }
            .sorted { $0.date > $1.date }
            .prefix(maxMessages))
    }

    /// The file's lines: the newest for each id this build reads, and the lines a newer build wrote,
    /// kept as they are. A line that is neither (half a line a crash left, say) is dropped.
    private func read() -> (saved: [SavedActivityMessage], newer: [Data], lines: Int) {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return ([], [], 0) }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        var byId: [UUID: SavedActivityMessage] = [:]
        var newer: [Data] = []
        for line in lines {
            let bytes = Data(line)
            if let saved = try? Self.decoder.decode(SavedActivityMessage.self, from: bytes),
               saved.version <= SavedActivityMessage.currentVersion {
                byId[saved.id] = saved
            } else if let version = (try? Self.decoder.decode(VersionOnly.self, from: bytes))?.version,
                      version > SavedActivityMessage.currentVersion {
                newer.append(bytes)
            }
        }
        return (Array(byId.values), newer, lines.count)
    }

    /// Trims the file to what it keeps, when it holds more than that or lines no build can read.
    /// Returns what it keeps, newest first.
    private func trimFile(now: Date) -> [SavedActivityMessage] {
        let file = read()
        let kept = Self.kept(file.saved, now: now)
        if file.lines > kept.count + file.newer.count {
            rewrite(kept.reversed(), keeping: file.newer)
        }
        appendedSinceTrim = 0
        return kept
    }

    /// Runs `body` holding an exclusive `flock` on the file, handed the descriptor, opened for
    /// appending (and reading, so `endsMidLine` can look at the last byte). Another copy of the app
    /// waits for the lock before it appends or reads to rewrite, so neither loses the other's
    /// lines. A rewrite replaces the file, so a lock taken on the file it replaced is let go and
    /// taken again on the one now at the path. Nil, after a log line, when the file can't be opened.
    private func withFileLock<T>(_ body: (Int32) -> T) -> T? {
        while true {
            let fd = open(fileURL.path, O_RDWR | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else {
                Logger.shared.warning("Activity: couldn’t open \(fileURL.lastPathComponent) to keep messages (errno \(errno))")
                return nil
            }
            var locked = flock(fd, LOCK_EX)
            while locked != 0, errno == EINTR { locked = flock(fd, LOCK_EX) }
            guard locked == 0 else {
                Logger.shared.warning("Activity: couldn’t lock \(fileURL.lastPathComponent) (errno \(errno)); writing unlocked")
                defer { close(fd) }
                return body(fd)
            }
            var held = stat(), atPath = stat()
            if fstat(fd, &held) == 0, stat(fileURL.path, &atPath) == 0,
               held.st_dev == atPath.st_dev, held.st_ino == atPath.st_ino {
                defer { flock(fd, LOCK_UN); close(fd) }
                return body(fd)
            }
            // Replaced while this waited: lock the file now at the path.
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    /// Whether the file still has a line for `id`: a byte search, no decoding.
    private func fileHolds(_ id: UUID) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        return data.range(of: Data("\"id\":\"\(id.uuidString)\"".utf8)) != nil
    }

    /// Appends one line to `fd`, opened for appending so two copies of the app writing at once
    /// each land whole; starts a fresh line first if the file doesn't end in one.
    private func append(_ line: Data, to fd: Int32) {
        var bytes = Data()
        if endsMidLine(fd) { bytes.append(UInt8(ascii: "\n")) }
        bytes.append(line)
        bytes.append(UInt8(ascii: "\n"))
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if written != bytes.count {
            Logger.shared.warning("Activity: couldn’t keep a message in \(fileURL.lastPathComponent) (errno \(errno))")
        }
    }

    /// Whether the file's last byte is not a newline: what a write cut short leaves.
    private func endsMidLine(_ fd: Int32) -> Bool {
        let size = lseek(fd, 0, SEEK_END)
        guard size > 0 else { return false }
        var last: UInt8 = 0
        return pread(fd, &last, 1, size - 1) == 1 && last != UInt8(ascii: "\n")
    }

    /// Writes `saved`, oldest first, then a newer build's lines, in one atomic replace.
    private func rewrite<S: Sequence>(_ saved: S, keeping newer: [Data]) where S.Element == SavedActivityMessage {
        beforeRewrite?()
        var data = Data()
        for message in saved {
            guard let line = try? Self.encoder.encode(message) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        for line in newer {
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        write(data)
    }

    private func write(_ data: Data) {
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.warning("Activity: couldn’t rewrite \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// A line's version alone, to tell a newer build's line from a broken one.
    private struct VersionOnly: Decodable { let version: Int }

    static func line(for message: ActivityMessage) -> Data? {
        try? encoder.encode(SavedActivityMessage(message))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()
}

/// One kept message, as written: what a later session can still show and do.
struct SavedActivityMessage: Codable, Equatable {
    static let currentVersion = 1

    var version = SavedActivityMessage.currentVersion
    let id: UUID
    let date: Date
    let message: String
    let detail: String?
    let severity: OperationBanner.Severity
    let followUps: [OperationBanner.FollowUp]
    let repeats: Int
    let runId: UUID?
    let spanStart: Date
    let spanEnd: Date
    let source: ActivityMessage.Source
    let isStopped: Bool

    init(_ message: ActivityMessage) {
        id = message.id
        date = message.date
        self.message = message.message
        detail = message.detail
        severity = message.severity
        // Download asks for a path that may name another file by the time it is clicked.
        followUps = message.followUps.filter {
            if case .download = $0 { return false }
            return true
        }
        repeats = message.repeats
        runId = message.runId
        spanStart = message.span.lowerBound
        spanEnd = message.span.upperBound
        source = message.source
        isStopped = message.isStopped
    }

    /// The message again, with no Undo: its step belonged to the session that wrote it.
    var restored: ActivityMessage {
        var restored = ActivityMessage(id: id, date: date, message: message, detail: detail, severity: severity,
                                       followUps: followUps, repeats: repeats, undoStep: nil, runId: runId,
                                       span: spanStart...max(spanStart, spanEnd), source: source)
        restored.isStopped = isStopped
        restored.isFromEarlierSession = true
        return restored
    }
}
