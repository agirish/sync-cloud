import FileProvider
import Foundation

/// **When a cloud app isn't syncing, its files look current and are not** (RD68, decision DK).
///
/// With the Dropbox, OneDrive or Google Drive app quit, the account's folder is still on disk and
/// still lists — in SyncCloud and in Finder — but nothing another device changed arrives, and a
/// folder not downloaded to this Mac won't open. Measured 2026-10-30 with Dropbox quit: writes made
/// here still uploaded, server-side changes never arrived until the app ran again. So every surface
/// that shows a provider says so, from this one status per provider.
///
/// What it can see, and nothing more — "nothing is shown when no problem is known", never a green
/// "syncing":
///
/// - **Not running**: the vendor's app, by bundle ID, missing for `notRunningGrace` — at any time,
///   not only at login, so a restart in progress never flashes a warning. Cleared the moment the app
///   launches.
/// - **Not responding**: a folder not downloaded to this Mac whose listing passed its deadline
///   (`DatalessFolderReads`, 5 s). Dropbox keeps every file here, so it never gets this one.
/// - **iCloud off**: no iCloud account token — signed out, or iCloud Drive turned off. The token
///   reads without any iCloud entitlement (measured on an unsigned probe).
/// - **Not uploading**: a file SyncCloud itself changed (`ChangedFileLedger`) still not uploaded
///   `uploadDeadline` later. Never a walk of a provider. A file the provider refuses is skipped,
///   not "not uploading".
///
/// An account folder File Provider no longer knows (`getIdentifierForUserVisibleFile` fails) is a
/// leftover whose account is gone, and gets nothing. A source turned off in Settings gets nothing.
public enum CloudApp: String, CaseIterable, Sendable, Comparable {
    case dropbox
    case oneDrive
    case googleDrive

    public init?(_ type: CloudProvider.ProviderType) {
        switch type {
        case .dropBox: self = .dropbox
        case .oneDrive: self = .oneDrive
        case .googleDrive: self = .googleDrive
        case .iCloud, .localFolder: return nil
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .dropbox: return "com.getdropbox.dropbox"
        case .oneDrive: return "com.microsoft.OneDrive-mac"
        case .googleDrive: return "com.google.drivefs"
        }
    }

    public var name: String {
        switch self {
        case .dropbox: return "Dropbox"
        case .oneDrive: return "OneDrive"
        case .googleDrive: return "Google Drive"
        }
    }

    public static func < (a: CloudApp, b: CloudApp) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// What is known to be wrong with one provider's syncing — the worst of what applies.
public enum CloudAppProblem: Equatable, Sendable {
    case notRunning(CloudApp)
    case notResponding
    case iCloudOff
    /// Files SyncCloud changed in this source, still not uploaded; `since` is the oldest change.
    case notUploading(paths: [String], since: Date)

    /// The words beside an amber dot in the source menu and the sidebar.
    public var shortLabel: String {
        switch self {
        case .notRunning: return "not running"
        case .notResponding: return "not responding"
        case .iCloudOff: return "signed out or off"
        case .notUploading: return "not uploading"
        }
    }
}

/// A file SyncCloud changed that the provider refuses to take — listed as skipped, not as a sync
/// problem.
public struct CloudSkippedFile: Equatable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// **The rules, with no system behind them** — what the monitor publishes, as a function of what
/// it has seen. A value, so a test can put it in any state and read the answer.
public struct CloudAppStatusModel: Sendable {

    /// How long an app must be missing before it is called not running.
    public static let notRunningGrace: TimeInterval = 5 * 60
    /// How long a file SyncCloud changed may wait to upload before it is called not uploading.
    public static let uploadDeadline: TimeInterval = 30 * 60

    /// What an upload looks like from here, read off the file's resource values.
    public enum UploadReading: Equatable, Sendable {
        case uploaded
        case pending
        case refused(String)
        /// Gone, not in a cloud folder, or not saying — never a problem.
        case unknown
    }

    struct ChangedFile: Equatable, Sendable {
        var changedAt: Date
        var reading: UploadReading = .pending
    }

    /// When each app was first seen missing; absent while it runs.
    public private(set) var missingSince: [CloudApp: Date] = [:]
    /// Folders not downloaded to this Mac that did not answer.
    public var unanswered: [String] = []
    public var iCloudAvailable = true
    /// Provider ids whose account folder File Provider no longer knows.
    public var leftoverIds: Set<String> = []
    private(set) var changed: [String: ChangedFile] = [:]

    /// The most changed files watched at once; the oldest go first.
    static let watchLimit = 1000

    public init() {}

    // MARK: Facts in

    /// The app was seen running, or seen missing at `now`. Missing keeps the FIRST time it was seen
    /// missing, so a refresh does not restart the grace; running clears it at once.
    public mutating func app(_ app: CloudApp, isRunning: Bool, at now: Date) {
        if isRunning {
            missingSince[app] = nil
        } else if missingSince[app] == nil {
            missingSince[app] = now
        }
    }

    /// SyncCloud changed the file at `path` at `now`. A later change restarts its wait — the
    /// provider may hold an upload while a file keeps changing.
    public mutating func noteChanged(_ path: String, at now: Date) {
        changed[path] = ChangedFile(changedAt: now)
        if changed.count > Self.watchLimit {
            let oldest = changed.sorted { $0.value.changedAt < $1.value.changedAt }
                .prefix(changed.count - Self.watchLimit)
            for (path, _) in oldest { changed[path] = nil }
        }
    }

    /// Paths whose upload is still worth reading.
    public var watchedPaths: [String] { changed.keys.sorted() }

    /// What a file's upload looks like now. Uploaded or unknown stops watching it.
    public mutating func record(_ reading: UploadReading, for path: String) {
        guard changed[path] != nil else { return }
        switch reading {
        case .uploaded, .unknown: changed[path] = nil
        case .pending, .refused: changed[path]?.reading = reading
        }
    }

    // MARK: Answers out

    /// Each enabled cloud source's problem, by provider id. A source with no known problem is
    /// absent — there is no "fine" entry to draw.
    public func problems(for providers: [CloudProvider], disabled: Set<String>,
                         now: Date) -> [String: CloudAppProblem] {
        let sources = providers.filter { !$0.isLocalFolder && !disabled.contains($0.id) && !leftoverIds.contains($0.id) }
        let coverage = FileLocation.coverage(of: sources, disabledProviderIds: [])
        func owner(_ path: String) -> String? { FileLocation.covering(path: path, in: coverage)?.providerId }

        let silent = Set(unanswered.compactMap(owner))
        var waiting: [String: [(String, Date)]] = [:]
        for (path, file) in changed where file.reading == .pending && now.timeIntervalSince(file.changedAt) >= Self.uploadDeadline {
            if let id = owner(path) { waiting[id, default: []].append((path, file.changedAt)) }
        }

        var answer: [String: CloudAppProblem] = [:]
        for source in sources {
            if source.type == .iCloud, !iCloudAvailable {
                answer[source.id] = .iCloudOff
            } else if let app = CloudApp(source.type), let since = missingSince[app],
                      now.timeIntervalSince(since) >= Self.notRunningGrace {
                answer[source.id] = .notRunning(app)
            } else if silent.contains(source.id) {
                answer[source.id] = .notResponding
            } else if let files = waiting[source.id] {
                answer[source.id] = .notUploading(paths: files.map(\.0).sorted(),
                                                  since: files.map(\.1).min()!)
            }
        }
        return answer
    }

    /// Files each enabled source refused, by provider id.
    public func skipped(for providers: [CloudProvider], disabled: Set<String>) -> [String: [CloudSkippedFile]] {
        let sources = providers.filter { !$0.isLocalFolder && !disabled.contains($0.id) && !leftoverIds.contains($0.id) }
        let coverage = FileLocation.coverage(of: sources, disabledProviderIds: [])
        var answer: [String: [CloudSkippedFile]] = [:]
        for (path, file) in changed {
            guard case .refused(let reason) = file.reading,
                  let id = FileLocation.covering(path: path, in: coverage)?.providerId else { continue }
            answer[id, default: []].append(CloudSkippedFile(path: path, reason: reason))
        }
        return answer.mapValues { $0.sorted { $0.path < $1.path } }
    }

    // MARK: Reading an upload

    /// Whether an upload error is the provider refusing THIS file — its name, or a kind it never
    /// syncs — rather than the account or the network being in the way, which is "not uploading".
    public static func isRefusal(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSFileProviderErrorDomain else { return false }
        return [NSFileProviderError.Code.filenameCollision.rawValue,
                NSFileProviderError.Code.cannotSynchronize.rawValue,
                NSFileProviderError.Code.excludedFromSync.rawValue].contains(error.code)
    }

    /// Reads a file's upload state. **Only an explicit "not uploaded" counts**: a file that is gone,
    /// outside every cloud folder, or not answering the key is `.unknown`.
    ///
    /// Hidden files are never watched — measured 2026-10-30: Dropbox reports its ignored
    /// `.DS_Store` as not uploaded, with no error, for good.
    public static func reading(at path: String) -> UploadReading {
        guard !(path as NSString).lastPathComponent.hasPrefix(".") else { return .unknown }
        // A fresh URL each time: a URL caches its resource values.
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                                             .ubiquitousItemUploadingErrorKey]),
              values.isUbiquitousItem == true, let uploaded = values.ubiquitousItemIsUploaded else { return .unknown }
        if uploaded { return .uploaded }
        if let error = values.ubiquitousItemUploadingError, isRefusal(error) {
            return .refused(error.localizedDescription)
        }
        return .pending
    }
}

/// **Every file SyncCloud put in place**, kept for the cloud app status to watch its upload
/// (RD68). Written from any thread by the copy and move primitives and Edit's saves; drained by
/// the monitor, which keeps only the ones inside a cloud source.
public final class ChangedFileLedger: @unchecked Sendable {
    public static let shared = ChangedFileLedger()

    private let lock = NSLock()
    private var pending: [(path: String, at: Date)] = []
    /// Bounded: a monitor that never drains (a test process, the CLI) holds at most this many.
    static let limit = 1000

    public init() {}

    public func note(_ path: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        pending.append((path, date))
        if pending.count > Self.limit { pending.removeFirst(pending.count - Self.limit) }
    }

    public func drain() -> [(path: String, at: Date)] {
        lock.lock(); defer { lock.unlock() }
        let drained = pending
        pending = []
        return drained
    }
}

/// A row Activity ▸ Now shows for a cloud app that isn't syncing — information, no notification.
public struct CloudAppNotice: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case open(CloudApp)
        case openICloudSettings
        case show([String])

        public var title: String {
            switch self {
            case .open(let app): return "Open \(app.name)"
            case .openICloudSettings: return "Open iCloud Settings"
            case .show: return "Show Them"
            }
        }
    }

    /// The kind of row, stable while the state changes.
    public let id: String
    /// What the row says; a dismissed row comes back when this changes.
    public let signature: String
    public let title: String
    public let detail: String
    public let actions: [Action]

    /// The rows for these problems and skipped files, over these providers. Folds every app that
    /// isn't running into one row, and every one not responding into another, the way the design
    /// draws them.
    public static func notices(problems: [String: CloudAppProblem], skipped: [String: [CloudSkippedFile]],
                               providers: [CloudProvider], now: Date) -> [CloudAppNotice] {
        let byId = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func app(_ id: String) -> CloudApp? { byId[id].flatMap { CloudApp($0.type) } }
        var rows: [CloudAppNotice] = []

        let stopped = problems.filter { if case .notRunning = $0.value { return true }; return false }
        if !stopped.isEmpty {
            let apps = Set(stopped.keys.compactMap(app)).sorted()
            let names = list(apps.map(\.name))
            let folders = stopped.count
            rows.append(CloudAppNotice(
                id: "not-running",
                signature: stopped.keys.sorted().joined(separator: ","),
                title: "\(names) \(apps.count == 1 ? "isn’t" : "aren’t") running",
                detail: "Files in \(apps.count == 1 ? "its" : "their") \(folders == 1 ? "folder" : "\(folders) folders") "
                    + "may be out of date, here and in Finder",
                actions: apps.map { .open($0) }))
        }

        let silent = problems.filter { $0.value == .notResponding }
        if !silent.isEmpty {
            let names = Set(silent.keys.map { app($0)?.name ?? byId[$0]?.displayName ?? $0 }).sorted()
            rows.append(CloudAppNotice(
                id: "not-responding",
                signature: silent.keys.sorted().joined(separator: ","),
                title: "\(list(names)) \(names.count == 1 ? "isn’t" : "aren’t") responding",
                detail: "A folder not downloaded to this Mac didn’t open within 5 seconds, so files may be "
                    + "out of date, here and in Finder",
                actions: []))
        }

        if problems.values.contains(.iCloudOff) {
            rows.append(CloudAppNotice(
                id: "icloud-off", signature: "icloud-off",
                title: "iCloud is signed out, or iCloud Drive is off",
                detail: "Files in iCloud Drive may be out of date, here and in Finder",
                actions: [.openICloudSettings]))
        }

        for (id, problem) in problems.sorted(by: { $0.key < $1.key }) {
            guard case .notUploading(let paths, let since) = problem else { continue }
            let name = byId[id]?.displayName ?? id
            let minutes = max(1, Int(now.timeIntervalSince(since) / 60))
            rows.append(CloudAppNotice(
                id: "not-uploading-\(id)",
                signature: paths.joined(separator: "\n"),
                title: "\(name) hasn’t uploaded \(paths.count == 1 ? "a file" : "\(paths.count) files") for \(minutes) min",
                detail: "\(paths.count == 1 ? "A file" : "Files") SyncCloud changed here \(paths.count == 1 ? "isn’t" : "aren’t") "
                    + "on your other devices yet",
                actions: [.show(paths)]))
        }

        for (id, files) in skipped.sorted(by: { $0.key < $1.key }) where !files.isEmpty {
            let name = app(id)?.name ?? byId[id]?.displayName ?? id
            let names = files.prefix(3).map { ($0.path as NSString).lastPathComponent }
            rows.append(CloudAppNotice(
                id: "skipped-\(id)",
                signature: files.map(\.path).joined(separator: "\n"),
                title: "\(files.count == 1 ? "1 item" : "\(files.count) items") skipped · \(name) won’t take "
                    + (files.count == 1 ? "it" : "them"),
                detail: names.joined(separator: ", ") + (files.count > 3 ? " and \(files.count - 3) more" : "")
                    + " · not a sync problem",
                actions: [.show(files.map(\.path))]))
        }
        return rows
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
