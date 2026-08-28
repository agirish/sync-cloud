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

    /// Whether the volume a not-yet-created destination will land on distinguishes names by case.
    ///
    /// A seam purely so the multi-volume batch is reachable from a test: a single machine's disk is
    /// one answer, and the bug this guards against needs two. `syncAll` asks per destination, and a
    /// wrong answer is a data-loss bug rather than a cosmetic one — a batch told "case-sensitive"
    /// about a case-INSENSITIVE destination lets two case-variant targets both pass its in-memory
    /// uniqueness check, after which the parallel workers write to one file.
    public var destinationCaseSensitivity: (URL) -> Bool = { url in
        FileSyncManager.volumeSupportsCaseSensitiveNamesForNewItem(at: url)
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
    ///
    /// Readable outside the module — like `lastScanRootNames` beside it, and for the same reason:
    /// it names the pair the published rows came from, which is what a caption ABOUT those rows has
    /// to use. Reading the panes instead would let a navigation after the scan rename the sources a
    /// caption is describing. Set only here.
    public internal(set) var lastScanProviders: (left: CloudProvider, right: CloudProvider)?

    /// The last path component of each compared folder at the moment the most recent scan's
    /// results were published — what the differences table's Path column anchors its paths to,
    /// so a root-level row can say "Home" instead of nothing. Captured with the results rather
    /// than read live from the panes: the panes can navigate away while the diff still describes
    /// the folders that were scanned. nil until a scan lands; cleared with the rest of the
    /// comparison state and swapped in `swapPanes`. Not `@Published` — it changes only inside
    /// the same publish that replaces `differences`, which already re-renders every reader.
    public internal(set) var lastScanRootNames: (left: String, right: String)?

    /// When the most recent comparison scan completed, for the pane header's freshness pill. nil
    /// until a scan lands and whenever the comparison state is invalidated (provider change), so a
    /// stale timestamp never outlives the diff it describes. A swap keeps it (same scan, sides
    /// traded). Published so the header re-renders as scans land.
    @Published public internal(set) var lastScanDate: Date?

    /// Confirms permanently deleting items that could not be moved to Trash (e.g. network volumes),
    /// given their **absolute paths**. Paths rather than basenames because this is the app's only
    /// unrecoverable action and its dialog has to be able to tell two same-named items apart — the
    /// duplicates flows ask about exactly that, since a group's copies usually share a name.
    /// Defaults to `false` so an unwired manager never destroys data; the app wires an
    /// NSAlert-backed confirmation at construction.
    public var permanentDeleteConfirmer: @MainActor ([String]) -> Bool = { _ in
        return false
    }

    /// Confirms a cloud (Claude) Filing classify before it commits, given a pre-flight cost estimate
    /// and this month's spend-vs-cap. Consulted once per **refine pass** — never by a scan, which
    /// classifies at ``FilingClassifierTier/free`` and cannot spend — and only when cloud Filing is
    /// actually on (`filingUsesAI && filingUsesCloud`), just before the classifier runs. The real
    /// cost is only known after the call, so this is the only chance to show the user a figure
    /// first. Returning false skips the cloud call and leaves the free scan's suggestions in place.
    /// Defaults to `true` (proceed) so an unwired manager keeps its prior behavior; the app wires an
    /// NSAlert-backed estimate/budget prompt at construction.
    public var filingCloudSpendConfirmer: @MainActor (FilingSpendPreflight) -> Bool = { _ in
        return true
    }

    /// Confirms a whole-tree pass whose PROBE ran out of budget — the tree is bigger than the pass
    /// can analyse without a wait worth warning about.
    ///
    /// Consulted only when the probe actually stopped, so on every ordinary source it never fires
    /// and costs nothing: the probe walk under its budget IS the tree the pass then uses.
    ///
    /// **Defaults to `false` — refuse — and that is the fail-safe direction here.** Proceeding costs
    /// time rather than data, so this is a weaker claim than `permanentDeleteConfirmer`'s, but the
    /// failure it guards is precisely a pass that never finishes: an unwired manager that proceeded
    /// would reintroduce the hang this exists to prevent, in the one configuration where nobody is
    /// watching. A refusal is not silent — the caller logs it and leaves the previous result
    /// standing. The app wires an NSAlert-backed prompt at construction.
    public var largeWalkConfirmer: @MainActor (LargeWalkPreflight) -> Bool = { _ in
        return false
    }

    /// **How much a whole-tree pass reads before it stops to ask.**
    ///
    /// Deliberately larger than `paneNodeBudget`, and the two are answering different questions. A
    /// pane must stay responsive, so its budget is about latency and it truncates silently because
    /// a partial view is still a useful view. These passes are deliberate acts with a progress bar
    /// and a cancel, so theirs is about whether the work is worth starting — and they cannot
    /// truncate at all, because a storage total or a duplicate group computed from part of a tree
    /// is a wrong ANSWER rather than a partial one.
    ///
    /// Measured (`PaneNodeBudgetBenchmark`, Release, warm, on a 196,726-directory home folder): a
    /// 400,000-entry walk costs ~2.3-2.5 s, which is a tolerable price for finding out that the
    /// real answer would cost minutes. Below this, no prompt appears and nothing is spent — the
    /// probe's tree is handed straight to the pass.
    nonisolated public static let defaultWholeTreeProbeBudget = 400_000

    /// The live probe budget. An instance property rather than the constant directly, so a test can
    /// drive the guard against a fixture of a dozen files instead of one of four hundred thousand —
    /// which is the difference between the confirm/decline paths being covered and being reasoned
    /// about.
    public var wholeTreeProbeBudget: Int = FileSyncManager.defaultWholeTreeProbeBudget

    /// The durable, structured Sync History (X2) every copy/move/delete is recorded into —
    /// separate from the in-memory Activity Log so it survives quit and can be filtered,
    /// exported, and reversed by run. Injected (defaults to the shared singleton) so tests get
    /// an isolated store. Recording is a best-effort side effect: `SyncHistoryStore.appendBatch`
    /// never throws and hands its disk write to a background queue, so a store failure can never
    /// block or fail the file operation that produced the record.
    public var syncHistoryStore: SyncHistoryStore = .shared

    /// The `UndoManager` action name captured the moment the last history-recorded run finished
    /// registering its undo group, plus that run's records. Together they let `undoLastSyncRun`
    /// verify the stack's top is STILL that run before reversing it — the shared `UndoManager` also
    /// carries Filing/rename/"New Folder" actions that are not sync runs and are not in the history.
    private(set) var lastRecordedRunUndoName: String?
    private(set) var lastRecordedRunRecords: [SyncHistoryRecord] = []
    /// Whether any run armed the pairing this session — distinguishes "the pairing was
    /// invalidated" (a manual ⌘Z, a mixed delete, a manager swap) from "no sync run ever
    /// happened", so the refusal banner doesn't claim history changed "since the last sync
    /// run" on a fresh launch that never had one.
    private(set) var hasArmedRunPairingThisSession = false

    /// Records a run's history entries, if any. A thin funnel so every op site records the same
    /// way and a future change (e.g. off switch) has one place to live. Never fails the caller.
    /// Also snapshots the run's undo-group name (each op site registers its undo BEFORE calling
    /// this) so "Undo Last Run" can later confirm it's still the top of the stack.
    ///
    /// `pairedWithUndo: false` appends to the durable store WITHOUT touching the pairing — for
    /// runs that registered no undo group covering exactly these records (an all-permanent
    /// delete: nothing reached the Trash, so nothing was registered). Snapshotting there would
    /// pair these records with whatever action happens to sit on top of the stack — and "Undo
    /// Last Run" would then describe this run while reversing that unrelated one. The previous
    /// pairing stays live: its group is still the top, so it still describes what undo() does.
    func recordSyncHistory(_ records: [SyncHistoryRecord], pairedWithUndo: Bool = true) {
        guard !records.isEmpty else { return }
        syncHistoryStore.appendBatch(records)
        guard pairedWithUndo else { return }
        lastRecordedRunUndoName = undoManager?.undoActionName
        lastRecordedRunRecords = records
        hasArmedRunPairingThisSession = true
    }

    /// Drops the run-undo pairing. Called on every direct `UndoManager` undo/redo (the
    /// `undoManager` didSet wires the notifications): a manual ⌘Z can pop run B and leave run
    /// A's *identically named* group ("Sync run") on top, where the name gate alone would pass —
    /// previewing B's records while reversing A. Identity can't be checked by name, so any
    /// undo/redo outside `undoLastSyncRun` (which clears the pairing itself) invalidates it.
    ///
    /// Also called (internal, from `deleteItems`) when an op registers an undo group WITHOUT
    /// arming the pairing — a mixed delete pushes a "Delete <trashedCount> Items" group whose
    /// name can collide with an earlier armed delete's, and the stale pairing would pass the
    /// name gate over the wrong group.
    func invalidateRunUndoPairing() {
        lastRecordedRunUndoName = nil
        lastRecordedRunRecords = []
    }

    /// A preview of what "Undo Last Run" would reverse, or nil when it must not act: nil unless the
    /// `UndoManager` can undo AND its next-undo action name still equals the last recorded run's
    /// (i.e. nothing — a Filing move, a rename, a New Folder, or a manual ⌘Z — has changed the top
    /// since). This is the gate that makes the reversal describe-what-it-does and never touch the
    /// wrong action.
    public var lastSyncRunUndoPreview: SyncRunUndoPreview? {
        guard let undoManager, undoManager.canUndo,
              let expected = lastRecordedRunUndoName,
              undoManager.undoActionName == expected,
              !lastRecordedRunRecords.isEmpty
        else { return nil }
        return SyncRunUndoPreview(actionName: expected, records: lastRecordedRunRecords)
    }

    /// Reverses the most recent sync run by reusing the app's existing, tested `UndoManager`
    /// reversal stack (safeMove-back, Trash-restore) — no new file-mutating path; bulk runs are one
    /// grouped step, so a whole run reverses at once. Guarded by `lastSyncRunUndoPreview`: it acts
    /// ONLY when the recorded run is still the top of the undo stack. If some other action is on top
    /// (Filing, rename, New Folder…) it refuses and names it, pointing the user at ⌘Z, rather than
    /// silently reversing something the Sync History window never showed. The app wires an NSAlert
    /// confirmation (built from the same preview) in front of this.
    public func undoLastSyncRun() {
        guard let undoManager else { return }
        guard let preview = lastSyncRunUndoPreview else {
            if undoManager.canUndo {
                let top = undoManager.undoActionName
                // A DEAD pairing (a manual ⌘Z/⇧⌘Z or a partial delete invalidated it) is not a
                // name mismatch: the top may well be named "Sync run", and the old text — "the
                // most recent action is “Sync run”, not a sync run" — contradicted itself.
                // NEVER-ARMED is different again: on a fresh launch with no sync run, "the undo
                // history changed since the last sync run" would invent a run — name the top
                // action instead (the pre-existing text, which is honest there).
                if lastRecordedRunUndoName == nil && hasArmedRunPairingThisSession {
                    banner = .warning("The undo history changed since the last sync run — use Edit ▸ Undo (⌘Z) to step back.")
                } else {
                    banner = .warning(top.isEmpty
                        ? "The most recent action isn't a sync run — use Edit ▸ Undo (⌘Z) to reverse it."
                        : "The most recent action is “\(top)”, not a sync run — use Edit ▸ Undo (⌘Z) to reverse it.")
                }
            } else {
                banner = .warning("There's no recent sync run to undo — the undo history resets when SyncCloud restarts.")
            }
            return
        }
        Logger.shared.info("Undoing last sync run: \(preview.actionName) — reversing \(preview.operationCount) operation(s)")
        undoManager.undo()
        // The run is consumed — clear the snapshot so a second press can't reverse it again (a redo
        // re-registers its own group with a fresh action name).
        lastRecordedRunUndoName = nil
        lastRecordedRunRecords = []
    }

    /// Initializes a new FileSyncManager with a specific file manager.
    /// - Parameter fileManager: The file manager to use. Defaults to `FileManager.default`.
    public init(fileManager: FileManaging = FileManager.default) {
        self.fileManager = fileManager
    }
    
    /// Cached differences from the latest scan before applying hidden/ignored filters.
    internal var rawDifferences: [FileDifference] = [] {
        didSet { rawDifferencesVersion += 1 }
    }
    /// Bumped on every write to ``rawDifferences``, including an in-place element edit. Lets
    /// `applyFilters()` tell whether the authoritative rows moved while its detached compute
    /// ran — the same trick `publishedLeftTreeVersion` plays for the panes, and the reason the
    /// reconcile pass there can be skipped rather than made cheaper.
    internal private(set) var rawDifferencesVersion = 0
    /// Counterpart for ``syncingDifferenceIds``: the other input the reconcile pass re-applies.
    internal private(set) var syncingDifferenceIdsVersion = 0
    /// IDs of differences with an in-flight sync/copy operation — the source of truth for the
    /// row-level `isSyncing` flag. `applyFilters()` rebuilds `differences` from
    /// `rawDifferences`, which never carries the flag, so a mid-operation filter pass (hidden
    /// toggle, ignore change, re-sort, a scan landing) would otherwise publish every row
    /// un-marked and re-enable the header sync actions while files are still being written.
    /// Every transition goes through `markSyncing`/`clearSyncing`, which update the set and
    /// the published rows in the same main-actor turn — and `applyFilters()` re-stamps the
    /// flag from this set (and drops resolved rows) at publish time, so a pass whose
    /// snapshot predates a transition cannot re-install stale rows.
    internal private(set) var syncingDifferenceIds: Set<UUID> = [] {
        didSet { syncingDifferenceIdsVersion += 1 }
    }
    /// IDs of differences that were verified as same content via checksum; these are hidden from the list until next scan.
    internal var verifiedSameDifferenceIds: Set<UUID> = []
    /// When non-nil, a "Verify All" run is in progress: (completed count, total count).
    @Published public var verifyAllProgress: (completed: Int, total: Int)?
    /// After Verify All completes, the differences that verified identical — the UI offers to
    /// copy them left→right. Cleared when the user copies or cancels, and whenever the rows
    /// underneath are superseded (rescan, pane retarget, swap).
    ///
    /// The list and the epoch its verdicts were hashed under travel together as one value
    /// (see ``VerifiedCopyOffer``), so an offer without its stamp is unrepresentable. Settable
    /// only inside this module — the app side reads it and nothing more.
    @Published public internal(set) var verifiedIdenticalForCopy: VerifiedCopyOffer?
    /// Filtered list of differences between the left and right panes (respects `showHiddenFiles`, `ignoredPaths`, and `verifiedSameDifferenceIds`).
    @Published public var differences: [FileDifference] = [] {
        didSet { publishedDifferencesVersion += 1 }
    }
    /// Bumped on every publish of ``differences``. Same role as ``publishedLeftTreeVersion``:
    /// it says whether the deep compare done off-main against an entry snapshot is still
    /// answering the question the main actor is about to ask.
    internal private(set) var publishedDifferencesVersion = 0
    /// How many times `applyFilters()` has had to run the reconcile pass because an input moved
    /// while its detached compute ran.
    ///
    /// Exists so the gate's FAST path is observable. The slow path is well covered — deleting the
    /// gate's condition fails two `InFlightSyncStateTests` — but no test can see a gate that
    /// silently never fires, and an optimization that never fires is one that does not exist.
    internal private(set) var reconcilePassesRun = 0
    /// The denominator for ``reconcilePassesRun``: passes that got far enough to evaluate the
    /// gate at all.
    ///
    /// Deliberately not `filterGeneration`, which counts every pass *started* — a superseded pass
    /// returns before the gate and would quietly deflate the ratio, making a gate that never
    /// fires look like one that fires often. Bumped where the gate is read, so the two numbers
    /// are always about the same set of passes.
    internal private(set) var filterPassesReachingPublish = 0
    /// Indicates whether a deep structure scan is currently in progress.
    @Published public var isScanning = false
    /// When the running scan started, or nil when none is running.
    ///
    /// The Compare scan is the longest thing the app does — two full directory walks — and until
    /// this existed it published a bare `isScanning` and nothing else, so its only report was an
    /// indeterminate spinner. Every lens scan says more than that. There is no honest *fraction* to
    /// publish (`FileDiffEngine.getFilesInDirectory` counts nothing on the way through, and adding
    /// a per-entry callback would put a main-actor hop in the hottest path in the app), so this
    /// publishes the one true number that costs nothing: how long it has been running.
    ///
    /// Set and cleared in lockstep with `isScanning`, so "scanning with no start time" is not a
    /// state any reader has to handle.
    @Published public internal(set) var scanStartedAt: Date?
    /// Indicates whether at least one successful scan has occurred.
    @Published public var hasScanned = false

    // MARK: Small persisted facts about what the user last did

    /// Where the manager keeps the handful of small facts that have to outlive a launch — each
    /// lens's last-completed scan target, and the Compare scan's last summary.
    ///
    /// Injected by the app; **nil — the default, what the CLI and bare test managers get — turns
    /// every one of them off entirely, reads and writes both.** Same rule as the cache-store URLs,
    /// and for the same reason: a fallback to `.standard` would have every test that completes a
    /// scan writing the user's real defaults.
    ///
    /// One property rather than one per feature, and named for the rule rather than for the first
    /// feature to need it (it was `lensAutoRescanDefaults`): a second injected store would be a
    /// second thing for the app to remember to set, and the failure mode of forgetting is a
    /// feature that is silently off.
    public var persistedUIStateDefaults: UserDefaults?

    /// The defaults key holding ``LastScanSummary`` as JSON.
    public static let lastScanSummaryKey = "compareLastScanSummary"

    /// **Whether the last completed Compare scan could read both sides in full.**
    ///
    /// Not persisted, unlike `lastScanSummary`: it describes rows that are on screen right now, and
    /// a coverage claim restored beside a table nobody has rebuilt would be a warning about a scan
    /// that is not there. Cleared by `invalidateComparisonState` with the rows it belongs to.
    ///
    /// See ``PartialComparison`` for what it costs the result — the short version is that a side
    /// whose root came back unread mints no Missing rows at all, so the count is a floor and
    /// nothing on screen said so.
    @Published public internal(set) var lastScanCoverage: PartialComparison = .complete

    /// What the last completed Compare scan found, restored at launch. See ``LastScanSummary``.
    ///
    /// `@Published` and loaded through ``loadLastScanSummary()`` rather than lazily in a getter:
    /// the empty state renders from it, and a getter that decoded on first read would decode
    /// inside `body`.
    @Published public internal(set) var lastScanSummary: LastScanSummary?

    /// Restores the persisted summary. Called once by the app after injecting the defaults; a
    /// no-op without them, which is how this stays off for the CLI and tests.
    ///
    /// A value that no longer decodes is dropped rather than repaired: the whole feature is one
    /// line of reassurance on an empty state, and there is nothing here worth a migration.
    public func loadLastScanSummary() {
        guard let defaults = persistedUIStateDefaults,
              let data = defaults.data(forKey: Self.lastScanSummaryKey),
              let summary = try? JSONDecoder().decode(LastScanSummary.self, from: data) else { return }
        lastScanSummary = summary
    }

    /// Records what a completed scan found. Publishes even without a store so the current session
    /// is consistent either way — only the *persistence* is gated, not the fact.
    func recordLastScanSummary(_ summary: LastScanSummary) {
        lastScanSummary = summary
        guard let defaults = persistedUIStateDefaults,
              let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: Self.lastScanSummaryKey)
    }

    // MARK: Lens auto-rescan — re-run a previously scanned lens on open, when it costs nothing

    /// Absolute paths recent completed Find Duplicates scans covered, newest first.
    public static let lastDuplicatesScanRootKey = "tidyLastDuplicatesScanRoot"
    /// Absolute folders recent completed Filing scans covered, newest first.
    public static let lastFilingScanFolderKey = "tidyLastFilingScanFolder"
    /// How many targets per lens to remember. **A single remembered target is not enough**: two
    /// panes on two providers is the ordinary way this app is used, so one key meant scanning the
    /// right pane silently withdrew consent for the left, and the feature fired or didn't
    /// depending on which provider was scanned last. Sized like ``StorageLensStore/maxRoots`` and
    /// for the same reason — someone who points a lens at a dozen folders should not accumulate
    /// consent forever, and the oldest is the least likely to be wanted.
    public static let maxRememberedScanTargets = 12
    /// The target an auto-rescan was already attempted for this session, per lens — whatever the
    /// outcome. One attempt per target: a completed scan latches via `hasCompleted`, but a
    /// cancelled or (Filing) declined-as-not-free attempt must not be retried by the next
    /// workspace switch, which would re-pay the walk each time. Cleared with the lens's results
    /// on a provider switch, so returning to a provider behaves like a fresh launch.
    var duplicateAutoRescanAttempted: String?
    var filingAutoRescanAttempted: String?

    /// Records `path` as a target the user has scanned to completion, newest first and bounded.
    /// A no-op without an injected store, which is how the feature stays off for the CLI and
    /// tests.
    func rememberLensScanTarget(_ path: String, forKey key: String) {
        guard let defaults = persistedUIStateDefaults else { return }
        var recent = (defaults.array(forKey: key) as? [String] ?? []).filter { $0 != path }
        recent.insert(path, at: 0)
        defaults.set(Array(recent.prefix(Self.maxRememberedScanTargets)), forKey: key)
    }

    /// Whether `path` is one of the targets the user has scanned to completion — the consent an
    /// auto-rescan needs.
    ///
    /// `array(forKey:)` rather than `stringArray(forKey:)` so a value of the wrong shape reads as
    /// "nothing remembered" instead of trapping: the first build of this feature wrote a bare
    /// String to these keys, and an install that ran it has one sitting there. It self-heals —
    /// the next completed scan overwrites the key with an array — at the cost of that install
    /// forgetting one target once, which is a manual scan away from being right again.
    func lensScanTargetIsRemembered(_ path: String, forKey key: String) -> Bool {
        guard let defaults = persistedUIStateDefaults else { return false }
        return (defaults.array(forKey: key) as? [String] ?? []).contains(path)
    }

    /// Whether `path` is a directory that exists right now.
    ///
    /// A remembered target can be deleted, renamed, or — the case that matters — sit on a cloud
    /// folder that is not mounted this launch. Scanning it anyway succeeds and publishes zero
    /// rows, and "no duplicates found" is a very different claim from "not scanned": it reads as
    /// a result about the user's files rather than as an absence of one. A manual scan may still
    /// do that, because the user asked; an automatic one must not say it unprompted.
    static func isReachableDirectory(_ path: String, fileManager: FileManaging) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Duplicates — in-provider duplicate finder (see FileSyncManager+Duplicates.swift)

    /// The Find Duplicates scan lifecycle (see ``ScanLifecycle``). The legacy running / has-found /
    /// root names below forward onto it; the status forwarder does NOT survive — readers ask
    /// `duplicateScanLifecycle.status` directly, so that one idle spelling is the only one.
    @Published public internal(set) var duplicateScanLifecycle = ScanLifecycle()
    /// Duplicate/related groups from the most recent Find Duplicates scan of one provider.
    @Published public var duplicateGroups: [DuplicateGroup] = []
    /// The absolute root the current `duplicateGroups` were scanned from — captured at scan time so
    /// breadcrumbs stay correct even if the user navigates elsewhere afterward.
    public var duplicateScanRoot: String? {
        get { duplicateScanLifecycle.root?.path }
        set { duplicateScanLifecycle.root = newValue.map { URL(fileURLWithPath: $0) } }
    }
    /// True while a Find Duplicates scan (walk + hash + group) is running.
    public var isFindingDuplicates: Bool {
        get { duplicateScanLifecycle.isRunning }
        set { duplicateScanLifecycle.isRunning = newValue }
    }
    /// Numeric progress for the duplicate scan's hashing phase; nil during the walk phase (total
    /// unknown) and whenever no scan is running. Drives the determinate bar in the lens workspace.
    ///
    /// Deliberately NOT folded into ``duplicateScanLifecycle``: its projected publisher
    /// (`$duplicateScanProgress`) — and its exact per-write emission cadence — is a tested
    /// contract (the numeric-progress and epoch-guard pin tests subscribe to it), and a computed
    /// forwarder has no projected value. It is the only lens with determinate progress; its
    /// writes are epoch-gated alongside the lifecycle's status via `updateScan`.
    @Published public var duplicateScanProgress: (completed: Int, total: Int)? = nil
    /// True once a duplicate scan has completed at least once (drives the empty-vs-results state).
    public var hasFoundDuplicates: Bool {
        get { duplicateScanLifecycle.hasCompleted }
        set { duplicateScanLifecycle.hasCompleted = newValue }
    }
    /// Files the most recent duplicate scan could not content-verify — and among which identical
    /// copies therefore go undetected (see ``DuplicateScanSkips``). Set just before
    /// `duplicateGroups` publishes so observers of the results always read a matching value;
    /// reset by `clearDuplicates`.
    @Published public internal(set) var duplicateScanSkips = DuplicateScanSkips()
    /// IDs of duplicate groups whose merge is currently in flight. A merge can run for minutes
    /// (it re-hashes the keeper, copies unique files, then trashes the folded copy); this both
    /// guards re-entry — a second click would re-plan against the half-merged keeper and mint
    /// " 2" junk copies — and drives the lens card's disabled/progress state while it runs.
    @Published public internal(set) var mergingGroupIDs: Set<DuplicateGroup.ID> = []
    /// Store for "Keep separate" duplicate-group keys (injectable so tests don't touch standard;
    /// internal — tests reach it via @testable, and nothing outside the module ever did).
    var duplicateIgnoreDefaults: UserDefaults = .standard
    /// The in-flight Find Duplicates task. Internal like the other lens tasks — the UI cancels
    /// through `cancelFindDuplicates()`, never by touching the task.
    var duplicateScanTask: Task<Void, Never>?

    // MARK: Storage Lens — read-only "where does my space go?" (see FileSyncManager+StorageLens.swift)

    /// The Storage Lens build lifecycle (see ``ScanLifecycle``); the legacy names forward onto it.
    @Published public internal(set) var storageLensLifecycle = ScanLifecycle()
    /// Backing storage for ``storageLensStoreURL``, which lives on the extension and so cannot
    /// declare a stored property of its own.
    var _storageLensStoreURL: URL?
    /// The most recent Storage Lens report (treemap + ranked lists) for one provider subtree.
    @Published public var storageLensReport: StorageLensReport?
    /// True while a Storage Lens build (walk + analyze) is running.
    public var isBuildingStorageLens: Bool {
        get { storageLensLifecycle.isRunning }
        set { storageLensLifecycle.isRunning = newValue }
    }
    /// The absolute root the current `storageLensReport` was built from — captured at build time so
    /// breadcrumbs stay correct even if the user navigates elsewhere afterward.
    public var storageLensRoot: URL? {
        get { storageLensLifecycle.root }
        set { storageLensLifecycle.root = newValue }
    }
    /// Numeric progress for the build; the walk phase has no granular count, so it stays 0 (the UI
    /// shows an indeterminate spinner). Reserved for a future determinate pass — kept as its own
    /// stored property (like `duplicateScanProgress`) rather than folded into the lifecycle.
    ///
    /// Deliberately NOT `@Published`, unlike its neighbours. It is written only to `0`, at the two
    /// ends of a build, and read nowhere — so the wrapper bought nothing and cost two whole-window
    /// invalidations per lens build (every `@Published` write on this manager re-evaluates the
    /// observing view). Whoever lands the determinate pass adds the wrapper back along with the
    /// reader that justifies it.
    public var storageLensProgress: Double = 0
    /// The in-flight Storage Lens build task, so the UI can cancel a long walk.
    var storageLensTask: Task<Void, Never>?

    // MARK: Name Normalizer — bulk-fix cloud-hostile names (see FileSyncManager+NameNormalize.swift)

    /// The Name Normalizer scan lifecycle (see ``ScanLifecycle``); the legacy names forward onto it.
    @Published public internal(set) var nameScanLifecycle = ScanLifecycle()
    /// The risky names (files AND folders) found by the most recent scan, each with its safe
    /// replacement. Empty until a scan runs; rows drop as they're fixed or skipped.
    ///
    /// `internal(set)` because `reportable(_:)` is not advice: a kept name reaching this list is a
    /// rename offered for something the user has already said they meant. A publicly settable
    /// property left that invariant resting on every future caller remembering a comment, which is
    /// the arrangement `filingSuggestions` was moved off for the same reason.
    @Published public internal(set) var riskyNames: [RiskyName] = []
    /// True while a Name Normalizer scan (walk + detect) is running.
    public var isScanningNames: Bool {
        get { nameScanLifecycle.isRunning }
        set { nameScanLifecycle.isRunning = newValue }
    }
    /// The absolute root the current `riskyNames` were scanned from — captured at scan time so the
    /// results stay labeled correctly even if the user navigates elsewhere.
    public var nameScanRoot: URL? {
        get { nameScanLifecycle.root }
        set { nameScanLifecycle.root = newValue }
    }
    /// True once a Name Normalizer scan has completed at least once (drives intro-vs-results state).
    public var hasScannedNames: Bool {
        get { nameScanLifecycle.hasCompleted }
        set { nameScanLifecycle.hasCompleted = newValue }
    }
    /// True while a "Fix all" / per-row normalize pass is applying renames.
    @Published public var isNormalizingNames = false

    // MARK: Rename pass — bring a folder back to its own convention (see +FilingRename.swift)

    /// The folder rename plans found by the most recent Filing scan, one per folder that has
    /// drifted from its own `NN. Mon YYYY` convention. Empty until a scan runs.
    ///
    /// `internal(set)` for the same reason `riskyNames` is: the only sound producer is the planner
    /// running over a freshly walked tree, and a publicly settable list would let a caller put a
    /// rename on screen that no folder ever asked for.
    @Published public internal(set) var renamePlans: [RenamePlan] = []
    /// True while an "Rename all" pass is applying renames.
    @Published public var isApplyingRenames = false
    /// The in-flight Name Normalizer scan task, so the UI can cancel a long walk.
    var nameScanTask: Task<Void, Never>?

    // MARK: Filing — suggest where loose files go (see FileSyncManager+Filing.swift)

    /// The Filing scan lifecycle (see ``ScanLifecycle``); the legacy names forward onto it.
    @Published public internal(set) var filingScanLifecycle = ScanLifecycle()
    /// What the last folder-memory re-survey did, or nil when none has run this session.
    ///
    /// Published so the lens can say what happened rather than leaving a menu item that appears to
    /// do nothing — the common outcome is "up to date", which is invisible unless it is stated.
    @Published public internal(set) var filingSurveyReport: FilingSurveyReport?
    /// When a survey last LOOKED at the tree, whatever it found — the corpus's `surveyedAt` stamp
    /// (ROADMAP_V5 §4.1). The app seeds it from disk at attach; a finishing re-survey publishes it
    /// directly, so the footnote updates the moment the survey does. Public set for the same
    /// reason `filingMemory`'s is: the app hands over what it read.
    @Published public var filingSurveyedAt: Date?
    /// The folder-memory re-survey lifecycle — a separate lens from the scan's on purpose.
    ///
    /// A re-survey is not a scan: it produces no suggestions, and flipping `isSuggestingFiles`
    /// would swap the lens to its scanning view and blank the results the user is reading. Its own
    /// lifecycle lets the status line say what is happening without the results moving.
    @Published public internal(set) var filingSurveyLifecycle = ScanLifecycle()
    /// Filing suggestions from the most recent scan of a picked folder.
    @Published public internal(set) var filingSuggestions: [FilingSuggestion] = []

    /// What the last Filing scan reused from the verdict cache, or nil when nothing was reused
    /// (including when there was no classification phase at all). Published with the results and
    /// cleared by ``clearFiling()``, so it always describes the suggestions currently on screen.
    @Published public internal(set) var filingLastCacheReuse: FilingCacheReuse?

    /// What the last refine pass did, or nil if none has run for the suggestions on screen.
    /// Published with the refined results and cleared by ``clearFiling()`` and by every scan, so
    /// like ``filingLastCacheReuse`` it always describes the list currently shown.
    @Published public internal(set) var filingLastRefine: FilingRefineSummary?

    /// The running refine pass's token, or nil when none is running.
    ///
    /// Both the re-entrancy guard and the ownership stamp: the token is compared again after the
    /// await for the same reason `filingTryAnotherInFlight` carries one — a pass whose entry was
    /// cleared mid-round-trip (a provider switch) must not release or overwrite its successor's.
    ///
    /// **The single storage for "a refine is running".** There was a separate stored
    /// `isRefiningFilingSuggestions` boolean, set and cleared alongside this — the same fact twice,
    /// with nothing stopping the two from disagreeing. Measured: deleting the token's re-entrancy
    /// check changed no test, because the boolean's copy of that check silently covered for it.
    /// One stored fact, so a mutation to the guard is a mutation to the only guard.
    @Published public internal(set) var filingRefineInFlight: UUID?

    /// True while the opt-in refine pass is out at the backend.
    ///
    /// Deliberately **not** `isSuggestingFiles`: that flag swaps the Organize lens to its scanning
    /// view, and the whole point of the refine pass is that it improves a list the user is already
    /// looking at. Flipping the scan flag would take that list off screen and put it back changed,
    /// which is the one thing a "refine what I'm seeing" action must not do.
    public var isRefiningFilingSuggestions: Bool { filingRefineInFlight != nil }
    /// Counts WHOLESALE replacements of `filingSuggestions` — the scan's single publish and
    /// `clearFiling()`, and nothing else. It is the currency check a "Try another" round-trip
    /// needs across its await: "is the list my verdict was computed against still the list on
    /// screen?". Deliberately NOT the scan epoch, which answers a different question — `endScan`
    /// lives in the scan body's `defer`, so a CANCELLED rescan bumps the epoch twice without ever
    /// republishing, and the epoch would drop a verdict about cards that never moved.
    ///
    /// Per-item edits (`replaceFilingSuggestion`, the `removeAll` in `dismissFilingSuggestion` /
    /// `performFiling`) do NOT bump it: they touch one card, so they cannot invalidate another
    /// card's in-flight snapshot, and a re-ask for the SAME card is already refused by
    /// `filingTryAnotherInFlight`'s token. Internal rather than private only because the one
    /// writer lives in `FileSyncManager+Filing.swift`; write it through
    /// `publishFilingSuggestions(_:)`, never by hand.
    var filingSuggestionsGeneration = 0
    /// True while a Filing scan (walk folder + learn taxonomy + suggest) is running.
    public var isSuggestingFiles: Bool {
        get { filingScanLifecycle.isRunning }
        set { filingScanLifecycle.isRunning = newValue }
    }
    /// True once a Filing scan has completed at least once.
    public var hasSuggestedFiling: Bool {
        get { filingScanLifecycle.hasCompleted }
        set { filingScanLifecycle.hasCompleted = newValue }
    }
    /// The folder the current suggestions were scanned from.
    public var filingScanFolder: String? {
        get { filingScanLifecycle.root?.path }
        set { filingScanLifecycle.root = newValue.map { URL(fileURLWithPath: $0) } }
    }
    /// The in-flight Filing scan task. Internal like the other lens tasks — the UI cancels
    /// through `cancelFindFilingSuggestions()`, never by touching the task.
    var filingScanTask: Task<Void, Never>?
    /// On-device content extractor for Filing (file path → entity/keyword tokens), injected by the
    /// app (PDF text / OCR / NaturalLanguage). nil = filename-only (F1). Gated by the read-contents
    /// setting. Runs only on files with no confident home from their name.
    public var filingContentExtractor: (@Sendable (String) async -> Set<String>)?
    /// Defaults store for the Filing read-contents toggle (injectable so tests don't touch standard;
    /// internal — tests reach it via @testable, and nothing outside the module ever did).
    var filingContentDefaults: UserDefaults = .standard
    /// Defaults store for remembered filing rules (F3), injectable so tests don't touch standard
    /// (internal — tests reach it via @testable, and nothing outside the module ever did).
    var filingRuleDefaults: UserDefaults = .standard
    /// Intelligent Filing backend — reasons about the folder taxonomy + file contents to pick a
    /// home (on-device Apple LLM, opt-in cloud), injected by the app. nil = keyword engine only.
    /// Its verdicts override the heuristic guess for files it's confident about.
    public var filingClassifier: FilingClassifier?
    /// §5.6's seam — the mapping refine, injected by the app beside the classifier. nil when the
    /// app has not wired it; whether a KEY is stored is `filingCloudRefineAvailable`'s question,
    /// same as the filing refine's split.
    public var mappingRefiner: MappingRefiner?
    /// Extracts a bounded text excerpt for the classifier (PDF text / OCR / plain), injected by the
    /// app. Gated by the same read-contents setting as F2's token extractor.
    public var filingSnippetExtractor: (@Sendable (String) async -> String?)?
    /// Warms up the classifier backend (e.g. loads the on-device model), injected by the app. Called
    /// when a Filing scan starts so the ~cold-start latency overlaps the keyword + content phases.
    public var filingClassifierPrewarm: (@Sendable () -> Void)?

    /// Names the backend that will answer this pass's classifications — the `model` component of
    /// ``FilingVerdictKey``. Called once per pass, before any classifying.
    ///
    /// **Takes the tier**, because the answer differs by tier and nothing else can reconcile them:
    /// the free pass resolves to the on-device model however the cloud toggle is set, while the
    /// refine pass resolves the way the router does. Asking one tier-blind question and using the
    /// answer for both would file every free-pass verdict under whatever the refine pass would
    /// have used — the same silent substitution described below, in the other direction and on
    /// every scan. It doubles as the check ``FileSyncManager/freePassWouldReachAPaidBackend``
    /// makes: the app answering "cloud" for `.free` is the app telling us its router will bill for
    /// a pass that promised not to, and we skip classifying rather than find out by being charged.
    ///
    /// It exists because **only the app can answer this correctly.** The manager knows what is
    /// *configured* (the cloud toggle and the model picker, both plain defaults), but the app's
    /// router also weighs whether a key can actually be read, and downgrades to the on-device
    /// model when it cannot. Caching an on-device verdict under a cloud model's name would make
    /// that downgrade *durable*: the next scan of an unchanged file would serve the on-device
    /// answer while the user believed Claude had filed it — the same silent-substitution problem
    /// `FilingBackendRouter.missingKeyDowngradeMessage` exists to surface, made permanent.
    /// Deciding the identity here also keeps the Keychain query on the app's side, where it stays
    /// gated behind the cloud toggle rather than running on every scan.
    ///
    /// Returning nil disables the cache for this scan — read *and* write. That is the honest
    /// answer whenever the app cannot vouch for which backend will run.
    ///
    /// nil (unset) falls back to the configured identity, which is right for the CLI and tests:
    /// neither has a Keychain downgrade to model.
    ///
    /// **Known gap, deliberately not plumbed:** a cloud call that fails at the *network* falls back
    /// to on-device inside the app's classifier, after this has already been asked. Such a verdict
    /// is cached under the cloud identity. It self-corrects when the file changes or via "Rescan
    /// (ignore cache)", and closing it properly would mean widening the `FilingClassifier` seam to
    /// carry provenance back — a change to a public contract with a dozen call sites, for a window
    /// the app already logs a warning about.
    public var filingBackendIdentity: (@Sendable (FilingClassifierTier) -> String?)?

    /// Whether the cloud backend is **set up** — the display question, and a different question
    /// from ``filingBackendIdentity``'s.
    ///
    /// **It exists because the two cost wildly different things, and only one of them may be asked
    /// while the user types.** `filingBackendIdentity` resolves the real route, which means
    /// `AnthropicKeychain.hasKey`, which *reads the secret* and on a locked or ACL-guarded item
    /// raises the Keychain password prompt. That is the right question for a pass about to use the
    /// key — and exactly the wrong one for a toolbar button, which SwiftUI re-evaluates on every
    /// render, including every keystroke in the Organize search field. Measured: the Refine button
    /// asked the router once per render.
    ///
    /// The app answers this with `AnthropicKeychain.isConfigured` — an attributes-only match that
    /// never decrypts and never prompts. `AnthropicKeychain` documents the split itself and points
    /// display-only callers here.
    ///
    /// The trade is that "an item is stored" is not "the item is readable", so with a corrupt or
    /// ACL-refused key this says yes while the route says on-device. That costs no money — the
    /// spend gate reads the real route — and ``refineFilingSuggestions(_:)`` names the downgrade in
    /// its banner rather than reporting a Claude result nobody got. nil (unset) falls back to the
    /// real route, which is right for the CLI and tests: neither has a Keychain to be slow about.
    public var filingCloudRefineConfigured: (@Sendable () -> Bool)?

    /// Where the Filing verdict cache is persisted. **nil disables the cache entirely** — no read,
    /// no write, every file classified as before.
    ///
    /// There is deliberately no ambient default here. Falling back to
    /// ``FilingVerdictStore/defaultURL(fileManager:)`` would mean library code reaching into the
    /// real home directory whenever nobody said otherwise, and the first thing that happens under
    /// `swift test` is a few dozen Filing tests constructing a bare `FileSyncManager()` — each of
    /// which would then read and write the user's actual cache file. The app opts in by setting
    /// this at startup; the CLI and tests get no cache and behave exactly as they did.
    public var filingVerdictCacheURL: URL?

    /// The verdict cache, loaded from disk on first use and written back after a scan records into
    /// it. Held here rather than re-read per scan so a scan pays at most one read.
    var filingVerdictCache: FilingVerdictCache?
    /// The most recent Filing scan's provider root + relative folder list, kept so a "Try another"
    /// re-ask can classify a single file without re-walking the whole provider.
    public var filingLastProviderRoot: String?

    // MARK: Automations (N2)

    /// The user's authored automation rules. Loaded lazily from `filingRuleDefaults` on first use
    /// (`ensureAutomationRulesLoaded`) and persisted on every mutation. `@Published` so the
    /// Automations lens re-renders as rules are added, edited, toggled, or removed.
    @Published public var automationRules: [AutomationRule] = []
    /// Guards the one-time load so the empty default array can't overwrite persisted rules.
    var didLoadAutomationRules = false
    /// The dry-run preview lifecycle (see ``ScanLifecycle``); read/written directly — this lens
    /// has no legacy forwarders left. Its `root` stays nil — the published report carries its
    /// own root string.
    @Published public internal(set) var automationDryRunLifecycle = ScanLifecycle()
    /// The most recent dry-run preview — what the enabled rules *would* do — or nil before any run.
    /// This surface never moves a file; the report is illustration only.
    @Published public var automationDryRun: AutomationDryRunReport?
    /// The in-flight preview task, so the UI can cancel it and a restart supersedes it.
    var automationDryRunTask: Task<Void, Never>?
    /// The capped folder list SENT to the classifier (bounded for token cost).
    public var filingLastTaxonomyFolders: [String] = []
    /// The tree's own filing artifacts, loaded once and reused by every pass.
    ///
    /// Injected by the app rather than read here, exactly as the verdict cache and the hash index
    /// are: `Sync` never reaches into a real home directory. Both nil is the ordinary state for
    /// anyone who has not had their tree surveyed, and it restores the behaviour the app had before
    /// any of this existed.
    public var filingFolderProfile: FolderProfile? {
        didSet {
            invalidateFilingRouterIndex()
            rebuildPersonIdentityIndex()
            cachedStructureReport = nil
        }
    }

    /// Where the tree disagrees with its own habits — the whole detector set's report, computed
    /// once per profile.
    ///
    /// **Cached, because the caller is a view body.** The detectors walk every folder in the
    /// profile (3,013 of them on the real tree) to build each family's vocabulary, and Organize's
    /// overview asks for this on every render. Recomputing there would put an O(folders²)-ish sweep
    /// on the main actor behind a scroll.
    ///
    /// The cache is keyed on nothing but the profile's own identity: `filingFolderProfile`'s
    /// `didSet` drops it, which is the only way the answer can change — the detectors read the
    /// profile and nothing else, no disk, no clock. **Scope is deliberately not part of the key**
    /// (ROADMAP_V5 §5.2): the lens scopes this report at render time by path prefix, so one cache
    /// serves every scope and there is no scoped invalidation to get wrong. That is also why this
    /// is not `@Published`: it is a pure function of a stored property, and republishing it would
    /// be a second source of truth for the same fact.
    public var structureReport: StructureReport {
        if let cachedStructureReport { return cachedStructureReport }
        guard let profile = filingFolderProfile else { return .empty }
        let report = StructureDetectors.run(in: profile)
        cachedStructureReport = report
        return report
    }

    /// The findings alone — every kind, in §5.2's grouped order.
    public var structureFindings: [StructureFinding] { structureReport.findings }

    private var cachedStructureReport: StructureReport?

    /// Whether the user has opened Restructure's answer **this launch**.
    ///
    /// ## Why this flag exists at all
    ///
    /// Every other lens shows its setup card until its scan has run, and the flag that decides
    /// that (`hasSuggestedFiling`, `hasScannedDuplicates`, `hasScannedNames`, `hasBuiltStorage`)
    /// is a scan lifecycle that starts false at launch. So all of them open on the card, and a
    /// relaunch puts them back there.
    ///
    /// **Restructure had no such flag, because it has no scan.** Its findings are a pure function
    /// of the folder profile, which is read off disk during startup — so it arrived at its answer
    /// before the user had asked anything, and it was the one lens that never showed the card.
    /// This is the same "has this lens been run this launch" fact the others get for free,
    /// declared explicitly for the one that cannot derive it.
    ///
    /// **Not persisted, deliberately.** The point is the launch boundary: the survey behind the
    /// answer can be weeks old, and starting the session on the card is what makes "these are
    /// cached results, here is how to refresh them" a thing the user is told rather than has to
    /// remember. A stored flag would say "you looked at this once in July" and skip it forever.
    @Published public var hasReviewedStructure = false
    /// Where those artifacts live, for the one pass that writes one back — see
    /// ``resurveyFilingMemory(root:taxonomy:)``. Injected for the same reason they are: `Sync` does
    /// not decide that a real home directory exists. nil ⇒ no re-survey, which is the state of any
    /// machine that has never been surveyed.
    public var filingProfilesDirectory: URL?
    /// The id those artifacts were actually **read under** — the folder name, not the `profileId`
    /// field inside the file.
    ///
    /// **The directory is the identity**, which ``FilingProfileStore/active(in:)`` states and warns
    /// about when the two disagree: a `folder-profile.json` with no `profileId` decodes to
    /// `"default"`, so a tree read from `work/` would have its re-survey written to `default/`,
    /// where nothing reads it — and the fingerprint rehashed against that empty folder, which turns
    /// off the verdict cache for every file. The app already loads the roster, the tag store and
    /// the fingerprint under this id; the re-survey is the one pass that was still deriving its own
    /// from the field, so it could send both artifacts somewhere the loader would never look.
    ///
    /// nil ⇒ fall back to the field, which is the pre-existing behaviour and the only thing a test
    /// that never set this can expect.
    public var filingProfileDirectoryId: String?
    /// Where the two content indexes live — `~/Library/Application Support/SyncCloud`.
    ///
    /// **Injected, never defaulted**, for exactly the reason the line above is and the reason
    /// ``FilingProfileStore/defaultDirectory(fileManager:)`` states: `Sync` does not decide that a
    /// real home directory exists. Left nil, "is this document already filed?" and the satellite
    /// relation are both no-ops — which is the state of any machine that has never hashed anything,
    /// and the state every test runs in. Defaulting it would have had the filing tests decode ten
    /// megabytes of the developer's own index on every scan.
    public var contentIndexDirectory: URL?
    /// Whether a document is on this disk to be read, asked before a re-survey opens one.
    ///
    /// Defaults to the real check, so this is the production path rather than a hook something else
    /// has to remember to install — see ``FilingSurvey/isAvailable(_:)`` for why a cloud-only
    /// placeholder must not be mistaken for an empty file. A test replaces it to make eviction reproducible,
    /// which is otherwise impossible to stage.
    public var filingDocumentIsAvailable: @Sendable (String) -> Bool = { FilingSurvey.isAvailable($0) }
    /// Digest of the artifacts above, mixed into every ``FilingVerdictKey`` so a re-survey does not
    /// replay answers composed against the old tree. See ``FilingProfileStore/fingerprint(id:in:)``.
    ///
    /// **Nil means UNAVAILABLE — an artifact exists but could not be read — and turns the verdict
    /// cache off for read and write both** at the two key-building sites, exactly like a nil
    /// verdict identity: a verdict recorded under a digest minted without the unreadable
    /// component can never be looked up again once the file is fixed. `""` is different — a tree
    /// with no artifacts at all, a perfectly recurring digest.
    public var filingArtifactFingerprint: String? = ""
    /// Loose PDFs that were READ and gave up nothing — scans with no text layer.
    ///
    /// Recorded rather than acted on: recovering their text means rendering a page and running it
    /// through Vision, measured at 0.5–2.1 s each on a real tree. That is nothing for one file and
    /// ten minutes for a 500-file inbox, so it is offered (``readScan(for:)``) instead of spent.
    public internal(set) var filingUnreadableScans: Set<String> = []
    /// Page 1 of each file the scan read, bounded to ``FilingRouter/contentSampleChars``.
    ///
    /// Kept because the *rule offered after a filing move* wants the same evidence the router had:
    /// a file called `Scan 2026-03-02.pdf` says nothing in its name, and without the page it read
    /// two minutes ago the offer falls back to the extension. Re-reading the PDF at click time to
    /// recover text already in hand is the one thing that would make the offer expensive.
    ///
    /// Bounded, not the whole excerpt: 400 characters is the sample the memory's weights were
    /// measured under, and 500 files of full extraction is megabytes held for one click.
    public internal(set) var filingPageSamples: [String: String] = [:]
    /// Renders a PDF's first page and reads it with OCR — injected by the app, because Vision has no
    /// place in a framework-free module. nil ⇒ the offer is never made.
    public var filingOCRExtractor: (@Sendable (String) async -> String?)?
    /// Files whose OCR is currently running, so a second click cannot start a second render.
    public internal(set) var filingOCRInFlight: Set<String> = []
    public var filingMemory: FilingMemory? {
        didSet { invalidateFilingRouterIndex(); rebuildPersonIdentityIndex() }
    }
    /// The household — who documents belong to. Loaded beside the artifacts above (from
    /// `people.json`, or seeded from the profile's person axis), and part of the router index for
    /// the same reason they are: it decides the person-axis score and the cross-person veto.
    ///
    /// Kept in step with ``filingPeopleStore`` rather than set independently once the store exists:
    /// the store is the editable truth, this is the compiled copy the engine reads.
    public var filingPersonRegistry: PersonRegistry? {
        didSet { invalidateFilingRouterIndex(); rebuildPersonIdentityIndex() }
    }
    /// Account and case numbers each person's folders have received — the last-resort attribution
    /// for a scan whose name and text name nobody. Rebuilt whenever the artifacts or the roster
    /// change, which is the same trigger the router index uses.
    public private(set) var filingPersonIdentity: PersonIdentityIndex = .empty
    /// What the cross-person rule has refused, so the People section can report it. Injected by
    /// the app like every other store; nil (tests, CLI) simply records nothing.
    public var filingPersonVetoLog: PersonVetoLog?
    /// The editable roster, when the app has somewhere to keep one.
    ///
    /// Unlike the profile and the memory, this artifact is *written* — see ``PeopleStore``. The
    /// subscriptions below are what make an edit take effect without a relaunch: they recompile
    /// the registry, drop the router index built from the old one, and re-derive the artifact
    /// fingerprint so cached verdicts composed against the previous roster are not replayed.
    ///
    /// **Two subscriptions, because they answer to different moments.** The registry is compiled
    /// from the roster *in memory*, so `$people` is exactly its trigger. The fingerprint hashes
    /// the roster *on disk*, and `$people` publishes before `save()` writes — reading it there
    /// hashed the previous household's bytes and left every edit one save stale, which is the
    /// replay the fingerprint exists to stop. It follows `$savedRevision` instead, which bumps
    /// only after the write lands.
    public var filingPeopleStore: PeopleStore? {
        didSet {
            filingPersonRegistry = filingPeopleStore?.registry ?? filingPersonRegistry
            peopleCancellable = filingPeopleStore?.$people
                .dropFirst()
                .sink { [weak self] _ in
                    guard let self, let store = self.filingPeopleStore else { return }
                    // Announced on THIS object explicitly, for the reason `keptNamesStore` is: the
                    // store is a separate ObservableObject behind a plain var, so a view watching
                    // only the manager sees nothing.
                    self.objectWillChange.send()
                    self.filingPersonRegistry = store.registry
                }
            peopleSaveCancellable = filingPeopleStore?.$savedRevision
                .dropFirst()
                .sink { [weak self] _ in self?.refreshFilingArtifactFingerprint() }
        }
    }
    private var peopleCancellable: AnyCancellable?
    private var peopleSaveCancellable: AnyCancellable?

    /// His verdicts on whose document is whose — see ``PersonTagStore``.
    ///
    /// The second writable filing artifact, and wired exactly like the roster: a store rather than
    /// a value, with a subscription so a verdict recorded in the person view re-renders the surface
    /// that asked for it without a relaunch.
    ///
    /// **Not part of ``filingArtifactFingerprint``, unlike `people.json`.** That fingerprint exists
    /// so cached *classifier* answers are not replayed against a changed question, and the roster
    /// changes the question — it moves the router's shortlist through the person-axis score and the
    /// cross-person veto. A tag does neither: it says who one document belongs to, is read only by
    /// the person gather, and re-deriving every cached verdict because one file was confirmed would
    /// be an expensive answer to a question nothing asked.
    public var filingPersonTagStore: PersonTagStore? {
        didSet {
            personTagCancellable = filingPersonTagStore?.$tags
                .dropFirst()
                .sink { [weak self] _ in
                    // Announced on THIS object for the same reason the roster's edit is: the store
                    // is a separate ObservableObject behind a plain var, so a view watching only
                    // the manager would see nothing.
                    self?.objectWillChange.send()
                    // **A "not theirs" has to take effect when it is pressed, not next launch.**
                    // The identifier index is built from the surveyed tree plus these rejections,
                    // and every other input to it rebuilds on its own `didSet`. Without this the
                    // correction sat on disk while the wrong attribution kept being made — which is
                    // most of what made it feel like the app was not listening.
                    self?.rebuildPersonIdentityIndex()
                }
        }
    }
    private var personTagCancellable: AnyCancellable?

    /// Everything Restructure remembers — suppressions and Ask answers now, drafts and the
    /// applied ledger when §5.4/§5.5 land. Wired exactly like the roster and the person tags: a
    /// store rather than a value, with the change re-announced on this object so the lens and the
    /// rail badge re-render the moment a finding is suppressed.
    ///
    /// **Not part of ``filingArtifactFingerprint``**, for `filingPersonTagStore`'s reason: a
    /// suppression changes what the lens shows, never the question any classifier was asked.
    public var restructureStore: RestructureStore? {
        didSet {
            restructureCancellable = restructureStore?.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    private var restructureCancellable: AnyCancellable?

    /// True while a Restructure landing (scaffold, plan apply, or ledger undo) is anywhere
    /// between its guards passing and its last step finishing. `activeFileOperationsCount`
    /// covers only step 3's queued moves — it drops to zero while steps 6–7 re-derive the
    /// profile through long awaits, and a second landing entering through that window would
    /// record itself under a profile id the first landing is about to replace, wedging the undo
    /// chain behind two honest-but-permanent refusals. Checked by `restructureLandingRefusal`.
    var restructureLandingInProgress = false

    /// ``structureFindings`` minus what the user said never to suggest again — what every surface
    /// renders and counts. One definition, because the lens, the overview and the rail badge all
    /// filtered `structureFindings` independently, and a suppression honoured by two of the three
    /// would leave a badge counting a card that never renders.
    /// §5.9's findings — the one detector that reads the duplicate scan rather than the profile,
    /// so it lives beside the memoised report instead of inside it: `duplicateGroups` has its own
    /// publish cycle, and the profile cache must not be invalidated by a scan finishing. Cheap on
    /// every access — one pass over the current groups, which are already in memory.
    public var duplicatedTaxonomyFindings: [StructureFinding] {
        guard let profile = filingFolderProfile, duplicateScanCoversSurvey else { return [] }
        return StructureDuplicatedTaxonomy.findings(groups: duplicateGroups, in: profile)
    }

    /// §5.9's staleness truth, in one place: whether a finished duplicate scan that COVERS the
    /// surveyed tree is on hand. Deliberately not `!duplicateGroups.isEmpty` — a clean scan
    /// leaves zero groups while very much having run, and a scan of an unrelated root leaves
    /// groups that say nothing about the survey's tree. Both directions lied through the
    /// emptiness test. No `isRunning` guard, on the lifecycle's own rule: the root is published
    /// WITH results, never at scan start, so a non-nil root always labels what is on screen —
    /// guarding on the flag made the answer flicker off for the length of every re-scan.
    public var duplicateScanCoversSurvey: Bool {
        guard let scanRoot = duplicateScanRoot,
              let profileRoot = filingFolderProfile?.root else { return false }
        let surveyed = (profileRoot as NSString).expandingTildeInPath
        return surveyed == scanRoot
            || surveyed.hasPrefix(scanRoot.hasSuffix("/") ? scanRoot : scanRoot + "/")
    }

    public var visibleStructureFindings: [StructureFinding] {
        // Through `grouped`, not appended raw: §5.2's rule is that one folder's rows sit
        // together, and the taxonomy findings joining the list after the report was grouped
        // would strand a folder's second observation at the bottom.
        let all = StructureDetectors.grouped(structureFindings + duplicatedTaxonomyFindings)
        guard let store = restructureStore else { return all }
        return all.filter { !store.isSuppressed(RestructureKey($0)) }
    }

    /// Records a cross-person refusal, resolving the ids to the names a person would recognise.
    ///
    /// The engine reports registry **ids** because that is what it reasons with; nobody wants to
    /// read `girish-2` in a sentence about their father, so the display names are looked up here,
    /// once, at the point the event becomes something a human will see.
    func recordPersonVeto(_ refusal: PersonVetoRefusal) {
        guard let log = filingPersonVetoLog else { return }
        log.record(PersonVetoEvent(namedPerson: refusal.namedPerson,
                                   proposedPerson: refusal.proposedPerson,
                                   fileName: refusal.fileName,
                                   destination: refusal.destination,
                                   at: Date()))
    }

    /// Re-reads the artifact digest after one of them is written.
    ///
    /// **The roster is part of the question every file is asked** — it decides the person veto and
    /// the person-axis score, both of which move the shortlist a backend is handed. Without this,
    /// editing a person would leave `FilingVerdictCache` replaying answers composed against the old
    /// household, which is the same bug the fingerprint was introduced for when a re-survey landed.
    /// Rebuilds the identifier index from the current artifacts and roster.
    ///
    /// Cheap (a pass over the memory's folders) and done eagerly rather than lazily, because the
    /// alternative is computing it inside attribution — which runs per file, per scan.
    func rebuildPersonIdentityIndex() {
        guard let registry = filingPersonRegistry else {
            filingPersonIdentity = .empty
            return
        }
        filingPersonIdentity = PersonIdentityIndex.make(registry: registry,
                                                        profile: filingFolderProfile,
                                                        memory: filingMemory,
                                                        rejectedIdentifiers: rejectedIdentifiers())
    }

    /// The identifiers the user's rejections withdraw, or empty when there are none.
    ///
    /// **The corpus is read only when there is a rejection to translate**, and that gating is the
    /// whole reason this is a function rather than a stored value. `filing-corpus.json` is megabytes
    /// — 4.9 MB on the tree this was built against — and this rebuild is documented as cheap and
    /// runs eagerly whenever the roster, the profile or a tag moves. A household that has never
    /// pressed "not theirs" pays one array scan for it.
    private func rejectedIdentifiers() -> [String: Set<String>] {
        let rejections = (filingPersonTagStore?.tags ?? []).filter { $0.verdict == .rejected }
        guard !rejections.isEmpty,
              let directory = filingProfilesDirectory,
              // The folder, not the field — same law as ``filingProfileDirectoryId`` states and
              // the fingerprint refresh below already follows. Keyed on the field, a disagreement
              // reads a corpus that is not there, so this answers `[:]` and every "not theirs" the
              // user pressed silently stops withdrawing anything.
              let id = filingProfileDirectoryId ?? filingFolderProfile?.profileId,
              let memory = filingMemory
        else { return [:] }
        // **Read once per change to the rejections, not once per verdict.** This rebuild fires on
        // every write to the tag store, and the People queue's whole interaction is pressing yes or
        // no on rows — so without the cache the SECOND rejection and every confirmation after it
        // paid a full corpus decode on the main actor. Measured on the real profile: 4,866 KB,
        // **100 ms**. That is the hitch `loadedFilingVerdictCache` exists to keep off this actor,
        // arriving through a different door.
        //
        // The salt is in the key because a re-survey re-salts the hashes, and a map translated
        // under the old salt names nothing in the new memory.
        if let cached = rejectedIdentifierCache, cached.rejections == rejections, cached.salt == memory.salt {
            return cached.value
        }
        guard let corpus = FilingSurveyStore.corpus(id: id, in: directory) else { return [:] }
        let value = PersonIdentityIndex.rejectedIdentifiers(tags: rejections, corpus: corpus,
                                                            salt: memory.salt)
        rejectedIdentifierCache = (rejections, memory.salt, value)
        return value
    }

    /// The last translation of ``PersonTagStore``'s rejections into identifier hashes, with the
    /// inputs it was derived from. See `rejectedIdentifiers()` for why it is worth keeping.
    private var rejectedIdentifierCache: (rejections: [PersonTag], salt: String,
                                          value: [String: Set<String>])?

    /// Re-derives ``filingArtifactFingerprint`` from the folder the roster was actually written
    /// to, after ``PeopleStore/savedRevision`` says the bytes landed.
    ///
    /// **The id comes from the store, not from `filingFolderProfile?.profileId`.** That field is
    /// the one *inside* `folder-profile.json`, and `FilingArtifacts.attach` deliberately does not
    /// build anything from it — see `FilingProfileStore.active`, which warns when it disagrees
    /// with the folder and lets the folder win. A profile folder `work/` whose json says
    /// `"profileId": "abhishek"` therefore digested `abhishek/`, a directory holding none of the
    /// three artifacts, and `fingerprint` answers `""` for that.
    ///
    /// `""` is not nil, so both cache gates (`FileSyncManager+Filing`,
    /// `FileSyncManager+FilingRefine`) stayed OPEN: every verdict for the rest of the session was
    /// recorded under `artifacts: ""` — billed, and unreachable at the next launch, when the digest
    /// is read correctly again. Worse in reverse, a `""`-keyed verdict from one artifact set can be
    /// served against another. That is the failure the `String?` change was made to prevent,
    /// arriving through the other door.
    ///
    /// Both remaining ways out are nil rather than a value, because nil is the honest answer and
    /// the safe one — cache off for read and write both:
    ///
    /// - **No file behind the store** (the in-memory `PeopleStore(people:)`, or none at all): there
    ///   is nothing on disk to digest, and the digest already in hand describes artifacts this
    ///   manager is no longer keyed to. Keeping it — which a bare `return` did — is a stale key
    ///   with the cache still on.
    /// - **`""` from a store that IS persistent**: unreachable by construction, since `save()` had
    ///   just written `people.json` into that very folder, so it means the pair no longer names
    ///   where the artifacts live. `""` would key this session's verdicts to an empty artifact set;
    ///   nil records nothing instead.
    func refreshFilingArtifactFingerprint() {
        guard let store = filingPeopleStore, store.isPersistent else {
            filingArtifactFingerprint = nil
            return
        }
        let refreshed = FilingProfileStore.fingerprint(id: store.profileId, in: store.directory)
        guard refreshed != "" else {
            Logger.shared.warning("Filing artifacts: nothing to digest in "
                                  + "\(store.profileId)/ after the roster was saved, so the "
                                  + "artifact fingerprint is unavailable and no classification is "
                                  + "cached or replayed this session. The roster was written to "
                                  + "\(store.fileURL.path).")
            filingArtifactFingerprint = nil
            return
        }
        filingArtifactFingerprint = refreshed
    }
    /// The prepared router index, and the destination set it was built from.
    ///
    /// Building it costs ~85 ms against a 2,979-folder tree, and the taxonomy is usually identical
    /// from one scan to the next — a rescan after a single file lands rebuilt the whole thing. The
    /// key is the destination set itself rather than a hash of it: `Set` equality exits early on a
    /// count mismatch, and an exact comparison cannot collide into serving a stale index.
    var filingRouterIndex: FilingRouter.Index?
    var filingRouterIndexKey: Set<String>?
    /// How many times the index has actually been built. Nothing reads it in the app — it exists
    /// so a test can tell a reused index from a rebuilt one, which is otherwise invisible: a
    /// rebuild produces a value equal to the one it replaced.
    var filingRouterIndexBuilds = 0

    /// Satellite folder → its homes, and the state that says whether it needs rebuilding.
    ///
    /// Derived from the two persisted content indexes, which together are ~10 MB of JSON — far too
    /// much to decode per scan, and it does not change per scan. The key is the pair of files'
    /// modification dates, so a duplicates scan that writes new fingerprints is picked up on the
    /// next filing scan and nothing else re-reads them.
    var filingSatelliteHomes: [String: Set<String>] = [:]
    var filingSatelliteKey: [Date]?
    /// So a test can tell a reused map from a rebuilt one — same reason as `filingRouterIndexBuilds`.
    var filingSatelliteBuilds = 0

    /// Rebuilds ``filingSatelliteHomes`` when the indexes behind it have moved.
    func refreshSatelliteHomes(providerRoot: String?, fileManager fm: FileManager = .default) {
        guard let providerRoot, let profile = filingFolderProfile,
              let directory = contentIndexDirectory
        else {
            filingSatelliteHomes = [:]
            filingSatelliteKey = nil
            return
        }
        let hashURL = directory.appendingPathComponent("content-hash-index.json")
        let fpURL = directory.appendingPathComponent("content-fingerprint-index.json")
        let stamps = [hashURL, fpURL].map {
            (try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? nil
                ?? Date.distantPast
        }
        if filingSatelliteKey == stamps { return }
        let index = DocumentIdentityIndex.build(
            hashes: ContentHashIndexStore.load(from: hashURL),
            fingerprints: ContentHashIndexStore.load(from: fpURL),
            providerRoot: providerRoot,
            existsOnDisk: { fm.fileExists(atPath: $0) })
        // Asked through the profile's own rule, not re-implemented — an inbox posing as the bigger
        // folder is what makes this relation read backwards. See `SatelliteFolders`.
        filingSatelliteHomes = SatelliteFolders.homesBySatellite(in: index) {
            profile.acceptsNewFiles($0)
        }
        filingSatelliteKey = stamps
        filingSatelliteBuilds += 1
        if !filingSatelliteHomes.isEmpty {
            Logger.shared.info("Filing: \(filingSatelliteHomes.count) folder(s) hold copies of another "
                        + "folder's documents and will not outrank it")
        }
    }

    /// Drops the cached index. Called whenever the artifacts it was built from are replaced.
    func invalidateFilingRouterIndex() {
        filingRouterIndex = nil
        filingRouterIndexKey = nil
        filingSatelliteKey = nil
    }

    /// Derives content tokens from text already read, so a file's page is never extracted twice.
    ///
    /// `filingContentExtractor` reads the file and then derives tokens from what it read; this is
    /// the second half of that on its own. With it, the scan reads a page once and shares it
    /// between the keyword pass, the router and the classifier — without it, the keyword pass and
    /// the router each read the same PDF.
    public var filingTokensFromText: (@Sendable (String) -> Set<String>)?
    /// The FULL set of existing relative folders (uncapped), used only to mark a "Try another"
    /// verdict's segments new-vs-existing — the same basis the main scan uses. Kept separate from
    /// the capped `filingLastTaxonomyFolders` so a real folder beyond the classifier cap isn't
    /// mislabeled as a folder to be created.
    public var filingLastExistingFolders: Set<String> = []
    /// Session-scoped "Try another" rejections keyed by file path. Persisted rejections are keyed
    /// by salient filename tokens, which token-less names ("IMG_0007", "Scan 12") don't have — this
    /// set is what stops those files from being re-offered the folder they just rejected.
    public var filingSessionRejections: [String: Set<String>] = [:]
    /// "Try another" re-asks currently in flight: suggestion id → the owning invocation's token.
    /// The button fires an unstructured Task per click, so two rapid clicks would run two
    /// classifier round-trips for the same card and whichever RETURNED last would win —
    /// `tryAnotherFolder` checks-and-inserts here at entry and ignores re-entrant calls for the
    /// same suggestion. Published and publicly readable so the card can disable its button while
    /// its own re-ask is out (`keys.contains` is the membership test) — a refused re-entrant
    /// click that still looks clickable reads as a dead button.
    ///
    /// The VALUE is per-invocation ownership, and it is load-bearing: the key is the file's
    /// absolute path, stable across scans and provider switches, and `clearFiling()` empties the
    /// dictionary as the only recovery when a round-trip never returns (`FilingClassifier` has
    /// no timeout). A cleared-then-re-armed key would otherwise let the STALE round-trip's defer
    /// release the NEW round-trip's guard, and let its late verdict overwrite the recreated card
    /// — so both the release and the result write check the token first (see `tryAnotherFolder`).
    /// Written only inside this module.
    @Published public internal(set) var filingTryAnotherInFlight: [String: UUID] = [:]

    /// Global sorting preference for the file trees.
    @Published public var sortOption: SortOption = .name {
        didSet {
            guard sortOption != oldValue else { return }
            // Invalidate prefetch cache for roots as they need re-sorting or re-scanning
            dropPrefetchedTrees()
            if sortOption == .tags {
                // Trees are built WITHOUT Finder tags unless sorting by them (the per-file
                // xattr fetch dominated large scans — see TreeBuilder.includeTags), so the
                // current nodes have nothing to re-sort by. Reload from disk instead; the
                // fresh walk includes tags because this option is now current.
                noteScanConfigChanged()
                refreshSubject.send(.both)
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
            dropPrefetchedTrees()
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

    /// Durable store of names the user deliberately meant (see ``KeptNamesStore``). Assigned by the
    /// app at launch; nil (tests, CLI) means nothing is kept and every risky name is reported,
    /// which is exactly the behavior before the store existed.
    ///
    /// Keeping a name drops it from `riskyNames` immediately, so Organize's list and its "Fix all"
    /// can never rename something the user just said they meant. The reverse is deliberately NOT
    /// symmetric: withdrawing a keep does not re-add the row, because `riskyNames` is the result of
    /// a scan and this is not one. The row badge, which is live, does come back at once.
    public var keptNamesStore: KeptNamesStore? {
        didSet {
            keptNamesCancellable = keptNamesStore?.$names
                .dropFirst()
                .sink { [weak self] kept in
                    guard let self else { return }
                    // Announce the change on THIS object, explicitly.
                    //
                    // The store is a separate `ObservableObject` reached through a plain `var`, so
                    // nothing observing the manager observes it. Views that render the kept set but
                    // only watch the manager — `DifferencesView`, whose name cells silence a badge
                    // on a kept name — would otherwise not re-render when a keep is made from a
                    // pane row, and the badge would linger in the table until something unrelated
                    // moved.
                    self.objectWillChange.send()
                    // Assign only when a row genuinely goes. `removeAll(where:)` is a mutating
                    // access, so calling it unconditionally republishes `riskyNames` — re-rendering
                    // Organize's whole list — on every keep, including the overwhelmingly common
                    // one that removes nothing because no scan has run or the name was never found.
                    //
                    // That spurious publish also used to be what refreshed the Differences table,
                    // by accident: it was doing the announcement's job, which made the line above
                    // untestable and made this efficiency fix a silent regression waiting to
                    // happen. Separating them is what lets
                    // `keepingANameAnnouncesOnTheManagerEvenWithNothingToRemove` mean anything.
                    let remaining = self.riskyNames.filter { !kept.contains($0.currentName) }
                    if remaining.count != self.riskyNames.count { self.riskyNames = remaining }
                }
            riskyNames.removeAll { isKeptName($0.currentName) }
        }
    }
    private var keptNamesCancellable: AnyCancellable?

    /// Whether the user has said they meant this name. False when no store is attached.
    public func isKeptName(_ name: String) -> Bool {
        keptNamesStore?.isKept(name) ?? false
    }

    /// `found` minus everything the user has already said they meant — the one filter every
    /// publisher of `riskyNames` goes through, so a kept name cannot reach the list by a route
    /// someone forgot about.
    func reportable(_ found: [RiskyName]) -> [RiskyName] {
        guard let kept = keptNamesStore?.names, !kept.isEmpty else { return found }
        return found.filter { !kept.contains($0.currentName) }
    }

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
            refreshSubject.send(.both)
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
            refreshSubject.send(.both)
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
              panesShareAPosition else { return }
        // The ANCHOR pane's focus, not the left pane's — see `ignoreAnchorIsLeft`. The two differ
        // only for a pair whose sources land at different depths, which is precisely the pair a
        // swap would otherwise re-read in the wrong coordinates.
        let focus = ignoreAnchorFocus
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
        // Read through the same anchor the entries were WRITTEN through, or a swapped mixed pair
        // reads yesterday's set in the other source's coordinates and matches nothing.
        return ignoredPaths.union(Self.focusRelativePaths(fromRootRelative: store.rootRelativePaths,
                                                          focus: ignoreAnchorFocus))
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
        if rememberIgnoredItems, let store = ignoredItemsStore, panesShareAPosition {
            let focus = ignoreAnchorFocus
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
        // `path` came out of the store, so it is in the anchor's coordinates; the session set it is
        // translated into is focus-relative and shared. See `ignoreAnchorIsLeft`.
        let focus = ignoreAnchorFocus
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
    /// Readable inside the module so a test can tell a pass that has not STARTED from one
    /// suspended inside its detached compute: this moves in `applyFilters()`'s synchronous
    /// prologue, `lastPublishedFilterGeneration` only when it commits.
    internal private(set) var filterGeneration = 0
    /// Generation of the most recent `applyFilters()` pass that published its results.
    ///
    /// Readable (not writable) outside this file as a test seam: it moves at the exact moment a
    /// pass commits, which is the only observable a pass that publishes NOTHING leaves behind.
    /// Every *published-property* assignment that follows it in `applyFilters` is guarded by
    /// "assign only what changed", so a pass over already cleared state —
    /// `invalidateDifferencesForPaneRetarget`'s insurance pass — touches none of them. A test
    /// waiting for that pass has nothing else to wait on, and waiting a guessed number of
    /// milliseconds instead is how it silently stops waiting for anything (docs/flaky-tests.md,
    /// mechanism 2).
    private(set) var lastPublishedFilterGeneration = 0
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

    /// A deferred column listing, identified by the pane that asked as well as the folder.
    ///
    /// **The side is part of the key**, and leaving it out was a real defect: keyed by path alone,
    /// two panes on the SAME source — comparing a folder against itself, an ordinary thing to do
    /// here — meant the left pane's request suppressed the right's as a duplicate. The right column
    /// then never filled, because its `onAppear` had already fired and nothing re-asks.
    internal struct ColumnGraftKey: Hashable {
        let isLeft: Bool
        let path: String
    }

    /// The listings running right now — see `loadColumnChildren`. Deduping on this is what stops a
    /// column re-rendering mid-walk from queueing a second listing of the same directory, and
    /// publishing it is what lets that column say "being read" rather than "can't be read".
    ///
    /// **Cleared by `swapPanes`, because every key in it names a side.** After a swap the tree a
    /// key's `isLeft` points at belongs to the other pane, so the set would claim the pane that is
    /// NOT loading is being read and leave the one that is saying "Can't be read" — the precise
    /// distinction this is published to make, inverted. `paneOrientationGeneration` is what stops
    /// the listings themselves landing on the wrong side.
    @Published internal var columnGraftsInFlight: Set<ColumnGraftKey> = []

    /// **Bumped when the panes change sides**, and nothing else.
    ///
    /// A column listing is started for a side and lands on the main actor some time later, holding
    /// an `isLeft` captured before the await. A swap in that window makes that capture name the
    /// other pane's tree — the answer is about a folder that is now on the other side, and grafting
    /// it where the key says would write one pane's listing into the other's tree.
    ///
    /// Its own counter rather than `rawTreeGeneration`, which bumps on every raw-tree publish
    /// INCLUDING each successful graft: guarding on that would make two columns filling at once
    /// cancel each other, which is the ordinary case rather than the exceptional one.
    internal var paneOrientationGeneration = 0

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

    /// Row projections, rebuilt only when their pane republishes — same
    /// invalidate-on-`published*TreeVersion` shape as `leftNodeIndexCache` below. Without the
    /// cache the projection would walk the whole tree on every access, and `leftPaneTree` is read
    /// once per pane per render.
    private var leftRowsCache: (version: Int, rows: [PaneRow])?
    private var rightRowsCache: (version: Int, rows: [PaneRow])?

    /// The left pane's tree stamped with the publish that produced it, plus its row projection.
    /// Views must take this rather than `leftTree`: storing a bare `[FileNode]` graph in a view
    /// makes SwiftUI deep-compare ~40,000 nodes on the main thread on every body-output
    /// comparison. See `PaneTree`.
    public var leftPaneTree: PaneTree {
        let version = publishedLeftTreeVersion
        let rows: [PaneRow]
        if let cached = leftRowsCache, cached.version == version {
            rows = cached.rows
        } else {
            rows = PaneRow.project(leftTree, side: .left, version: version)
            leftRowsCache = (version, rows)
        }
        return PaneTree(side: .left, version: version, nodes: leftTree, rows: rows)
    }

    /// Children indices, rebuilt only when their pane republishes or is re-rooted — same
    /// invalidate-on-`published*TreeVersion` shape as the row cache above. Without the cache every
    /// column would rebuild the index per render, which is the whole-tree walk the index exists to
    /// avoid.
    private var leftChildrenCache: (version: Int, root: String, index: PaneChildrenIndex)?
    private var rightChildrenCache: (version: Int, root: String, index: PaneChildrenIndex)?

    /// Path → children for the left pane, for the Columns presentation. `treeRoot` is the pane's
    /// current absolute path — the folder whose children are the pane's top-level rows.
    public func leftChildrenIndex(treeRoot: String) -> PaneChildrenIndex {
        if let cached = leftChildrenCache, cached.version == publishedLeftTreeVersion, cached.root == treeRoot {
            return cached.index
        }
        let index = PaneChildrenIndex(tree: leftPaneTree, treeRoot: treeRoot)
        leftChildrenCache = (publishedLeftTreeVersion, treeRoot, index)
        return index
    }

    /// Right-pane counterpart of `leftChildrenIndex(treeRoot:)`.
    public func rightChildrenIndex(treeRoot: String) -> PaneChildrenIndex {
        if let cached = rightChildrenCache, cached.version == publishedRightTreeVersion, cached.root == treeRoot {
            return cached.index
        }
        let index = PaneChildrenIndex(tree: rightPaneTree, treeRoot: treeRoot)
        rightChildrenCache = (publishedRightTreeVersion, treeRoot, index)
        return index
    }

    /// Right-pane counterpart of `leftPaneTree`.
    public var rightPaneTree: PaneTree {
        let version = publishedRightTreeVersion
        let rows: [PaneRow]
        if let cached = rightRowsCache, cached.version == version {
            rows = cached.rows
        } else {
            rows = PaneRow.project(rightTree, side: .right, version: version)
            rightRowsCache = (version, rows)
        }
        return PaneTree(side: .right, version: version, nodes: rightTree, rows: rows)
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

    // MARK: - Selection resolution index

    /// Path→node maps for resolving a selection to nodes in O(selection) instead of walking the
    /// ~40k-node tree on every render — that walk was the pane action bar's "fraction of a second"
    /// appearance lag. Built lazily on first lookup after a tree change and cached against the
    /// published tree version, so a scan/navigation invalidates it without any eager cost.
    private var leftNodeIndexCache: (version: Int, index: [String: FileNode])?
    private var rightNodeIndexCache: (version: Int, index: [String: FileNode])?

    private static func buildNodeIndex(_ tree: [FileNode]) -> [String: FileNode] {
        var index = [String: FileNode](minimumCapacity: 1024)
        func walk(_ nodes: [FileNode]) {
            for node in nodes {
                index[node.id] = node
                if let children = node.children { walk(children) }
            }
        }
        walk(tree)
        return index
    }

    /// Resolves selected paths to left-pane nodes via the cached index. Order is unspecified (the
    /// consumers — the action bar's count/size summary and per-node file actions — don't depend on
    /// it). A stale path absent from the current tree is simply dropped, matching `findNodes`.
    public func leftNodes(for paths: Set<String>) -> [FileNode] {
        guard !paths.isEmpty else { return [] }
        if leftNodeIndexCache?.version != publishedLeftTreeVersion {
            leftNodeIndexCache = (publishedLeftTreeVersion, Self.buildNodeIndex(leftTree))
        }
        let index = leftNodeIndexCache!.index
        return paths.compactMap { index[$0] }
    }

    /// Right-pane counterpart of `leftNodes(for:)`.
    public func rightNodes(for paths: Set<String>) -> [FileNode] {
        guard !paths.isEmpty else { return [] }
        if rightNodeIndexCache?.version != publishedRightTreeVersion {
            rightNodeIndexCache = (publishedRightTreeVersion, Self.buildNodeIndex(rightTree))
        }
        let index = rightNodeIndexCache!.index
        return paths.compactMap { index[$0] }
    }

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
    /// The cache entries whose deep walk `paneNodeBudget` STOPPED — provenance the trees
    /// themselves cannot carry, because a budget-stopped directory and a permission-denied one
    /// wear the same `isUnexplored` mark. Read by the warm scan branch, which must banner a
    /// comparison over a truncated tree (`PartialComparison.of`'s walk-stopped overload) even
    /// though its per-directory suppression stays precise. Written only beside a cache write;
    /// a bit is never read without its `prefetchedTrees` entry, so a cleared cache cannot leak
    /// a stale bit into a verdict.
    public var prefetchedTreeWalkStopped: Set<String> = []

    /// Drops every cached pane tree AND its walk-stopped provenance — one verb, so the two stores
    /// cannot part company at an invalidation site. Every invalidation of `prefetchedTrees` goes
    /// through here; a site that cleared the trees alone would leave provenance bits to be
    /// re-read the next time the same focus path is cached by a slice.
    public func dropPrefetchedTrees() {
        prefetchedTrees.removeAll()
        prefetchedTreeWalkStopped.removeAll()
    }
    /// Focused-folder path each pane's published tree was last loaded for; distinguishes a
    /// same-focus refresh (keep showing the current tree while rebuilding) from a focus
    /// change (repaint shallow immediately) in `loadTree`.
    var lastLoadedLeftFocusPath: String? = nil
    var lastLoadedRightFocusPath: String? = nil
    
    @Published public var clipboardNodes: [FileNode] = []
    @Published public var clipboardIsCut: Bool = false
    /// `NSPasteboard.general.changeCount` as it stood after the app's own last ⌘C/⌘X, or nil if it
    /// has not written one this launch.
    ///
    /// The token that keeps two clipboards behaving as one: while this still equals the live count,
    /// SyncCloud owns what is on the pasteboard and `clipboardNodes` — which carries `isCut`, and
    /// so is the only path that can move rather than copy — is what a paste means. The moment
    /// anything else writes, the count moves and the pasteboard becomes the answer. See
    /// `ClipboardSource.resolve`.
    ///
    /// Held here rather than in `FileActionHandler` because it is part of the clipboard's state,
    /// and the two lines above are already here.
    @Published public var clipboardPasteboardChangeCount: Int? = nil
    
    /// Global UndoManager injected from SwiftUI environment. Re-wires the did-undo/did-redo
    /// observers that keep the "Undo Last Run" pairing honest (see `invalidateRunUndoPairing`).
    public var undoManager: UndoManager? {
        didSet {
            guard undoManager !== oldValue else { return }
            // A DIFFERENT manager means a different stack: a pairing armed against the old
            // instance must not be validated against the new one's identically-named groups
            // (a window reopen swaps managers; the first unpaired registration on the fresh
            // stack would otherwise resurrect the stale preview). The armed-this-session
            // flag resets too: the old stack's runs are unreachable through the new one, so
            // the "history changed" advice would point at nothing.
            invalidateRunUndoPairing()
            hasArmedRunPairingThisSession = false
            undoStackObservers.forEach { NotificationCenter.default.removeObserver($0) }
            undoStackObservers = []
            guard let undoManager else { return }
            for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                undoStackObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: undoManager, queue: .main
                ) { [weak self] _ in
                    // Delivered synchronously on the main queue (undo/redo run on the main
                    // actor), so hopping is safe. undoLastSyncRun's own undo() also lands
                    // here — it clears the pairing itself right after, so this is a no-op.
                    MainActor.assumeIsolated { self?.invalidateRunUndoPairing() }
                })
            }
        }
    }
    /// Tokens for the did-undo/did-redo observers on the injected `undoManager`.
    private var undoStackObservers: [NSObjectProtocol] = []
    
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

    /// The rows the last bulk transfer failed on, or nil when the last one was clean. Drives the
    /// Differences table's Failed filter — see ``TransferFailures`` for why this exists at all.
    @Published public internal(set) var lastTransferFailures: TransferFailures?

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
    ///
    /// This is the pane's comparison **scope**, not merely where it is looking: assigning it goes
    /// through `focusOn` → `syncPathsFromHistory` → `refreshSubject`, reloading the tree and
    /// re-running the scan. Where the pane is *browsing* inside that scope is `leftBrowsePath`.
    @Published public var leftRelativePath: String = ""
    /// Current subfolder path relative to the right pane root (empty = root).
    @Published public var rightRelativePath: String = ""

    /// Where each pane's source **opens**, as a path relative to that pane's root — the origin its
    /// positions are quoted against once you stop assuming both panes share one.
    ///
    /// Supplied by the app because the pane → source mapping is its state, and a closure rather
    /// than two stored strings so it is read at the moment of the decision: it is a preference
    /// discovery republishes, and a cached copy would answer with the folder a source used to open
    /// at. The default answers `""` for both, which reproduces exactly the pre-landing-folder
    /// behaviour — every test that does not set it is asking the old question and still gets the
    /// old answer.
    ///
    /// Two things read it, and both were silently wrong without it. Linked navigation drove both
    /// panes with ONE root-relative path, so an iCloud/OneDrive pair sent the sibling either into a
    /// doubled `Documents` or into a real-but-unrelated folder at the top of the account. And the
    /// durable ignore store's "both panes are showing the same thing" guard compared the two
    /// root-relative paths directly, which for a mixed pair is permanently false — Ignore worked
    /// for the session, wrote nothing, and the row was back after a relaunch with no diagnostic.
    @MainActor public var paneOpenAt: (_ isLeft: Bool) -> String = { _ in "" }

    /// Each pane's source id, supplied by the app for the same reason as `paneOpenAt` and read at
    /// the same moment: the pane → source mapping is the app's state, and a cached copy answers
    /// about the source a pane used to be on.
    ///
    /// Only the durable ignore store reads it, and only to decide WHICH pane's coordinates its
    /// entries are quoted in — see `ignoreAnchorIsLeft`. The default answers `""` for both, which
    /// makes that decision "the left pane", i.e. exactly what the store did before this existed.
    @MainActor public var paneSourceId: (_ isLeft: Bool) -> String = { _ in "" }

    /// Which pane's root the durable ignore set is measured from.
    ///
    /// **It cannot be "the left one", and that is the whole reason this exists.**
    /// `IgnoredItemsStore.pairKey` sorts its two ids, so one key serves the pair in either
    /// orientation — which was exact while both panes' roots were documents folders, because a
    /// root-relative path then read the same from either side and a swap changed nothing. Sources
    /// now land at `openAt`, so the same item is `Family/x` from an iCloud pane and
    /// `Documents/Family/x` from a OneDrive one; quoting the store against whichever source
    /// happens to be on the left means ⌘⇧S re-reads yesterday's entries in the other source's
    /// coordinates, where they match nothing — the ignored rows come back, and the next Ignore
    /// writes the same item a second time under its other spelling.
    ///
    /// So the pair key picks: entries are quoted against the source whose id sorts FIRST, which is
    /// the id the key itself names first. That is stable under a swap by construction, and it is
    /// the same choice `RootsMigration.rebaseIgnoredItems` makes when it moves the stored entries
    /// into the new roots, so the two agree about what is on disk.
    ///
    /// Falls back to the left pane when either id is unknown — the pre-`paneSourceId` behaviour,
    /// and the only answer available when there is nothing to sort.
    @MainActor var ignoreAnchorIsLeft: Bool {
        let left = paneSourceId(true)
        let right = paneSourceId(false)
        guard !left.isEmpty, !right.isEmpty, left != right else { return true }
        return min(left, right) == left
    }

    /// The focus the durable ignore store's translations run through: the anchor pane's, not the
    /// left pane's. Identical to `leftRelativePath` for every same-landing pair and for every
    /// orientation in which the left source is the anchor.
    @MainActor var ignoreAnchorFocus: String {
        ignoreAnchorIsLeft ? leftRelativePath : rightRelativePath
    }

    /// Whether a focus-relative path names the SAME item in both panes — the condition the durable
    /// ignore store's identity depends on.
    ///
    /// Anchor-relative, not a raw comparison of the two focus paths. Before sources had a landing
    /// folder the two were the same test, because every root WAS a documents folder; now iCloud
    /// lands at `""` and OneDrive at `Documents`, so two panes showing exactly the same thing
    /// disagree by two components and the raw test never becomes true again.
    @MainActor var panesShareAPosition: Bool {
        PathBoundary.reanchor(leftRelativePath, from: paneOpenAt(true), to: paneOpenAt(false))
            == rightRelativePath
    }

    /// Where the left pane is browsing inside its loaded tree — the Columns view's column stack.
    /// Empty is the resting single column. See `PaneBrowsePath` for why this is deliberately not
    /// `leftRelativePath`.
    @Published public var leftBrowsePath = PaneBrowsePath()
    /// Right-pane counterpart of `leftBrowsePath`.
    @Published public var rightBrowsePath = PaneBrowsePath()

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
    /// Which surface the user last selected something in — the tie-break `CurrentSelection` needs
    /// when a pane and the Differences table both hold a selection, which they legitimately can.
    ///
    /// Written only when it actually changes, and only on a *non-empty* selection: a clear says
    /// "not this any more", not "this surface is now what I mean", and letting a clear claim the
    /// token would hand priority to a surface holding nothing.
    ///
    /// `nil` until the first selection of the session, which `CurrentSelection.quickLookPath`
    /// treats as pane-first — the panes are what a fresh window is looking at.
    @Published public var lastSelectionSurface: SelectionSurface? = nil

    /// Which pane the pane-scoped chords act on, once something has said so explicitly — ⌃⇥, or a
    /// click that selects in a pane. `nil` until then, which hands the question to the
    /// selection-derived fallback in `PaneLogic.focusedPaneIsLeft`.
    ///
    /// A second stored fact next to the selection was the thing to avoid, so this deliberately
    /// does NOT feed the action bar: that bar is about a selection and draws where the selection
    /// is, which `PaneLogic.activePane` still answers on its own and unchanged. This answers the
    /// different question the chords ask — "which pane am I working in" — and it is the one the
    /// selection cannot answer, because letting go of a selection does not mean leaving the pane.
    ///
    /// **Held here rather than on the view because `swapPanes` has to swap it.** It is a per-side
    /// fact exactly like the selections, histories and browse paths beside it, and as view `@State`
    /// it was one line in `swapPanesAction` away from being forgotten — with no test that could
    /// reach the omission. Here it swaps with everything else, in the function whose whole job is
    /// swapping per-side facts.
    @Published public var focusedPaneSide: PaneTree.Side?
    /// Tracks the number of currently active file operations (Sync, Move, Delete, etc.).
    /// Used by the app-level guard to prevent accidental termination during critical tasks.
    /// Not `@Published`: the quit guard reads it imperatively; no view observes it.
    public var activeFileOperationsCount = 0
    /// Monotonic count of file operations ever STARTED, and never decremented, so a long async
    /// pass can tell that an operation ran even when it started AND finished during the pass —
    /// re-checking `activeFileOperationsCount == 0` alone cannot see that window.
    ///
    /// Three consumers, answering two different questions:
    ///
    /// - `autoVerifySameSizePairs` and `verifyAllWithChecksum` capture it at entry and discard
    ///   their batch if it moved by commit time — "did anything rewrite the bytes I hashed while
    ///   I was hashing them?".
    /// - `confirmVerifiedCopy` compares it against the epoch stamped into the standing offer —
    ///   "have those verdicts been invalidated in the time the dialog has been up?".
    ///
    /// The epoch answers both only for operations that have STARTED. It says nothing about one
    /// that is claimed and imminent, because the bump happens at enqueue time (below) while the
    /// claim happens earlier, at `preCountFileOperation()`. Whether that gap matters depends on
    /// the consumer, so the two questions take different guards and MUST NOT be unified:
    /// `confirmVerifiedCopy` pairs the epoch with `activeFileOperationsCount == 0` because it is
    /// about to write and a pending write must stop it; the scan pass deliberately does not,
    /// because a pre-counted operation the user then declines never runs, and voiding a whole
    /// hashed batch for it cost real coverage. Each guard carries the reasoning at its site.
    ///
    /// Bumped in `enqueueFileOperation`, NOT alongside `activeFileOperationsCount` — the two
    /// deliberately move at different moments. The count moves at PRE-count time because the
    /// quit guard and the hashing exclusions must treat a pending transfer as in flight while
    /// its confirmation prompt is up. The epoch may not: a declined prompt runs no I/O, yet the
    /// bump cannot be taken back (that is the point of a monotonic counter), so bumping it there
    /// voided the whole auto-verify batch for an operation that never happened — and since
    /// nothing ran, nothing sent `refreshSubject`, so no rescan re-ran the pass and those rows
    /// stayed listed as differences until a manual rescan.
    internal private(set) var fileOperationsEpoch = 0

    /// Records that a file operation is about to run (see `fileOperationsEpoch`). Called from
    /// `enqueueFileOperation` only — that is the serial queue every user file operation is
    /// routed through. (The orphaned-temp sweep is the one filesystem write that is not, and
    /// deliberately so: it only ever REMOVES age-gated `.tmp_<UUID>` staging artifacts, and a
    /// removal cannot make a differing pair hash identical, which is the whole failure this
    /// counter exists to catch. `sweepOrphanedTempArtifacts` carries the full reasoning and the
    /// cost of the naive fix.)
    private func noteFileOperationBegan() {
        fileOperationsEpoch += 1
    }
    /// Real-time progress tracker for the currently active bulk file operation.
    @Published public var activeProgress: Progress? = nil
    /// Short-lived banner for in-app operation completion toasts. The severity drives the UI's
    /// icon, tint, and dismissal behavior.
    ///
    /// Every banner is also logged here, at the severity it wears, prefixed `[banner]`. This is
    /// the choke point that keeps refusals findable after the fact: a dozen guards across this
    /// class refuse an operation with nothing but a banner, and a banner is gone in seconds —
    /// a report of "I clicked sync and nothing happened" was undiagnosable from the log alone.
    /// Sites that also log their own richer line will produce a near-duplicate pair; that is
    /// accepted, because the `[banner]` line records what the USER was shown, which the richer
    /// line does not.
    @Published public var banner: OperationBanner? = nil {
        didSet {
            guard let banner, banner.id != oldValue?.id else { return }
            switch banner.severity {
            case .success: Logger.shared.info("[banner] \(banner.message)")
            case .warning: Logger.shared.warning("[banner] \(banner.message)")
            case .error: Logger.shared.error("[banner] \(banner.message)")
            }
        }
    }
    
    /// Global Combine subject to trigger a UI refresh of trees from anywhere without closure retain cycles.
    ///
    /// **It carries which panes to walk, and that is the whole point of the payload.** This was
    /// `Void`, and a scopeless request can only be honoured as `.both` — so *navigating one pane*
    /// re-walked the other pane's root as well, on a source and a focus that navigation had not
    /// touched. The tab strip already knew better (`refreshForTabSwitch` names the moved pane and
    /// measured 15–36ms of every switch spent re-walking a pane nobody moved), but navigation is far
    /// commoner than a tab switch, and after any file operation or sort change the prefetch cache is
    /// empty, so the untouched pane's "reload" is a full cold walk of its root — 37–39k nodes and
    /// most of a second on a real pair.
    ///
    /// Senders that genuinely change what a walk would produce — a finished file operation, a
    /// date-tolerance change, a sort that needs fresh tags — still send `.both`, and must: their
    /// change applies to both trees. The narrow scopes come from `syncPathsFromHistory`, the one
    /// sender here that knows a pane moved and the other did not — through ordinary navigation, or
    /// through `retargetPane`, which re-points a single pane at a new source.
    ///
    /// A narrow request is never a way to skip a load that is owed: `refreshTreesAndScan` unions a
    /// one-pane scope with any wider refresh already in flight, so a `.leftOnly` arriving mid-launch
    /// widens back to `.both` rather than stranding the right pane.
    public let refreshSubject = PassthroughSubject<PaneReloadScope, Never>()
    
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
        /// Which panes this refresh will actually walk.
        ///
        /// Part of the key so a one-pane refresh and a two-pane one for the same target are never
        /// mistaken for each other: without it, a tab switch's `.leftOnly` refresh in flight would
        /// swallow a `.both` that arrived a moment later as a duplicate, and the right pane would
        /// keep a tree nobody reloaded.
        let reloading: PaneReloadScope
    }

    /// Which panes a refresh walks. See `refreshTreesAndScan(left:right:reloading:)`.
    public enum PaneReloadScope: Equatable, Sendable {
        /// Both panes — the answer for anything that changes what a walk would produce.
        case both
        /// Only the left pane; the right keeps the tree it is already showing.
        case leftOnly
        /// Only the right pane.
        case rightOnly

        public static func movedPane(isLeft: Bool) -> PaneReloadScope { isLeft ? .leftOnly : .rightOnly }

        /// How this scope reads in `~/sync-cloud.log`, as the object of a sentence: "…re-walking
        /// \(scope.describedPanes)".
        ///
        /// Here rather than as a `switch` at the call site because the one caller is a closure in
        /// `ContentView.body`, where no test can reach it — the same reason `PaneSideChoice.name`
        /// exists in the app target. `String(describing:)` is not a substitute: it yields
        /// `leftOnly`, which is a case name, not something a person reading a log has been told the
        /// meaning of. (The widening line deliberately keeps the case name: it is naming the
        /// *request* it received, and matching the source is the point there.)
        public var describedPanes: String {
            switch self {
            case .both: return "both panes"
            case .leftOnly: return "the left pane"
            case .rightOnly: return "the right pane"
            }
        }
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

    /// Prepares a user-initiated force refresh: drops the prefetch cache AND bumps the scan-config
    /// epoch. The epoch bump is essential — `refreshTreesAndScan` dedupes on a `RefreshKey` that
    /// includes `scanConfigGeneration`, so without it a forced rescan requested while a same-target
    /// refresh is already in flight would produce a byte-identical key and be swallowed as a
    /// duplicate, silently doing nothing. Bumping the epoch makes the forced refresh supersede the
    /// in-flight one instead (matching the file-operation and setting-change supersede paths).
    /// `noteScanConfigChanged` is `internal`, so the app can't do this itself — hence this entry.
    public func prepareForcedRescan() {
        dropPrefetchedTrees()
        noteScanConfigChanged()
    }

    /// The dedupe identity for a refresh of the given targets under the current config epoch.
    internal func makeRefreshKey(left: CloudProvider, right: CloudProvider,
                                 reloading: PaneReloadScope = .both) -> RefreshKey {
        RefreshKey(
            leftId: left.id, leftPath: left.rootPath,
            rightId: right.id, rightPath: right.rootPath,
            leftRel: leftRelativePath, rightRel: rightRelativePath,
            config: scanConfigGeneration,
            reloading: reloading
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
    /// The task draining a queued scan, when one is running. Separate from `activeRefreshTask`
    /// because a drained scan runs after its refresh has finished — see the drain at the end of
    /// `executeScan`, and `cancelScan`, which is the only reader.
    var scanDrainTask: Task<Void, Never>?
    
    /// Synchronously counts a file operation that is committed but not yet queueable — today only
    /// `transferItems`, which counts before its confirmation modal so the quit guard and the
    /// hashing exclusions treat a pending transfer as in flight while the dialog is up. Pair with
    /// `enqueueFileOperation(alreadyCounted: true)`, or with `cancelPreCountedFileOperation()`
    /// when the user declines; the completion decrement is shared and unconditional.
    ///
    /// **Counts only — it does NOT claim a queue position, and for this caller must not.** The
    /// modal can stay open for minutes, and a slot claimed in front of it would hold every later
    /// operation for exactly that long. The undo/redo handlers, which have no such gap, use
    /// `claimFileOperationSlot()` instead: it counts the same way and additionally fixes the
    /// operation's position before the `Task` that runs it exists.
    public func preCountFileOperation() {
        activeFileOperationsCount += 1
    }

    /// Reverts a `preCountFileOperation()` whose operation will never be enqueued — the user
    /// declined its confirmation prompt. Only for that pairing: operations that DID enqueue
    /// are decremented by `enqueueFileOperation`'s unconditional completion handler.
    ///
    /// There is nothing to revert on the epoch side, and that is the point: a monotonic counter
    /// cannot be un-bumped, so the pre-count deliberately leaves it alone and the bump happens
    /// at enqueue time instead. A declined prompt therefore leaves no trace at all, which is
    /// correct — nothing was read and nothing was written.
    public func cancelPreCountedFileOperation() {
        activeFileOperationsCount = max(0, activeFileOperationsCount - 1)
    }

    /// Synchronously CLAIMS this operation's position in the serial file-operation queue, before
    /// the `Task` that will run it exists.
    ///
    /// **Why a claim and not just an ordering convention.** `enqueueFileOperation` reads and
    /// writes `fileOperationTask` without a suspension in front of it, so two callers that are
    /// ALREADY on the main actor claim in call order — but that rests on the caller's isolation
    /// and, for callers that spawn a `Task` first, on equal-priority main-actor jobs being FIFO.
    /// Neither is checkable at the call site: a future `Task.detached { await
    /// manager.enqueueFileOperation { … } }` reinstates the hop and the race silently, and the
    /// race is a ⌘Z that deletes the folded files out of a merge's keeper before restoring the
    /// originals (measured at ~1 inversion in 300 undos of that pair before the hop was removed).
    /// A slot moves the ordering decision to a point the caller controls — its own synchronous
    /// main-actor stretch — so the queue order stops depending on task scheduling or on where
    /// `enqueueFileOperation` is eventually called from.
    ///
    /// Everything `enqueueFileOperation`'s prologue does happens HERE instead: the count, the
    /// epoch bump, and the chain claim. Pass the returned slot to exactly one
    /// `enqueueFileOperation(slot:)`; do not also pass `alreadyCounted`.
    ///
    /// **Claiming BLOCKS every later operation until this one finishes**, which is why the
    /// confirmation-gated transfer path keeps `preCountFileOperation()` instead: it counts before
    /// a modal that can stay open for minutes, and a slot claimed there would hold the whole queue
    /// for the length of the dialog. The undo/redo handlers have no such gap — their `Task` starts
    /// immediately — so they claim.
    ///
    /// Dropping a slot without enqueuing it is safe: the slot releases its position on
    /// `deinit`, so a claim that is never used cannot wedge the queue.
    public func claimFileOperationSlot() -> FileOperationSlot {
        claimFileOperationSlot(alreadyCounted: false)
    }

    private func claimFileOperationSlot(alreadyCounted: Bool) -> FileOperationSlot {
        if !alreadyCounted { activeFileOperationsCount += 1 }
        noteFileOperationBegan()
        let predecessor = fileOperationTask
        let slot = FileOperationSlot(predecessor: predecessor)
        // The successor's claim chains on THIS: it waits for our predecessor and then for our
        // body's completion signal — the same total order the previous shape got by chaining on
        // the operation's own task, just claimed earlier.
        //
        // The chain captures the SIGNAL, never the slot. Holding the slot here would keep it
        // alive for the whole chain and disarm the `deinit` release that stops an unused claim
        // from wedging the queue.
        let released = slot.released
        fileOperationTask = Task { _ = await predecessor.result; await released.wait() }
        return slot
    }

    /// Enqueues a file operation to be executed sequentially.
    /// Manages `activeFileOperationsCount` and triggers UI refreshes and selection pruning upon completion.
    /// - Parameter alreadyCounted: True when the caller already bumped the counter via
    ///   `preCountFileOperation()`; skips the increment so the operation isn't double-counted.
    /// - Parameter slot: A position already claimed by `claimFileOperationSlot()`, in the caller's
    ///   own synchronous main-actor stretch. Pass one whenever this operation's order relative to
    ///   another matters — with a slot the order is fixed at claim time and no longer depends on
    ///   where or when this method is called. Mutually exclusive with `alreadyCounted`: the claim
    ///   already counted the operation.
    @discardableResult
    public func enqueueFileOperation<T: Sendable>(
        alreadyCounted: Bool = false,
        slot: FileOperationSlot? = nil,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        // The epoch moves HERE, unconditionally — this is the last point before the work is
        // queued, and every user file operation (transfers, undo/redo, bulk sync, duplicates,
        // name normalization, automations, filing) reaches the disk through this call. The
        // count moves here only when the caller didn't already pre-count it (see
        // `preCountFileOperation`, which deliberately runs earlier).
        //
        // **Straight-line, and NOT `await MainActor.run` — that hop is what made the queue's
        // order a race.** This method is already `@MainActor`, so the block was redundant for
        // isolation; what it was not was free. `MainActor.run` is a *nonisolated* async
        // function, so awaiting it from the main actor hops OFF to the generic executor and back
        // (SE-0338) — two real suspensions between entering this method and claiming a slot in
        // `fileOperationTask` below. Two callers that entered in a fixed order came back from
        // that round trip in whatever order the pool released them, and the second could read
        // `fileOperationTask` before the first had written it: the two operations then chained
        // on the SAME predecessor and ran concurrently, or in the reverse of the order they were
        // requested in.
        //
        // That is a correctness property, not a tidiness one, and undo is where it bites. A
        // merge's ⌘Z pops two registrations in a deliberate order — restore the redundant copies
        // from the Trash FIRST, delete the folded files out of the keeper SECOND — so a failed
        // restore still leaves the folded files in the keeper rather than leaving the user with
        // neither. Both handlers run synchronously inside `undo()` and each spawns a `Task` that
        // calls this method; the registration order and the task-start order are both
        // deterministic, and this hop threw the ordering away at the last step. Measured before
        // the fix, on an IDLE machine: two operations requested in a fixed order from two
        // main-actor tasks ran in the wrong order 8 and 12 times out of 300, while the
        // task-start order inverted 0 times out of 300 — so the inversion was entirely inside
        // this method, between entering it and claiming the slot. Driven through the merge's
        // real pair (a `registerCopyUndo` and a `registerRestoreItems` in one group, then
        // `undo()`) the rate is ~1 in 300 idle, which is why it read as a full-suite-only flake:
        // `--filter` passed eight times out of eight and six whole idle package runs never hit
        // it. After the fix, 0 in 900 through the same merge pair and 0 in 300 through the
        // primitive.
        //
        // **What the fix actually guarantees, stated precisely, because the unqualified version of
        // this sentence was wrong.** With no suspension between entry and the claim, the
        // read-modify-write of `fileOperationTask` happens in the caller's own main-actor turn —
        // so the queue order is the call order FOR CALLERS ALREADY ON THE MAIN ACTOR, and, for
        // callers that spawn a `Task` and call from inside it (the undo/redo handlers), only
        // additionally because equal-priority main-actor jobs run FIFO. Every call site today
        // satisfies the first condition; nothing here enforces it, and a future
        // `Task.detached { await manager.enqueueFileOperation { … } }` would reinstate the hop
        // and the race without a word.
        //
        // `slot:` is what makes the ordering structural instead of conventional: the caller claims
        // its position synchronously (`claimFileOperationSlot()`), before the Task that will run
        // the operation exists, so neither this method's isolation nor the scheduler can reorder
        // two claims. `FileOperationQueueOrderTests` pins both halves — the unslotted call order
        // for main-actor callers, and slotted order held across deliberately inverted, off-main
        // enqueues.
        let claimed = slot ?? claimFileOperationSlot(alreadyCounted: alreadyCounted)
        let previousTask = claimed.predecessor
        let newTask = Task.detached(priority: .userInitiated) {
            _ = await previousTask.result
            let res = await operation()
            await MainActor.run { [weak self] in
                // File operations mutate the filesystem; cached prefetched roots are stale after any write.
                self?.dropPrefetchedTrees()
                // A refresh already in flight walked mid-operation disk state; the post-op
                // refresh below must supersede it, not dedupe against it.
                self?.noteScanConfigChanged()
                self?.activeFileOperationsCount = max(0, (self?.activeFileOperationsCount ?? 1) - 1)
                self?.scheduleSelectionPrune()
                self?.refreshSubject.send(.both)
            }
            // Hands the queue on, AFTER the cleanup above — the successor's claim is waiting on
            // exactly this. Holding `claimed` strongly here is what keeps its `deinit` release
            // (the unused-claim valve) from firing while the operation is still running.
            claimed.release()
            return res
        }
        return await newTask.value
    }
    
    public func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool {
        // Strip currentPath only at a path-component boundary (PathBoundary's exact semantics —
        // this method was its reference implementation) so a pane rooted at "/root/ab" never
        // claims "/root/abc/x" via a bare string prefix. A node outside the pane root keeps its
        // absolute path, exactly as the hand-rolled fall-through did.
        let rPath = PathBoundary.relativize(node.id, under: currentPath) ?? node.id
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
    /// Records which rows a bulk transfer could not move, or clears the record on a clean run.
    ///
    /// Called by BOTH bulk paths, unconditionally, at the same point each removes its successes —
    /// including when `failures` is empty. That is the half worth stating: a clean run has to
    /// *clear* the previous run's failures, or the Failed filter keeps offering rows that have
    /// since gone through, and the count in the menu becomes a number nobody can reconcile.
    internal func recordTransferFailures(_ failures: [(FileDifference, Error)]) {
        guard !failures.isEmpty else {
            // Assigning nil over nil would republish for no reason on every clean run; the manager
            // has ~56 published properties and every write re-evaluates the window's body.
            if lastTransferFailures != nil { lastTransferFailures = nil }
            return
        }
        lastTransferFailures = TransferFailures(ids: Set(failures.map { $0.0.id }))
    }

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
        stampSyncing(true, on: ids)
    }

    /// Clears the in-flight mark set by `markSyncing(ids:)` from the id set and the published
    /// rows. Rows already removed by `removeResolvedDifferences` are simply not found — the
    /// set subtraction still runs, so no id can leak.
    internal func clearSyncing(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        syncingDifferenceIds.subtract(ids)
        stampSyncing(false, on: ids)
    }

    /// Stamps `isSyncing` on the published rows in ONE write.
    ///
    /// **`differences` is `@Published`, so `differences[i].isSyncing = x` is not an in-place edit.**
    /// The wrapper exposes only a getter and a setter — no `_modify` — so each element write reads
    /// the whole array out, mutates a copy while the original still holds a reference (a full COW
    /// copy of every row), writes it back, and publishes. Per row. Marking m of n rows was
    /// therefore O(n·m) copying plus m `objectWillChange` sends, all on the main actor.
    ///
    /// Measured on 29,000 rows, marking all of them — the "Sync All" shape, where the id set is
    /// every row: **11,144 ms before, 7.9 ms after**, and 11,107 ms → 7.1 ms to clear them again.
    /// A bulk sync spent ~22 s of main-thread time doing nothing but setting a flag, and sent
    /// 58,000 `objectWillChange`s where 2 will do. Reading the rows out once is the entire fix;
    /// the loop below is unchanged apart from where it writes.
    ///
    /// The `!= value` test makes a redundant stamp free, and the `changed` guard keeps a no-op from
    /// republishing at all — the same reason `applyFilters()` compares before assigning, since
    /// republishing an unchanged list rebuilds the whole pane `List` and can eat a click.
    ///
    /// **This was the only instance, and that was checked rather than assumed.** All 100
    /// `@Published` properties across `Modules`, `MacApp` and `SyncCloudCLI` were scanned for a
    /// subscript write or a mutating call inside a loop over the same collection: the other
    /// element writes (`PeopleStore.update`, `PersonTagStore`, `SettingsManager.folderSources`,
    /// `filingSuggestions`, `automationRules`) are all single writes guarded by a `firstIndex`,
    /// which costs one COW copy per call, not one per element. `duplicateGroups` is written inside
    /// a loop, but only for the one or two groups that contain the path, over a collection
    /// measured at 722–977 here. The shape that hurts is m writes into a list of n where m scales
    /// with n, and `differences` at ~29,000 rows was the only place it occurred.
    private func stampSyncing(_ value: Bool, on ids: Set<UUID>) {
        var rows = differences
        var changed = false
        for i in rows.indices where ids.contains(rows[i].id) && rows[i].isSyncing != value {
            rows[i].isSyncing = value
            changed = true
        }
        if changed { differences = rows }
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
        // The two inputs the reconcile pass below re-applies. Snapshotted here so that pass can
        // be skipped outright when neither moved, rather than rebuilt more cheaply.
        let entryRawDifferencesVersion = rawDifferencesVersion
        let entrySyncingVersion = syncingDifferenceIdsVersion
        // Snapshot the published rows too, so their deep compare joins the trees' off the main
        // actor. `[FileDifference]` is Sendable and this is a COW retain, not a copy.
        let publishedDifferences = differences
        let entryDifferencesVersion = publishedDifferencesVersion

        let (state, leftTreeChanged, rightTreeChanged, differencesChanged) = await Task.detached(priority: .userInitiated) {
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
            return (state,
                    state.leftTree != publishedLeft,
                    state.rightTree != publishedRight,
                    state.differences != publishedDifferences)
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
        //
        // **Skipped entirely when neither input moved, which is the ordinary case.** Both halves
        // are then provably no-ops: every row in `state.differences` was filtered FROM the same
        // `rawDifferences`, so none can be missing from it, and `computeFilteredState`'s
        // postcondition is that every row it returns already carries the flag this loop would
        // stamp — unconditionally, the empty set included, which is the half that had to be made
        // true rather than assumed. Measured over 29,000 differences, the two together are ~5 ms
        // of MAIN-ACTOR time per pass, on a function reached from sixteen call sites.
        //
        // Whether the skip was taken, kept rather than re-derived: the publish gate below needs
        // the same answer, and two spellings of one condition is a thing that drifts the day a
        // third input joins the reconcile pass.
        let reconcileWasSkipped = rawDifferencesVersion == entryRawDifferencesVersion
            && syncingDifferenceIdsVersion == entrySyncingVersion
        filterPassesReachingPublish += 1
        let reconciledDifferences: [FileDifference]
        if reconcileWasSkipped {
            reconciledDifferences = state.differences
        } else {
            reconcilePassesRun += 1
            var reconciled = state.differences
            let liveIds = Set(rawDifferences.map(\.id))
            reconciled.removeAll { !liveIds.contains($0.id) }
            for i in reconciled.indices {
                reconciled[i].isSyncing = syncingDifferenceIds.contains(reconciled[i].id)
            }
            reconciledDifferences = reconciled
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
        // The rows' deep compare, trusted from the detached pass on the same terms as the trees':
        // only while nothing wrote the published list since entry, AND while the reconcile pass
        // was skipped — because it is the skip that makes `reconciledDifferences` and
        // `state.differences`, which is what was compared off-main, the same value. Either
        // condition failing drops to the live compare, which is what this line always did.
        let differencesNeedPublishing = reconcileWasSkipped
            && publishedDifferencesVersion == entryDifferencesVersion
            ? differencesChanged
            : self.differences != reconciledDifferences
        if differencesNeedPublishing { self.differences = reconciledDifferences }
    }

    /// One line's worth of "is the filter gate actually skipping anything?", for the scan
    /// breadcrumb in `~/sync-cloud.log`.
    ///
    /// `applyFilters()` skips its reconcile pass whenever neither input moved mid-compute — the
    /// ordinary case, and ~5 ms of main-actor time a pass. **Nothing outside the tests could see
    /// whether that fires on a real tree**, and a gate that never takes its fast path leaves the
    /// cost exactly where it was with every test still green. The fixture that pins the fast path
    /// holds three rows; the question this answers is what happens at 29,000.
    ///
    /// Once per scan rather than once per pass: there are sixteen call sites and a load+scan cycle
    /// runs several, so a per-pass line would bury the log it is written into. Counts are since
    /// launch, which is what makes the ratio worth reading — a single scan's passes are too few.
    ///
    /// Split out from the logging call so the numbers can be asserted directly, without a scan
    /// fixture and without racing the logger's async handoff (`info` returns a `Task`, so
    /// `entries` lags the call that filled it).
    ///
    /// Worded for a reader, not for a profiler, because it lands in the Activity Log beside
    /// `[scan] … completed` rather than only in the file.
    internal func filterGateSummary(rawDifferenceCount: Int) -> String {
        "\(reconcilePassesRun) of \(filterPassesReachingPublish) list rebuilds needed a reconcile"
            + " pass since launch (\(rawDifferenceCount) raw differences)"
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
            // Compiled ONCE for the whole pass. `matches(_:patterns:)` folds every pattern on
            // every call, and this call is per differing item.
            let compiledIgnores = IgnoreRules.Compiled(ignorePatterns)
            filteredDifferences = filteredDifferences.filter { diff in
                !IgnoreRules.matches(diff.relativePath, compiled: compiledIgnores)
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
        //
        // **The postcondition is unconditional: every returned row satisfies
        // `isSyncing == syncingDifferenceIds.contains(id)`, the empty set included.**
        // `applyFilters()` skips its own reconcile pass when nothing moved mid-compute, and that
        // skip is sound only because of this. Leaving the flag alone on the empty set — which is
        // what the guard used to do — would rest it instead on "nothing ever writes `isSyncing`
        // into `rawDifferences`": true today, enforced nowhere, and its failure is a spinner on a
        // row with no operation behind it, which no test would see. So the guard now asks exactly
        // "is this loop provably a no-op?", and the added half is an O(n) read that short-circuits
        // on the first flag, off the main actor, standing in for an O(n) write.
        if !syncingDifferenceIds.isEmpty || filteredDifferences.contains(where: \.isSyncing) {
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

    /// How many times `resortTreesAndRefilter` has taken a snapshot and sorted it.
    ///
    /// Test-only observability, in the same spirit as `publishedLeftTreeVersion`: a retry that
    /// happens is indistinguishable from one that was never needed, so a test for the retry has no
    /// way to tell "the interleaving I set up occurred and the retry saved it" from "the
    /// interleaving never happened and the first pass was fine". Both end with correctly-sorted
    /// trees, and the second is a test that proves nothing. See
    /// `aSupersededResortTriesAgainInsteadOfLeavingAPaneOnTheOldOrder`.
    internal private(set) var resortPasses = 0

    /// Called on the main actor by `resortTreesAndRefilter` **after** it has snapshotted the trees
    /// and **before** it suspends into the off-main sort. `nil` in the app; nothing production
    /// installs it.
    ///
    /// A test seam, in the same shape as `paneSearchSnapshot`, and it exists because the bug the
    /// retry fixes lives entirely inside that suspension: the supersede has to land after the
    /// snapshot, and there is no way to ask for that from outside. Driving it with `Task.yield()`
    /// was tried and did not hold — the resort had not taken its turn, the first pass was never
    /// superseded, and the test measured nothing (which its pass-count assertion said, loudly, and
    /// is why the seam is here rather than a wider timing window that would say it only sometimes).
    internal var resortDidSnapshot: (() -> Void)?

    /// Re-sorts both raw trees off the main actor, then refilters.
    ///
    /// **A pass that is superseded mid-sort tries again rather than giving up**, and the difference
    /// is a pane silently left on the previous sort order.
    ///
    /// The original reasoning for giving up was sound as far as it went: `rawTreeGeneration` moves
    /// when a fresh tree is adopted, and a fresh tree is built with the current option already
    /// applied — so the stale snapshot would clobber newer, correctly-ordered data. But the
    /// generation also moves for `supersedeInFlightPaneWork`, which does **not** hand every pane a
    /// fresh tree. Since pane-scoped invalidation arrived, a source switch or a browse-tab switch
    /// drops only the moving pane's tree and re-walks only that pane: the sibling's raw tree
    /// survives, still ordered by the option the discarded sort was replacing. Nothing re-sorts it,
    /// nothing says so, and it self-heals only on that pane's next reload.
    ///
    /// Retrying is safe for exactly the reason the bail was: each pass publishes only when the
    /// generation held still across its own await, so it can never overwrite a newer tree. A retry
    /// re-snapshots whatever is current — including a freshly adopted tree, which it sorts again
    /// idempotently — so it is correct regardless of *why* the generation moved, which is the part
    /// this function cannot see. Passes stop as soon as one publishes.
    ///
    /// - Parameter attempts: how many snapshots to try before giving up. Bounded because each pass
    ///   is a full sort of both trees; a progressive load publishes shallow-then-deep, so two
    ///   supersedes in a row is ordinary and three passes clears it. Giving up leaves exactly the
    ///   state this method used to leave, plus a line saying so.
    func resortTreesAndRefilter(attempts: Int = 3) async {
        for _ in 0..<max(1, attempts) {
            let option = sortOption
            let left = rawLeftTree
            let right = rawRightTree
            let generation = rawTreeGeneration
            resortPasses += 1
            resortDidSnapshot?()
            let (sortedLeft, sortedRight) = await Task.detached(priority: .userInitiated) {
                (Self.sort(nodes: left, by: option), Self.sort(nodes: right, by: option))
            }.value
            // A newer OPTION is not a supersede to retry through — its own pass is already queued
            // by the `didSet` that changed it, and retrying here would race that pass with a
            // snapshot taken under the option the user has just moved off.
            guard option == sortOption else { return }
            guard generation == rawTreeGeneration else { continue }
            rawLeftTree = sortedLeft
            rawRightTree = sortedRight
            await applyFilters()
            return
        }
        Logger.shared.warning("Re-sort superseded \(max(1, attempts)) times running; a pane may still be "
                              + "ordered by the previous sort until its next reload")
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
    
    /// Whether any component of `path` begins with a dot.
    ///
    /// **The scan exists because this is the one filter in ``computeFilteredState`` that runs in
    /// the default configuration.** All five are behind an `if`, but the other four's conditions
    /// are empty or false until something turns them on, whereas this one's — `showHiddenFiles`,
    /// the ⇧⌘. toggle — starts `false`, so hiding hidden files is what a fresh session does. It
    /// therefore runs over the whole difference list on every rebuild.
    ///
    /// `components(separatedBy:)` allocates an array AND a String per path component per call;
    /// measured over 29,000 differences that is ~37 ms a pass against ~2 ms for the scan below.
    ///
    /// **29,000 is the top of the range, not the middle of it — counted, because this whole family
    /// of changes was justified by that number.** Over 1,721 scans in `~/sync-cloud.log`
    /// (2026-07-05 to 2026-08-26) the median scan finds **123** differences and 96% find fewer
    /// than 1,000; the ~29,000 case is one specific pair, compared repeatedly — 47 scans, 2.7%,
    /// clustered at 28,843 and 28,883, with a single 39,489. So this is a real recurring
    /// comparison and worth optimising for, and at the same time the ordinary scan sees a list two
    /// orders of magnitude smaller, where all of these costs round to nothing. Both halves are the
    /// finding: quoting only the first is how "measured" turns into "typical".
    ///
    /// **The scan can only ever prove the answer is FALSE, and that is what makes it safe.** A
    /// component satisfying `hasPrefix(".")` starts with the grapheme `"."`, which in UTF-8 is the
    /// single byte `0x2E`; so if no component start carries that byte, no component can be hidden
    /// and `false` is certain. When the scan does find a candidate the original expression decides,
    /// because the two do NOT agree there: `hasPrefix` compares grapheme clusters under canonical
    /// equivalence, so a component beginning `"." + U+0301` is one cluster that is not `"."` and
    /// reads as visible, while a byte scan sees the dot and would call it hidden. That is arguably
    /// the better answer — the kernel sees a leading dot — but it is a different answer, and this
    /// change is a performance change. `theScanAgreesWithTheOriginalExpression` pins the equivalence
    /// over an exhaustive sweep of that alphabet; change the fallback and it fails.
    ///
    /// The fallback is also what keeps the two hidden-file deciders in one window agreeing:
    /// ``filterTree`` filters the pane trees on `node.name.hasPrefix(".")`, this same grapheme
    /// comparison, so a byte-only answer here would drop such a name from the difference list
    /// while the pane beside it still listed the file. Same window, same name, two answers.
    ///
    /// Reading UTF-8 rather than Characters is safe for the same reason in reverse: UTF-8 is
    /// self-synchronising, so the bytes for `.` and `/` never occur inside a multi-byte scalar.
    public nonisolated static func isHiddenPath(_ path: String) -> Bool {
        var atComponentStart = true
        var sawCandidate = false
        for byte in path.utf8 {
            if atComponentStart && byte == UInt8(ascii: ".") { sawCandidate = true; break }
            atComponentStart = (byte == UInt8(ascii: "/"))
        }
        guard sawCandidate else { return false }
        return path.components(separatedBy: "/").contains { $0.hasPrefix(".") }
    }
    
    /// Back/forward stack for the left pane; independent of the right pane's.
    @Published public var leftHistory = PaneNavigationHistory()
    /// Back/forward stack for the right pane; independent of the left pane's.
    @Published public var rightHistory = PaneNavigationHistory()

    /// The left pane's tabs. Browse's strip is this one; so is the Organize/Storage rail's, which
    /// is the same pane at 220pt. Seeded with a single tab whose provider id is a placeholder the
    /// host replaces on launch — `FileSyncManager` has never known which providers exist, and this
    /// is not the place to start.
    ///
    /// See `PaneTab` for why the ACTIVE entry here is a stale snapshot by construction: the live
    /// position is `leftRelativePath` and friends, and this list holds only what is parked.
    @Published public var leftPaneTabs = PaneTabList(single: PaneTab(providerId: ""))
    /// The right pane's tabs — Compare's right-hand side. Independent of the left list; ⇄ swaps
    /// the two wholesale, exactly as it swaps the paths they are lists of.
    @Published public var rightPaneTabs = PaneTabList(single: PaneTab(providerId: ""))

    /// What a pane's search field currently holds, asked of the host when a tab is parked.
    ///
    /// A tab owns its query (v4.x roadmap companion §1) and the field is the host's `@State` — `Sync` cannot
    /// see `PaneSearchFieldState`, which also carries a walk index and a reveal nonce derived from
    /// a tree the parked tab is not showing. So the one direction that has to cross the boundary
    /// does it here, and the other direction needs nothing: every tab verb RETURNS the tab it
    /// applied, and the host reads the query off that.
    ///
    /// Unset outside the app — every test of the tab verbs then parks an empty query, which is
    /// exactly what a pane with no search field would hold.
    public var paneSearchSnapshot: (@MainActor (Bool) -> (query: String, isExpanded: Bool))?
    
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

        // Verify All's exclusion guard, mirrored in the write direction: Verify All refuses
        // to START while anything is writing, but a transfer starting MID-verify could still
        // overwrite a file as it's hashed — the pair can read "identical" against bytes that
        // no longer exist, poisoning the copy-to-match-dates offer.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before syncing")
            return false
        }

        // The other half of syncAll's own "a single row may be mid-flight" guard, which was
        // written in one direction only. syncAll latches `isBulkSyncRunning` BEFORE its
        // confirmation prompt, and that prompt's modal spins the run loop — so between the latch
        // and `markSyncing(toSyncIDs)` a queued syncFile aimed at a row in the bulk set passes
        // both guards above (the row is not marked yet) and both flows handle the same
        // difference. `syncingDifferenceIds` is a set, not a refcount, so whichever defer runs
        // first releases the id the other still owns, and a syncFile parked at its own prompt
        // becomes invisible to Verify All's exclusion guard — the hashed-mid-overwrite window
        // these guards exist to close.
        guard !isBulkSyncRunning else {
            banner = .warning("Wait for the current operation to finish before syncing")
            return false
        }

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
                    // Registration is synchronous; the awaited value is the detached identity
                    // walk (see `registerCopyUndo(items:)`), so the sync does not report done
                    // until its undo is fully armed. One file, so the walk is one stat.
                    await self.registerCopyUndo(items: [(source: from, destination: to, overwritten: result.trashed)], actionName: actionName, fileManager: activeFM).value
                }
                // Durable Sync History (X2). Size is free from the difference (source side);
                // checksum is left nil at op time (see the bulk path's checksum note).
                let size = difference.action == .copyToRight ? difference.leftFileSize : difference.rightFileSize
                self.recordSyncHistory([SyncHistoryRecord(
                    runId: UUID(),
                    action: isMove ? .move : .copy,
                    sourcePath: from.path,
                    destPath: to.path,
                    sizeBytes: size,
                    checksum: nil,
                    backupPath: result.trashed?.path,
                    direction: difference.action == .copyToRight ? "→ Right" : "← Left"
                )])
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
