import Foundation
import Events
import Sync

/// Activity's messages, kept across quits: every one that says something happened or failed, never
/// a refusal (`OperationBanner.isRefusal`), which only buries what did happen. Events draws them
/// beside the runs, and a run's row keeps its own sentence after a relaunch.
///
/// One JSON line per write, appended to `~/sync-cloud-activity.jsonl` beside the history file. A
/// repeat folding into a row appends that row again, and the newest line for an id wins when the
/// file is read, so a write never rewrites the file: the installed app and a worktree build beside
/// it can both append without either losing the other's lines. The file is rewritten only to trim
/// it, as it is read at launch, and to clear it.
///
/// What a message's buttons can't do later is not kept: its Undo, whose step numbers start again
/// at every launch, and Download, whose path may name another file by then.
public final class ActivityMessageStore: @unchecked Sendable {
    /// The most kept, newest first, and for how long.
    public static let maxMessages = 500
    public static let maxAge: TimeInterval = 90 * 86_400

    public let fileURL: URL
    /// Appends and rewrites, in order, off the main thread.
    private let queue = DispatchQueue(label: "com.abhishekgirish.SyncCloud.activity-messages")

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
    /// ``maxMessages``. Rewrites the file when it holds far more lines than that, keeping lines this
    /// build can't read (a newer build's), so running an older build never deletes them.
    public func load(now: Date = Date()) -> [ActivityMessage] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
            let lines = data.split(separator: UInt8(ascii: "\n"))
            var byId: [UUID: (order: Int, saved: SavedActivityMessage)] = [:]
            var unreadable: [Data] = []
            for (order, line) in lines.enumerated() {
                if let saved = try? Self.decoder.decode(SavedActivityMessage.self, from: Data(line)),
                   saved.version <= SavedActivityMessage.currentVersion {
                    byId[saved.id] = (order, saved)
                } else {
                    unreadable.append(Data(line))
                }
            }
            let kept = Self.kept(byId.values.map(\.saved), now: now)
            if lines.count > Self.maxMessages * 2 || kept.count < byId.count {
                rewrite(kept.reversed(), keeping: unreadable)
            }
            return kept.map(\.restored)
        }
    }

    /// Appends `message`, unless it is a refusal.
    public func save(_ message: ActivityMessage) {
        guard !message.isRefusal, let line = Self.line(for: message) else { return }
        queue.async { self.append(line) }
    }

    /// Replaces everything kept with `messages` (newest first): Clear, or a clear of the runs they
    /// reported.
    public func replaceAll(with messages: [ActivityMessage]) {
        let saved = messages.filter { !$0.isRefusal }.map(SavedActivityMessage.init)
        queue.async { self.rewrite(saved.reversed(), keeping: []) }
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

    private func append(_ line: Data) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            Logger.shared.warning("Activity: couldn’t open \(fileURL.lastPathComponent) to keep a message")
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line + Data([UInt8(ascii: "\n")]))
        } catch {
            Logger.shared.warning("Activity: couldn’t keep a message in \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Writes `saved`, oldest first, then the lines this build can't read, in one atomic replace.
    private func rewrite<S: Sequence>(_ saved: S, keeping unreadable: [Data]) where S.Element == SavedActivityMessage {
        var data = Data()
        for message in saved {
            guard let line = try? Self.encoder.encode(message) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        for line in unreadable {
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.warning("Activity: couldn’t rewrite \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

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
        return restored
    }
}
