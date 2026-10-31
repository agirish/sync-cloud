import AppKit
import Combine
import Darwin
import Events
import FileProvider
import Foundation
import Sync

/// **The one status per provider**, shared by the panes, the source menu, the sidebar and
/// Activity — and, later, one-way sync (RD67).
@MainActor
public final class CloudAppMonitor: ObservableObject {
    public static let shared = CloudAppMonitor()

    /// What the monitor asks of the system — swapped in tests.
    public struct System: Sendable {
        public var isRunning: @Sendable (CloudApp) -> Bool
        public var iCloudAvailable: @Sendable () -> Bool
        /// Whether File Provider still knows this account folder. Blocks; asked off the pool, and a
    /// "known" answer is kept until the sources change or the Mac wakes.
        public var isLiveAccount: @Sendable (String) -> Bool
        public var reading: @Sendable (String) -> CloudAppStatusModel.UploadReading
        public var unanswered: @Sendable () -> [String]
        public var changes: @Sendable () -> [(path: String, at: Date)]
        /// Where the app is installed, or nil. A LaunchServices call; asked off the main thread.
        public var appURL: @Sendable (CloudApp) -> URL?
        /// When the app's running process started, or nil when unknown: the Dropbox gate's five
        /// minutes count from it, not from when SyncCloud first saw it (RD67).
        public var startedAt: @Sendable (CloudApp) -> Date?

        public init(isRunning: @escaping @Sendable (CloudApp) -> Bool,
                    iCloudAvailable: @escaping @Sendable () -> Bool,
                    isLiveAccount: @escaping @Sendable (String) -> Bool,
                    reading: @escaping @Sendable (String) -> CloudAppStatusModel.UploadReading,
                    unanswered: @escaping @Sendable () -> [String],
                    changes: @escaping @Sendable () -> [(path: String, at: Date)],
                    appURL: @escaping @Sendable (CloudApp) -> URL? = { _ in nil },
                    startedAt: @escaping @Sendable (CloudApp) -> Date? = { _ in nil }) {
            self.isRunning = isRunning
            self.iCloudAvailable = iCloudAvailable
            self.isLiveAccount = isLiveAccount
            self.reading = reading
            self.unanswered = unanswered
            self.changes = changes
            self.appURL = appURL
            self.startedAt = startedAt
        }

        public static let live = System(
            isRunning: { !RunningBundles.shared.identifiers().isDisjoint(with: $0.bundleIdentifiers) },
            iCloudAvailable: { FileManager.default.ubiquityIdentityToken != nil },
            isLiveAccount: { CloudAppMonitor.fileProviderKnows($0) },
            reading: { CloudAppStatusModel.reading(at: $0) },
            unanswered: { FileSyncManager.DatalessFolderReads.shared.unansweredPaths() },
            changes: { ChangedFileLedger.shared.drain() },
            appURL: { app in
                app.bundleIdentifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
            },
            startedAt: { RunningBundles.shared.earliestStart(of: $0.bundleIdentifiers) })
    }

    @Published public private(set) var problems: [String: CloudAppProblem] = [:]
    @Published public private(set) var skipped: [String: [CloudSkippedFile]] = [:]
    /// The rows Activity ▸ Now shows: every notice not dismissed at its current signature.
    @Published public private(set) var notices: [CloudAppNotice] = []

    private var model = CloudAppStatusModel()
    /// The status as the rules hold it, for one-way sync's Dropbox gate (RD67).
    public var statusModel: CloudAppStatusModel { model }
    /// When the Mac last woke while SyncCloud ran: the gate's five minutes count from it too.
    public private(set) var lastWake: Date?
    private var providers: [CloudProvider] = []
    private var disabled: Set<String> = []
    /// Dismissed notices, by id, at the signature they had.
    private var dismissed: [String: String] = [:]
    private let system: System
    private let clock: () -> Date
    private var observers: [NSObjectProtocol] = []
    private var runningApps: NSKeyValueObservation?
    /// File Provider's answer per account folder, asked again only when the sources change or the
    /// Mac wakes: the call blocks its thread, measured over a second once, and an account does not
    /// come and go between ticks.
    private var liveAccounts: [String: Bool] = [:]
    /// Where each app is installed, read with the rest of a refresh — so a view asking whether it
    /// can offer Open never makes a LaunchServices call while it renders.
    private var appURLs: [CloudApp: URL] = [:]
    /// Who ran at the last refresh, so a launch or a quit is logged once.
    private var lastRunning: Set<CloudApp>?
    private var ticker: Task<Void, Never>?
    private var refreshing: Task<Void, Never>?
    private var refreshAgain = false
    private var slowHalf: Task<Void, Never>?

    /// How often the status is re-read while nothing announces a change: the grace and the upload
    /// deadline pass on their own.
    static let tick: Duration = .seconds(30)

    public init(system: System = .live, clock: @escaping () -> Date = Date.init) {
        self.system = system
        self.clock = clock
    }

    /// The problem to show for this source, if any is known.
    public func problem(for providerId: String) -> CloudAppProblem? { problems[providerId] }

    /// The sources to report on: every provider, with the ones turned off in Settings named.
    public func setProviders(_ providers: [CloudProvider], disabled: Set<String>) {
        guard providers != self.providers || disabled != self.disabled else { return }
        self.providers = providers
        self.disabled = disabled
        liveAccounts = [:]
        requestRefresh()
    }

    /// Starts watching: the running apps, unanswered folders, the iCloud account, wake, and a slow
    /// tick. Idempotent.
    public func start() {
        guard ticker == nil else { return }
        // **Key-value observing the running apps, not the launch and quit notifications.** macOS
        // posts those for no app with `LSUIElement` — and Dropbox, OneDrive and Google Drive are all
        // menu-bar apps: quit and reopened on 2026-10-30, not one notification arrived. The list
        // itself does change for them. A change only asks for a refresh, which reads who runs off
        // the main thread — so a launch clears its warning in that refresh, not at the next tick.
        runningApps = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            Task { @MainActor in self?.requestRefresh() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastWake = self?.clock()
                self?.liveAccounts = [:]
                self?.requestRefresh()
            }
        })
        for name in [FileSyncManager.DatalessFolderReads.unansweredDidChange, .NSUbiquityIdentityDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestRefresh() }
            })
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.requestRefresh()
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    /// **The user asked about these sources** (decision DN) — picked one in a pane, opened a
    /// source menu, or showed Settings ▸ Sources. Their apps are checked now, and one that is not
    /// running says so at once, without the grace. Ids that are not a cloud app's are ignored.
    public func checkNow(_ providerIds: [String]) {
        Task { await check(providerIds) }
    }

    /// `checkNow`, awaitable — what a test drives.
    func check(_ providerIds: [String]) async {
        let ids = Set(providerIds)
        let apps = Set(providers.filter { ids.contains($0.id) && !disabled.contains($0.id) }.compactMap { CloudApp($0.type) })
        guard !apps.isEmpty else { return }
        let system = self.system
        let running = await Self.offPool(qos: .userInitiated) { Set(apps.filter(system.isRunning)) }
        let now = clock()
        for app in apps.sorted() {
            let isRunning = running.contains(app)
            if !isRunning, !model.askedWhileMissing.contains(app) {
                Logger.shared.info("Cloud app status: \(app.name) isn’t running — asked about, so said at once")
            }
            model.asked(app, isRunning: isRunning, at: now)
        }
        publish()
    }

    /// Hides `notice` until what it says changes.
    public func dismiss(_ notice: CloudAppNotice) {
        dismissed[notice.id] = notice.signature
        publish()
    }

    /// Re-reads the status, coalescing: a request while one runs runs once more after it.
    ///
    /// **In two halves, so one stuck call cannot freeze it.** Who runs, the iCloud account and the
    /// unanswered folders are read every time. Upload states, File Provider and LaunchServices —
    /// calls into other processes that have hung before — go in a second half with its own
    /// in-flight guard: while one is stuck, the first half still clears a warning on a launch.
    func requestRefresh() {
        guard refreshing == nil else { refreshAgain = true; return }
        refreshing = Task { [weak self] in
            await self?.refreshRunning()
            guard let self else { return }
            self.startSlowHalf()
            self.refreshing = nil
            if self.refreshAgain {
                self.refreshAgain = false
                self.requestRefresh()
            }
        }
    }

    /// Both halves, in turn — what a test awaits.
    func refresh() async {
        await refreshRunning()
        await refreshUploadsAndAccounts()
    }

    private func startSlowHalf() {
        guard slowHalf == nil else { return }
        slowHalf = Task { [weak self] in
            await self?.refreshUploadsAndAccounts()
            self?.slowHalf = nil
        }
    }

    /// Who runs, the iCloud account, the unanswered folders.
    private func refreshRunning() async {
        let now = clock()
        let system = self.system
        // `.userInitiated`: a launch clears its warning through this half, and on a busy Mac a
        // `.utility` thread waited minutes (hosted CI, 2026-10-30).
        let (running, iCloudAvailable, starts) = await Self.offPool(qos: .userInitiated) { () -> (Set<CloudApp>, Bool, [CloudApp: Date]) in
            let running = Set(CloudApp.allCases.filter(system.isRunning))
            var starts: [CloudApp: Date] = [:]
            for app in running { starts[app] = system.startedAt(app) }
            return (running, system.iCloudAvailable(), starts)
        }
        for app in CloudApp.allCases { model.app(app, isRunning: running.contains(app), at: now, startedAt: starts[app]) }
        if let lastRunning, lastRunning != running {
            for app in running.subtracting(lastRunning).sorted() { Logger.shared.info("Cloud app status: \(app.name) is running") }
            for app in lastRunning.subtracting(running).sorted() {
                Logger.shared.info("Cloud app status: \(app.name) quit — its sources say so if it isn’t back in 5 minutes")
            }
        }
        lastRunning = running
        model.iCloudAvailable = iCloudAvailable
        model.unanswered = system.unanswered()
        publish()
    }

    /// What SyncCloud changed and whether it uploaded, which accounts File Provider still knows,
    /// and where each app is installed.
    private func refreshUploadsAndAccounts() async {
        let system = self.system
        let sources = providers.filter { !$0.isLocalFolder && !disabled.contains($0.id) }
        let coverage = FileLocation.coverage(of: sources, disabledProviderIds: [])
        let changes = system.changes()
        let watched = model.watchedPaths
        let accounts = sources.compactMap { source in Self.accountFolder(of: source).map { (source.id, $0) } }
        let known = liveAccounts
        let (kept, readings, asked, urls) = await Self.offPool {
            // A change made through a link into an account — `~/Dropbox/…`, `~/OneDrive/…` — is
            // spelled through the link; coverage knows the account by its real folder.
            // The folder is resolved, not the file: a path whose last part is gone resolves nothing.
            let kept: [(String, Date)] = changes.compactMap { change in
                if FileLocation.covering(path: change.path, in: coverage) != nil { return (change.path, change.at) }
                let url = URL(fileURLWithPath: change.path)
                let real = url.deletingLastPathComponent().resolvingSymlinksInPath()
                    .appendingPathComponent(url.lastPathComponent).path
                return FileLocation.covering(path: real, in: coverage) != nil ? (real, change.at) : nil
            }
            // Read the new ones in this same pass, not the next.
            let readings = Set(watched + kept.map(\.0)).map { ($0, system.reading($0)) }
            // Only a "known" answer is kept; a failure is asked again, so one bad moment of
            // File Provider never hides a source until the next wake.
            var asked: [String: Bool] = [:]
            for (_, folder) in accounts where known[folder] != true { asked[folder] = system.isLiveAccount(folder) }
            let urls = Dictionary(uniqueKeysWithValues: CloudApp.allCases.compactMap { app in system.appURL(app).map { (app, $0) } })
            return (kept, readings, asked, urls)
        }
        let now = clock()
        for (path, at) in kept { model.noteChanged(path, at: at) }
        model.trimToLimit()
        for (path, reading) in readings { model.record(reading, for: path, at: now) }
        appURLs = urls
        for (folder, live) in asked where live { liveAccounts[folder] = true }
        let leftovers = Set(accounts.filter { asked[$0.1] == false }.map(\.0))
        if leftovers != model.leftoverIds {
            Logger.shared.debug("Cloud app status: leftover account folders, shown nothing: \(leftovers.sorted())")
        }
        model.leftoverIds = leftovers
        publish()
    }

    private func publish() {
        let now = clock()
        let problems = model.problems(for: providers, disabled: disabled, now: now)
        let skipped = model.skipped(for: providers, disabled: disabled)
        if problems != self.problems {
            for (id, problem) in problems where self.problems[id] != problem {
                Logger.shared.info("Cloud app status: \(id) — \(problem.shortLabel)")
            }
            for id in self.problems.keys where problems[id] == nil {
                Logger.shared.info("Cloud app status: \(id) — no problem known")
            }
            self.problems = problems
        }
        if skipped != self.skipped { self.skipped = skipped }
        // Activity's rows appear on their own, so they keep the grace even for an app the user
        // asked about (DN); the panes, menus and sidebar do not.
        let unasked = model.problems(for: providers, disabled: disabled, now: now, waitingOutTheGrace: true)
        let current = CloudAppNotice.notices(problems: unasked, skipped: skipped, providers: providers, now: now)
        // A row that went away forgets its dismissal: the same problem coming back is a change.
        dismissed = dismissed.filter { id, _ in current.contains { $0.id == id } }
        let notices = current.filter { dismissed[$0.id] != $0.signature }
        if notices != self.notices { self.notices = notices }
    }

    // MARK: Doors

    /// Whether the app is installed here, so an Open button can do something.
    public func canOpen(_ app: CloudApp) -> Bool { appURLs[app] != nil }

    /// Starts the app by bundle ID. The provider settings door opens nothing for Dropbox or
    /// OneDrive, so this does not go through it.
    public func open(_ app: CloudApp) {
        guard let url = appURLs[app] else { return }
        Logger.shared.info("Cloud app status: opening \(app.name)")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    public func openICloudSettings() {
        let iCloud = CloudProvider(id: "", displayName: "", imageName: "", rootPath: "", type: .iCloud)
        if case .systemSettings(let url) = iCloud.settingsDoor { NSWorkspace.shared.open(url) }
    }

    public func perform(_ action: CloudAppNotice.Action) {
        switch action {
        case .open(let app): open(app)
        case .openICloudSettings: openICloudSettings()
        case .show(let paths): NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        }
    }

    // MARK: File Provider

    /// The CloudStorage account folder a source lives in, or nil when it is not in one (iCloud, a
    /// Location moved elsewhere) — then there is nothing to ask File Provider.
    static func accountFolder(of provider: CloudProvider) -> String? {
        let components = (provider.rootPath as NSString).pathComponents
        for index in components.indices.dropLast().reversed()
        where components[index] == "Library" && components[index + 1] == "CloudStorage" {
            guard index + 2 < components.count else { return nil }
            return NSString.path(withComponents: Array(components[0...(index + 2)]))
        }
        return nil
    }

    /// Whether File Provider still knows `folder`. A failure means the account is gone and the
    /// folder a leftover. No answer in 5 s is taken as live: an unknown is never a reason to hide.
    /// Blocks the calling thread — even the call itself, before its answer, held one 1.2 s
    /// (sampled 2026-10-30) — so it is only ever asked through `offPool`.
    nonisolated static func fileProviderKnows(_ folder: String) -> Bool {
        let answered = DispatchSemaphore(value: 0)
        let known = KnownBox()
        NSFileProviderManager.getIdentifierForUserVisibleFile(at: URL(fileURLWithPath: folder)) { _, _, error in
            known.set(error == nil)
            answered.signal()
        }
        guard answered.wait(timeout: .now() + 5) == .success else { return true }
        return known.value
    }

    private final class KnownBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = true
        func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Runs `body` on a dispatch thread, which may block, and hands back its answer — never on the
    /// cooperative pool, whose threads a blocked call to another process would take from every task.
    nonisolated static func offPool<T: Sendable>(qos: DispatchQoS.QoSClass = .utility,
                                                 _ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(returning: body()) }
        }
    }
}

/// **Which app bundles have a process running, asked of the kernel** — never of LaunchServices.
///
/// Two LaunchServices routes failed here, both measured 2026-10-30: reading `bundleIdentifier` off
/// every `NSRunningApplication` is a synchronous LaunchServices round trip each, and on the main
/// thread it held the app 42 s while three cloud apps quit; and
/// `NSRunningApplication.runningApplications(withBundleIdentifier:)`, asked off the main thread,
/// answered "none running" and "all running" 4 ms apart at launch, again and again. So: every
/// process's executable path from the kernel, the bundle it sits in, and that bundle's identifier
/// from its own `Info.plist` — read once per bundle and kept.
final class RunningBundles: @unchecked Sendable {
    static let shared = RunningBundles()

    private let lock = NSLock()
    /// Bundle path → its identifier.
    private var identifierByBundle: [String: String] = [:]

    /// The identifiers of every app bundle with a process running now.
    func identifiers() -> Set<String> {
        var answer: Set<String> = []
        for path in Self.executablePaths() {
            guard let bundle = Self.bundlePath(ofExecutable: path), let id = identifier(ofBundle: bundle) else { continue }
            answer.insert(id)
        }
        return answer
    }

    private func identifier(ofBundle bundle: String) -> String? {
        lock.lock()
        if let known = identifierByBundle[bundle] { lock.unlock(); return known }
        lock.unlock()
        let plist = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist")
        // Not kept when unreadable: an app updating itself has no Info.plist for a moment, and a
        // kept nil would make it "not running" for the rest of the session.
        guard let id = plist?["CFBundleIdentifier"] as? String else { return nil }
        lock.lock()
        identifierByBundle[bundle] = id
        lock.unlock()
        return id
    }

    /// `/Applications/Dropbox.app/Contents/MacOS/Dropbox` → `/Applications/Dropbox.app`. The LAST
    /// `/Contents/MacOS/`, so an app nested inside another is its own bundle.
    static func bundlePath(ofExecutable path: String) -> String? {
        guard let range = path.range(of: "/Contents/MacOS/", options: .backwards) else { return nil }
        return String(path[..<range.lowerBound])
    }

    /// When the earliest of this user's processes from a bundle with one of `identifiers` started,
    /// read from the kernel (`pbi_start_tvsec`); nil when none runs.
    func earliestStart(of identifiers: [String]) -> Date? {
        let wanted = Set(identifiers)
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let user = getuid()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        var earliest: Date?
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize, info.pbi_uid == user,
                  proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  let bundle = Self.bundlePath(ofExecutable: String(cString: buffer)),
                  let id = identifier(ofBundle: bundle), wanted.contains(id) else { continue }
            let start = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
            earliest = min(earliest ?? start, start)
        }
        return earliest
    }

    /// Every running process's executable path — this user's only: another user logged in on the
    /// same Mac running Dropbox does not sync this user's Dropbox.
    static func executablePaths() -> [String] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let user = getuid()
        let infoSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        return pids.prefix(Int(count)).compactMap { pid in
            var info = proc_bsdshortinfo()
            guard pid > 0, proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, infoSize) == infoSize,
                  info.pbsi_uid == user,
                  proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(cString: buffer)
        }
    }
}
