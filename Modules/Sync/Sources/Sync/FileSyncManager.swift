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
    /// The `FileCollision` carries the source and destination paths (so the prompt can say
    /// which copy is replacing which) and whether the colliding destination is a folder (so
    /// it can warn that replacing a folder replaces its whole contents).
    public var collisionResolver: @MainActor (FileCollision) -> CollisionResolution = { _ in
        return .skip
    }

    /// The bulk-sync variant of `collisionResolver`, adding an "Apply to all" choice.
    /// Defaults to skipping the conflicting item; the app wires an NSAlert-backed prompt at construction.
    public var bulkCollisionResolver: @MainActor (FileCollision) -> (resolution: CollisionResolution, applyToAll: Bool) = { _ in
        return (.skip, false)
    }

    /// Confirms a copy/move before any I/O starts — every transfer entry point
    /// (`transferItems`, `syncFile`, `syncAll`) asks it exactly once per user action, so a
    /// stray click can be cancelled while it still costs nothing. Defaults to proceeding
    /// (a transfer is recoverable: replaces are separately prompted and everything is
    /// undoable); the app wires an NSAlert gated by the "Confirm before copying or moving"
    /// setting at construction.
    public var transferConfirmer: @MainActor (TransferSummary) -> Bool = { _ in
        return true
    }

    /// Resolves a destination name the destination provider forbids (Dropbox/OneDrive reject
    /// trailing spaces or dots; OneDrive also certain characters and reserved names), BEFORE
    /// any I/O: writing such a name into a provider's folder creates an item the provider
    /// silently never uploads — a local-only doppelganger that looks identical to its
    /// sanitized sibling. Defaults to `.skip` so an unwired manager never creates one; the
    /// app wires an NSAlert-backed prompt (offering the sanitized name) at construction.
    /// Only consulted when the destination lies inside a provider root known from the last
    /// scan (see `lastScanProviders`).
    public var invalidNameResolver: @MainActor (NameViolationPrompt) -> InvalidNameResolution = { _ in
        return .skip
    }

    /// The pane providers of the most recent completed scan; how transfer destinations are
    /// attributed to a provider for the `invalidNameResolver` pre-write name check. nil until
    /// a scan lands (tests, CLI cold start) — destinations are then not name-checked, which
    /// preserves the pure pre-seam behavior. Cleared with the rest of the comparison state
    /// on provider changes and swapped in `swapPanes`.
    var lastScanProviders: (left: CloudProvider, right: CloudProvider)?

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

    // MARK: Tidy — in-provider duplicate finder (see FileSyncManager+Duplicates.swift)

    /// Duplicate/related groups from the most recent Find Duplicates scan of one provider.
    @Published public var duplicateGroups: [DuplicateGroup] = []
    /// The absolute root the current `duplicateGroups` were scanned from — captured at scan time so
    /// breadcrumbs stay correct even if the user navigates elsewhere afterward.
    @Published public var duplicateScanRoot: String? = nil
    /// True while a Find Duplicates scan (walk + hash + group) is running.
    @Published public var isFindingDuplicates = false
    /// Human-readable progress for the running duplicate scan (e.g. "Hashing 340 candidates").
    @Published public var duplicateScanStatus: String? = nil
    /// Numeric progress for the duplicate scan's hashing phase; nil during the walk phase (total
    /// unknown) and whenever no scan is running. Drives the determinate bar in Tidy.
    @Published public var duplicateScanProgress: (completed: Int, total: Int)? = nil
    /// Bumped when a duplicate scan starts or ends, so main-actor progress hops scheduled by a
    /// finished/cancelled scan drop themselves instead of republishing stale status or numbers.
    var duplicateScanEpoch = 0
    /// True once a duplicate scan has completed at least once (drives the empty-vs-results state).
    @Published public var hasFoundDuplicates = false
    /// Store for "Keep separate" duplicate-group keys (injectable so tests don't touch standard).
    public var duplicateIgnoreDefaults: UserDefaults = .standard
    /// The in-flight Find Duplicates task, so the UI can cancel a long scan.
    public var duplicateScanTask: Task<Void, Never>?

    // MARK: Filing — suggest where loose files go (see FileSyncManager+Filing.swift)

    /// Filing suggestions from the most recent scan of a picked folder.
    @Published public var filingSuggestions: [FilingSuggestion] = []
    /// True while a Filing scan (walk folder + learn taxonomy + suggest) is running.
    @Published public var isSuggestingFiles = false
    /// Human-readable progress for the running Filing scan.
    @Published public var filingScanStatus: String? = nil
    /// True once a Filing scan has completed at least once.
    @Published public var hasSuggestedFiling = false
    /// The folder the current suggestions were scanned from.
    @Published public var filingScanFolder: String? = nil
    /// The in-flight Filing scan task, so the UI can cancel it.
    public var filingScanTask: Task<Void, Never>?
    /// On-device content extractor for Filing (file path → entity/keyword tokens), injected by the
    /// app (PDF text / OCR / NaturalLanguage). nil = filename-only (F1). Gated by the read-contents
    /// setting. Runs only on files with no confident home from their name.
    public var filingContentExtractor: (@Sendable (String) async -> Set<String>)?
    /// Defaults store for the Filing read-contents toggle (injectable so tests don't touch standard).
    public var filingContentDefaults: UserDefaults = .standard

    /// Global sorting preference for the file trees.
    @Published public var sortOption: SortOption = .name {
        didSet {
            guard sortOption != oldValue else { return }
            // Invalidate prefetch cache for roots as they need re-sorting or re-scanning
            prefetchedTrees.removeAll()
            if sortOption == .tags {
                // Trees are built WITHOUT Finder tags unless sorting by them (the per-file
                // xattr fetch dominated large scans — see TreeBuilder.includeTags), so the
                // current nodes have nothing to re-sort by. Reload from disk instead; the
                // fresh walk includes tags because this option is now current.
                noteScanConfigChanged()
                refreshSubject.send()
            } else {
                // Re-sort current trees when the option changes — off the main actor; the full
                // re-sort of both trees froze the UI on large panes.
                Task { await self.resortTreesAndRefilter() }
            }
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
    /// Focus-relative and session-scoped: navigation clears it (via `clearSessionIgnoredPaths()`,
    /// so the clear never counts as the user un-ignoring). Every USER edit is mirrored into
    /// `ignoredItemsStore` (root-relative) when `rememberIgnoredItems` is on, which is what
    /// makes ignores survive rescans, navigation, and relaunches.
    @Published public var ignoredPaths: Set<String> = [] {
        didSet {
            guard ignoredPaths != oldValue else { return }
            persistIgnoredPathsDelta(from: oldValue, to: ignoredPaths)
            Task { await self.applyFilters() }
        }
    }

    /// Durable ignore store (root-relative paths, keyed per provider pair). Assigned by the
    /// app at launch; nil (tests, CLI) preserves the pure session behavior. Edits made in
    /// Settings (un-ignore, clear all) publish through the store, so re-filter on them.
    public var ignoredItemsStore: IgnoredItemsStore? {
        didSet {
            ignoredItemsStoreCancellable = ignoredItemsStore?.$rootRelativePaths
                .dropFirst()
                .sink { [weak self] _ in
                    Task { await self?.applyFilters() }
                }
        }
    }
    private var ignoredItemsStoreCancellable: AnyCancellable?

    /// When true (the default), ignoring an item also records it in `ignoredItemsStore` and
    /// stored ignores apply to every scan. Off restores the old session-only behavior; the
    /// stored set is kept, just not applied. Set by the app from persisted settings.
    @Published public var rememberIgnoredItems: Bool = true {
        didSet {
            guard rememberIgnoredItems != oldValue else { return }
            Task { await self.applyFilters() }
        }
    }

    /// Name patterns (e.g. `.DS_Store`, `*.tmp`, `node_modules`) hidden from the Differences
    /// list on every scan; see `IgnoreRules`. Set by the app from persisted settings.
    @Published public var ignorePatterns: [String] = [] {
        didSet {
            guard ignorePatterns != oldValue else { return }
            Task { await self.applyFilters() }
        }
    }

    /// Modification dates within this many seconds compare as equal during scans (see
    /// `FileDiffEngine.computeDifferences`). Set by the app from persisted settings; changing
    /// it requests a fresh scan, since the current differences were computed under the old
    /// tolerance.
    @Published public var dateToleranceSeconds: TimeInterval = 1 {
        didSet {
            guard dateToleranceSeconds != oldValue else { return }
            noteScanConfigChanged()
            refreshSubject.send()
        }
    }

    /// When true, every scan finishes with a background checksum pass over same-size pairs that
    /// only differ by date, hiding the ones whose content is identical (see
    /// `autoVerifySameSizePairs(scanGeneration:)`). Set by the app from persisted settings;
    /// toggling requests a rescan so the change applies immediately in both directions.
    @Published public var autoVerifySameSizeDuringScan: Bool = false {
        didSet {
            guard autoVerifySameSizeDuringScan != oldValue else { return }
            noteScanConfigChanged()
            refreshSubject.send()
        }
    }

    /// True while a navigation clear of `ignoredPaths` is running, so its mass removal is
    /// never mirrored into the durable store as a user un-ignore.
    private var suppressIgnorePersistence = false

    /// Clears the session ignore layer without touching the durable store. The navigation
    /// paths call this instead of mutating `ignoredPaths` directly.
    func clearSessionIgnoredPaths() {
        guard !ignoredPaths.isEmpty else { return }
        suppressIgnorePersistence = true
        defer { suppressIgnorePersistence = false }
        ignoredPaths.removeAll()
    }

    /// Mirrors a user edit of the session ignore set into the durable store, translating
    /// focus-relative paths to root-relative ones under the current left focus.
    ///
    /// Only while both panes share one focus: with divergent foci a focus-relative path names
    /// DIFFERENT items on the two sides, and the left-focus translation would store an entry
    /// that later hides an unrelated pair (e.g. right pane in Docs, left at root: ignoring
    /// that row must not durably hide the root-level pair of the same name). Divergent-foci
    /// ignores stay session-only — exactly the pre-durable-layer behavior.
    private func persistIgnoredPathsDelta(from oldValue: Set<String>, to newValue: Set<String>) {
        guard !suppressIgnorePersistence, rememberIgnoredItems, let store = ignoredItemsStore,
              leftRelativePath == rightRelativePath else { return }
        let focus = leftRelativePath
        let added = newValue.subtracting(oldValue)
        let removed = oldValue.subtracting(newValue)
        if !added.isEmpty {
            store.add(Set(added.map { Self.rootRelativePath($0, focus: focus) }))
        }
        if !removed.isEmpty {
            store.remove(Set(removed.map { Self.rootRelativePath($0, focus: focus) }))
        }
    }

    /// The ignore set filtering actually uses: the session layer plus the durable store's
    /// entries translated into the current focus's coordinates. Public so the pane context
    /// menus can toggle against what the user actually sees (a durably ignored node shows as
    /// ignored, and toggling it removes it from the store via the session didSet's delta).
    public var effectiveIgnoredPaths: Set<String> {
        guard rememberIgnoredItems, let store = ignoredItemsStore, !store.rootRelativePaths.isEmpty else {
            return ignoredPaths
        }
        return ignoredPaths.union(Self.focusRelativePaths(fromRootRelative: store.rootRelativePaths, focus: leftRelativePath))
    }

    /// Toggles the ignore state of focus-relative paths against the EFFECTIVE set — what the
    /// user actually sees — so a durably ignored node (hidden by the store, absent from the
    /// session set) un-ignores instead of being "ignored" a second time. When every target is
    /// already ignored the action un-ignores them all, otherwise it ignores them all.
    ///
    /// Un-ignoring removes each target's exact entry AND any covering ancestor entry ("docs"
    /// ignored, target "docs/report.txt") from both layers: the menu label says "Include", so
    /// the clicked item must actually become visible — inserting or keeping a covered state
    /// would leave the row struck through with the toggle silently doing nothing.
    public func toggleIgnored(focusRelativePaths targets: Set<String>) {
        guard !targets.isEmpty else { return }
        let effective = effectiveIgnoredPaths
        let allIgnored = targets.allSatisfy { Self.isIgnoredPath($0, ignored: effective) }
        guard allIgnored else {
            ignoredPaths.formUnion(targets)
            return
        }

        // The session didSet's delta also removes from the store; the direct store removal
        // below covers entries the session layer never held (post-navigation, prior session).
        ignoredPaths = ignoredPaths.filter { entry in
            !targets.contains { $0 == entry || $0.hasPrefix(entry + "/") }
        }
        // Same equal-foci condition as persistIgnoredPathsDelta: with divergent foci the
        // left-focus translation could remove a stored entry belonging to a different pair.
        if rememberIgnoredItems, let store = ignoredItemsStore, leftRelativePath == rightRelativePath {
            let focus = leftRelativePath
            let rootTargets = targets.map { Self.rootRelativePath($0, focus: focus) }
            let covering = store.rootRelativePaths.filter { entry in
                rootTargets.contains { $0 == entry || $0.hasPrefix(entry + "/") }
            }
            store.remove(covering)
        }
    }

    /// Removes one durable ignore entry (root-relative, as listed in Settings) plus its
    /// session counterpart under the current focus. Exactly that entry: when a covering
    /// ancestor entry also exists it keeps its own effect (and its own row in the Settings
    /// list) until removed too — the list edits entries, it doesn't re-derive coverage.
    public func unignoreRootRelative(_ path: String) {
        ignoredItemsStore?.remove([path])
        let focus = leftRelativePath
        let sessionPath: String?
        if focus.isEmpty {
            sessionPath = path
        } else if path.hasPrefix(focus + "/") {
            sessionPath = String(path.dropFirst(focus.count + 1))
        } else {
            sessionPath = nil
        }
        if let sessionPath, ignoredPaths.contains(sessionPath) {
            ignoredPaths.remove(sessionPath)
        }
    }

    /// Empties both ignore layers for the current provider pair (Settings' "Clear all").
    public func clearAllIgnoredItems() {
        ignoredItemsStore?.removeAll()
        clearSessionIgnoredPaths()
    }

    /// Root-relative identity of a focus-relative path (`focus` empty = pane root). The LEFT
    /// focus is used as the identity's coordinate system; in the dominant workflow both panes
    /// navigate together, so the identity reads the same from either side.
    nonisolated static func rootRelativePath(_ path: String, focus: String) -> String {
        focus.isEmpty ? path : focus + "/" + path
    }

    /// The subset of root-relative entries that live under `focus`, re-expressed relative to
    /// it. Entries at or above the focus are deliberately dropped: navigating INTO an ignored
    /// folder shows its contents (that's how you inspect or un-ignore it) rather than
    /// presenting an inexplicably empty comparison.
    nonisolated static func focusRelativePaths(fromRootRelative paths: Set<String>, focus: String) -> Set<String> {
        guard !focus.isEmpty else { return paths }
        let prefix = focus + "/"
        var result: Set<String> = []
        for path in paths where path.hasPrefix(prefix) {
            result.insert(String(path.dropFirst(prefix.count)))
        }
        return result
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
    /// Bumped by `didSet` on EVERY write to its pane's published tree — no writer can forget
    /// it, including `swap(&leftTree, &rightTree)` and tests assigning the public property
    /// directly. A filter pass compares its freshly computed trees against the published ones
    /// OFF the main actor (the deep equality walk is O(total nodes) and hitched the UI on
    /// large panes); a verdict is only valid while nothing wrote that pane's published tree
    /// mid-flight, which its version detects. Per pane, so one pane's publish doesn't
    /// invalidate an overlapping pass's verdict for the OTHER pane — during a dual-pane load
    /// passes routinely overlap, and a shared version sent every other pass back to the
    /// main-actor fallback compare.
    internal private(set) var publishedLeftTreeVersion = 0
    /// Right-pane counterpart of `publishedLeftTreeVersion`.
    internal private(set) var publishedRightTreeVersion = 0

    /// Bumped on every raw-tree publish (see `adoptRawTree`). Guards the off-main resort in
    /// `resortTreesAndRefilter()` against clobbering trees a load published mid-sort.
    internal var rawTreeGeneration = 0

    /// Raw file tree for the left pane (before hidden/ignored filtering).
    internal var rawLeftTree: [FileNode] = []
    /// Filtered file tree for the left pane (used by the UI).
    @Published public var leftTree: [FileNode] = [] {
        didSet { publishedLeftTreeVersion += 1 }
    }

    /// Raw file tree for the right pane (before hidden/ignored filtering).
    internal var rawRightTree: [FileNode] = []
    /// Filtered file tree for the right pane (used by the UI).
    @Published public var rightTree: [FileNode] = [] {
        didSet { publishedRightTreeVersion += 1 }
    }

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
        /// `scanConfigGeneration` at key construction. Keying the target on the config epoch
        /// means a refresh requested AFTER a scan-affecting change never reads as a duplicate
        /// of one started before it — the dedupe otherwise swallowed the follow-up refresh a
        /// config didSet requested while a same-target refresh was in flight (e.g. switching
        /// to the Tags sort mid-scan left the panes tag-less and old-sorted).
        let config: Int
    }

    /// Epoch of "what a load/scan would produce". Bumped whenever something makes an
    /// in-flight refresh's output stale for reasons a `RefreshKey`'s paths can't see: a
    /// scan-affecting setting changed (date tolerance, auto-verify, a sort switch that needs
    /// a from-disk reload), comparison state was invalidated, or a file operation finished.
    /// See `RefreshKey.config`.
    internal private(set) var scanConfigGeneration = 0

    /// Records that in-flight refresh results are stale (see `scanConfigGeneration`).
    internal func noteScanConfigChanged() {
        scanConfigGeneration += 1
    }

    /// The dedupe identity for a refresh of the given targets under the current config epoch.
    internal func makeRefreshKey(left: CloudProvider, right: CloudProvider) -> RefreshKey {
        RefreshKey(
            leftId: left.id, leftPath: left.path,
            rightId: right.id, rightPath: right.path,
            leftRel: leftRelativePath, rightRel: rightRelativePath,
            config: scanConfigGeneration
        )
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

    /// Reverts a `preCountFileOperation()` whose operation will never be enqueued — the user
    /// declined its confirmation prompt. Only for that pairing: operations that DID enqueue
    /// are decremented by `enqueueFileOperation`'s unconditional completion handler.
    public func cancelPreCountedFileOperation() {
        activeFileOperationsCount = max(0, activeFileOperationsCount - 1)
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
                // A refresh already in flight walked mid-operation disk state; the post-op
                // refresh below must supersede it, not dedupe against it.
                self?.noteScanConfigChanged()
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
        // Deliberately path-layers only, NO pattern matching: this predicate drives the pane
        // rows' ignored look AND the context menu's Ignore/Include label, whose click lands in
        // `toggleIgnored` — which can only edit the path layers. Counting pattern matches here
        // made the label promise an "Include" the toggle cannot deliver (a pattern can't be
        // excepted per item), and the resulting formUnion mirrored a phantom entry into the
        // durable store. Pattern-hidden items are managed in Settings, not per row.
        return Self.isIgnoredPath(rPath, ignored: effectiveIgnoredPaths)
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

    /// Removes resolved differences by id AND by pending-copy identity. Sync callers that
    /// operate on captured values (guided review's frozen queue, a Copy Remaining subset) can
    /// outlive a rescan, which regenerates every row UUID — an id-only removal then no-ops and
    /// the just-resolved row ghosts in the list until the next rescan lands. Matching a row
    /// this way is safe for replace/plain copies (the operation just equalized the two sides);
    /// a keep-both leaves the destination differing, but its row was removed under fresh ids
    /// too, and the operation's own triggered rescan re-adds whatever still differs.
    internal func removeResolvedDifferences(matching resolved: [FileDifference]) {
        guard !resolved.isEmpty else { return }
        let keys = Set(resolved.map(Self.pendingCopyKey))
        var ids = Set(resolved.map(\.id))
        // `differences` is a filtered subset of `rawDifferences`, so scanning raw covers both.
        for row in rawDifferences where keys.contains(Self.pendingCopyKey(for: row)) {
            ids.insert(row.id)
        }
        removeResolvedDifferences(ids: ids)
    }

    /// The identity of "this pending copy" across rescans (ids don't survive them): the
    /// absolute source→destination pair. Absolute on purpose — `relativePath` is relative to
    /// the FOCUSED folder, so a same-named file in another focus could collide and get a real
    /// row removed. The pair is also swap-invariant (`mirrored()` flips action and sides
    /// together, so from→to is unchanged) and naturally excludes a row whose direction flipped
    /// since capture — that is a different pending copy and must survive.
    private nonisolated static func pendingCopyKey(for difference: FileDifference) -> String {
        let urls = difference.transferURLs
        return "\(urls.from.path)|\(urls.to.path)"
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
        let ignored = effectiveIgnoredPaths
        let patterns = ignorePatterns
        let verifiedSame = verifiedSameDifferenceIds
        let syncingIds = syncingDifferenceIds
        let dropDriveDateNoise = ignoreGoogleDriveNewerDateOnly && lastRightProviderType == .googleDrive
        // Snapshot the published trees so the tree-changed comparisons run in the detached
        // compute: deep equality is a full O(nodes) walk, and doing it on the main actor
        // (twice per pass, several passes per load+scan cycle) hitched the UI on large panes.
        let publishedLeft = leftTree
        let publishedRight = rightTree
        let leftVersion = publishedLeftTreeVersion
        let rightVersion = publishedRightTreeVersion

        let (state, leftTreeChanged, rightTreeChanged) = await Task.detached(priority: .userInitiated) {
            let state = Self.computeFilteredState(
                rawLeftTree: rawLeft,
                rawRightTree: rawRight,
                rawDifferences: rawDiffs,
                showHidden: showHidden,
                ignoredPaths: ignored,
                ignorePatterns: patterns,
                verifiedSameDifferenceIds: verifiedSame,
                syncingDifferenceIds: syncingIds,
                dropDriveDateNoise: dropDriveDateNoise
            )
            return (state, state.leftTree != publishedLeft, state.rightTree != publishedRight)
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
        // NSTableView mouse-down and mouse-up drops the click ("dead clicks"). The tree
        // comparisons ran off-main against entry-time snapshots; each is trusted only while
        // nothing wrote THAT pane's published tree since (its `published*TreeVersion`, bumped
        // by the property's own didSet) — on the rare mid-flight write, fall back to a live
        // compare for just that pane.
        if leftVersion == publishedLeftTreeVersion ? leftTreeChanged : (self.leftTree != state.leftTree) {
            self.leftTree = state.leftTree
        }
        if rightVersion == publishedRightTreeVersion ? rightTreeChanged : (self.rightTree != state.rightTree) {
            self.rightTree = state.rightTree
        }
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
        ignorePatterns: [String] = [],
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
        if !ignorePatterns.isEmpty {
            filteredDifferences = filteredDifferences.filter { diff in
                !IgnoreRules.matches(diff.relativePath, patterns: ignorePatterns)
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
    ///   - confirmed: Pass true when the calling UI already embodies the user's confirmation
    ///     for this exact transfer (a Retry click on its failure alert, a review-card accept)
    ///     — the `transferConfirmer` prompt is skipped so one gesture never asks twice.
    /// - Returns: Whether the operation ran (Replace/Keep Both/plain copy); false when the user
    ///   skipped at a collision prompt or the operation failed. This is the only reliable
    ///   "did it happen" signal — inferring from the differences list breaks the moment the
    ///   post-operation rescan regenerates row UUIDs (guided review records outcomes from it).
    @discardableResult
    public func syncFile(_ difference: FileDifference, isMove: Bool = false, fileManager: FileManaging? = nil, confirmed: Bool = false) async -> Bool {
        let activeFM = fileManager ?? self.fileManager
        let urls = difference.transferURLs
        let fromURL = urls.from
        var toURL = urls.to

        // A row already marked in-flight is being handled by another syncFile — possibly
        // parked at one of the prompts below, whose modal spins the run loop and lets a
        // queued twin call run. Refuse rather than stack a second prompt: the twin's exit
        // would clearSyncing an id the first call still owns (the set is not a refcount),
        // making the parked sync invisible to Verify All's exclusion guard.
        guard !syncingDifferenceIds.contains(difference.id) else { return false }

        // Mark the difference as syncing BEFORE any prompt can hold this call, not after:
        // Verify All's exclusion guard reads `syncingDifferenceIds` precisely so that a
        // syncFile parked at a prompt is visible to it — a prompt's modal spins the run loop,
        // so a queued Verify All would otherwise start hashing the very file this sync is
        // about to overwrite. The defer releases the mark structurally on every exit — no
        // early return can leak an id (which would refuse Verify All and pane swaps for the
        // session). On the success path the row was already removed wholesale by
        // removeResolvedDifferences; clearSyncing on a removed row is a documented no-op.
        markSyncing(ids: [difference.id])
        defer { clearSyncing(ids: [difference.id]) }

        // Confirm before any I/O: single-row syncs are one click away in the Differences
        // list, so a mis-click must be cancellable while it still costs nothing.
        if !confirmed {
            let userConfirmed = transferConfirmer(TransferSummary(
                isMove: isMove,
                itemCount: 1,
                firstItemName: fromURL.lastPathComponent,
                sourceDirectory: fromURL.deletingLastPathComponent().path,
                destinationDirectory: toURL.deletingLastPathComponent().path
            ))
            guard userConfirmed else {
                Logger.shared.debug("Sync of \(difference.relativePath) cancelled at the confirmation prompt")
                return false
            }
        }

        // Provider name check: a destination name the provider forbids (e.g. a trailing
        // space on Dropbox) would be written locally and then never uploaded. The sanitized
        // target may collide with an existing item — the collision flow below stats whatever
        // URL comes out of here, so that case becomes a normal Replace/Keep Both/Skip prompt.
        switch checkDestinationName(for: toURL, isMove: isMove) {
        case .skip:
            return false
        case .sanitized(let sanitizedURL):
            toURL = sanitizedURL
        case .clean, .keepOriginal:
            break
        }

        // If destination exists, prompt before overwriting (same behavior as copy-from-tree).
        // The prompt itself stays on the MainActor.
        let (destinationExists, destinationIsDirectory) = await Self.statExists(at: toURL, fileManager: activeFM)

        /// Prompts for a collision at `collidingURL` and returns the URL the operation should
        /// target: `collidingURL` itself for Replace, a fresh unique sibling for Keep Both, or
        /// nil for Skip. `isDirectory` reflects the colliding item so the prompt can warn about
        /// wholesale folder replacement.
        func resolveCollision(at collidingURL: URL, isDirectory: Bool) async -> URL? {
            let resolution = collisionResolver(FileCollision(
                sourcePath: fromURL.path,
                destinationPath: collidingURL.path,
                isMove: isMove,
                isDirectory: isDirectory
            ))
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
                return false
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
                    return false
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
                // confirmed: the Retry click IS the confirmation — re-running the
                // transferConfirmer here would re-ask about an already-affirmed transfer,
                // and an Escape reflex would silently swallow the retry.
                retry: { [weak self] in Task { await self?.syncFile(difference, isMove: isMove, confirmed: true) } }
            )
            return false
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
            removeResolvedDifferences(matching: [difference])
            return true
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
