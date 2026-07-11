import Events
import Foundation
import Combine

/// Core business logic for the two-pane file comparison and sync engine.
/// Holds in-memory trees (`FileNode`) for the left and right panes, runs differential scans,
/// and serializes file operations (copy, move, delete) with undo support and termination guards.
@MainActor
public class FileSyncManager: ObservableObject {
    /// File system abstraction used for all disk I/O (supports injection for tests).
    public let fileManager: FileManaging
    
    /// A closure that resolves naming collisions during file operations.
    /// Defaults to `.skip` so an unwired manager never overwrites existing files.
    /// The app wires an NSAlert-backed prompt at construction; tests inject specific resolutions.
    /// The trailing `isDirectory` flag reflects the colliding destination item, so the prompt can
    /// warn that replacing a folder replaces its whole contents (not just the same-named file).
    public var collisionResolver: @MainActor (_ fileName: String, _ isMove: Bool, _ isDirectory: Bool) -> CollisionResolution = { _, _, _ in
        return .skip
    }

    /// The bulk-sync variant of `collisionResolver`, adding an "Apply to all" choice.
    /// Defaults to skipping the conflicting item; the app wires an NSAlert-backed prompt at construction.
    /// The trailing `isDirectory` flag carries the same folder-replacement warning signal.
    public var bulkCollisionResolver: @MainActor (_ fileName: String, _ isMove: Bool, _ isDirectory: Bool) -> (resolution: CollisionResolution, applyToAll: Bool) = { _, _, _ in
        return (.skip, false)
    }

    /// Confirms permanently deleting items that could not be moved to Trash (e.g. network volumes).
    /// Defaults to `false` so an unwired manager never destroys data; the app wires an
    /// NSAlert-backed confirmation at construction.
    public var permanentDeleteConfirmer: @MainActor ([String]) -> Bool = { _ in
        return false
    }
    
    /// Initializes a new FileSyncManager with a specific file manager.
    /// - Parameter fileManager: The file manager to use. Defaults to `FileManager.default`.
    public init(fileManager: FileManaging = FileManager.default) {
        self.fileManager = fileManager
    }
    
    /// Cached differences from the latest scan before applying hidden/ignored filters.
    internal var rawDifferences: [FileDifference] = []
    /// IDs of differences with an in-flight sync/copy operation — the source of truth for the
    /// row-level `isSyncing` flag. `applyFilters()` rebuilds `differences` from
    /// `rawDifferences`, which never carries the flag, so a mid-operation filter pass (hidden
    /// toggle, ignore change, re-sort, a scan landing) would otherwise publish every row
    /// un-marked and re-enable the header sync actions while files are still being written.
    /// Every transition goes through `markSyncing`/`clearSyncing`, which update the set and
    /// the published rows in the same main-actor turn — and `applyFilters()` re-stamps the
    /// flag from this set (and drops resolved rows) at publish time, so a pass whose
    /// snapshot predates a transition cannot re-install stale rows.
    internal private(set) var syncingDifferenceIds: Set<UUID> = []
    /// IDs of differences that were verified as same content via checksum; these are hidden from the list until next scan.
    internal var verifiedSameDifferenceIds: Set<UUID> = []
    /// When non-nil, a "Verify All" run is in progress: (completed count, total count).
    @Published public var verifyAllProgress: (completed: Int, total: Int)?
    /// After Verify All completes, the list of differences that verified identical; UI shows dialog to copy left→right. Cleared when user copies or cancels.
    @Published public var verifiedIdenticalForCopy: [FileDifference]?
    /// Filtered list of differences between the left and right panes (respects `showHiddenFiles`, `ignoredPaths`, and `verifiedSameDifferenceIds`).
    @Published public var differences: [FileDifference] = []
    /// Indicates whether a deep structure scan is currently in progress.
    @Published public var isScanning = false
    /// Indicates whether at least one successful scan has occurred.
    @Published public var hasScanned = false
    
    /// Global sorting preference for the file trees.
    @Published public var sortOption: SortOption = .name {
        didSet {
            guard sortOption != oldValue else { return }
            // Invalidate prefetch cache for roots as they need re-sorting or re-scanning
            prefetchedTrees.removeAll()
            // Re-sort current trees when the option changes — off the main actor; the full
            // re-sort of both trees froze the UI on large panes.
            Task { await self.resortTreesAndRefilter() }
        }
    }
    
    /// Global toggle to show/hide hidden files (e.g. .DS_Store, .git)
    @Published public var showHiddenFiles: Bool = false {
        didSet {
            guard showHiddenFiles != oldValue else { return }
            prefetchedTrees.removeAll()
            Task { await self.applyFilters() }
        }
    }
    
    /// Paths that the user has explicitly requested to hide from the current comparison context.
    @Published public var ignoredPaths: Set<String> = [] {
        didSet {
            guard ignoredPaths != oldValue else { return }
            Task { await self.applyFilters() }
        }
    }

    /// When true, differences that are only "right newer, same size" are hidden when the right pane is Google Drive (avoids noise from Drive overwriting file dates). Set by the app from persisted settings.
    @Published public var ignoreGoogleDriveNewerDateOnly: Bool = false {
        didSet {
            guard ignoreGoogleDriveNewerDateOnly != oldValue else { return }
            Task { await self.applyFilters() }
        }
    }
    /// Provider type of the right pane from the last scan; used with ignoreGoogleDriveNewerDateOnly to filter differences.
    internal var lastRightProviderType: CloudProvider.ProviderType?

    /// Monotonic token for `applyFilters()` passes: each pass claims the next value on entry.
    /// A pass publishes only while no newer pass has published (see
    /// `lastPublishedFilterGeneration`), so overlapping off-main filter computations can never
    /// publish out of order — yet an awaited pass still publishes when it's the freshest done.
    private var filterGeneration = 0
    /// Generation of the most recent `applyFilters()` pass that published its results.
    private var lastPublishedFilterGeneration = 0

    /// Bumped on every raw-tree publish (see `adoptRawTree`). Guards the off-main resort in
    /// `resortTreesAndRefilter()` against clobbering trees a load published mid-sort.
    internal var rawTreeGeneration = 0
    
    /// Raw file tree for the left pane (before hidden/ignored filtering).
    internal var rawLeftTree: [FileNode] = []
    /// Filtered file tree for the left pane (used by the UI).
    @Published public var leftTree: [FileNode] = []

    /// Raw file tree for the right pane (before hidden/ignored filtering).
    internal var rawRightTree: [FileNode] = []
    /// Filtered file tree for the right pane (used by the UI).
    @Published public var rightTree: [FileNode] = []

    /// True when the left pane's folder has entries but filtering (hidden files) removed all
    /// of them — lets the empty-pane placeholder point at the Hidden toggle. Not `@Published`:
    /// read during renders that `leftTree` (always published after the raw tree is set)
    /// already triggers.
    public var leftTreeHasOnlyHiddenEntries: Bool { leftTree.isEmpty && !rawLeftTree.isEmpty }
    /// Right-pane counterpart of `leftTreeHasOnlyHiddenEntries`.
    public var rightTreeHasOnlyHiddenEntries: Bool { rightTree.isEmpty && !rawRightTree.isEmpty }
    /// True while the left pane tree is being loaded from disk.
    @Published public var isLoadingLeftTree = false
    /// True while the right pane tree is being loaded from disk.
    @Published public var isLoadingRightTree = false

    /// Total number of files and folders in the left pane tree (recursive).
    @Published public var leftItemCount = 0
    /// Total number of files and folders in the right pane tree (recursive).
    @Published public var rightItemCount = 0
    
    /// Cached structures generated asynchronously upon app load to eliminate blocking when switching providers.
    /// Not `@Published`: no view renders from it, and it is cleared after every file operation —
    /// publishing it forced whole-window re-renders per operation.
    /// Deep trees by focused-folder path (pane roots and any folder visited since the last
    /// invalidation). Never holds shallow trees — consumers (navigation fast path, the
    /// in-memory diff scan) rely on cached trees being fully walked. The one exception is a
    /// cycle- or depth-capped directory inside a deep tree: it carries `isUnexplored: true`,
    /// and `subtree(atPath:in:)` treats it as a miss so a drill-down re-walks from that path
    /// instead of serving its artificial empty children. Cleared by file operations, sort
    /// changes, and force refresh.
    public var prefetchedTrees: [String: [FileNode]] = [:]
    /// Focused-folder path each pane's published tree was last loaded for; distinguishes a
    /// same-focus refresh (keep showing the current tree while rebuilding) from a focus
    /// change (repaint shallow immediately) in `loadTree`.
    var lastLoadedLeftFocusPath: String? = nil
    var lastLoadedRightFocusPath: String? = nil
    
    @Published public var clipboardNodes: [FileNode] = []
    @Published public var clipboardIsCut: Bool = false
    
    /// Global UndoManager injected from SwiftUI environment
    public var undoManager: UndoManager?
    
    /// Last failure from a file operation, structured for a rich alert (title, message,
    /// affected path, underlying reason, retryability). Cleared when the user dismisses the alert.
    @Published public var currentError: SyncError? = nil {
        didSet {
            // Clearing the error (dismissal) always drops its retry handler, so a stale
            // closure can never outlive the error it belonged to.
            if currentError == nil { currentErrorRetry = nil }
        }
    }

    /// Re-attempts the operation behind `currentError`, when one is both retryable and cleanly
    /// re-invocable (currently only single-item sync). Not `@Published`: the error alert reads it
    /// while presenting, and `currentError` (published) already drives that presentation. Cleared
    /// together with the error via `currentError`'s `didSet`.
    public var currentErrorRetry: (@MainActor () -> Void)? = nil

    /// Publishes a structured failure to the error alert and logs it. Centralizes the
    /// `currentError` + retry-handler + log triple so call sites stay one line and the three
    /// can never drift apart. Public so UI-side coordinators (FileActionHandler) can surface
    /// pre-flight failures — e.g. a pane whose provider root vanished — through the same alert.
    public func present(_ error: SyncError, retry: (@MainActor () -> Void)? = nil) {
        currentError = error
        currentErrorRetry = retry
        Logger.shared.error(error.logDescription)
    }

    /// When non-nil, a bulk sync is in progress: (completed count, total count). Used for progress indicator.
    @Published public var bulkSyncProgress: (completed: Int, total: Int)? = nil
    /// Cached "Apply to all" resolution for the current bulk run; cleared when bulk sync ends.
    internal var bulkApplyToAllResolution: CollisionResolution?
    /// True while a bulk run — `syncAll` or the verified-copy bulk copy — is in flight. Both
    /// write `bulkSyncProgress` and nil it in their defer, and syncAll's prepare phase suspends
    /// (detached stat pass, keep-both probing) before the progress overlay can block input, so
    /// without a shared guard two bulk runs could interleave there, reset
    /// `bulkApplyToAllResolution` mid-prompt, interleave the shared progress counter, and tear
    /// down `bulkSyncProgress` on exit while the other run is still using it. Internal (not
    /// private) so tests can pin the refusal paths without racing a real run.
    var isBulkSyncRunning = false
    /// True while a `verifyAllWithChecksum` run is in flight. Symmetric with
    /// `isBulkSyncRunning`: each refuses to start while the other runs. Verify All hashes both
    /// sides of every candidate, so overlapping a bulk sync — especially its prepare phase,
    /// where `bulkSyncProgress` is still nil — would checksum files mid-overwrite and could
    /// record bogus "identical" results in `verifiedIdenticalForCopy`. Internal (not private)
    /// so tests can pin the syncAll-refuses-during-verify direction without racing a real run.
    var isVerifyAllRunning = false

    /// Current subfolder path relative to the left pane root (empty = root).
    @Published public var leftRelativePath: String = ""
    /// Current subfolder path relative to the right pane root (empty = root).
    @Published public var rightRelativePath: String = ""

    /// Paths currently selected in the left pane.
    ///
    /// Invariant: at most one pane has a selection at a time. It is enforced
    /// synchronously at the UI binding layer (the pane selection bindings in
    /// MacApp/ContentView.swift), not here — a didSet would either publish from
    /// within a view update or have to defer the clear, leaving a window where
    /// both panes hold selections and consumers target the wrong pane.
    @Published public var selectedLeftPaths: Set<String> = []
    /// Paths currently selected in the right pane. See `selectedLeftPaths` for
    /// the one-pane-selected invariant (enforced in MacApp/ContentView.swift).
    @Published public var selectedRightPaths: Set<String> = []
    /// Tracks the number of currently active file operations (Sync, Move, Delete, etc.).
    /// Used by the app-level guard to prevent accidental termination during critical tasks.
    /// Not `@Published`: the quit guard reads it imperatively; no view observes it.
    public var activeFileOperationsCount = 0
    /// Real-time progress tracker for the currently active bulk file operation.
    @Published public var activeProgress: Progress? = nil
    /// Short-lived banner for in-app operation completion toasts. The severity drives the UI's
    /// icon, tint, and dismissal behavior.
    @Published public var banner: OperationBanner? = nil
    
    /// Global Combine subject to trigger a UI refresh of trees from anywhere without closure retain cycles.
    public let refreshSubject = PassthroughSubject<Void, Never>()
    
    /// Chains file operations so they run one after another (avoids concurrent copy/move/undo conflicts).
    private var fileOperationTask: Task<Void, Swift.Error> = Task {}

    /// Captures a single scan request (left/right providers and paths) for re-entrancy and cancellation.
    struct ScanRequest: Sendable {
        let left: CloudProvider
        let leftPath: String
        let right: CloudProvider
        let rightPath: String
        let generation: Int
    }

    /// Active tree-load and refresh tasks; cancel before starting a new one for the same pane.
    internal var activeLoadLeftTask: Task<Void, Never>?
    internal var activeLoadRightTask: Task<Void, Never>?
    internal var activeRefreshTask: Task<Void, Never>?
    /// Target of the in-flight refresh (both providers + focused subpaths); nil when none is
    /// running. Lets refreshTreesAndScan dedupe the identical refreshes the launch bootstrap
    /// fires (explicit initial refresh + the provider-id onChange that resets navigation)
    /// instead of cancel-restarting them, which raced and could strand a pane's load.
    var activeRefreshKey: RefreshKey?
    /// Identity of a refresh target. Two concurrent refreshes with the same key would load the
    /// same thing, so the later one is skipped; a different key is real navigation and supersedes.
    struct RefreshKey: Equatable {
        let leftId: String
        let leftPath: String
        let rightId: String
        let rightPath: String
        let leftRel: String
        let rightRel: String
    }
    /// Monotonic per-pane load tokens: each `loadTree` call claims the next value. The deferred
    /// spinner cleanup in `loadTree` fires only while the pane's token still matches, so a
    /// superseded load never clears a newer load's spinner, yet the current load always
    /// releases it — even when cancelled with no successor to take over.
    var leftLoadGeneration = 0
    var rightLoadGeneration = 0
    private var hasPendingSelectionPrune = false
    var scanRequestGeneration = 0
    var pendingScanRequest: ScanRequest?
    
    /// Synchronously counts a file operation whose `enqueueFileOperation` call happens inside a
    /// `Task` the caller is about to spawn (the undo/redo handlers). The counter must move
    /// before that Task is even scheduled: the quit guard reads it, and ⌘Z immediately followed
    /// by ⌘Q would otherwise pass `applicationShouldTerminate` before the undo's file I/O is
    /// counted. Pair with `enqueueFileOperation(alreadyCounted: true)`; the completion decrement
    /// there is shared and unconditional.
    public func preCountFileOperation() {
        activeFileOperationsCount += 1
    }

    /// Enqueues a file operation to be executed sequentially.
    /// Manages `activeFileOperationsCount` and triggers UI refreshes and selection pruning upon completion.
    /// - Parameter alreadyCounted: True when the caller already bumped the counter via
    ///   `preCountFileOperation()`; skips the increment so the operation isn't double-counted.
    @discardableResult
    public func enqueueFileOperation<T: Sendable>(
        alreadyCounted: Bool = false,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        if !alreadyCounted {
            await MainActor.run { self.activeFileOperationsCount += 1 }
        }

        let previousTask = fileOperationTask
        let newTask = Task.detached(priority: .userInitiated) {
            _ = await previousTask.result
            let res = await operation()
            await MainActor.run { [weak self] in 
                // File operations mutate the filesystem; cached prefetched roots are stale after any write.
                self?.prefetchedTrees.removeAll()
                self?.activeFileOperationsCount = max(0, (self?.activeFileOperationsCount ?? 1) - 1)
                self?.scheduleSelectionPrune()
                self?.refreshSubject.send() 
            }
            return res
        }
        fileOperationTask = Task { _ = await newTask.value }
        return await newTask.value
    }
    
    public func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool {
        // Strip currentPath only at a path-component boundary so a pane rooted at
        // "/root/ab" never claims "/root/abc/x" via a bare string prefix.
        let base = currentPath.hasSuffix("/") ? String(currentPath.dropLast()) : currentPath
        var rPath = node.id
        if rPath == base {
            rPath = ""
        } else if rPath.hasPrefix(base + "/") {
            rPath = String(rPath.dropFirst(base.count + 1))
        }
        return Self.isIgnoredPath(rPath, ignored: ignoredPaths)
    }
    
    /// Removes resolved differences from both the published list and the raw backing list.
    /// `applyFilters()` rebuilds `differences` from `rawDifferences`, so removing from the
    /// published list alone lets any pre-rescan filter change (hidden toggle, sort, the post-sync
    /// refresh itself) resurrect items that were already synced.
    internal func removeResolvedDifferences(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        differences.removeAll { ids.contains($0.id) }
        rawDifferences.removeAll { ids.contains($0.id) }
        // A resolved row is gone from both lists; leaving its id marked in-flight would keep
        // the pane swap (and Verify All) refused forever after a successful sync.
        syncingDifferenceIds.subtract(ids)
    }

    /// Marks the given differences as having an in-flight operation, in both the authoritative
    /// id set and the published rows. Counterpart of `clearSyncing(ids:)`; all `isSyncing`
    /// transitions must go through these two (see `syncingDifferenceIds`).
    internal func markSyncing(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        syncingDifferenceIds.formUnion(ids)
        for i in differences.indices where ids.contains(differences[i].id) {
            differences[i].isSyncing = true
        }
    }

    /// Clears the in-flight mark set by `markSyncing(ids:)` from the id set and the published
    /// rows. Rows already removed by `removeResolvedDifferences` are simply not found — the
    /// set subtraction still runs, so no id can leak.
    internal func clearSyncing(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        syncingDifferenceIds.subtract(ids)
        for i in differences.indices where ids.contains(differences[i].id) {
            differences[i].isSyncing = false
        }
    }

    /// Everything a filter pass publishes, computed off the main actor in one shot.
    struct FilteredState: Sendable {
        var leftTree: [FileNode]
        var rightTree: [FileNode]
        var leftItemCount: Int
        var rightItemCount: Int
        var differences: [FileDifference]
    }

    /// Reapplies `showHiddenFiles` and `ignoredPaths` to raw trees and differences, updating
    /// published state. The filtering itself — full walks of both pane trees plus a pass over
    /// every raw difference — runs off the main actor: with tens of thousands of nodes it takes
    /// long enough to freeze every window in the app (the Settings hitches were exactly this,
    /// landing on the main thread several times per progressive load + scan cycle).
    /// Overlapping passes are safe: the last-started pass wins; earlier results are discarded.
    public func applyFilters() async {
        filterGeneration += 1
        let generation = filterGeneration

        let rawLeft = rawLeftTree
        let rawRight = rawRightTree
        let rawDiffs = rawDifferences
        let showHidden = showHiddenFiles
        let ignored = ignoredPaths
        let verifiedSame = verifiedSameDifferenceIds
        let syncingIds = syncingDifferenceIds
        let dropDriveDateNoise = ignoreGoogleDriveNewerDateOnly && lastRightProviderType == .googleDrive

        let state = await Task.detached(priority: .userInitiated) {
            Self.computeFilteredState(
                rawLeftTree: rawLeft,
                rawRightTree: rawRight,
                rawDifferences: rawDiffs,
                showHidden: showHidden,
                ignoredPaths: ignored,
                verifiedSameDifferenceIds: verifiedSame,
                syncingDifferenceIds: syncingIds,
                dropDriveDateNoise: dropDriveDateNoise
            )
        }.value

        // Publish unless a newer pass (with a newer snapshot) already has: results may
        // finish out of entry order, and stale state must never overwrite fresher state.
        guard generation > lastPublishedFilterGeneration else { return }
        lastPublishedFilterGeneration = generation
        // The snapshot above is stale if a sync resolved rows (`removeResolvedDifferences`)
        // or marked/cleared in-flight state while the detached compute ran; publishing it
        // verbatim would resurrect resolved rows and re-install a stale `isSyncing` flag.
        // Reconcile against the live authoritative state: keep only rows still present in
        // `rawDifferences`, and re-stamp `isSyncing` from `syncingDifferenceIds` — in both
        // directions, so a row marked after the snapshot keeps its spinner and one cleared
        // after it doesn't get the spinner back.
        var reconciledDifferences = state.differences
        let liveIds = Set(rawDifferences.map(\.id))
        reconciledDifferences.removeAll { !liveIds.contains($0.id) }
        for i in reconciledDifferences.indices {
            reconciledDifferences[i].isSyncing = syncingDifferenceIds.contains(reconciledDifferences[i].id)
        }
        // Assign only what actually changed. A load+scan cycle runs several filter passes and
        // each rebuilds fresh arrays, but republishing an unchanged tree still makes SwiftUI
        // tear down and rebuild the whole pane List — and a rebuild landing between an
        // NSTableView mouse-down and mouse-up drops the click ("dead clicks"). Comparing
        // against the live published value (cheap: `!=` short-circuits at the first real
        // change; a full walk happens only on the no-op passes we want to suppress) keeps
        // identical passes from touching @Published state at all.
        if self.leftTree != state.leftTree { self.leftTree = state.leftTree }
        if self.rightTree != state.rightTree { self.rightTree = state.rightTree }
        if self.leftItemCount != state.leftItemCount { self.leftItemCount = state.leftItemCount }
        if self.rightItemCount != state.rightItemCount { self.rightItemCount = state.rightItemCount }
        if self.differences != reconciledDifferences { self.differences = reconciledDifferences }
    }

    /// The pure core of `applyFilters()`: value inputs in, published-ready state out.
    nonisolated static func computeFilteredState(
        rawLeftTree: [FileNode],
        rawRightTree: [FileNode],
        rawDifferences: [FileDifference],
        showHidden: Bool,
        ignoredPaths: Set<String>,
        verifiedSameDifferenceIds: Set<UUID>,
        syncingDifferenceIds: Set<UUID> = [],
        dropDriveDateNoise: Bool
    ) -> FilteredState {
        let leftTree = filterTree(rawLeftTree, showHidden: showHidden)
        let rightTree = filterTree(rawRightTree, showHidden: showHidden)

        var filteredDifferences = rawDifferences
        if !showHidden {
            filteredDifferences = filteredDifferences.filter { !isHiddenPath($0.relativePath) }
        }
        if !ignoredPaths.isEmpty {
            filteredDifferences = filteredDifferences.filter { diff in
                !isIgnoredPath(diff.relativePath, ignored: ignoredPaths)
            }
        }
        if !verifiedSameDifferenceIds.isEmpty {
            filteredDifferences = filteredDifferences.filter { !verifiedSameDifferenceIds.contains($0.id) }
        }
        if dropDriveDateNoise {
            filteredDifferences = filteredDifferences.filter { diff in
                // Hide "right is newer, same size" only (Drive date noise)
                if diff.type == .differentDates, diff.sizesMatch, diff.action == .copyToLeft {
                    return false
                }
                return true
            }
        }
        // Re-stamp the in-flight flag from the authoritative set: raw differences never carry
        // `isSyncing`, so a rebuild mid-operation would otherwise strip it from every row.
        if !syncingDifferenceIds.isEmpty {
            for i in filteredDifferences.indices {
                filteredDifferences[i].isSyncing = syncingDifferenceIds.contains(filteredDifferences[i].id)
            }
        }

        return FilteredState(
            leftTree: leftTree,
            rightTree: rightTree,
            leftItemCount: countItems(in: leftTree),
            rightItemCount: countItems(in: rightTree),
            differences: filteredDifferences
        )
    }

    /// Re-sorts both raw trees off the main actor, then refilters. Skips publishing when a
    /// tree load or another sort change landed mid-sort: fresh trees are built already sorted
    /// by the then-current option, so the stale result would clobber newer data.
    func resortTreesAndRefilter() async {
        let option = sortOption
        let left = rawLeftTree
        let right = rawRightTree
        let generation = rawTreeGeneration
        let (sortedLeft, sortedRight) = await Task.detached(priority: .userInitiated) {
            (Self.sort(nodes: left, by: option), Self.sort(nodes: right, by: option))
        }.value
        guard option == sortOption, generation == rawTreeGeneration else { return }
        rawLeftTree = sortedLeft
        rawRightTree = sortedRight
        await applyFilters()
    }

    /// Bulk copy the given differences from left to right (overwrites if exists). No per-file confirmation; 2–4 concurrent copies.
    /// Internal (not private) because `confirmVerifiedCopy` in FileSyncManager+Verify.swift starts it.
    func bulkCopyDifferencesLeftToRight(_ toCopy: [FileDifference]) async {
        let total = toCopy.count
        guard total > 0 else { return }
        // Same exclusion as syncAll: this run writes `bulkSyncProgress` and nils it in its
        // defer, so overlapping a bulk sync would interleave the shared counter and tear down
        // the survivor's overlay — and syncAll's up-front destination stats would be staled by
        // these overwrites. A concurrent Verify All would hash files mid-overwrite. Refuse
        // visibly, mirroring syncAll's verify refusal.
        guard !isBulkSyncRunning, !isVerifyAllRunning else {
            banner = .warning("Wait for the current operation to finish before copying")
            return
        }
        isBulkSyncRunning = true
        let toCopyIDs = Set(toCopy.map { $0.id })

        let progress = Progress(totalUnitCount: Int64(total))
        progress.localizedDescription = "Copying \(total) files to match dates"
        progress.isCancellable = true
        activeProgress = progress

        markSyncing(ids: toCopyIDs)
        bulkSyncProgress = (0, total)

        // Yield so the progress overlay can render before we block on the copy work.
        await MainActor.run { }

        defer {
            isBulkSyncRunning = false
            bulkSyncProgress = nil
            if activeProgress === progress { activeProgress = nil }
            clearSyncing(ids: toCopyIDs)
        }

        let activeFM = fileManager
        let workList: [(FileDifference, URL, URL, Bool)] = toCopy.map { diff in
            (diff, URL(fileURLWithPath: diff.leftItemPath), URL(fileURLWithPath: diff.rightItemPath), false)
        }

        let progressRef = ProgressRef(progress)
        let weakRef = WeakSyncManagerRef(self)
        let totalCount = total

        let result = await enqueueFileOperation {
            await Self.performBulkSyncIO(
                workList: workList,
                concurrency: min(4, max(2, workList.count)),
                progress: progressRef,
                fileManager: activeFM,
                reportCompleted: { completed in weakRef.value?.bulkSyncProgress = (completed, totalCount) }
            )
        }

        for (diff, (trashed, from, to)) in result.successes {
            let actionName = "Sync \(diff.relativePath.components(separatedBy: "/").last ?? "")"
            registerCopyUndo(items: [(source: from, destination: to, overwritten: trashed)], actionName: actionName, fileManager: activeFM)
        }
        removeResolvedDifferences(ids: Set(result.successes.map { $0.0.id }))
        // No per-failure isSyncing reset here: the defer above clears the flag for every
        // item of this run, and nothing can observe the list before it runs.
        if result.failures.count == 1, let (diff, error) = result.failures.first {
            present(.copyFailed(
                items: "\"\(diff.relativePath)\"",
                path: diff.leftItemPath,
                reason: error.localizedDescription
            ))
        } else if result.failures.count > 1 {
            // Same aggregation as syncAll: one alert summarizes; every failure is logged.
            for (diff, error) in result.failures {
                Logger.shared.error(SyncError.copyFailed(
                    items: "\"\(diff.relativePath)\"",
                    path: diff.leftItemPath,
                    reason: error.localizedDescription
                ).logDescription)
            }
            let (firstDiff, firstError) = result.failures[0]
            present(.bulkFailed(
                verb: "copy",
                failureCount: result.failures.count,
                firstItem: firstDiff.relativePath,
                firstPath: firstDiff.leftItemPath,
                firstReason: firstError.localizedDescription
            ))
        }
        if !result.failures.isEmpty {
            banner = .warning("\(result.successes.count) copied; \(result.failures.count) failed")
        } else if !result.successes.isEmpty {
            banner = .success("\(result.successes.count) files copied — dates matched")
        }
    }

    /// Shared scaffolding for the parallel bulk-sync / verify workers: a work queue drained by
    /// up to `concurrency` tasks, stopping early once the progress is cancelled. After each item
    /// the shared completed count (offset by `completedBase`, for items resolved before the
    /// workers started) is mirrored into the `Progress` and reported on the MainActor.
    /// Internal (not private) because `verifyAllWithChecksum` in FileSyncManager+Verify.swift
    /// runs its checksum workers on the same scaffolding.
    nonisolated static func processInParallel<Item: Sendable>(
        items: [Item],
        concurrency: Int,
        progress progressRef: ProgressRef,
        completedBase: Int = 0,
        reportCompleted: @escaping @MainActor @Sendable (Int) -> Void,
        handle: @escaping @Sendable (Item) async -> Void
    ) async {
        let queue = WorkQueue(items: items)
        let counter = CompletedCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    while !progressRef.progress.isCancelled, let item = await queue.next() {
                        await handle(item)
                        let completed = completedBase + (await counter.increment())
                        progressRef.progress.completedUnitCount = Int64(completed)
                        await MainActor.run { reportCompleted(completed) }
                    }
                }
            }
        }
    }

    /// Runs the copy/move I/O for a prepared bulk work list on the parallel scaffolding,
    /// collecting per-difference successes and failures. Shared by `syncAll` and
    /// `bulkCopyDifferencesLeftToRight`.
    private nonisolated static func performBulkSyncIO(
        workList: [(FileDifference, URL, URL, Bool)],
        concurrency: Int,
        progress progressRef: ProgressRef,
        completedBase: Int = 0,
        fileManager: FileManaging,
        reportCompleted: @escaping @MainActor @Sendable (Int) -> Void
    ) async -> (successes: [(FileDifference, (URL?, URL, URL))], failures: [(FileDifference, Error)]) {
        let collector = BulkSyncResultsCollector()
        await processInParallel(
            items: workList,
            concurrency: concurrency,
            progress: progressRef,
            completedBase: completedBase,
            reportCompleted: reportCompleted
        ) { item in
            let (diff, fromURL, toURL, isMove) = item
            do {
                let syncResult = try performFileSyncIO(from: fromURL, to: toURL, isMove: isMove, fileManager: fileManager)
                await collector.addSuccess(diff, (syncResult.trashed, syncResult.from, syncResult.to))
            } catch {
                await collector.addFailure(diff, error)
            }
        }
        return await collector.get()
    }

    /// Recursively filters a tree removing nodes whose names start with a period if `showHidden` is false.
    nonisolated static func filterTree(_ nodes: [FileNode], showHidden: Bool) -> [FileNode] {
        if showHidden { return nodes }
        var filtered: [FileNode] = []
        for node in nodes {
            if node.name.hasPrefix(".") { continue }
            
            var newNode = node
            if let children = node.children {
                newNode.children = filterTree(children, showHidden: showHidden)
            }
            filtered.append(newNode)
        }
        return filtered
    }
    
    /// Stats one destination off the main actor: on network/cloud volumes a synchronous
    /// fileExists can block the UI for seconds. Used by the collision flows, whose prompts
    /// stay on the MainActor.
    nonisolated static func statExists(at url: URL, fileManager activeFM: FileManaging) async -> (exists: Bool, isDirectory: Bool) {
        await Task.detached(priority: .userInitiated) {
            var isDir: ObjCBool = false
            let exists = activeFM.fileExists(atPath: url.path, isDirectory: &isDir)
            return (exists, isDir.boolValue)
        }.value
    }

    public nonisolated static func isIgnoredPath(_ path: String, ignored: Set<String>) -> Bool {
        for ignoredPath in ignored {
            if path == ignoredPath || path.hasPrefix(ignoredPath + "/") {
                return true
            }
        }
        return false
    }
    
    public nonisolated static func isHiddenPath(_ path: String) -> Bool {
        let components = path.components(separatedBy: "/")
        return components.contains { $0.hasPrefix(".") }
    }
    
    /// Back/forward stack for the left pane; independent of the right pane's.
    @Published public var leftHistory = PaneNavigationHistory()
    /// Back/forward stack for the right pane; independent of the left pane's.
    @Published public var rightHistory = PaneNavigationHistory()
    
    // Navigation and Scanning methods moved to extensions
    
    /// Resolves one difference by copying or moving the file between the two panes — the
    /// single-row sync action. On failure it presents a retryable error (`present(retry:)`)
    /// that re-invokes this exact call; bulk syncs go through `syncAll`, which owns the
    /// "Apply to all" collision flow and the progress overlay.
    /// If the destination already exists, prompts for Replace / Keep Both / Skip before overwriting.
    /// - Parameters:
    ///   - difference: The discrepancy to resolve (determines from/to paths from `action`).
    ///   - isMove: If true, moves the file; otherwise copies.
    ///   - fileManager: Optional override for tests (defaults to `self.fileManager`).
    public func syncFile(_ difference: FileDifference, isMove: Bool = false, fileManager: FileManaging? = nil) async {
        let activeFM = fileManager ?? self.fileManager
        // Mark the difference as syncing (published row + authoritative id set)
        markSyncing(ids: [difference.id])

        let urls = difference.transferURLs
        let fromURL = urls.from
        var toURL = urls.to

        // If destination exists, prompt before overwriting (same behavior as copy-from-tree).
        // The prompt itself stays on the MainActor.
        let (destinationExists, destinationIsDirectory) = await Self.statExists(at: toURL, fileManager: activeFM)

        /// Prompts for a collision at `collidingURL` and returns the URL the operation should
        /// target: `collidingURL` itself for Replace, a fresh unique sibling for Keep Both, or
        /// nil for Skip. `isDirectory` reflects the colliding item so the prompt can warn about
        /// wholesale folder replacement.
        func resolveCollision(at collidingURL: URL, isDirectory: Bool) async -> URL? {
            let resolution = collisionResolver(collidingURL.lastPathComponent, isMove, isDirectory)
            switch resolution {
            case .skip:
                return nil
            case .keepBoth:
                // generateUniqueURL stats candidate names in a loop; keep that off the main actor too.
                return await Task.detached(priority: .userInitiated) {
                    Self.generateUniqueURL(for: collidingURL, fileManager: activeFM)
                }.value
            case .replace:
                return collidingURL
            }
        }

        // True once the user has approved replacing whatever is at the CURRENT toURL, so the
        // pre-enqueue re-stat below doesn't re-prompt for a destination that is expected to exist.
        var replaceSanctioned = false
        if destinationExists {
            guard let resolvedURL = await resolveCollision(at: toURL, isDirectory: destinationIsDirectory) else {
                clearSyncing(ids: [difference.id])
                return
            }
            replaceSanctioned = (resolvedURL == toURL)
            toURL = resolvedURL
        }

        // The stat above is stale by the time the operation runs: the collision prompt holds
        // this call for an unbounded time, and the serial operation queue can add more. A file
        // that appears at a destination the stat saw as missing (cloud placeholder hydration,
        // another sync client) would be replaced without its overwrite prompt — the same gap
        // syncAll's promptShownSinceStatPass loop closes. Re-stat once right before enqueueing
        // and run the collision flow if a destination newly appeared. The residual window
        // between this stat and the queued operation executing is accepted: the operation runs
        // detached, where no prompt is possible.
        if !replaceSanctioned {
            let (newlyAppeared, newlyAppearedIsDirectory) = await Self.statExists(at: toURL, fileManager: activeFM)
            if newlyAppeared {
                guard let resolvedURL = await resolveCollision(at: toURL, isDirectory: newlyAppearedIsDirectory) else {
                    clearSyncing(ids: [difference.id])
                    return
                }
                toURL = resolvedURL
            }
        }


        let resolvedToURL = toURL
        let result = await enqueueFileOperation { () -> (error: Error?, trashed: URL?, from: URL?, to: URL?) in
            do {
                try Self.ensureParentDirectoryExists(for: resolvedToURL, fileManager: activeFM)
                
                let trashed: URL?
                if isMove {
                    trashed = try Self.safeMoveItem(at: fromURL, to: resolvedToURL, fileManager: activeFM)
                } else {
                    trashed = try Self.safeCopyItem(at: fromURL, to: resolvedToURL, fileManager: activeFM)
                }
                
                return (nil, trashed, fromURL, resolvedToURL)
                
            } catch {
                return (error, nil, nil, nil)
            }
        }
        
        if let error = result.error {
            present(
                .syncFailed(item: difference.relativePath, path: fromURL.path, reason: error.localizedDescription),
                retry: { [weak self] in Task { await self?.syncFile(difference, isMove: isMove) } }
            )

            clearSyncing(ids: [difference.id])
        } else {
            Logger.shared.info("Synced file: \(difference.relativePath)")
            if let from = result.from, let to = result.to {
                let actionName = "Sync \(difference.relativePath.components(separatedBy: "/").last ?? "")"
                if isMove {
                    self.registerMoveUndo(items: [(from: from, to: to, overwritten: result.trashed)], actionName: actionName, fileManager: activeFM)
                } else {
                    self.registerCopyUndo(items: [(source: from, destination: to, overwritten: result.trashed)], actionName: actionName, fileManager: activeFM)
                }
            }
            removeResolvedDifferences(ids: [difference.id])
        }
    }

    /// Resolves all differences in one direction by copying or moving each matching item (same behavior as per-file sync; collisions show "Apply to all" when applicable).
    /// Runs up to 4 file operations in parallel. Cancellation completes the current file then stops before starting new ones.
    /// - Parameters:
    ///   - direction: Which direction to sync (e.g. `.copyToRight` → copy all that are "missing on right" or "left newer").
    ///   - isMove: If true, moves each file; otherwise copies.
    ///   - subset: When non-nil, only differences in this array are considered (e.g. the currently filtered list). When nil, uses the full `differences` array.
    public func syncAll(direction: FileDifference.SyncAction, isMove: Bool = false, subset: [FileDifference]? = nil) async {
        let source = subset ?? differences
        let toSync = source.filter { $0.action == direction }
        let total = toSync.count
        guard total > 0 else { return }
        // Drop, don't queue, a bulk run started while another is in flight (see the flag's doc).
        guard !isBulkSyncRunning else { return }
        // A Verify All in flight is hashing the very files this run would overwrite; starting
        // anyway would feed it half-written content. Tell the user rather than silently drop.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for the current operation to finish before syncing")
            return
        }
        isBulkSyncRunning = true
        let toSyncIDs = Set(toSync.map { $0.id })
        bulkApplyToAllResolution = nil

        let progress = Progress(totalUnitCount: Int64(total))
        progress.localizedDescription = "Syncing \(total) files"
        progress.isCancellable = true
        activeProgress = progress

        markSyncing(ids: toSyncIDs)

        defer {
            isBulkSyncRunning = false
            bulkSyncProgress = nil
            bulkApplyToAllResolution = nil
            if activeProgress === progress { activeProgress = nil }
            clearSyncing(ids: toSyncIDs)
        }

        let activeFM = fileManager
        // Resolve from/to URLs first (pure string work), then stat every destination in one
        // detached pass: a per-file synchronous fileExists on the MainActor stalls the UI
        // proportionally to file count on network/cloud volumes before any copying starts.
        // Collision prompts still run afterwards on the MainActor, in list order, with the
        // same resolutions; once a prompt has held the run, the loop below re-stats results
        // the batch saw as missing so externally created destinations still get prompted.
        var candidates: [(difference: FileDifference, fromURL: URL, toURL: URL)] = []
        candidates.reserveCapacity(toSync.count)
        for difference in toSync {
            let urls = difference.transferURLs
            candidates.append((difference, urls.from, urls.to))
        }

        let statURLs = candidates.map(\.toURL)
        let statProgress = ProgressRef(progress)
        let destinationExists = await Task.detached(priority: .userInitiated) { () -> [(exists: Bool, isDirectory: Bool)] in
            // A cancelled run stops stat-ing; the prepare loop below breaks on the same flag
            // before ever reading the remaining (false) placeholders.
            statURLs.map { url in
                guard !statProgress.progress.isCancelled else { return (false, false) }
                var isDir: ObjCBool = false
                let exists = activeFM.fileExists(atPath: url.path, isDirectory: &isDir)
                return (exists, isDir.boolValue)
            }
        }.value

        var preparedList: [(FileDifference, URL, URL, Bool)] = []
        var skippedCount = 0
        // Destinations already claimed by earlier items in THIS batch. Targets are resolved here,
        // up front, but the copies run later in parallel — so a disk-only uniqueness check can't
        // see another pending target. Without this, a keep-both "report 2.txt" could coincide with
        // a different item whose real target is "report 2.txt" (missing at the batch stat), and the
        // workers would overwrite one with the other: silent data loss.
        var reservedTargets = Set<String>()
        // The batch stat above ran before the first prompt. A prompt holds this loop for an
        // unbounded time, during which a destination the batch saw as missing can be created
        // externally — and would then be replaced without its overwrite prompt. Once a prompt
        // has been shown, re-stat the "missing" results (still off the main actor) so such a
        // file gets the same prompt a just-in-time stat would have produced.
        var promptShownSinceStatPass = false
        for (index, candidate) in candidates.enumerated() {
            if progress.isCancelled { break }
            var toURL = candidate.toURL
            var destinationOccupied = destinationExists[index].exists
            var destinationIsDirectory = destinationExists[index].isDirectory
            if !destinationOccupied && promptShownSinceStatPass {
                (destinationOccupied, destinationIsDirectory) = await Self.statExists(at: toURL, fileManager: activeFM)
            }
            if destinationOccupied {
                let fileName = toURL.lastPathComponent
                let resolution: CollisionResolution
                if let cached = bulkApplyToAllResolution {
                    resolution = cached
                } else {
                    promptShownSinceStatPass = true
                    let (res, applyToAll) = bulkCollisionResolver(fileName, isMove, destinationIsDirectory)
                    if applyToAll { bulkApplyToAllResolution = res }
                    resolution = res
                }
                switch resolution {
                case .skip:
                    skippedCount += 1
                    continue
                case .keepBoth:
                    let collidingURL = toURL
                    let claimed = reservedTargets
                    toURL = await Task.detached(priority: .userInitiated) {
                        Self.generateUniqueURL(for: collidingURL, fileManager: activeFM, reserved: claimed)
                    }.value
                case .replace:
                    break
                }
            }
            // Final guard for the non-collision paths (a "missing" target, or a Replace): its plain
            // name may still be one an earlier item's keep-both already claimed this batch. Uniquify
            // against disk + the reserved set so no two items ever share a destination.
            if reservedTargets.contains(toURL.path) {
                let claimedURL = toURL
                let claimed = reservedTargets
                toURL = await Task.detached(priority: .userInitiated) {
                    Self.generateUniqueURL(for: claimedURL, fileManager: activeFM, reserved: claimed)
                }.value
            }
            reservedTargets.insert(toURL.path)
            preparedList.append((candidate.difference, candidate.fromURL, toURL, isMove))
        }

        // Skipped items still count toward the visible total; treat them as already completed
        // so the progress can reach 100% instead of stalling at (total - skipped).
        progress.completedUnitCount = Int64(skippedCount)
        bulkSyncProgress = (skippedCount, total)
        let skipped = skippedCount
        let progressRef = ProgressRef(progress)
        let weakRef = WeakSyncManagerRef(self)
        let totalCount = total
        let workList = preparedList

        let result = await enqueueFileOperation {
            await Self.performBulkSyncIO(
                workList: workList,
                concurrency: 4,
                progress: progressRef,
                completedBase: skipped,
                fileManager: activeFM,
                reportCompleted: { completed in weakRef.value?.bulkSyncProgress = (completed, totalCount) }
            )
        }

        for (diff, (trashed, from, to)) in result.successes {
            let actionName = "Sync \(diff.relativePath.components(separatedBy: "/").last ?? "")"
            if isMove {
                registerMoveUndo(items: [(from: from, to: to, overwritten: trashed)], actionName: actionName, fileManager: activeFM)
            } else {
                registerCopyUndo(items: [(source: from, destination: to, overwritten: trashed)], actionName: actionName, fileManager: activeFM)
            }
        }
        removeResolvedDifferences(ids: Set(result.successes.map { $0.0.id }))
        // No per-failure isSyncing reset here: the defer above clears the flag for every
        // item of this run, and nothing can observe the list before it runs.
        if result.failures.count == 1, let (diff, error) = result.failures.first {
            present(.syncFailed(
                item: diff.relativePath,
                path: diff.sourceItemPath,
                reason: error.localizedDescription,
                isRetryable: false
            ))
        } else if result.failures.count > 1 {
            // The alert holds one error at a time, so presenting per failure would leave only
            // the last one visible. Log each failure individually, then present one aggregate.
            for (diff, error) in result.failures {
                Logger.shared.error(SyncError.syncFailed(
                    item: diff.relativePath,
                    path: diff.sourceItemPath,
                    reason: error.localizedDescription,
                    isRetryable: false
                ).logDescription)
            }
            let (firstDiff, firstError) = result.failures[0]
            present(.bulkFailed(
                verb: "sync",
                failureCount: result.failures.count,
                firstItem: firstDiff.relativePath,
                firstPath: firstDiff.sourceItemPath,
                firstReason: firstError.localizedDescription
            ))
        }
    }

    /// Removes selected paths that no longer exist in the trees (e.g. after move/delete) to avoid
    /// ghost selection. A pane whose tree is still loading is skipped: progressive loading
    /// publishes a shallow (root-children-only) tree before the deep walk finishes, and pruning
    /// against it would wipe a still-valid deeper selection.
    public func pruneSelection() {
        // Collecting every path in a pane's tree is a full main-thread walk — skip it
        // outright when the pane has no selection (the common case, e.g. the post-scan
        // prune during launch churn).
        if !isLoadingLeftTree, !selectedLeftPaths.isEmpty {
            var allLeftPaths = Set<String>()
            collectPaths(in: leftTree, into: &allLeftPaths)
            let prunedLeft = selectedLeftPaths.filter { allLeftPaths.contains($0) }
            if prunedLeft != selectedLeftPaths {
                selectedLeftPaths = prunedLeft
            }
        }
        if !isLoadingRightTree, !selectedRightPaths.isEmpty {
            var allRightPaths = Set<String>()
            collectPaths(in: rightTree, into: &allRightPaths)
            let prunedRight = selectedRightPaths.filter { allRightPaths.contains($0) }
            if prunedRight != selectedRightPaths {
                selectedRightPaths = prunedRight
            }
        }
    }

    /// Defers selection pruning to the next run loop to avoid reentrant list delegate mutations.
    func scheduleSelectionPrune() {
        guard !hasPendingSelectionPrune else { return }
        hasPendingSelectionPrune = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingSelectionPrune = false
            self.pruneSelection()
        }
    }
    
    private func collectPaths(in tree: [FileNode], into paths: inout Set<String>) {
        for node in tree {
            paths.insert(node.id)
            if let children = node.children {
                collectPaths(in: children, into: &paths)
            }
        }
    }

    // Implementations moved to FileOperations.swift

    // Diff algorithms moved to FileDiffEngine.swift
}

// MARK: - Bulk sync helpers (Sendable-safe refs and actors for parallel workers)

// ProgressRef and WeakSyncManagerRef are internal (not private) because the verify machinery
// in FileSyncManager+Verify.swift shares the parallel-worker scaffolding.
final class ProgressRef: @unchecked Sendable {
    let progress: Progress
    init(_ progress: Progress) { self.progress = progress }
}

final class WeakSyncManagerRef: @unchecked Sendable {
    weak var value: FileSyncManager?
    init(_ value: FileSyncManager?) { self.value = value }
}

/// Hands work items one at a time to the parallel workers.
private actor WorkQueue<Item: Sendable> {
    private let items: [Item]
    private var index: Int = 0
    init(items: [Item]) { self.items = items }
    func next() -> Item? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}

/// Monotonic completed-item counter shared by the parallel workers.
private actor CompletedCounter {
    private var completed: Int = 0
    func increment() -> Int {
        completed += 1
        return completed
    }
}

private actor BulkSyncResultsCollector {
    private var successes: [(FileDifference, (URL?, URL, URL))] = []
    private var failures: [(FileDifference, Error)] = []
    func addSuccess(_ diff: FileDifference, _ result: (URL?, URL, URL)) {
        successes.append((diff, result))
    }
    func addFailure(_ diff: FileDifference, _ error: Error) {
        failures.append((diff, error))
    }
    func get() -> (successes: [(FileDifference, (URL?, URL, URL))], failures: [(FileDifference, Error)]) {
        (successes, failures)
    }
}

