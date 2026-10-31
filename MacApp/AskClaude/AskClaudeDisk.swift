import Foundation
import Sync

/// What Ask Claude’s Look tools read when the Browse pane hasn’t loaded a folder (RD69, v7.0).
///
/// **Names and metadata only, the same data the pane shows.** A folder is listed with
/// `contentsOfDirectory` and its resource values: no file is opened, and a cloud-only file is not
/// downloaded, because nothing here reads contents. Hidden files are skipped, as the pane skips
/// them by default.
///
/// **Why it exists:** the first version read only the pane’s loaded tree, and `go_to` re-roots the
/// pane, so after one move everything above and beside it read as “not loaded”. On 2026-10-30
/// that cost 7 of 16 tool calls across two questions, each one re-sending the whole chat.
enum AskClaudeDisk {

    /// How long a read may take before the tool answers without it. An iCloud folder can stall in
    /// `open()` for minutes (the [load] walk has seen 208 s), and a question must not wait on that.
    static let timeout: Duration = .seconds(5)
    /// Spotlight paths stat’ed per search: more than enough for the 50 listed and an honest count.
    static let maxExamined = 500

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .tagNamesKey,
    ]

    /// One item’s row data from the file system, or nil when it’s gone.
    nonisolated static func node(atPath path: String) -> FileNode? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        // A link's own values describe the link: iCloud's Documents and Desktop are links to
        // folders, and read as files without following them.
        var isDirectory = values.isDirectory ?? false
        if values.isSymbolicLink == true {
            var isDir: ObjCBool = false
            isDirectory = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        return FileNode(id: path, name: url.lastPathComponent, isDirectory: isDirectory,
                        children: isDirectory ? [] : nil, modificationDate: values.contentModificationDate,
                        fileSize: isDirectory ? nil : values.fileSize, tags: values.tagNames,
                        kind: values.localizedTypeDescription,
                        // Not walked: a folder read from disk says nothing about how many items it holds.
                        isUnexplored: isDirectory ? true : nil)
    }

    /// A folder’s direct items, in name order, or nil when it can’t be read within `timeout`.
    nonisolated static func list(_ folder: String) async -> [FileNode]? {
        await bounded {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
            return urls.compactMap { node(atPath: $0.path) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// Paths under `folder` whose names contain every word, from Spotlight’s index; nil when
    /// Spotlight can’t be asked or doesn’t answer in time.
    @MainActor
    static func findNames(_ words: [String], under folder: String) async -> [String]? {
        await SpotlightNameQuery(query: queryString(words), folder: folder).run()
    }

    /// Paths under `folder` whose text holds every word (TE239), from Spotlight’s index.
    @MainActor
    static func findContents(_ words: [String], under folder: String) async -> [String]? {
        await SpotlightNameQuery(query: AskClaudeReading.contentQuery(words), folder: folder).run()
    }

    /// `kMDItemFSName` containing ANY of the words, ignoring case and accents. Any, not all: a word
    /// can live in a folder’s name rather than the file’s (`H-1B/2026-2029/Approval/GIRISH….pdf`),
    /// so the caller keeps the paths whose folders and name together hold every word. A quote,
    /// backslash or `*` in a word is escaped so it is searched for, not read as syntax.
    nonisolated static func queryString(_ words: [String]) -> String {
        words.map { word -> String in
            var escaped = ""
            for character in word {
                if character == "\\" || character == "\"" || character == "*" || character == "?" { escaped.append("\\") }
                escaped.append(character)
            }
            return "(kMDItemFSName == \"*\(escaped)*\"cd)"
        }.joined(separator: " || ")
    }

    /// A Spotlight path re-spelled under `folder`, or nil when it is outside it or under a hidden
    /// folder. Spotlight answers with real paths, and iCloud’s Documents is reached through a link.
    nonisolated static func respell(_ path: String, folder: String, resolved: String, linked: [String] = []) -> String? {
        // Inside a folder linked from this one (iCloud's Documents is ~/Documents): Spotlight
        // answers with the real path, which is the spelling lookups use already.
        if let target = linked.first(where: { path.hasPrefix($0 + "/") }) {
            let relative = String(path.dropFirst(target.count + 1))
            return relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) ? nil : path
        }
        let base: String
        if path.hasPrefix(folder + "/") { base = folder } else if path.hasPrefix(resolved + "/") { base = resolved } else { return nil }
        let relative = String(path.dropFirst(base.count + 1))
        guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        // The real spelling, the one the pane's tree uses, so lookups and Edit agree (AskClaudePaths).
        return (resolved as NSString).appendingPathComponent(relative)
    }

    /// Results read per search: more than `maxExamined` keeps after its filters, and bounded so a
    /// common word across a whole drive can't hold the main thread reading tens of thousands.
    static let maxResultsRead = 5_000

    /// Runs `work` off the main thread and gives up on it after `timeout`. The work itself can’t be
    /// cancelled — a stalled `open()` holds its thread until it returns — so it is left to finish
    /// and its answer is dropped. **On a Dispatch thread, not a task**: a blocked read parked on
    /// Swift's shared task threads holds one of only a few, and a handful of stalled iCloud folders
    /// would starve every async task in the app.
    nonisolated private static func bounded<T: Sendable>(_ work: @escaping @Sendable () -> T?) async -> T? {
        // Stop answers at once too: the read is left to finish, as at the timeout.
        let once = OnceFlag()
        let resume = ContinuationBox<T?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                resume.set(continuation)
                if Task.isCancelled, once.claim() { resume.resume(nil); return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let value = work()
                    if once.claim() { resume.resume(value) }
                }
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    if once.claim() { resume.resume(nil) }
                }
            }
        } onCancel: {
            if once.claim() { resume.resume(nil) }
        }
    }
}

/// A continuation that may be resumed from a cancellation handler before it is even set.
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var early: T?
    private var hasEarly = false

    func set(_ continuation: CheckedContinuation<T, Never>) {
        lock.withLock {
            if hasEarly { continuation.resume(returning: early!) } else { self.continuation = continuation }
        }
    }

    func resume(_ value: T) {
        lock.withLock {
            if let continuation { continuation.resume(returning: value); self.continuation = nil } else { early = value; hasEarly = true }
        }
    }
}

/// True for the first caller only.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// One Spotlight name search, answered once: when the index has been read, or with nil at the
/// timeout. An object so the query, its observer and the continuation live in one place on the
/// main actor, where `NSMetadataQuery` posts.
@MainActor
private final class SpotlightNameQuery {
    private let query = NSMetadataQuery()
    private let folder: String
    private let resolved: String
    /// Folders linked from this one, by their real paths: searched too, as Spotlight indexes
    /// them where they really are.
    private let linked: [String]
    private let predicate: NSPredicate?
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<[String]?, Never>?

    init(query: String, folder: String) {
        self.folder = folder
        self.resolved = (folder as NSString).resolvingSymlinksInPath
        self.linked = AskClaudePaths.aliases(of: folder).map(\.real)
        self.predicate = NSPredicate(fromMetadataQueryString: query)
    }

    func run() async -> [String]? {
        guard let predicate else { return nil }
        query.predicate = predicate
        // The real folder: Spotlight may not follow a link (iCloud's Documents is one).
        query.searchScopes = ([resolved] + linked).map { URL(fileURLWithPath: $0, isDirectory: true) }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.gathered() }
            }
            guard query.start() else { finish(nil); return }
            Task { [weak self] in
                try? await Task.sleep(for: AskClaudeDisk.timeout)
                self?.finish(nil)
            }
        }
    }

    private func gathered() {
        query.disableUpdates()
        var paths: [String] = []
        for index in 0..<min(query.resultCount, AskClaudeDisk.maxResultsRead) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let spelled = AskClaudeDisk.respell(path, folder: folder, resolved: resolved, linked: linked) else { continue }
            paths.append(spelled)
        }
        finish(paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    private func finish(_ paths: [String]?) {
        guard let continuation else { return }
        self.continuation = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        query.stop()
        continuation.resume(returning: paths)
    }
}
