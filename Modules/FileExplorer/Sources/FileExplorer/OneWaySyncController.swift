import AppKit
import Combine
import Events
import Foundation
import Sync
import UserNotifications

/// What the toolbar's one-way sync chip says: the first rung that applies (the page's ladder).
public enum OneWaySyncLadder: Equatable, Sendable {
    case stopped(String)
    case needsYou(Int)
    case paused(since: Date)
    case syncing(String)
    case upToDate(asOf: Date, skipped: Int)
    case syncedByAnotherMac(lastSync: Date?)
    /// Set up, nothing synced yet.
    case notYetSynced

    public var isProblem: Bool {
        switch self {
        case .stopped, .needsYou: return true
        default: return false
        }
    }

    public func title(now: Date = Date()) -> String {
        switch self {
        case .stopped(let why): return why
        case .needsYou(let count): return count == 1 ? "1 needs you" : "\(count) need you"
        case .paused(let since): return "Paused since \(Self.clock(since, now: now))"
        case .syncing(let what): return what
        case .upToDate(let asOf, let skipped):
            return "Up to date as of \(Self.clock(asOf, now: now))" + (skipped > 0 ? " · \(skipped) skipped" : "")
        case .syncedByAnotherMac(let last):
            guard let last else { return "Synced by another Mac" }
            return "Synced by another Mac · \(Self.ago(last, now: now))"
        case .notYetSynced: return "One-way sync not run yet"
        }
    }

    /// 14:02 today, else "30 Oct, 14:02".
    static func clock(_ date: Date, now: Date) -> String {
        let format = Calendar.current.isDate(date, inSameDayAs: now) ? Date.FormatStyle(date: .omitted, time: .shortened)
            : Date.FormatStyle(date: .abbreviated, time: .shortened)
        return date.formatted(format)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 60 { return "\(max(1, minutes)) min ago" }
        if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / (24 * 60)) days ago"
    }
}

/// A sheet one-way sync opens, from Now, History, Settings or the toolbar.
public enum OneWaySyncSheet: Identifiable, Equatable {
    /// Setup, or *Review First Run…* (`replacing` an earlier sync's record).
    case setup(replacing: Bool)
    /// *Choose Folders…*, from Settings.
    case chooseFolders
    /// The sync at a glance: its pair, how it stands, what needs you, Sync Now and Pause — from
    /// the differences bar's pill and Compare's sidebar.
    case overview
    /// *Review…* for the removal limit: in one folder, or across all.
    case review(folder: String?)
    case chooseVersion(OneWaySyncWait.Subject)
    case renameICloud(OneWaySyncWait.Subject)
    case reverse(UUID)
    case chooseItemsToEmpty
    case stoppedFiles
    /// The many file rows of one folder, folded into one.
    case group(String)

    public var id: String {
        switch self {
        case .setup(let replacing): return "setup:\(replacing)"
        case .chooseFolders: return "folders"
        case .overview: return "overview"
        case .review(let folder): return "review:\(folder ?? "")"
        case .chooseVersion(let subject): return "version:\(subject)"
        case .renameICloud(let subject): return "rename:\(subject)"
        case .reverse(let id): return "reverse:\(id)"
        case .chooseItemsToEmpty: return "empty"
        case .stoppedFiles: return "stopped"
        case .group(let folder): return "group:\(folder)"
        }
    }
}

/// The window a sheet opens over: the one whose button opened it.
public enum OneWaySyncSheetHost: Equatable, Sendable {
    case main
    case activity
}

/// Which side of the sync a pane shows (the panes' role chips).
public enum OneWaySyncPaneRole: Equatable, Sendable {
    case source
    case copy
}

/// What setup has chosen so far: the two parents and what is in them.
public struct OneWaySyncSetupDraft: Sendable {
    public var iCloudParent: URL
    public var dropboxParent: URL
    public var dropboxAccount: URL?
    public var iCloud: OneWaySyncSideListing
    public var dropbox: OneWaySyncSideListing
    public var choices: [OneWaySyncFolderChoice]
    /// Why these parents can't be used, or nil.
    public var problem: String?
}

/// **RD67's manual Sync Now** — the one place the app drives one-way sync from: setup and its
/// first run, *Sync Now*, the answers to Now's rows, Settings' controls, and what the toolbar,
/// the Compare strip and the panes say about it. No automatic trigger yet (step 4): a pass runs
/// only when asked.
///
/// The work itself is `Sync`'s (`OneWaySyncRun`, `OneWaySyncAnswers`), off the main thread; this
/// holds the saved state as last read, the lock, the watcher that tells the Dropbox gate what is
/// still arriving, and the rows.
@MainActor
public final class OneWaySyncController: ObservableObject {
    public static let shared = OneWaySyncController()

    @Published public private(set) var record: OneWaySyncRecord?
    @Published public private(set) var state: OneWaySyncSavedState?
    @Published public private(set) var exclusions = OneWaySyncExclusions()
    @Published public private(set) var firstRun: UUID?
    /// What stops the whole sync now, from the last pass or start check.
    @Published public internal(set) var stop: OneWaySyncStopReason?
    /// The Mac Dropbox's marker names, when it isn't this one.
    @Published public private(set) var otherMac: OneWaySyncMacMarker?
    /// What a pass is doing now; nil while none runs.
    @Published public private(set) var activity: String?
    /// The last pass's look: what Now's sheets read until a fresher one.
    @Published public private(set) var lastLook: OneWaySyncLook?
    @Published public private(set) var lastSkipped = 0
    @Published public var sheet: OneWaySyncSheet?
    /// Where `sheet` opens.
    @Published public internal(set) var sheetHost: OneWaySyncSheetHost = .main
    /// Why this copy of SyncCloud may not sync at all (a build outside /Applications, a test host).
    public let refusal: OneWaySyncLaunchRefusal?

    public let store: OneWaySyncStore?
    let center: ActivityCenter
    let cloudApps: CloudAppMonitor
    private var lock: OneWaySyncProcessLock?
    private var watcher: FolderWatcher?
    private var arrivals = OneWaySyncArrivals()
    private var running: Task<Void, Never>?
    /// Asked between a pass's steps, off the main thread: Pause and Stop reach a pass that writes.
    private let stopFlag = OneWaySyncStopFlag()
    /// An answer is writing: no pass starts until it is done, and no second answer.
    @Published public private(set) var isAnswering = false
    /// When the setup sheet opened: Start needs Dropbox running and quiet since.
    public private(set) var setupOpenedAt: Date?

    public init(store: OneWaySyncStore? = OneWaySyncStore.defaultDirectory().map(OneWaySyncStore.init),
                center: ActivityCenter = .shared, cloudApps: CloudAppMonitor = .shared,
                refusal: OneWaySyncLaunchRefusal? = OneWaySyncLaunchGate.refusalForThisProcess()) {
        self.store = store
        self.center = center
        self.cloudApps = cloudApps
        self.refusal = refusal
    }

    // MARK: State

    public var isSetUp: Bool { record != nil }
    public var isPaused: Bool { state?.pausedSince != nil }
    public var isRunning: Bool { running != nil }

    /// The toolbar's rung (the page's ladder), or nil before setup.
    public var ladder: OneWaySyncLadder? {
        if let otherMac { return .syncedByAnotherMac(lastSync: otherMac.lastSyncAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }) }
        guard isSetUp || stop != nil else { return nil }
        if let stop { return .stopped(OneWaySyncRows.stop(stop, at: Date()).title) }
        let waiting = center.oneWaySync.needsYou.count
        if waiting > 0 { return .needsYou(waiting) }
        if let since = state?.pausedSince { return .paused(since: Date(timeIntervalSince1970: TimeInterval(since))) }
        if let activity { return .syncing(activity) }
        if let last = state?.lastSyncAt { return .upToDate(asOf: Date(timeIntervalSince1970: TimeInterval(last)), skipped: lastSkipped) }
        return .notYetSynced
    }

    /// "4 folders · 3 need you", for the Compare strip and Settings.
    public var summary: String {
        guard let record else { return "Not set up" }
        var parts = [record.syncedFolders.count == 1 ? "1 folder" : "\(record.syncedFolders.count) folders"]
        if otherMac == nil, refusal == nil { parts.append("this Mac syncs") }
        let waiting = center.oneWaySync.needsYou.count
        if waiting > 0 { parts.append(waiting == 1 ? "1 needs you" : "\(waiting) need you") }
        return parts.joined(separator: " · ")
    }

    /// Why *Sync Now* can't run now, or nil.
    public var syncNowRefusal: String? {
        if refusal != nil { return "Only SyncCloud in Applications syncs" }
        if record == nil { return "Set up one-way sync first" }
        if isPaused { return "Paused — resume to sync" }
        if isRunning { return "A sync is running" }
        if isAnswering { return "Wait for the change you asked for to finish" }
        if otherMac != nil { return "Another Mac syncs this — Sync From This Mac Instead to take it over" }
        return nil
    }

    /// Takes a record and its state as if read from the store: a test's way in.
    func adopt(_ record: OneWaySyncRecord?, state: OneWaySyncSavedState?, firstRun: UUID? = UUID()) {
        self.record = record
        self.state = state
        self.firstRun = record == nil ? nil : firstRun
    }

    /// The two folders setup opens on (EE): Compare's panes, when one shows iCloud and the other
    /// Dropbox. Set by whoever opens setup; nil falls back to iCloud Drive ▸ Documents and
    /// Dropbox ▸ Documents.
    public var setupPrefill: (iCloud: URL, dropbox: URL)?
    /// Opens Activity on Now, and Settings on Sync: set by the app.
    public var onOpenActivity: () -> Void = {}
    /// Hears the paths SyncCloud's own sync wrote, so the panes read them again: the folder
    /// watcher marks this process's writes as its own, and a pane never re-reads them by itself.
    public var onWrote: @MainActor ([String]) -> Void = { _ in }
    public var onOpenSettings: () -> Void = {}

    /// Which of `paths` (the panes' folders) is in iCloud Drive and which in Dropbox, or nil
    /// unless one of each.
    public nonisolated static func prefill(fromPanes paths: [String]) -> (iCloud: URL, dropbox: URL)? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let iCloudRoots = [home + "/Library/Mobile Documents/com~apple~CloudDocs",
                           OneWaySyncDisk.canonicalPath(OneWaySyncSetup.defaultICloudParent())]
        var iCloud: URL?, dropbox: URL?
        for path in paths where !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            let canonical = OneWaySyncDisk.canonicalPath(url)
            if let account = OneWaySyncSetup.accountFolder(containing: url), account.lastPathComponent.hasPrefix("Dropbox") {
                dropbox = url
            } else if iCloudRoots.contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") || expanded.hasPrefix($0 + "/") }) {
                iCloud = url
            }
        }
        guard let iCloud, let dropbox else { return nil }
        return (iCloud, dropbox)
    }

    /// Opens setup on the folders `panes` show, when they are an iCloud and a Dropbox folder.
    public func openSetup(panes: [String], from host: OneWaySyncSheetHost = .main) {
        setupPrefill = Self.prefill(fromPanes: panes)
        open(.setup(replacing: stop != nil || otherMac != nil), from: host)
    }

    /// Opens a sheet over the window `host` names.
    public func open(_ sheet: OneWaySyncSheet, from host: OneWaySyncSheetHost) {
        sheetHost = host
        self.sheet = sheet
    }

    // MARK: Launch

    /// Reads what is saved and starts listening for Dropbox's changes. At launch.
    public func start() {
        reload()
        watchDropbox()
    }

    /// Reads the record, the state and the exclusions again.
    public func reload() {
        guard let store else { return }
        let account = record?.binding.dropboxAccountFolder ?? OneWaySyncSetup.dropboxAccountFolder()?.path ?? ""
        switch store.loadRecord(on: .current(dropboxAccountFolder: account)) {
        case .ready(let record, let firstRun, let state):
            self.record = record
            self.firstRun = firstRun
            self.state = state
            if case .needsNewFirstRun = stop { stop = nil }
        case .needsNewFirstRun(let reason):
            record = nil
            state = nil
            firstRun = nil
            // A record that was there and no longer fits says so; never having set up says nothing.
            // A record that was there and no longer fits says so, with its row; never having set
            // up says nothing.
            if reason != .noRecord { stopped(.needsNewFirstRun(reason)) }
        case .cannotConfirm:
            stopped(.iCloudSignedOut)
        }
        exclusions = store.loadExclusions().value ?? OneWaySyncExclusions()
        if record == nil, refusal == nil, let account = OneWaySyncSetup.dropboxAccountFolder() {
            // Never set up here: another Mac may sync the usual pair, and this one says so.
            let marker = OneWaySyncMarkerFile(folder: OneWaySyncSetup.defaultDropboxParent(account: account))
            Task { [weak self] in
                let check = await Task.detached(priority: .utility) { marker.check(hardwareID: OneWaySyncBinding.platformUUID() ?? "") }.value
                if case .otherMac(let other) = check, self?.record == nil { self?.otherMac = other }
            }
        }
        if let record, let marker = marker(for: record) {
            switch marker.check(hardwareID: OneWaySyncBinding.platformUUID() ?? "") {
            case .otherMac(let other): otherMac = other
            default: otherMac = nil
            }
        }
    }

    /// The Dropbox gate needs to know what is still arriving in the synced folders: a watcher on
    /// them, its own replay history, from now. Not a trigger: nothing syncs because of it.
    func watchDropbox() {
        watcher?.stop()
        watcher = nil
        guard refusal == nil, let record else { return }
        let parent = OneWaySyncDisk.canonicalPath(URL(fileURLWithPath: record.dropboxParent.path))
        let folders = record.syncedFolders.map { parent + "/" + $0.dropboxPath }
        let watcher = FolderWatcher(history: .userDefaults(.standard, key: "oneWaySyncWatchHistory"), latency: 0.5) { [weak self] batch in
            Task { @MainActor in self?.arrivals.note(batch, syncedFolders: folders, at: Date()) }
        }
        watcher.watch(Set(folders.map(FolderWatchRoot.init)), replay: .none)
        self.watcher = watcher
    }

    // MARK: Places

    func places(for record: OneWaySyncRecord) -> OneWaySyncPlaces {
        OneWaySyncPlaces(
            iCloudParent: URL(fileURLWithPath: OneWaySyncDisk.canonicalPath(URL(fileURLWithPath: record.iCloudParent.path)), isDirectory: true),
            dropboxParent: URL(fileURLWithPath: OneWaySyncDisk.canonicalPath(URL(fileURLWithPath: record.dropboxParent.path)), isDirectory: true),
            dropboxAccountFolder: URL(fileURLWithPath: record.binding.dropboxAccountFolder, isDirectory: true),
            staging: OneWaySyncPlaces.defaultStaging())
    }

    func marker(for record: OneWaySyncRecord) -> OneWaySyncMarkerFile? {
        OneWaySyncMarkerFile(folder: URL(fileURLWithPath: OneWaySyncDisk.canonicalPath(URL(fileURLWithPath: record.dropboxParent.path))))
    }

    static var macName: String { Host.current().localizedName ?? "This Mac" }

    // MARK: Sync Now

    /// Runs one pass: checks, waits for Dropbox to catch up, looks, applies, and says what waits.
    public func syncNow() {
        guard syncNowRefusal == nil else { return }
        stopFlag.set(false)
        running = Task { [weak self] in
            await self?.pass()
            self?.running = nil
            self?.activity = nil
        }
    }

    /// Stops a pass: one waiting stops at once, one writing after the step it is on. What is
    /// left waits for the next Sync Now.
    public func cancel() {
        stopFlag.set(true)
        running?.cancel()
    }

    /// Where a pass's time went, for its log line: the checks, Dropbox catching up, the look, the
    /// writes and the wait for uploads.
    private var timings: [(String, Duration)] = []
    private var lap = ContinuousClock.now

    private func mark(_ phase: String) {
        let now = ContinuousClock.now
        timings.append((phase, now - lap))
        lap = now
    }

    private func pass() async {
        guard let store else { return }
        timings = []
        lap = .now
        activity = "Checking"
        guard let (record, firstRun, state) = await startCheck() else { return }
        // A lost list of files you stopped syncing would sync them over the copies you kept.
        guard case .ready(let exclusions) = store.loadExclusions() else {
            return stopped(.failed("the list of files you stopped syncing couldn’t be read"))
        }
        self.exclusions = exclusions
        if let problem = OneWaySyncSetup.parentProblem(record.iCloudParent) ?? OneWaySyncSetup.parentProblem(record.dropboxParent) {
            return stopped(.parentMoved(problem))
        }
        mark("checks")
        guard await dropboxCaughtUp() else { return }
        mark("Dropbox gate")
        activity = "Comparing"
        let places = places(for: record)
        let now = Date()
        let look = await Task.detached(priority: .userInitiated) {
            OneWaySyncRun.look(record: record, state: state, exclusions: exclusions, places: places, download: true, now: now)
        }.value
        mark("look")
        if Task.isCancelled { return }
        let notHere = look.dropboxNotHere
        if !notHere.isEmpty {
            lastLook = look
            return stopped(.dropboxFilesNotHere(count: notHere.count))
        }
        let summary = look.summary
        if let lowDisk = await Task.detached(priority: .userInitiated, operation: { Self.lowDiskSpace(for: summary) }).value {
            return stopped(lowDisk)
        }
        await apply(look, state: state, firstRun: firstRun, store: store)
    }

    /// The start check, with the lock taken: nil (and the row raised) when it may not start.
    private func startCheck() async -> (OneWaySyncRecord, UUID, OneWaySyncSavedState)? {
        guard let store else { return nil }
        if let refusal { Logger.shared.info("One-way sync: not from this copy (\(refusal))"); return nil }
        let lockResult: Result<OneWaySyncProcessLock, OneWaySyncProcessLock.Refusal>
        if let lock { lockResult = .success(lock) } else { lockResult = OneWaySyncProcessLock.acquire(at: store.lockURL) }
        if case .success(let taken) = lockResult { lock = taken }
        let account = record?.binding.dropboxAccountFolder ?? ""
        let saved = store.loadRecord(on: .current(dropboxAccountFolder: account))
        let markerCheck: OneWaySyncMarkerCheck
        if case .ready(let r, _, _) = saved, let marker = marker(for: r) {
            markerCheck = marker.check(hardwareID: OneWaySyncBinding.platformUUID() ?? "")
        } else {
            markerCheck = .missing
        }
        switch OneWaySyncStartCheck.evaluate(refusal: nil, lock: lockResult, record: saved, marker: markerCheck) {
        case .ready(let record, let firstRun, let state):
            otherMac = nil
            self.record = record
            self.firstRun = firstRun
            self.state = state
            return (record, firstRun, state)
        case .refused: return nil
        case .anotherProcessSyncs(let pid):
            stopped(.failed("another SyncCloud on this Mac syncs (process \(pid.map(String.init) ?? "?"))"))
        case .lockUnavailable(let code):
            stopped(.failed("SyncCloud’s lock couldn’t be taken (\(String(cString: strerror(code))))"))
        case .needsNewFirstRun(let reason): stopped(.needsNewFirstRun(reason))
        case .otherMacSyncs(let other):
            otherMac = other
            // That Mac's rows are its own: this one closes them.
            center.clearOneWaySync(center.oneWaySync.rows.map(\.id).filter { $0.hasPrefix(OneWaySyncRows.prefix) })
        case .twoMacsClaim: stopped(.twoMacsClaim)
        case .cannotConfirm: stopped(.iCloudSignedOut)
        case .markerUnavailable: stopped(.markerUnavailable)
        }
        return nil
    }

    /// Waits for the Dropbox gate (DI): running five minutes since it started or the Mac woke, and
    /// nothing still arriving. False, with its row raised, when it stops the sync or is cancelled.
    private func dropboxCaughtUp() async -> Bool {
        while !Task.isCancelled {
            let now = Date()
            switch OneWaySyncDropboxGate.check(status: cloudApps.statusModel, arrivals: arrivals, lastWake: cloudApps.lastWake, now: now) {
            case .caughtUp:
                return true
            case .stop(.dropboxNotRunning):
                stopped(.dropboxNotRunning)
                return false
            case .stop(.dropboxNeverQuiet):
                stopped(.dropboxNeverQuiet)
                return false
            case .waiting(.dropboxNotSeenRunning):
                activity = "Waiting for the Dropbox app"
                cloudApps.checkNow(["dropbox"])
            case .waiting(.dropboxJustStarted(let until)):
                activity = "Letting Dropbox catch up · until \(until.formatted(date: .omitted, time: .shortened))"
            case .waiting(.changesArriving):
                activity = "Letting Dropbox catch up"
            }
            try? await Task.sleep(for: .seconds(5))
        }
        return false
    }

    /// The paths Dropbox is still changing on its own, relative to the Dropbox parent.
    private func holdingBack(parent: String) -> Set<String> {
        guard case .caughtUp(let paths) = OneWaySyncDropboxGate.check(status: cloudApps.statusModel, arrivals: arrivals,
                                                                      lastWake: cloudApps.lastWake, now: Date()) else { return [] }
        return Set(paths.compactMap { path in path.hasPrefix(parent + "/") ? String(path.dropFirst(parent.count + 1)) : nil })
    }

    /// Low disk space, counting every download and copy the pass needs, and a margin.
    nonisolated static func lowDiskSpace(for summary: OneWaySyncSummary) -> OneWaySyncStopReason? {
        let needed = summary.downloadBytes + summary.copyBytes + summary.replaceBytes
        guard needed > 0,
              let free = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage else { return nil }
        let margin: Int64 = 2 * 1024 * 1024 * 1024
        return needed + margin > free ? .lowDiskSpace(needed: needed, free: free) : nil
    }

    private func apply(_ look: OneWaySyncLook, state: OneWaySyncSavedState, firstRun: UUID, store: OneWaySyncStore) async {
        let record = look.pass.record
        let places = places(for: record)
        let writer: OneWaySyncWriter
        do { writer = try OneWaySyncWriter(places: places) } catch { return stopped(.failed(OneWaySyncRun.describe(error))) }
        writer.removeTemporaryFiles()
        let marker = marker(for: record)
        let held = holdingBack(parent: places.dropboxParent.path)
        let total = look.plan.steps.count
        activity = total == 0 ? "Comparing" : "Syncing \(total)"
        let hardwareID = OneWaySyncBinding.platformUUID() ?? ""
        let macName = Self.macName
        nonisolated(unsafe) let unsafeWriter = writer
        let stopFlag = self.stopFlag
        let progressBeat = OneWaySyncProgressBeat()
        let result: OneWaySyncRunResult
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try await OneWaySyncRun.apply(look, state: state, firstRun: firstRun, store: store, writer: unsafeWriter,
                                              marker: marker, hardwareID: hardwareID, macName: macName, holdingBack: held,
                                              isCancelled: { stopFlag.isSet },
                                              progress: { done, of in
                                                  // Twice a second at most: each one re-renders the window.
                                                  guard progressBeat.due() else { return }
                                                  Task { @MainActor [weak self] in
                                                      guard let self, done < of else { return }
                                                      self.activity = "Syncing \(of - done)"
                                                  }
                                              })
            }.value
        } catch {
            return stopped(.failed("its saved state couldn’t be written: \(error.localizedDescription)"))
        }
        mark("apply")
        finish(result)
    }

    /// After a pass: the record and state as saved, Now's rows as this pass found things, and a
    /// line in the log.
    private func finish(_ result: OneWaySyncRunResult) {
        reload()
        stop = nil
        var look = result.look
        look.iCloud.skipped += result.refused
        lastLook = look
        lastSkipped = look.iCloud.skipped.count
        if let record {
            let dropboxParent = places(for: record).dropboxParent
            let written = result.look.plan.steps.indices.filter { result.outcomes[$0].happened }
                .flatMap { OneWaySyncRun.dropboxPaths(of: result.look.plan.steps[$0].action) }
                .map { dropboxParent.appendingPathComponent($0) }
            // Each path, and the folder it is in: a folder the sync made is new in its parent too.
            if !written.isEmpty { onWrote(Array(Set(written.flatMap { [$0.path, $0.deletingLastPathComponent().path] })).sorted()) }
        }
        let known = Set(state?.knownUnsyncedFolders ?? [])
        let rows = OneWaySyncRows.rows(for: look, knownUnsynced: known, at: Date())
        let raised = Set(rows.map(\.id))
        // A new folder announced once stays announced; it is not new at the next pass.
        let announced = rows.compactMap { row -> String? in
            guard row.id.hasPrefix("ows:info:new-folder:") else { return nil }
            return String(row.id.dropFirst("ows:info:new-folder:".count))
        }
        let stillNew = Set(result.look.plan.unsyncedICloudFolders)
        let stale = center.oneWaySync.rows.map(\.id).filter { id in
            guard id.hasPrefix(OneWaySyncRows.prefix), !raised.contains(id) else { return false }
            // An announced folder's row stays, until dismissed, while the folder is there.
            if id.hasPrefix("ows:info:new-folder:") { return !stillNew.contains(String(id.dropFirst("ows:info:new-folder:".count))) }
            return true
        }
        center.clearOneWaySync(stale)
        center.raiseOneWaySync(rows)
        if !announced.isEmpty, var state, let store {
            state.knownUnsyncedFolders = Array(Set(state.knownUnsyncedFolders).union(announced)).sorted()
            try? store.saveState(state)
            self.state = state
        }
        let synced = result.synced
        let waiting = result.look.plan.waits.filter(\.reason.needsYou).count
        let took = timings.map { "\($0.0) \(Int($0.1.components.seconds * 1000 + $0.1.components.attoseconds / 1_000_000_000_000_000)) ms" }
            .joined(separator: ", ")
        Logger.shared.info("One-way sync: \(synced) of \(result.look.plan.steps.count) changes synced, \(waiting) wait for you"
                           + (took.isEmpty ? "" : " (\(took))")
                           + (result.notDone.isEmpty ? "" : ", \(result.notDone.count) didn’t go through: "
                              + result.notDone.prefix(5).map { "\($0.path) (\($0.why))" }.joined(separator: "; "))
                           + (result.unconfirmed.isEmpty ? "" : ", \(result.unconfirmed.count) not yet reported uploaded"))
    }

    /// Stops the sync with its row under *Needs you*; the other stop rows go.
    private func stopped(_ reason: OneWaySyncStopReason) {
        stop = reason
        let row = OneWaySyncRows.stop(reason, at: Date())
        let others = center.oneWaySync.rows.map(\.id).filter { $0.hasPrefix(OneWaySyncRows.stopPrefix) && $0 != row.id }
        center.clearOneWaySync(others)
        center.raiseOneWaySync([row])
        Logger.shared.info("One-way sync: \(row.title)")
    }

    // MARK: A fresh look, for the sheets

    /// Lists and plans again without applying anything: what a sheet shows and answers.
    public func freshLook(download: Bool = false) async -> OneWaySyncLook? {
        guard let record, let state else { return lastLook }
        let places = places(for: record)
        let exclusions = self.exclusions
        let now = Date()
        let look = await Task.detached(priority: .userInitiated) {
            OneWaySyncRun.look(record: record, state: state, exclusions: exclusions, places: places, download: download, now: now)
        }.value
        lastLook = look
        return look
    }

    /// Runs `work` with a writer off the main thread, then a pass, so what it did is recorded.
    public func answer(_ what: String, then syncs: Bool = true,
                       _ work: @escaping @Sendable (OneWaySyncWriter) throws -> Void) async -> String? {
        guard let record else { return "One-way sync isn’t set up" }
        guard !isRunning, !isAnswering else { return "Wait for the sync that is running to finish" }
        isAnswering = true
        defer { isAnswering = false }
        let places = places(for: record)
        // On the pass's own write queue, one thing at a time.
        let failure: String? = await OneWaySyncRun.onWriteQueue {
            do {
                let writer = try OneWaySyncWriter(places: places)
                try work(writer)
                return nil
            } catch {
                return OneWaySyncRun.describe(error)
            }
        }
        if let failure {
            Logger.shared.info("One-way sync: \(what) didn’t go through: \(failure)")
            return failure
        }
        Logger.shared.info("One-way sync: \(what)")
        // An answer can write on either side; the panes on both parents read again.
        onWrote([places.iCloudParent.appendingPathComponent("."), places.dropboxParent.appendingPathComponent(".")].map(\.path))
        if syncs, syncNowRefusal == nil { syncNow() }
        return nil
    }

    /// Saves a record an answer changed, keeping its first run.
    func save(_ record: OneWaySyncRecord) throws {
        // A pass saves the record it ends with: one saved under it would be lost, or undo it.
        guard !isRunning else { throw CocoaError(.userCancelled) }
        guard let store, let firstRun else { return }
        try store.saveRecord(record, firstRun: firstRun)
        self.record = record
    }

    func save(_ exclusions: OneWaySyncExclusions) throws {
        guard !isRunning else { throw CocoaError(.userCancelled) }
        try store?.saveExclusions(exclusions)
        self.exclusions = exclusions
    }

    func saveState(_ change: (inout OneWaySyncSavedState) -> Void) {
        guard var state, let store else { return }
        change(&state)
        do {
            try store.saveState(state)
            self.state = state
        } catch {
            Logger.shared.error("One-way sync: couldn’t save its settings: \(error.localizedDescription)")
        }
    }

    // MARK: Settings

    public func pause() {
        saveState { $0.pausedSince = OneWaySyncHistoryStore.seconds(Date()) }
        cancel()
    }

    public func resume() {
        saveState { $0.pausedSince = nil }
    }

    public func setWhenDeletedRenamedOrMoved(_ value: OneWaySyncSettings.WhenDeletedRenamedOrMoved) {
        saveState { $0.settings.whenDeletedRenamedOrMoved = value }
    }

    public func setWhenEdited(_ value: OneWaySyncSettings.WhenEdited) {
        saveState { $0.settings.whenEdited = value }
    }

    /// *Turn Off One-Way Sync*: the record, the state, the marker and SyncCloud's temporary files
    /// go, and Now's rows. Dropbox's copies and SyncCloud Removed stay.
    public func turnOff() {
        guard let store, refusal == nil, !isRunning, !isAnswering else { return }
        cancel()
        if let record {
            try? marker(for: record)?.remove()
            if let writer = try? OneWaySyncWriter(places: places(for: record)) { writer.removeTemporaryFiles() }
        }
        try? store.removeRecord()
        try? store.saveExclusions(OneWaySyncExclusions())
        center.clearOneWaySync(center.oneWaySync.rows.map(\.id).filter { $0.hasPrefix(OneWaySyncRows.prefix) })
        record = nil
        state = nil
        firstRun = nil
        stop = nil
        otherMac = nil
        lastLook = nil
        exclusions = OneWaySyncExclusions()
        watcher?.stop()
        watcher = nil
        Logger.shared.info("One-way sync: turned off")
    }

    /// *Sync From This Mac Instead…*: this Mac takes the marker, and a new first run follows.
    public func syncFromThisMacInstead(from host: OneWaySyncSheetHost = .main) {
        sheetHost = host
        otherMac = nil
        if case .twoMacsClaim = stop { stop = nil }
        sheet = .setup(replacing: true)
    }

    // MARK: Setup

    /// The setup sheet opened on `dropboxParent`: from now, Dropbox has to stay quiet there for
    /// Start First Run, so what arrives there is watched.
    public func setupOpened(dropboxParent: URL) {
        setupOpenedAt = Date()
        arrivals = OneWaySyncArrivals()
        guard refusal == nil else { return }
        watcher?.stop()
        let parent = OneWaySyncDisk.canonicalPath(dropboxParent)
        let watcher = FolderWatcher(history: .userDefaults(.standard, key: "oneWaySyncWatchHistory"), latency: 0.5) { [weak self] batch in
            Task { @MainActor in self?.arrivals.note(batch, syncedFolders: [parent], at: Date()) }
        }
        watcher.watch([FolderWatchRoot(path: parent)], replay: .none)
        self.watcher = watcher
    }

    /// Reads both parents for setup: the folders directly in each, which can be ticked.
    public func draft(iCloudParent: URL, dropboxParent: URL) async -> OneWaySyncSetupDraft {
        await Task.detached(priority: .userInitiated) {
            let iCloud = OneWaySyncLister(side: .iCloud, parent: iCloudParent).list(syncedFolders: [])
            let dropbox = OneWaySyncLister(side: .dropbox, parent: dropboxParent).list(syncedFolders: [])
            let account = OneWaySyncSetup.accountFolder(containing: dropboxParent)
            var problem: String?
            if OneWaySyncDisk.kind(at: OneWaySyncDisk.canonicalPath(iCloudParent)) != .folder { problem = "iCloud’s folder isn’t there" }
            else if OneWaySyncDisk.kind(at: OneWaySyncDisk.canonicalPath(dropboxParent)) != .folder { problem = "Dropbox’s folder isn’t there" }
            else if account == nil { problem = "That folder isn’t in Dropbox" }
            else if OneWaySyncDisk.canonicalPath(iCloudParent).hasPrefix(OneWaySyncDisk.canonicalPath(dropboxParent) + "/")
                        || OneWaySyncDisk.canonicalPath(dropboxParent).hasPrefix(OneWaySyncDisk.canonicalPath(iCloudParent) + "/") {
                problem = "One folder is inside the other"
            }
            return OneWaySyncSetupDraft(iCloudParent: iCloudParent, dropboxParent: dropboxParent, dropboxAccount: account,
                                        iCloud: iCloud, dropbox: dropbox,
                                        choices: OneWaySyncSetup.choices(iCloud: iCloud, dropbox: dropbox), problem: problem)
        }.value
    }

    /// The setup sheet closed: the watcher goes back to the synced folders.
    public func setupClosed() {
        setupOpenedAt = nil
        watchDropbox()
    }

    /// The record a first run of `folders` starts from.
    func firstRunRecord(_ draft: OneWaySyncSetupDraft, folders: [String]) -> OneWaySyncRecord? {
        guard let account = draft.dropboxAccount else { return nil }
        return OneWaySyncSetup.record(
            binding: .current(dropboxAccountFolder: account.path), iCloudParent: OneWaySyncSetup.parentRecord(draft.iCloudParent),
            dropboxParent: OneWaySyncSetup.parentRecord(draft.dropboxParent), folders: folders,
            iCloud: draft.iCloud, dropbox: draft.dropbox)
    }

    /// The first run's preview (CZ): what Start would do. Offloaded files aren't downloaded for it.
    public func preview(_ draft: OneWaySyncSetupDraft, folders: [String], settings: OneWaySyncSettings) async -> OneWaySyncLook? {
        guard let record = firstRunRecord(draft, folders: folders) else { return nil }
        let places = OneWaySyncPlaces(iCloudParent: draft.iCloudParent, dropboxParent: draft.dropboxParent,
                                      dropboxAccountFolder: draft.dropboxAccount!, staging: OneWaySyncPlaces.defaultStaging())
        let exclusions = self.exclusions
        let state = OneWaySyncSavedState(settings: settings)
        return await Task.detached(priority: .userInitiated) {
            OneWaySyncRun.look(record: record, state: state, exclusions: exclusions, places: places, download: false, now: Date())
        }.value
    }

    /// Why Start First Run must wait, or nil: Dropbox running and quiet since the sheet opened.
    public var firstRunGate: String? {
        if let refusal = syncNowRefusalForSetup { return refusal }
        switch OneWaySyncDropboxGate.check(status: cloudApps.statusModel, arrivals: arrivals, lastWake: cloudApps.lastWake, now: Date()) {
        case .caughtUp: break
        case .stop(.dropboxNotRunning), .waiting(.dropboxNotSeenRunning): return "Open Dropbox first: SyncCloud syncs only while it runs"
        case .stop(.dropboxNeverQuiet), .waiting(.changesArriving): return "Dropbox is still bringing changes in"
        case .waiting(.dropboxJustStarted(let until)): return "Dropbox just started: ready at \(until.formatted(date: .omitted, time: .shortened))"
        }
        if let opened = setupOpenedAt, let last = arrivals.lastArrival, last > opened { return "Dropbox changed something since this opened" }
        return nil
    }

    var syncNowRefusalForSetup: String? {
        if refusal != nil { return "Only SyncCloud in Applications syncs" }
        if isRunning { return "A sync is running" }
        return nil
    }

    /// *Start First Run*: the record saved under a new first run, the marker claimed, the settings
    /// and notifications as chosen, then a pass, which re-checks both sides first.
    public func startFirstRun(_ draft: OneWaySyncSetupDraft, folders: [String], settings: OneWaySyncSettings,
                              notify: Bool) async -> String? {
        guard firstRunGate == nil, let store, var record = firstRunRecord(draft, folders: folders) else {
            return firstRunGate ?? "Choose at least one folder"
        }
        if record.syncedFolders.isEmpty { return "Choose at least one folder" }
        // Folders left unticked aren't new later.
        let unticked = draft.choices.filter { !folders.contains($0.name) && $0.place != .onlyInDropbox }.map(\.name)
        let old = self.record
        record.nextKey = max(record.nextKey, old?.nextKey ?? 1)
        let state = OneWaySyncSavedState(settings: settings, knownUnsyncedFolders: unticked)
        do {
            try store.startFirstRun(record, state: state)
            let hardwareID = OneWaySyncBinding.platformUUID() ?? ""
            try marker(for: record)?.claim(OneWaySyncMacMarker(
                hardwareID: hardwareID, macName: Self.macName, claimedAt: OneWaySyncHistoryStore.seconds(Date())))
        } catch {
            return "SyncCloud couldn’t save the sync: \(error.localizedDescription)"
        }
        center.clearOneWaySync(center.oneWaySync.rows.map(\.id).filter { $0.hasPrefix(OneWaySyncRows.prefix) })
        UserDefaults.standard.set(notify, forKey: OneWaySyncNoticeBoard.notifyKey)
        if notify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        stop = nil
        otherMac = nil
        reload()
        watchDropbox()
        Logger.shared.info("One-way sync: set up, \(record.syncedFolders.count) folders; first run starting")
        syncNow()
        return nil
    }

    // MARK: Folders

    /// *Choose Folders…*: folders ticked now that weren't start their own first run; ones unticked
    /// stop syncing, leaving Dropbox's copies as they are.
    public func chooseFolders(_ names: [String], draft: OneWaySyncSetupDraft) -> String? {
        guard var record else { return "One-way sync isn’t set up" }
        let key = OneWaySyncSide.dropbox.nameKey
        let wanted = Set(names.map(key))
        for folder in record.syncedFolders where !wanted.contains(key(folder.iCloudPath)) {
            record = OneWaySyncSetup.removing(folder.iCloudPath, from: record)
            clearRows(ofFolder: folder.iCloudPath)
        }
        for name in names where !record.syncedFolders.contains(where: { key($0.iCloudPath) == key(name) }) {
            if let added = OneWaySyncSetup.adding(name, to: record, iCloud: draft.iCloud, dropbox: draft.dropbox) { record = added }
        }
        do { try save(record) } catch { return error.localizedDescription }
        let unticked = draft.choices.filter { !wanted.contains(key($0.name)) && $0.place != .onlyInDropbox }.map(\.name)
        saveState { $0.knownUnsyncedFolders = Array(Set($0.knownUnsyncedFolders).union(unticked)).sorted() }
        watchDropbox()
        return nil
    }

    func clearRows(ofFolder name: String) {
        let key = OneWaySyncSide.dropbox.nameKey
        let ids = center.oneWaySync.rows.filter { row in
            switch row.scope {
            case .folder(let folder): return key(folder) == key(name)
            case .file(let folder, _): return key(folder) == key(name)
            case .wholeSync: return false
            }
        }.map(\.id)
        center.clearOneWaySync(ids)
    }

    // MARK: SyncCloud Removed

    /// Everything in Dropbox ▸ SyncCloud Removed, oldest first.
    public func removedItems() async -> [OneWaySyncRemovedItem] {
        guard let record else { return [] }
        let account = places(for: record).dropboxAccountFolder
        return await Task.detached(priority: .userInitiated) { OneWaySyncRemovedStore(accountFolder: account).items() }.value
    }

    /// What SyncCloud Removed holds, for Settings: items, bytes, and the oldest.
    public func removedSummary() async -> (count: Int, bytes: Int64, oldest: Date?) {
        let items = await removedItems()
        return (items.count, items.reduce(0) { $0 + $1.size },
                items.map(\.origin.removedAt).min().map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    /// *Choose Items to Empty…*: the chosen go to Dropbox's own deleted files.
    public func empty(_ chosen: [OneWaySyncRemovedItem]) async {
        guard let record else { return }
        let account = places(for: record).dropboxAccountFolder
        let result = await Task.detached(priority: .userInitiated) { OneWaySyncRemovedStore(accountFolder: account).empty(chosen) }.value
        Logger.shared.info("One-way sync: emptied \(result.emptied.count) items (\(OneWaySyncWords.bytes(result.bytes))) from SyncCloud Removed"
                           + (result.failed.isEmpty ? "" : "; \(result.failed.count) had changed and were left"))
    }

    /// Shows Dropbox ▸ SyncCloud Removed in Finder.
    public func showRemoved() {
        guard let record else { return }
        let root = OneWaySyncRemovedStore(accountFolder: places(for: record).dropboxAccountFolder).root
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    /// Shows a file you stopped syncing, in both places.
    public func reveal(_ exclusion: OneWaySyncExclusion) {
        guard let record else { return }
        let places = places(for: record)
        NSWorkspace.shared.activateFileViewerSelecting([places.iCloudParent.appendingPathComponent(exclusion.iCloudPath),
                                                        places.dropboxParent.appendingPathComponent(exclusion.dropboxPath)])
    }

    // MARK: The panes

    /// Which side of the sync a folder shown in a pane is on: the iCloud parent or anything in it
    /// is the source, Dropbox's the copy. Nil outside both, or before setup.
    public func role(ofFolder path: String) -> OneWaySyncPaneRole? {
        guard let record, otherMac == nil else { return nil }
        let canonical = OneWaySyncDisk.canonicalPath(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        let places = places(for: record)
        // The parent itself, or a synced folder or anything in it; a folder beside them isn't synced.
        func within(_ base: URL, _ synced: [String]) -> Bool {
            if canonical == base.path { return true }
            guard canonical.hasPrefix(base.path + "/") else { return false }
            let top = OneWaySyncSide.dropbox.nameKey(OneWaySyncPath.top(String(canonical.dropFirst(base.path.count + 1))))
            return synced.contains { OneWaySyncSide.dropbox.nameKey($0) == top }
        }
        if within(places.iCloudParent, record.syncedFolders.map(\.iCloudPath)) { return .source }
        if within(places.dropboxParent, record.syncedFolders.map(\.dropboxPath)) { return .copy }
        return nil
    }

    /// The iCloud file a synced Dropbox file at `path` comes from, or nil when it isn't one.
    public func iCloudFile(forDropbox path: String) -> String? {
        guard let record else { return nil }
        let places = places(for: record)
        let canonical = OneWaySyncDisk.canonicalPath(URL(fileURLWithPath: path))
        guard canonical.hasPrefix(places.dropboxParent.path + "/") else { return nil }
        let relative = String(canonical.dropFirst(places.dropboxParent.path.count + 1))
        let key = OneWaySyncSide.dropbox.nameKey(relative)
        if let file = record.files.first(where: { OneWaySyncSide.dropbox.nameKey($0.dropboxPath) == key }) {
            return places.iCloudParent.appendingPathComponent(file.iCloudPath).path
        }
        // A synced folder, or one recorded below it.
        if let folder = (record.syncedFolders + record.subfolders).first(where: { OneWaySyncSide.dropbox.nameKey($0.dropboxPath) == key }) {
            return places.iCloudParent.appendingPathComponent(folder.iCloudPath).path
        }
        return nil
    }

    /// Why a rename, move or delete in the Dropbox pane may not touch `paths`: a synced file, or a
    /// folder holding synced files, is changed in iCloud. Dropbox-only files go ahead.
    public func refusal(forChanging paths: [String]) -> String? {
        // Still a copy while another Mac syncs it.
        guard let record else { return nil }
        let places = places(for: record)
        let base = places.dropboxParent.path + "/"
        let synced = record.files.map { OneWaySyncSide.dropbox.nameKey($0.dropboxPath) }
        let folders = Set((record.syncedFolders + record.subfolders).map { OneWaySyncSide.dropbox.nameKey($0.dropboxPath) })
        for path in paths {
            let canonical = OneWaySyncDisk.canonicalPath(URL(fileURLWithPath: path))
            let name = (path as NSString).lastPathComponent
            // The Dropbox parent itself holds every synced folder.
            if canonical == places.dropboxParent.path, !record.syncedFolders.isEmpty {
                return "“\(name)” holds folders synced from iCloud — turn one-way sync off before moving or deleting it."
            }
            guard canonical.hasPrefix(base) else { continue }
            let key = OneWaySyncSide.dropbox.nameKey(String(canonical.dropFirst(base.count)))
            if folders.contains(key) || synced.contains(key) || synced.contains(where: { $0.hasPrefix(key + "/") }) {
                return "“\(name)” is synced from iCloud — change it in iCloud and the sync carries it over. Show in iCloud opens it there."
            }
        }
        return nil
    }
}

/// A pass's stop, set on the main actor and read between its steps on the write queue.
final class OneWaySyncStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}

/// Lets a progress report through at most twice a second.
final class OneWaySyncProgressBeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func due(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now.timeIntervalSince(last) >= 0.5 else { return false }
        last = now
        return true
    }
}
