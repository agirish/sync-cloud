import Events
import Foundation
import Combine

/// Core business logic for the two-pane file comparison and sync engine.
/// Holds in-memory trees (`FileNode`) for the left and right panes, runs differential scans,
/// and serializes file operations (copy, move, delete) with undo support and termination guards.
@MainActor
public class FileSyncManager: ObservableObject {
    /// Refuses a rename, move or delete that would change one-way sync's copy, which is iCloud's to
    /// change: given the paths about to be touched, the reason, or nil. Set by the app. A synced
    /// Dropbox file is changed in iCloud, and the sync carries it over.
    public var oneWaySyncRefusal: (([String]) -> String?)?

    /// File system abstraction used for all disk I/O (supports injection for tests).
    public let fileManager: FileManaging
    
    /// Resolves a name collision during a file operation. Defaults to `.skip` so an unwired manager
    /// never overwrites; the app wires an NSAlert prompt and tests inject answers. The
    /// `FileCollision` says which copy replaces which, and whether the destination is a folder,
    /// whose whole contents a replace would take.
    public var collisionResolver: @MainActor (FileCollision) -> CollisionResolution = { _ in
        return .skip
    }

    /// The bulk-sync variant of `collisionResolver`, adding an "Apply to all" choice.
    /// Defaults to skipping the conflicting item; the app wires an NSAlert-backed prompt at construction.
    public var bulkCollisionResolver: @MainActor (FileCollision) -> (resolution: CollisionResolution, applyToAll: Bool) = { _ in
        return (.skip, false)
    }

    /// Confirms a copy or move before any I/O. Each transfer entry point (`transferItems`,
    /// `syncFile`, `syncAll`) asks once per user action. Defaults to proceeding, since a transfer
    /// is undoable and replaces prompt separately; the app wires an NSAlert gated by the "Confirm
    /// before copying or moving" setting.
    public var transferConfirmer: @MainActor (TransferSummary) -> Bool = { _ in
        return true
    }

    /// Whether the volume a not-yet-created destination will land on distinguishes names by case. A
    /// seam so a multi-volume batch is testable; `syncAll` asks per destination. A wrong answer
    /// loses data: told "case-sensitive" about a case-insensitive volume, two case-variant targets
    /// both pass the batch's uniqueness check and the parallel workers write to one file.
    public var destinationCaseSensitivity: (URL) -> Bool = { url in
        FileSyncManager.volumeSupportsCaseSensitiveNamesForNewItem(at: url)
    }

    /// Resolves a destination name the provider forbids (Dropbox and OneDrive reject trailing
    /// spaces or dots; OneDrive also some characters and reserved names), before any I/O. Such a
    /// name creates an item the provider never uploads, a local-only lookalike of its sanitized
    /// sibling. Defaults to `.skip`; the app wires a prompt offering the sanitized name. Consulted
    /// only inside a provider root known from the last scan (`lastScanProviders`).
    public var invalidNameResolver: @MainActor (NameViolationPrompt) -> InvalidNameResolution = { _ in
        return .skip
    }

    /// The pane providers of the most recent completed scan, which attribute transfer destinations
    /// to a provider for the `invalidNameResolver` check. nil until a scan lands (tests, CLI cold
    /// start), and then destinations are not name-checked. Cleared with the comparison state on
    /// provider changes; swapped in `swapPanes`.
    ///
    /// Public for the reason `lastScanRootNames` is: a caption about the published rows must name
    /// the pair they came from, not wherever the panes navigated since. Set only here.
    public internal(set) var lastScanProviders: (left: CloudProvider, right: CloudProvider)?

    /// The last path component of each compared folder when the latest scan's results were
    /// published, which the differences table's Path column anchors to (so a root-level row says
    /// "Home"). Captured with the results, since the panes can navigate away while the diff still
    /// describes the scanned folders. nil until a scan lands; cleared with the comparison state and
    /// swapped in `swapPanes`. Not `@Published`: it changes only in the publish that replaces
    /// `differences`.
    public internal(set) var lastScanRootNames: (left: String, right: String)?

    /// When the latest comparison scan completed, so the Differences view tells a new scan from the
    /// last (its folds are kept per scan). nil until a scan lands and whenever the comparison is
    /// invalidated, so it never outlives its diff; a swap keeps it. Published so the header
    /// re-renders. Not the comparison's age, which is `lastScanReadAt`.
    @Published public internal(set) var lastScanDate: Date?

    /// When the folders behind the latest comparison were read (the older of its two walks): the
    /// comparison's real age, which its freshness pill and the not-scanned card report. nil exactly
    /// when `lastScanDate` is; a swap keeps it.
    ///
    /// Not `lastScanDate`, because a scan from cached trees reads no disk: it compares the panes'
    /// walks (`prefetchedTrees`), each as old as its `prefetchedTreeReadAt`, and a source switch
    /// keeps the other pane's walk, so it can be hours old. A scan that walks both folders itself
    /// has the two dates agree.
    @Published public internal(set) var lastScanReadAt: Date?

    /// Confirms permanently deleting items that could not be moved to the Trash (such as on network
    /// volumes), given their absolute paths: this is the app's only unrecoverable action, and its
    /// dialog must tell two same-named items apart, which a duplicate group's copies usually are.
    /// Defaults to `false` so an unwired manager never destroys data; the app wires an NSAlert
    /// confirmation.
    public var permanentDeleteConfirmer: @MainActor ([String]) -> Bool = { _ in
        return false
    }

    /// Moves items to the Trash through the system's file-operation service, for when
    /// `FileManager.trashItem` is refused permission. Returns original → trashed for what it moved;
    /// empty means it couldn't either.
    ///
    /// `trashItem` moves in this process, so this process must be allowed to write to that item's
    /// Trash, which for an iCloud Drive file is `~/Library/Mobile Documents/.Trash`; Full Disk
    /// Access does not help. `NSWorkspace.recycle` asks the system to do the move, as Finder does.
    ///
    /// Defaults to doing nothing, and the app wires the real service at construction: the engine
    /// may not import AppKit (`LayeringPinTests`), and an unwired manager then behaves as if there
    /// were no fallback. A fallback only, never the first attempt: `trashItem` reports per-item
    /// errors this can't.
    public var trashViaWorkspace: @Sendable ([URL]) async -> [URL: URL] = { _ in [:] }

    /// Whether a provider is moving this item's bytes right now. `deleteItems` asks before spending
    /// the re-registration retry, which renames the item twice.
    ///
    /// A property, so only the delete loop consults it. There the alternative to parking is a
    /// retryable refusal that leaves the file in place; the move primitives' source cleanup reaches
    /// the same retry through `retriedSourceCleanupTrash`, where the alternative is `removeItem`, a
    /// permanent delete. One answer must not serve both.
    ///
    /// A seam because an uploading item can't be fabricated in a test. It defaults to the real
    /// probe (Foundation only, nothing to wire); false is the behaviour without it.
    public var isMidCloudTransfer: @Sendable (URL) -> Bool = { FileSyncManager.midCloudTransfer($0) }

    /// Confirms a cloud (Claude) Filing classify before it commits, given a cost estimate and this
    /// month's spend against the cap. Asked once per refine pass, only when cloud Filing is on
    /// (`filingUsesAI && filingUsesCloud`), just before the classifier runs; never by a scan, which
    /// classifies at ``FilingClassifierTier/free`` and can't spend. The real cost is known only
    /// afterwards, so this is the only chance to show a figure. False skips the cloud call and
    /// keeps the free scan's suggestions. **Defaults to `false`**, the fail-safe: the app wires none,
    /// because its Refine is a plan card in the Ask Claude chat whose Send is the click (TE335). This
    /// is for a host with no chat that calls ``FileSyncManager/refineFilingSuggestions(_:options:)``.
    public var filingCloudSpendConfirmer: @MainActor (FilingSpendPreflight) -> Bool = { _ in
        return false
    }

    /// Confirms a whole-tree pass whose probe ran out of budget: the tree is too big to analyse
    /// without a wait worth warning about. Asked only when the probe stopped; otherwise the probe's
    /// walk is the tree the pass uses.
    ///
    /// Defaults to `false`, the fail-safe here: an unwired manager that proceeded would start a
    /// pass that may never finish, where nobody is watching. A refusal is logged and leaves the
    /// previous result standing. The app wires an NSAlert prompt.
    public var largeWalkConfirmer: @MainActor (LargeWalkPreflight) -> Bool = { _ in
        return false
    }

    /// How much a whole-tree pass reads before it stops to ask. Larger than `paneNodeBudget`, which
    /// is about latency and truncates silently because a partial pane is still useful. These passes
    /// have a progress bar and a cancel, and can't truncate: a storage total or a duplicate group
    /// computed from part of a tree is a wrong answer.
    ///
    /// A 400,000-entry walk costs ~2.5 s (Release, warm), a fair price
    /// for learning that the real answer would take minutes. Below it no prompt appears, and the
    /// probe's tree goes straight to the pass.
    nonisolated public static let defaultWholeTreeProbeBudget = 400_000

    /// The live probe budget, an instance property so a test can drive the guard on a dozen-file
    /// fixture.
    public var wholeTreeProbeBudget: Int = FileSyncManager.defaultWholeTreeProbeBudget

    /// The durable Sync History every copy, move and delete is recorded into: unlike the in-memory
    /// Activity Log it survives quit and can be filtered, exported and reversed by run. Injected
    /// (defaults to the shared store) so tests get their own. Recording never fails or blocks the
    /// operation: `SyncHistoryStore.appendBatch` doesn't throw and writes on a background queue.
    public var syncHistoryStore: SyncHistoryStore = .shared
    /// Where each filing's first-pick verdict is kept (TE341). Injected so tests get their own.
    public var filingScorecard: FilingScorecardStore = .shared

    /// The `UndoManager` action name captured when the last history-recorded run registered its
    /// undo group, plus that run's records. They let `undoLastSyncRunAskingFirst` check that the
    /// stack's top is still that run, since the shared `UndoManager` also holds Filing, rename and
    /// New Folder actions that aren't sync runs.
    private(set) var lastRecordedRunUndoName: String?
    private(set) var lastRecordedRunRecords: [SyncHistoryRecord] = []
    /// A fresh token each time a run arms the pairing, carried by its preview, so a confirmation
    /// can tell when answered whether the run on top is still the one it showed. The name can't:
    /// every bulk run is "Sync run".
    private(set) var lastRecordedRunToken: UUID?
    /// Whether any run armed the pairing this session. Tells "the pairing was invalidated" (a
    /// manual ⌘Z, a mixed delete, a manager swap) from "no sync run yet", so a fresh launch's
    /// refusal doesn't claim history changed since a last sync run.
    private(set) var hasArmedRunPairingThisSession = false
    /// The Ask Claude card whose Apply tops the undo stack (`applyPlan`); cleared by every undo
    /// registration (`invalidateUndoableBanner`) and every undo or redo (`invalidateRunUndoPairing`).
    var planUndoToken: UUID?

    /// Records a run's history entries, if any: one funnel so every op site records the same way.
    /// Never fails the caller. Also snapshots the run's undo-group name (each op site registers its
    /// undo first) so Undo Last Run can confirm it's still the top of the stack.
    ///
    /// **Call it in the same main-actor turn as the registration, never after an await.** Read
    /// later, the top may be a rename registered meanwhile (Undo Last Run would describe the run
    /// and reverse the rename), and a ⌘Z in between would be undone by re-arming the pairing over
    /// the group below.
    ///
    /// `pairedWithUndo: false` appends without touching the pairing, for runs that registered no
    /// undo group for these records (an all-permanent delete). Pairing them would describe this run
    /// while reversing whatever sits on top. The previous pairing stays live: its group is still
    /// the top.
    ///
    /// Returns the run's id, for the operation to put on the message that reports it
    /// (``OperationBanner/reporting(run:)``), or nil when there was nothing to record.
    @discardableResult
    func recordSyncHistory(_ records: [SyncHistoryRecord], pairedWithUndo: Bool = true) -> UUID? {
        guard let runId = records.first?.runId else { return nil }
        syncHistoryStore.appendBatch(records)
        guard pairedWithUndo else { return runId }
        lastRecordedRunUndoName = undoManager?.undoActionName
        lastRecordedRunRecords = records
        lastRecordedRunToken = UUID()
        hasArmedRunPairingThisSession = true
        return runId
    }

    /// Drops the run-undo pairing. Called on every direct undo or redo (wired in the `undoManager`
    /// didSet): a manual ⌘Z can pop run B and leave run A's identically named "Sync run" group on
    /// top, where the name gate would preview B and reverse A. `reverseLastSyncRun` clears the
    /// pairing itself.
    ///
    /// Also called from `deleteItems` when an op registers an undo group without arming the
    /// pairing: a mixed delete's "Move N Items to Trash" can match an earlier armed delete's name
    /// and pass the gate over the wrong group.
    func invalidateRunUndoPairing() {
        lastRecordedRunUndoName = nil
        lastRecordedRunRecords = []
        lastRecordedRunToken = nil
        planUndoToken = nil
    }

    /// A preview of what Undo Last Run would reverse, or nil when it must not act: nil unless the
    /// `UndoManager` can undo and its next action name still equals the last recorded run's, so
    /// nothing (a Filing move, rename, New Folder or manual ⌘Z) has changed the top since. This
    /// gate keeps the reversal from touching the wrong action.
    public var lastSyncRunUndoPreview: SyncRunUndoPreview? {
        guard let undoManager, undoManager.canUndo,
              let expected = lastRecordedRunUndoName,
              undoManager.undoActionName == expected,
              !lastRecordedRunRecords.isEmpty,
              let token = lastRecordedRunToken
        else { return nil }
        return SyncRunUndoPreview(actionName: expected, records: lastRecordedRunRecords, runToken: token)
    }

    /// Why Undo Last Run would refuse right now, in the user's words, or nil when it would act.
    /// Shown in Activity's Events' own alert (`undoLastSyncRunAskingFirst`), where the click
    /// happened. The advice names the main window because ⌘Z in Sync History acts on that window's
    /// own, empty undo stack.
    public var lastSyncRunUndoRefusal: String? {
        // A long run going is the first reason: undo waits for it, as every other write does,
        // whatever the stack holds.
        if let run = activeProgress { return run.runLockReason ?? Progress.genericRunLockReason }
        guard lastSyncRunUndoPreview == nil else { return nil }
        guard let undoManager, undoManager.canUndo else {
            return "There’s no recent sync run to undo — the undo history resets when SyncCloud restarts."
        }
        let top = undoManager.undoActionName
        // A dead pairing (a manual ⌘Z or ⇧⌘Z, or a partial delete, invalidated it) is not a name
        // mismatch: the top may well be named "Sync run". Never armed is different again: with no
        // sync run this launch, name the top action rather than invent a run.
        if lastRecordedRunUndoName == nil && hasArmedRunPairingThisSession {
            return "The undo history changed since the last sync run — use Edit ▸ Undo (⌘Z) in the main window to step back."
        }
        return top.isEmpty
            ? "The most recent action isn’t a sync run — use Edit ▸ Undo (⌘Z) in the main window to reverse it."
            : "The most recent action is “\(top)”, not a sync run — use Edit ▸ Undo (⌘Z) in the main window to reverse it."
    }

    /// Reverses the most recent sync run for its Undo… in Activity's Events: asks `confirm` with the
    /// preview, and reverses only on yes. Reuses the tested `UndoManager` stack, no new
    /// file-mutating path; a bulk run is one grouped step, so it reverses at once.
    ///
    /// When nothing may be reversed, `confirm` isn't asked and the reason is returned for the
    /// caller to show where the click happened. No banner: that belongs to the main window.
    /// - Returns: The refusal, or nil when it asked (whatever the answer was).
    @discardableResult
    public func undoLastSyncRunAskingFirst(confirm: (SyncRunUndoPreview) -> Bool) -> String? {
        guard activeProgress == nil, let preview = lastSyncRunUndoPreview else { return loggedRunUndoRefusal() }
        guard confirm(preview) else { return nil }
        // Re-read, not `preview`: the confirm is a modal, and the stack is only trusted as of now —
        // a run may have started behind it, too.
        guard activeProgress == nil, let current = lastSyncRunUndoPreview else { return loggedRunUndoRefusal() }
        // …and it must still be the run the alert listed: a second "Sync run" finishing behind the
        // modal re-arms the pairing under the same name.
        guard current.runToken == preview.runToken else {
            Logger.shared.warning("Undo Last Run refused: the run on top of the undo stack is not the one the confirmation listed (\(preview.operationCount) operation(s) shown, \(current.operationCount) on top)")
            return "Another sync run finished while you were deciding, so nothing was undone. Choose Undo… on the run again to see what it would reverse."
        }
        reverseLastSyncRun()
        return nil
    }

    /// `lastSyncRunUndoRefusal`, logged: Events' alert leaves no trace, so the log keeps the
    /// line.
    private func loggedRunUndoRefusal() -> String? {
        let refusal = lastSyncRunUndoRefusal
        if let refusal { Logger.shared.info("Undo Last Run refused: \(refusal)") }
        return refusal
    }

    /// The reversal itself, behind the gate `undoLastSyncRunAskingFirst` checks first.
    private func reverseLastSyncRun() {
        guard let undoManager, let preview = lastSyncRunUndoPreview else { return }
        Logger.shared.info("Undoing last sync run: \(preview.actionName) — reversing \(preview.operationCount) operation(s)")
        undoManager.undo()
        // The run is consumed — clear the snapshot so a second press can't reverse it again (a redo
        // re-registers its own group with a fresh action name).
        lastRecordedRunUndoName = nil
        lastRecordedRunRecords = []
        lastRecordedRunToken = nil
    }

    /// Initializes a new FileSyncManager with a specific file manager.
    /// - Parameter fileManager: The file manager to use. Defaults to `FileManager.default`.
    public init(fileManager: FileManaging = FileManager.default) {
        self.fileManager = fileManager
    }

    /// A manager whose settings stores (Keep separate, Filing's settings and rules) are `defaults`
    /// instead of `.standard`. For tests the app hosts, where `.standard` is the user's live domain.
    public convenience init(fileManager: FileManaging = FileManager.default, defaults: UserDefaults) {
        self.init(fileManager: fileManager)
        duplicateIgnoreDefaults = defaults
        filingContentDefaults = defaults
        filingRuleDefaults = defaults
    }

    /// Cached differences from the latest scan before applying hidden/ignored filters.
    internal var rawDifferences: [FileDifference] = [] {
        didSet { rawDifferencesVersion += 1 }
    }
    /// Bumped on every write to ``rawDifferences``, including an in-place element edit, so
    /// `applyFilters()` can tell whether the rows moved while its detached compute ran (as
    /// `publishedLeftTreeVersion` does for the panes) and skip the reconcile pass when they didn't.
    internal private(set) var rawDifferencesVersion = 0
    /// Counterpart for ``syncingDifferenceIds``: the other input the reconcile pass re-applies.
    internal private(set) var syncingDifferenceIdsVersion = 0
    /// IDs of differences with a sync or copy in flight: the source of truth for each row's
    /// `isSyncing`. `applyFilters()` rebuilds `differences` from `rawDifferences`, which never
    /// carries the flag, so without this a filter pass mid-operation would un-mark every row and
    /// re-enable the sync actions while files are still being written. `markSyncing`/`clearSyncing`
    /// update the set and the rows in one main-actor turn, and `applyFilters()` re-stamps the flag
    /// from this set at publish time, so a stale snapshot can't reinstall stale rows.
    internal private(set) var syncingDifferenceIds: Set<UUID> = [] {
        didSet { syncingDifferenceIdsVersion += 1 }
    }
    /// IDs of differences that were verified as same content via checksum; these are hidden from the list until next scan.
    internal var verifiedSameDifferenceIds: Set<UUID> = []
    /// When non-nil, a "Verify All" run is in progress: (completed count, total count).
    @Published public var verifyAllProgress: (completed: Int, total: Int)?
    /// After Verify All, the differences that verified identical, which the UI offers to copy
    /// left→right. Cleared when the user copies or cancels, and when the rows are superseded
    /// (rescan, pane retarget, swap). The list travels with the epoch its verdicts were hashed
    /// under (``VerifiedCopyOffer``), so an offer without its stamp can't exist. Settable only in
    /// this module.
    @Published public internal(set) var verifiedIdenticalForCopy: VerifiedCopyOffer?
    /// Filtered list of differences between the left and right panes (respects `showHiddenFiles`, `ignoredPaths`, and `verifiedSameDifferenceIds`).
    @Published public var differences: [FileDifference] = [] {
        didSet { publishedDifferencesVersion += 1 }
    }
    /// Bumped on every publish of ``differences``. Same role as ``publishedLeftTreeVersion``:
    /// it says whether the deep compare done off-main against an entry snapshot is still
    /// answering the question the main actor is about to ask.
    internal private(set) var publishedDifferencesVersion = 0
    /// How many times `applyFilters()` ran the reconcile pass because an input moved while its
    /// detached compute ran. Makes the gate's fast path observable: no test can see a gate that
    /// silently never fires.
    internal private(set) var reconcilePassesRun = 0
    /// The denominator for ``reconcilePassesRun``: passes that reached the gate. Not
    /// `filterGeneration`, which counts every pass started; superseded passes return before the
    /// gate and would deflate the ratio. Bumped where the gate is read, so both numbers cover the
    /// same passes.
    internal private(set) var filterPassesReachingPublish = 0
    /// Indicates whether a deep structure scan is currently in progress.
    @Published public var isScanning = false
    /// When the running scan started, or nil when none is running. The Compare scan has no honest
    /// fraction to publish (`FileDiffEngine.getFilesInDirectory` counts nothing, and a per-entry
    /// callback would put a main-actor hop on the hottest path), so it publishes how long it has
    /// run. Set and cleared with `isScanning`, so no reader sees one without the other.
    @Published public internal(set) var scanStartedAt: Date?
    /// Whether the running scan has run long enough to show as running. Every busy surface of
    /// Compare reads it (its card, its count pill, the panes' Stop rung); commands still decide by
    /// `isScanning`. A scan of two cached walks usually takes 120–400 ms, and showing that would
    /// flash the pill, the card and the rungs inside half a second. Rises once a scan has run for
    /// `defaultScanShownAfter` (`scanShownWait`); falls with `isScanning`.
    @Published public internal(set) var isScanShown = false
    /// How long a scan runs before `isScanShown` rises. 0.75 s clears typical scans and still
    /// answers inside the second after which a wait reads as a stall.
    static let defaultScanShownAfter: Duration = .milliseconds(750)
    /// The wait itself, `defaultScanShownAfter` of sleep. A seam so a test decides when it ends
    /// rather than racing a clock: on a loaded machine a two-file scan can take over a second.
    var scanShownWait: @MainActor () async -> Void = {
        try? await Task.sleep(for: FileSyncManager.defaultScanShownAfter)
    }
    /// The wait behind `isScanShown`, cancelled when the scan it was started for ends.
    var scanShownTask: Task<Void, Never>?
    /// Indicates whether at least one successful scan has occurred.
    @Published public var hasScanned = false

    // MARK: Small persisted facts about what the user last did

    /// Where the manager keeps the few small facts that outlive a launch: each lens's
    /// last-completed scan target, and the Compare scan's last summary.
    ///
    /// Injected by the app. nil, the default for the CLI and bare test managers, turns all of them
    /// off, reads and writes both; a fallback to `.standard` would have every test that completes a
    /// scan writing the user's real defaults. One store rather than one per feature, since
    /// forgetting to set a second would leave a feature silently off.
    public var persistedUIStateDefaults: UserDefaults?

    /// The defaults key holding ``LastScanSummary`` as JSON.
    public static let lastScanSummaryKey = "compareLastScanSummary"

    /// Whether the last completed Compare scan could read both sides in full. Not persisted, unlike
    /// `lastScanSummary`: it describes the rows on screen, and restored beside a table nobody
    /// rebuilt it would warn about a scan that isn't there. Cleared by `invalidateComparisonState`
    /// with its rows. See ``PartialComparison``: a side whose root came back unread mints no
    /// Missing rows, so the count is a floor.
    @Published public internal(set) var lastScanCoverage: PartialComparison = .complete

    /// What the last completed Compare scan found, restored at launch. See ``LastScanSummary``.
    ///
    /// `@Published` and loaded through ``loadLastScanSummary()`` rather than lazily in a getter:
    /// the empty state renders from it, and a getter that decoded on first read would decode
    /// inside `body`.
    @Published public internal(set) var lastScanSummary: LastScanSummary?

    /// Restores the persisted summary. Called once by the app after injecting the defaults; a no-op
    /// without them. A value that no longer decodes is dropped: it is one line of reassurance on an
    /// empty state, not worth a migration.
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
    /// How many targets per lens to remember. One is not enough: two panes on two providers is
    /// ordinary use, and scanning one pane would silently withdraw consent for the other. Sized
    /// like ``StorageLensStore/maxRoots``, so consent doesn't accumulate forever and the oldest
    /// goes first.
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

    /// Whether `path` is a target the user has scanned to completion: the consent an auto-rescan
    /// needs. `array(forKey:)`, not `stringArray(forKey:)`, so a value of the wrong shape, such as
    /// a bare String, reads as nothing remembered instead of trapping; the next completed scan
    /// overwrites it with an array.
    func lensScanTargetIsRemembered(_ path: String, forKey key: String) -> Bool {
        guard let defaults = persistedUIStateDefaults else { return false }
        return (defaults.array(forKey: key) as? [String] ?? []).contains(path)
    }

    /// Whether `path` is a directory that exists right now. A remembered target can be deleted,
    /// renamed, or on a cloud folder not mounted this launch. Scanning it would publish zero rows,
    /// and "no duplicates found" reads as a result about the user's files. A manual scan may do
    /// that because the user asked; an automatic one must not.
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
    @Published public var duplicateGroups: [DuplicateGroup] = [] {
        didSet { duplicateGroupsGeneration &+= 1 }
    }

    /// Bumped on every write to ``duplicateGroups`` — a wholesale scan result, a merge's removal,
    /// an element rewrite. Read by ``visibleStructureFindings``' memo key, which must not hash the
    /// groups themselves on a render path. See ``VisibleFindingsKey``.
    private var duplicateGroupsGeneration: UInt64 = 0
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
    /// Numeric progress for the duplicate scan's hashing phase; nil during the walk (total unknown)
    /// and when no scan runs. Drives the lens's determinate bar.
    ///
    /// Not folded into ``duplicateScanLifecycle``: its projected publisher
    /// (`$duplicateScanProgress`) and per-write cadence are a tested contract, and a computed
    /// forwarder has no projected value. Its writes are epoch-gated with the lifecycle's status via
    /// `updateScan`.
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
    /// The kept-separate keys the last duplicate scan found a copy of missing from its tree —
    /// groups no scan can flag again, so not counted or promised back (see `keptSeparateKeys`).
    @Published var keptSeparateGoneKeys: Set<String> = []
    /// IDs of duplicate groups whose merge is in flight. A merge can run for minutes (re-hash the
    /// keeper, copy unique files, trash the folded copy); this blocks a second click, which would
    /// re-plan against the half-merged keeper and mint " 2" junk copies, and drives the card's
    /// progress state.
    @Published public internal(set) var mergingGroupIDs: Set<DuplicateGroup.ID> = []
    /// Store for "Keep separate" duplicate-group keys, injectable so tests don't touch `.standard`.
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
    /// Numeric progress for the build. The walk has no granular count, so it stays 0 and the UI
    /// shows a spinner; its own property, like `duplicateScanProgress`, for a future determinate
    /// pass.
    ///
    /// Not `@Published`: it is written only to 0 and read nowhere, and every `@Published` write on
    /// this manager re-evaluates the observing view. Add the wrapper back with a reader.
    public var storageLensProgress: Double = 0
    /// The in-flight Storage Lens build task, so the UI can cancel a long walk.
    var storageLensTask: Task<Void, Never>?

    // MARK: Name Normalizer — bulk-fix cloud-hostile names (see FileSyncManager+NameNormalize.swift)

    /// The Name Normalizer scan lifecycle (see ``ScanLifecycle``); the legacy names forward onto it.
    @Published public internal(set) var nameScanLifecycle = ScanLifecycle()
    /// The risky names (files and folders) found by the latest scan, each with its safe
    /// replacement. Empty until a scan runs; rows drop as they're fixed or skipped.
    ///
    /// `internal(set)` so that `reportable(_:)` filtering out kept names doesn't rest on every
    /// caller: a kept name here would offer a rename for something the user said they meant.
    /// `filingSuggestions` is guarded the same way.
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

    /// The folder rename plans from the latest Filing scan, one per folder that drifted from its
    /// own `NN. Mon YYYY` convention. Empty until a scan runs. `internal(set)`, like `riskyNames`:
    /// only the planner over a freshly walked tree may produce one, or a caller could show a rename
    /// no folder asked for.
    @Published public internal(set) var renamePlans: [RenamePlan] = []
    /// True while an "Rename all" pass is applying renames.
    @Published public var isApplyingRenames = false
    /// The in-flight Name Normalizer scan task, so the UI can cancel a long walk.
    var nameScanTask: Task<Void, Never>?

    // MARK: Filing — suggest where loose files go (see FileSyncManager+Filing.swift)

    /// The Filing scan lifecycle (see ``ScanLifecycle``); the legacy names forward onto it.
    @Published public internal(set) var filingScanLifecycle = ScanLifecycle()
    /// What the last folder-memory re-survey did, or nil if none ran this session. Published so the
    /// lens can say what happened; the usual "up to date" is invisible unless stated.
    @Published public internal(set) var filingSurveyReport: FilingSurveyReport?
    /// When a survey last looked at the tree, whatever it found: the corpus's `surveyedAt` stamp.
    /// The app seeds it from disk at attach; a finishing re-survey publishes it, so the footnote
    /// updates at once. Publicly settable, like `filingMemory`, so the app can hand over what it
    /// read.
    @Published public var filingSurveyedAt: Date?
    /// The folder-memory re-survey lifecycle, separate from the scan's. A re-survey makes no
    /// suggestions, and flipping `isSuggestingFiles` would swap the lens to its scanning view and
    /// blank the results being read.
    @Published public internal(set) var filingSurveyLifecycle = ScanLifecycle()
    /// Where the running document survey has got to, or nil when none is running. Its own value,
    /// not fields on ``ScanLifecycle``: of the six lifecycles sharing that struct only the survey
    /// pauses or has a denominator, and it needs a fraction, an ETA basis and a typed pause reason.
    /// The lifecycle still says running, completed and root.
    @Published public internal(set) var documentSurveyProgress: DocumentSurveyProgress?

    /// What the last document survey did, for the completion card. Survives the run so the summary
    /// can be read after the fact.
    @Published public internal(set) var documentSurveyReport: DocumentSurveyReport?

    /// The source whose own survey the running reading reads into (its entry's root), or nil while
    /// the primary survey's reads or nothing does. Organize's card shows only the primary's.
    @Published public internal(set) var documentSurveySourceRoot: String?

    /// Whether a document's content is on this disk — ``FilingSurvey/isAvailable(_:)``; a test
    /// stands in for it, since only a File Provider can make a file cloud-only.
    public var documentSurveyIsAvailable: @Sendable (String) -> Bool = { FilingSurvey.isAvailable($0) }

    /// How a source's reading downloads a cloud-only document before reading it. It stays
    /// downloaded after.
    public var sourceDocumentFetch: @Sendable (String) async -> Void = { await FileSyncManager.fetchCloudOnly($0) }

    /// The running survey, so Pause, Resume and Stop reach it. Not published: it is a handle, not a
    /// state — `documentSurveyProgress` is what a view watches.
    var documentSurveyRun: DocumentSurveyRun?

    /// Whoever is waiting for the running survey to end — see
    /// ``stopDocumentSurveyBeforeReplacingProfile(savingFolder:)``. Resumed with `true` as the run
    /// lets go of its handle, or with `false` by the wait's own bound.
    var documentSurveyEndWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// How long a profile write waits for a stopped survey to finish the document it is reading.
    public var documentSurveyStopWait: Duration = .seconds(60)

    /// The folder of a run the person had paused when a profile write of the same folder stopped
    /// it, so the run that carries it on starts paused too. Taken by the next run to start.
    var documentSurveyPauseToCarry: URL?

    /// The causes *Resume now* told the running survey to read through — see
    /// ``DocumentSurveyOverride``. Here rather than in the run because the conditions it is
    /// decided from are this actor's; cleared at the start of every run.
    var documentSurveyOverride = DocumentSurveyOverride()

    /// What the Mac is doing that a background survey should stand aside for: display asleep,
    /// thermal state, Low Power Mode.
    ///
    /// A closure the app supplies, as `filingSnippetExtractor` is: these come from AppKit and
    /// `ProcessInfo`, and a `Sync` that read them would answer differently under `swift test`. nil
    /// means nothing known, so the survey never pauses for the machine rather than guessing.
    public var machineConditions: (@MainActor @Sendable () -> MachineConditions)?

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
    /// What the latest pass did, file by file, for the answers card in the chat (TE335).
    @Published public internal(set) var filingLastRefineReport: FilingRefineReport?
    /// What Undo Refine puts back: the on-device suggestions of the files the latest pass moved.
    @Published public internal(set) var filingRefineUndo: FilingRefineUndo?
    /// What Try Another says on a card, by file path: why it stayed on this Mac, why Claude did not
    /// answer, that the limit is reached. Each card shows its own (TE335); cleared when the person
    /// asks again for that file, and when the list is replaced.
    @Published public internal(set) var filingTryAnotherNotes: [String: FilingTryAnotherNote] = [:]
    /// Told after each Refine Names request, for the chat's receipt.
    public var filingMappingRefineReports: (@MainActor (MappingRefineReport) -> Void)?
    /// Told after each Try Another that reached Claude, for the chat's running line.
    public var filingTryAnotherReports: (@MainActor (FilingTryAnotherReport) -> Void)?
    /// Whether a pass reports itself in the Organize banner. On where there is no chat to show the
    /// card; the app turns it off, since the card in the Ask Claude chat says it (TE335).
    public var filingRefineShowsBanner = true

    /// The running refine pass's token, or nil when none is running: the only stored fact for "a
    /// refine is running". It is both the re-entrancy guard and the ownership stamp. It is compared
    /// again after the await, as `filingTryAnotherInFlight`'s is, so a pass whose entry was cleared
    /// mid-round-trip (a provider switch) doesn't release or overwrite its successor's. Keep it the
    /// only copy, so the guard has one place to break.
    @Published public internal(set) var filingRefineInFlight: UUID?

    /// The Refine plan each source has open, waiting for Send: one per source, replaced by the next
    /// prepare and taken by a send. Cleared with the filing state.
    @Published public internal(set) var filingOpenRefinePlans: [String: FilingRefinePlan] = [:]

    /// Folders (relative to the source) the person left out of the folder list with Customize… on
    /// the plan card, and everything under them. Kept until the app quits, and read by Refine and Try
    /// Another alike (TE335, LY-A), so there is one rule and nothing to manage in Settings: neither
    /// sends a left-out name, not even as "avoid: …". Refine Names sends its mapping's own names and
    /// does not read it. Never saved.
    @Published public var filingRefineLeftOutFolders: Set<String> = []

    /// How Refine and Try Another reach Claude: a request that says how it ended, so a failure shows
    /// as one and nothing stands in for Claude's answer (TE335, E2). The app installs it; where it is
    /// nil (the CLI, tests) a pass that routes to Claude goes through ``filingClassifier`` as before.
    public var filingRefineClassifier: FilingRefineClassifier?

    /// The request a refine pass has out, so ``stopFilingRefine()`` can end it.
    var filingRefineRun: Task<FilingRefineResult, Never>?

    /// Stop was pressed during the pass that is running, possibly before its request began.
    var filingRefineStopRequested = false
    /// The latest sent pass whose answers came after the list moved on (see `DiscardedRefine`).
    var filingDiscardedRefine: DiscardedRefine?

    /// True while the opt-in refine pass is out at the backend. Not `isSuggestingFiles`, which
    /// swaps the Organize lens to its scanning view: a refine improves the list the user is looking
    /// at and must not take it off screen.
    public var isRefiningFilingSuggestions: Bool { filingRefineInFlight != nil }
    /// Counts wholesale replacements of `filingSuggestions`: the scan's single publish and
    /// `clearFiling()`. A "Try another" round-trip checks it across its await: is the list its
    /// verdict was computed against still on screen? Not the scan epoch: `endScan` runs in the
    /// scan's `defer`, so a cancelled rescan bumps the epoch twice without republishing, and would
    /// drop a verdict about cards that never moved.
    ///
    /// Per-item edits (`replaceFilingSuggestion`, the `removeAll` in
    /// `dismissFilingSuggestion`/`performFiling`) don't bump it: they can't invalidate another
    /// card's snapshot, and a re-ask for the same card is refused by `filingTryAnotherInFlight`'s
    /// token. Write it only through `publishFilingSuggestions(_:)`.
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
    /// On-device content extractor for Filing (path → entity and keyword tokens, from PDF text, OCR
    /// and NaturalLanguage), injected by the app. nil means filename-only. Gated by the
    /// read-contents setting; runs only on files with no confident home from their name.
    public var filingContentExtractor: (@Sendable (String) async -> Set<String>)?
    /// Defaults store for the Filing read-contents toggle, injectable so tests don't touch
    /// `.standard`.
    var filingContentDefaults: UserDefaults = .standard
    /// Defaults store for remembered filing rules, injectable so tests don't touch `.standard`.
    var filingRuleDefaults: UserDefaults = .standard
    /// Intelligent Filing backend — reasons about the folder taxonomy + file contents to pick a
    /// home (on-device Apple LLM, opt-in cloud), injected by the app. nil = keyword engine only.
    /// Its verdicts override the heuristic guess for files it's confident about.
    public var filingClassifier: FilingClassifier?
    /// The mapping refine, injected by the app beside the classifier. nil when the app hasn't wired
    /// it; whether a key is stored is `filingCloudRefineAvailable`'s question, as for the filing
    /// refine.
    public var mappingRefiner: MappingRefiner?
    /// Extracts a bounded text excerpt for the classifier (PDF text, OCR, plain), injected by the
    /// app. Gated by the same read-contents setting as `filingContentExtractor`.
    public var filingSnippetExtractor: (@Sendable (String) async -> String?)?
    /// The same excerpt without OCR, for Ask Claude's look-ahead over a folder's loose files
    /// (TE343): a picture is ranked by its name until a card reads it in full. Same gate.
    public var filingLightSnippetExtractor: (@Sendable (String) async -> String?)?
    /// Warms up the classifier backend (e.g. loads the on-device model), injected by the app. Called
    /// when a Filing scan starts so the ~cold-start latency overlaps the keyword + content phases.
    public var filingClassifierPrewarm: (@Sendable () -> Void)?

    /// Names the backend that will answer this pass's classifications: the `model` component of
    /// ``FilingVerdictKey``. Called once per pass, before any classifying.
    ///
    /// Takes the tier because the answer differs by tier: the free pass resolves to the on-device
    /// model whatever the cloud toggle says, and the refine pass resolves as the router does. One
    /// tier-blind answer would file free-pass verdicts under the refine pass's model. It doubles as
    /// ``FileSyncManager/freePassWouldReachAPaidBackend``'s check: the app answering "cloud" for
    /// `.free` means its router would bill a pass that promised not to, so classifying is skipped.
    ///
    /// Only the app can answer: its router also checks that a key can be read, and downgrades to
    /// on-device when it can't. Caching an on-device verdict under a cloud model's name would make
    /// that downgrade durable, serving on-device answers the user believes came from Claude (what
    /// `FilingBackendRouter.missingKeyDowngradeMessage` surfaces). It also keeps the Keychain query
    /// on the app's side, behind the cloud toggle.
    ///
    /// Returning nil disables the cache for this scan, read and write: the honest answer when the
    /// app can't vouch for the backend. Unset, it falls back to the configured identity, which is
    /// right for the CLI and tests.
    ///
    /// Known gap: a cloud call that fails at the network falls back to on-device inside the app's
    /// classifier, after this was asked, so that verdict is cached under the cloud identity. It
    /// corrects when the file changes or on "Rescan (ignore cache)"; fixing it would widen the
    /// public `FilingClassifier` seam, and the app already logs a warning.
    public var filingBackendIdentity: (@Sendable (FilingClassifierTier) -> String?)?

    /// Whether the cloud backend is set up: a display question, and far cheaper than
    /// ``filingBackendIdentity``'s. That one resolves the real route through
    /// `AnthropicKeychain.hasKey`, which reads the secret and can raise the Keychain password
    /// prompt: right for a pass about to use the key, wrong for a toolbar button SwiftUI
    /// re-evaluates on every render, including every keystroke in the Organize search field.
    ///
    /// The app answers with `AnthropicKeychain.isConfigured`, an attributes-only match that never
    /// decrypts or prompts. The trade: "stored" isn't "readable", so with a corrupt or refused key
    /// this says yes while the route says on-device. That costs no money (the spend gate reads the
    /// real route), and ``refineFilingSuggestions(_:)`` names the downgrade in its banner. Unset,
    /// it falls back to the real route, which is right for the CLI and tests.
    public var filingCloudRefineConfigured: (@Sendable () -> Bool)?

    /// Where the Filing verdict cache is persisted. nil disables the cache entirely: no read, no
    /// write.
    ///
    /// No ambient default: falling back to ``FilingVerdictStore/defaultURL(fileManager:)`` would
    /// have every test that builds a bare `FileSyncManager()` read and write the user's real cache
    /// file. The app sets it at startup; the CLI and tests get no cache.
    public var filingVerdictCacheURL: URL?

    /// The verdict cache, loaded from disk on first use and written back after a scan records into
    /// it. Held here rather than re-read per scan so a scan pays at most one read.
    var filingVerdictCache: FilingVerdictCache?
    /// The most recent Filing scan's provider root + relative folder list, kept so a "Try another"
    /// re-ask can classify a single file without re-walking the whole provider.
    public var filingLastProviderRoot: String?
    /// The name ruleset that scan checked against (its `nameProvider`), set and cleared with
    /// ``filingLastProviderRoot``, so a refine or "Try another" holds a model's new folder names to
    /// the same provider rules. nil means no provider rules, only `validateItemName`.
    public var filingLastNameProvider: CloudProvider.ProviderType?

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
    /// The tree's own filing artifacts, loaded once and reused by every pass. Injected by the app,
    /// like the verdict cache and the hash index: `Sync` never reaches into a real home directory.
    /// nil is the ordinary state for a tree that has not been surveyed.
    public var filingFolderProfile: FolderProfile? {
        didSet {
            // Bumped BEFORE the caches are dropped, so an in-flight warm-up started for the
            // previous profile can see that it has been superseded and decline to install.
            filingFolderProfileGeneration &+= 1
            invalidateFilingRouterIndex()
            rebuildPersonIdentityIndex()
            cachedStructureReport = nil
            warmStructureReport()
        }
    }

    /// Bumped on every write to ``filingFolderProfile``: the cache key both structure memos read,
    /// and the token the off-actor warm-up presents before it installs. A counter, because
    /// comparing a 5,000-entry `FolderProfile` per render would cost more than the cache saves.
    /// `&+=` because only consecutive values are compared, so wrap-around doesn't matter.
    private var filingFolderProfileGeneration: UInt64 = 0

    /// The warm-up computing ``structureReport`` off the main actor for the current profile, or nil.
    /// Cancelled and replaced when the profile changes again.
    private var structureWarmUpTask: Task<Void, Never>?

    /// Awaited by the warm-up after its cancellation check and before its hop to the main actor:
    /// the seam a test holds a superseded warm-up at, past the check that would otherwise stop it,
    /// so the generation token alone decides whether it installs. Read when the warm-up starts.
    /// nil in the app.
    var structureWarmUpGate: (@Sendable () async -> Void)?

    /// Computes the detector sweep off the main actor and caches it, so the first Organize render
    /// after a survey finds it there. The synchronous path in ``structureReport`` stays correct: a
    /// render that arrives first computes and caches the report itself, and this then installs an
    /// identical value. Nothing is published; a cache entry changes no answer.
    ///
    /// - No stale install: the generation is captured before the hop and re-checked on the main
    ///   actor. Cancellation is a fast path; the token is the guarantee.
    /// - No retain past the manager's life: `[weak self]` on both the detached body and the
    ///   main-actor hop.
    /// - No deadlock: the detached body touches nothing actor-isolated (`FolderProfile` and
    ///   `StructureReport` are `Sendable` values); the only hop back is the install.
    private func warmStructureReport() {
        structureWarmUpTask?.cancel()
        guard let profile = filingFolderProfile else {
            structureWarmUpTask = nil
            return
        }
        let generation = filingFolderProfileGeneration
        let gate = structureWarmUpGate
        structureWarmUpTask = Task.detached(priority: .utility) { [weak self] in
            let report = StructureDetectors.run(in: profile)
            guard !Task.isCancelled else { return }
            await gate?()
            await MainActor.run { [weak self] in
                guard let self, self.filingFolderProfileGeneration == generation else { return }
                self.cachedStructureReport = report
            }
        }
    }

    /// Where the tree disagrees with its own habits: the whole detector set's report, computed once
    /// per profile. Cached because the caller is a view body: the detectors walk every folder in
    /// the profile (about 5,000 on a real tree), and Organize's overview asks on every render.
    /// Warmed off the main actor too (``warmStructureReport()``): the sweep is cheap enough to pay
    /// on a render that arrives first, but not worth paying behind a tab switch.
    ///
    /// Keyed on nothing but the profile: `filingFolderProfile`'s `didSet` drops it, the only way
    /// the answer can change, since the detectors read nothing else. Scope isn't part of the key:
    /// the lens scopes the report at render time by path prefix, so one cache serves every scope.
    /// Not `@Published` either: it is a pure function of a stored property.
    public var structureReport: StructureReport {
        if let cachedStructureReport { return cachedStructureReport }
        guard let profile = filingFolderProfile else { return .empty }
        let report = StructureDetectors.run(in: profile)
        cachedStructureReport = report
        return report
    }

    /// The findings alone, every kind, in the report's grouped order.
    public var structureFindings: [StructureFinding] { structureReport.findings }

    private var cachedStructureReport: StructureReport?

    /// Whether the user has opened Restructure's answer this launch. Every other lens shows its
    /// setup card until its scan has run this launch (`hasSuggestedFiling`, `hasScannedDuplicates`,
    /// `hasScannedNames`, `hasBuiltStorage`). Restructure has no scan: its findings are a pure
    /// function of the folder profile, read at startup, so this flag declares that fact for it.
    ///
    /// Not persisted: the survey behind the answer can be weeks old, and opening each session on
    /// the card tells the user these are cached results and how to refresh them. A stored flag
    /// would skip the card forever.
    @Published public var hasReviewedStructure = false
    /// Where those artifacts live, for the one pass that writes one back
    /// (``resurveyFilingMemory(root:taxonomy:)``). Injected for the same reason: `Sync` doesn't
    /// decide that a real home directory exists. nil means no re-survey.
    public var filingProfilesDirectory: URL?
    /// The id those artifacts were read under: the folder name, not the `profileId` field in the
    /// file.
    ///
    /// The directory is the identity (``FilingProfileStore/active(in:)`` warns when the two
    /// disagree). A `folder-profile.json` with no `profileId` decodes to `"default"`, so a tree
    /// read from `work/` would have its re-survey written to `default/`, where nothing reads it,
    /// and the fingerprint rehashed against that empty folder would turn off the verdict cache. The
    /// app loads the roster, tag store and fingerprint under this id too. nil falls back to the
    /// field, which is what a test that never sets it expects.
    public var filingProfileDirectoryId: String?
    /// Where the two content indexes live: `~/Library/Application Support/SyncCloud`. Injected,
    /// never defaulted, for the reason ``FilingProfileStore/defaultDirectory(fileManager:)``
    /// states: `Sync` doesn't decide that a real home directory exists. nil makes "is this document
    /// already filed?" and the satellite relation no-ops, as in every test; a default would have
    /// the filing tests decode the developer's own index on every scan.
    public var contentIndexDirectory: URL?
    /// The identity index the filing scan last built, and the index files' dates and sizes it was
    /// built from — see ``alreadyFiledIndex(in:providerRoot:)``.
    var filingAlreadyFiledIndex: (key: [String], index: DocumentIdentityIndex)?
    /// Whether a document is on this disk to be read, asked before a re-survey opens one. Defaults
    /// to the real check, so production needs nothing installed; see
    /// ``FilingSurvey/isAvailable(_:)`` for why a cloud-only placeholder must not be mistaken for
    /// an empty file. Tests replace it to stage eviction.
    public var filingDocumentIsAvailable: @Sendable (String) -> Bool = { FilingSurvey.isAvailable($0) }
    /// Called at the start of each of Refresh's two off-main hops, on whatever thread runs it — the
    /// seam a test reads to prove the corpus decode and the memory build stay off the main thread.
    /// nil in the app.
    var filingResurveyOffMainWitness: (@Sendable () -> Void)?
    /// How many `finishInterruptedSurveyReplay` calls are carrying a cut-off survey in; Refresh
    /// refuses while any is.
    var surveyReplaysInFlight = 0
    /// Digest of the artifacts above, mixed into every ``FilingVerdictKey`` so a re-survey doesn't
    /// replay answers composed against the old tree. See
    /// ``FilingProfileStore/fingerprint(id:in:)``.
    ///
    /// nil means unavailable (an artifact exists but couldn't be read), and turns the verdict cache
    /// off, read and write, at both key-building sites: a verdict keyed by a digest missing the
    /// unreadable part could never be found again once the file is fixed. `""` is a tree with no
    /// artifacts, a stable digest.
    public var filingArtifactFingerprint: String? = ""
    /// Loose PDFs that were read and gave up nothing: scans with no text layer. Recorded, not acted
    /// on: OCR through Vision costs 0.5–2.1 s a file, nothing for one but ten minutes for a
    /// 500-file inbox, so it is offered (``readScan(for:)``) instead.
    public internal(set) var filingUnreadableScans: Set<String> = []
    /// Page 1 of each file the scan read, bounded to ``FilingRouter/contentSampleChars``. Kept so
    /// the rule offered after a filing move has the router's evidence: `Scan 2026-03-02.pdf` says
    /// nothing in its name, and re-reading the PDF at click time would make the offer expensive.
    /// Bounded because 400 characters is the sample the memory's weights were measured under, and
    /// full excerpts for 500 files is megabytes held for one click.
    public internal(set) var filingPageSamples: [String: String] = [:]
    /// Renders a PDF's first page and reads it with OCR — injected by the app, because Vision has no
    /// place in a framework-free module. nil ⇒ the offer is never made.
    public var filingOCRExtractor: (@Sendable (String) async -> String?)?
    /// Files whose OCR is currently running, so a second click cannot start a second render.
    public internal(set) var filingOCRInFlight: Set<String> = []
    /// Loose files the last scan found only in the cloud, so it placed them by name. Recorded,
    /// never fetched: downloading what it couldn't read would pull every installer and archive in a
    /// cloud Downloads onto the disk. The cards say "placed by name", and
    /// ``downloadAndReadFiling(_:)`` fetches them when asked.
    public internal(set) var filingNotDownloaded: Set<String> = []
    /// "N files in M subfolders. Scan them?", set by a scan of an inbox whose files sit below it.
    /// See ``FilingSubfolderOffer``.
    @Published public internal(set) var filingSubfolderOffer: FilingSubfolderOffer?
    /// Folders scanned with their subfolders this session; persisted alongside in
    /// ``filingRecursiveFoldersKey`` when a store is injected.
    var filingRecursiveFolders: Set<String> = []
    /// Folders whose subfolder offer was turned down this session.
    var filingDeclinedSubfolderFolders: Set<String> = []
    /// Whether the scan behind the current suggestions read its folder's subfolders too.
    @Published public internal(set) var filingScanReadSubfolders = false
    /// The survey root the last scan walked in place of File Into, when it walked a wider tree;
    /// nil when it walked File Into itself. Verdict-cache keys carry it, so an answer recorded
    /// against one root is never replayed against another.
    var filingRoutedRoot: String?
    /// File Into of the last scan, which rules are scoped to and resolved against even when the
    /// scan walked a wider tree (``filingRoutedRoot``).
    var filingLastFileInto: String?
    /// The last scan's account index and walked tree, for re-asks that place by account.
    var filingAccountIndex: AccountIndex?
    var filingAccountTaxonomy: [FileNode] = []
    /// Members of a group card that couldn't be filed; the lens shows them as cards of their own.
    @Published public internal(set) var filingGroupFailures: Set<String> = []
    /// Page 1 facts of filed statements read to learn accounts named without digits, by path, with
    /// the modification date they were read at. Session-long; nil facts mean nothing readable.
    var filingAccountPageCache: [String: (modified: Date?, facts: DocumentFacts?)] = [:]
    /// True while ``downloadAndReadFiling(_:)`` is fetching and reading.
    @Published public internal(set) var isDownloadingFilingFiles = false
    /// Asks a file's provider to fetch it. The real download in the app; a test substitutes.
    public var filingDownloader: @Sendable (String) throws -> Void = { try MaterializationStatus.download(atPath: $0) }
    /// The flags read that says whether a loose file is cloud-only. Real `lstat` in the app; a test
    /// substitutes, because only a File Provider can set `SF_DATALESS`.
    public var filingStatFlags: MaterializationStatus.StatFlags = MaterializationStatus.realStatFlags
    /// How long ``downloadAndReadFiling(_:)`` watches for downloads to land: checks, and the pause
    /// between them. Thirty seconds in the app; tests shorten it.
    var filingDownloadWait: (checks: Int, interval: Duration) = (30, .seconds(1))
    public var filingMemory: FilingMemory? {
        didSet { invalidateFilingRouterIndex(); rebuildPersonIdentityIndex() }
    }
    /// The household: who documents belong to. Loaded beside the artifacts above (from
    /// `people.json`, or seeded from the profile's person axis), and part of the router index
    /// because it decides the person-axis score and the cross-person veto. Kept in step with
    /// ``filingPeopleStore`` once the store exists: the store is the editable truth, this the
    /// compiled copy the engine reads.
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
    /// The editable roster, when the app has somewhere to keep one. Unlike the profile and memory,
    /// it is written (``PeopleStore``). The subscriptions below make an edit take effect without a
    /// relaunch: they recompile the registry, drop the router index built from the old one, and
    /// re-derive the artifact fingerprint so verdicts composed against the old roster aren't
    /// replayed.
    ///
    /// Two subscriptions, because they answer to different moments. The registry compiles from the
    /// roster in memory, so `$people` is its trigger. The fingerprint hashes the roster on disk,
    /// and `$people` publishes before `save()` writes, so reading it there would hash the previous
    /// roster and leave every edit one save stale. It follows `$savedRevision`, which bumps only
    /// after the write lands.
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

    /// The user's verdicts on whose document is whose (``PersonTagStore``). The second writable
    /// filing artifact, wired like the roster: a store with a subscription, so a verdict recorded
    /// in the person view re-renders without a relaunch.
    ///
    /// Not part of ``filingArtifactFingerprint``, unlike `people.json`. The fingerprint keeps
    /// cached classifier answers from being replayed against a changed question, and the roster
    /// changes the question (the person-axis score and the cross-person veto move the shortlist). A
    /// tag only says who one document belongs to, and only the person gather reads it.
    public var filingPersonTagStore: PersonTagStore? {
        didSet {
            personTagCancellable = filingPersonTagStore?.$tags
                .dropFirst()
                .sink { [weak self] _ in
                    // Announced on this object for the roster's reason: a view watching only the
                    // manager would see nothing.
                    self?.objectWillChange.send()
                    // A "not theirs" must take effect when pressed, not next launch. The identifier
                    // index is built from the surveyed tree plus these rejections, and every other
                    // input rebuilds it on its own `didSet`; without this the wrong attribution
                    // would keep being made while the correction sat on disk.
                    self?.rebuildPersonIdentityIndex()
                }
        }
    }
    private var personTagCancellable: AnyCancellable?

    /// Everything Restructure remembers: suppressions and Ask answers. Wired like the roster and
    /// the person tags: a store whose changes are re-announced on this object, so the lens and the
    /// rail badge re-render the moment a finding is suppressed. Not part of
    /// ``filingArtifactFingerprint``, for `filingPersonTagStore`'s reason: a suppression changes
    /// what the lens shows, never what a classifier was asked.
    public var restructureStore: RestructureStore? {
        didSet {
            restructureCancellable = restructureStore?.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    private var restructureCancellable: AnyCancellable?

    /// True while a Restructure landing (scaffold, plan apply or ledger undo) is anywhere between
    /// its guards passing and its last step finishing. `activeFileOperationsCount` covers only step
    /// 3's queued moves and drops to zero while steps 6–7 re-derive the profile through long
    /// awaits. A second landing entering then would record itself under a profile id the first is
    /// about to replace, wedging the undo chain behind two permanent refusals. Checked by
    /// `restructureLandingRefusal`.
    ///
    /// Published and public so a surface can show that a landing is running: "Update the survey"
    /// walks the tree for seconds, and with no busy state it reads as a dead button and gets
    /// clicked again.
    @Published public internal(set) var restructureLandingInProgress = false

    /// What ⌘Q's guard counts as in flight: the queued file operations, plus a Restructure landing
    /// as one more while it runs. `activeFileOperationsCount` alone is zero through a landing's
    /// re-derive, after `profiles.json` already names the new profile folder but before that folder
    /// has its corpus and memory; a quit there would relaunch onto a survey with nothing learned. A
    /// landing is one operation however many moves it queued, so this is the larger of the two,
    /// never their sum.
    public var operationsAQuitWouldInterrupt: Int {
        max(activeFileOperationsCount, restructureLandingInProgress ? 1 : 0)
    }

    /// Where a landing has got to while it runs; nil otherwise. One small struct, published from
    /// the main actor and coalesced: every published write on this manager re-evaluates the
    /// window's root view (both panes, the differences pane, the inspector), so publishing per file
    /// would be the storm ``ProgressPublishGate`` stops. `RestructureApply` updates it at its step
    /// boundaries, and inside step 3 through that gate.
    @Published public var restructureApplyProgress: RestructureApplyProgress?

    /// The duplicated-taxonomy findings: the one detector that reads the duplicate scan rather than
    /// the profile, so it lives beside the memoised report, not inside it. `duplicateGroups` has
    /// its own publish cycle, and a scan finishing must not invalidate the profile cache. Cheap on
    /// every access: one pass over the groups in memory.
    public var duplicatedTaxonomyFindings: [StructureFinding] {
        guard let profile = filingFolderProfile, duplicateScanCoversSurvey else { return [] }
        return StructureDuplicatedTaxonomy.findings(groups: duplicateGroups, in: profile)
    }

    /// Whether a finished duplicate scan that covers the surveyed tree is on hand: the
    /// duplicated-taxonomy findings' staleness rule, in one place. Not `!duplicateGroups.isEmpty`:
    /// a clean scan leaves zero groups, and a scan of an unrelated root leaves groups that say
    /// nothing about the survey's tree. No `isRunning` guard: the root is published with results,
    /// never at scan start, so a non-nil root always labels what is on screen, and guarding on the
    /// flag would blank the answer during every re-scan.
    public var duplicateScanCoversSurvey: Bool {
        guard let scanRoot = duplicateScanRoot,
              let profileRoot = filingFolderProfile?.root else { return false }
        let surveyed = (profileRoot as NSString).expandingTildeInPath
        return surveyed == scanRoot
            || surveyed.hasPrefix(scanRoot.hasSuffix("/") ? scanRoot : scanRoot + "/")
    }

    /// Everything the inputs to ``visibleStructureFindings`` can contribute to its answer, in one
    /// comparable value: the memo's key. Each field moves when the answer can:
    /// - `profile`: ``filingFolderProfileGeneration``, standing for the whole `filingFolderProfile`
    ///   (and so for `structureReport`, and the folder universe and file counts the
    ///   duplicated-taxonomy findings read).
    /// - `duplicateGroups`: a `didSet` counter on the array. A scan rewrites the groups wholesale,
    ///   and a merge, a fold or a keeper change edits elements; a `didSet` sees all of them, where
    ///   a count would miss element writes. Hashing the groups per render is what this avoids.
    /// - `coversSurvey`: ``duplicateScanCoversSurvey``, which can flip with no change to the groups
    ///   (a scan of another root).
    /// - `store` and `suppressed`: the store's identity and its suppression set, by value. The set
    ///   is single digits in practice, cheaper to compare than the render it guards, and can't go
    ///   stale the way a counter on a swapped-in store could. Both, because a different store with
    ///   an equal set is still a different store.
    private struct VisibleFindingsKey: Equatable {
        let profile: UInt64
        let duplicateGroups: UInt64
        let coversSurvey: Bool
        let store: ObjectIdentifier?
        let suppressed: Set<RestructureKey>
    }

    private var cachedVisibleStructureFindings: (key: VisibleFindingsKey, value: [StructureFinding])?

    /// ``structureFindings`` minus what the user said never to suggest again: what every surface
    /// renders and counts. One definition for the lens, the overview and the rail badge, so a
    /// suppression can't leave a badge counting a card that never renders.
    public var visibleStructureFindings: [StructureFinding] {
        let key = VisibleFindingsKey(
            profile: filingFolderProfileGeneration,
            duplicateGroups: duplicateGroupsGeneration,
            coversSurvey: duplicateScanCoversSurvey,
            store: restructureStore.map(ObjectIdentifier.init),
            suppressed: restructureStore?.suppressed ?? [])
        if let cached = cachedVisibleStructureFindings, cached.key == key { return cached.value }
        let value = computeVisibleStructureFindings(store: restructureStore)
        cachedVisibleStructureFindings = (key, value)
        return value
    }

    /// The uncached answer. Memoised at this layer as well as below it: the report is cached, but
    /// this re-derives the duplicated-taxonomy findings over every group, re-groups the whole list
    /// and re-filters suppressions, and Organize reads it several times per render.
    private func computeVisibleStructureFindings(store: RestructureStore?) -> [StructureFinding] {
        // Through `grouped`, not appended raw: one folder's rows sit together, and findings
        // appended after the report was grouped would strand a folder's second observation at the
        // bottom.
        let all = StructureDetectors.grouped(structureFindings + duplicatedTaxonomyFindings)
        guard let store else { return all }
        return all.filter { !store.isSuppressed(RestructureKey($0)) }
    }

    /// Records a cross-person refusal, resolving the ids to names a person would recognise. The
    /// engine reports registry ids; nobody wants to read `elder-2` in a sentence about their
    /// father, so the names are looked up here, where the event becomes something a person sees.
    func recordPersonVeto(_ refusal: PersonVetoRefusal) {
        guard let log = filingPersonVetoLog else { return }
        log.record(PersonVetoEvent(namedPerson: refusal.namedPerson,
                                   proposedPerson: refusal.proposedPerson,
                                   fileName: refusal.fileName,
                                   destination: refusal.destination,
                                   at: Date()))
    }

    /// Rebuilds the identifier index from the current artifacts and roster. Cheap (a pass over the
    /// memory's folders) and done eagerly: lazily, it would run inside attribution, which runs per
    /// file, per scan.
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

    /// The identifiers the user's rejections withdraw, or empty when there are none. A function so
    /// the corpus is read only when there is a rejection to translate: `filing-corpus.json` is
    /// megabytes, and this rebuild runs eagerly whenever the roster, the profile or a tag moves. A
    /// household that never pressed "not theirs" pays one array scan.
    private func rejectedIdentifiers() -> [String: Set<String>] {
        let rejections = (filingPersonTagStore?.tags ?? []).filter { $0.verdict == .rejected }
        guard !rejections.isEmpty,
              let directory = filingProfilesDirectory,
              // The folder, not the field, as ``filingProfileDirectoryId`` states. Keyed on the
              // field, a disagreement reads a corpus that isn't there, answers `[:]`, and every
              // "not theirs" silently stops withdrawing anything.
              let id = filingProfileDirectoryId ?? filingFolderProfile?.profileId,
              let memory = filingMemory
        else { return [:] }
        // Read once per change to the rejections, not once per verdict. This rebuild fires on every
        // write to the tag store, and the People queue is all yes/no presses, so without the cache
        // each press would decode the whole corpus on the main actor (about 100 ms on a real
        // profile).
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

    /// Re-derives ``filingArtifactFingerprint`` from the folder the roster was written to, after
    /// ``PeopleStore/savedRevision`` says the bytes landed. The roster is part of the question
    /// every file is asked (it decides the person veto and the person-axis score), so without this
    /// a person edit would replay verdicts composed against the old household.
    ///
    /// The id comes from the store, not `filingFolderProfile?.profileId`: that field is inside
    /// `folder-profile.json`, and `FilingProfileStore.active` lets the folder win when they
    /// disagree. Digesting the field's folder would answer `""`, which is not nil, so both cache
    /// gates (`FileSyncManager+Filing`, `FileSyncManager+FilingRefine`) would stay open and record
    /// the session's verdicts under `artifacts: ""`: billed, unreachable next launch, and servable
    /// against another artifact set.
    ///
    /// Both other ways out are nil, which turns the cache off for read and write:
    ///
    /// - No file behind the store (the in-memory `PeopleStore(people:)`, or none): nothing on disk
    ///   to digest, and the digest in hand describes artifacts this manager is no longer keyed to.
    /// - `""` from a persistent store: `save()` just wrote `people.json` into that folder, so the
    ///   pair no longer names where the artifacts live. nil records nothing rather than keying
    ///   verdicts to an empty set.
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
    /// The prepared router index, and the destination set it was built from. A build costs ~85 ms
    /// on a 3,000-folder tree, and the taxonomy rarely changes between scans. The key is the set
    /// itself, not a hash: `Set` equality exits early on a count mismatch, and an exact comparison
    /// can't collide into serving a stale index.
    var filingRouterIndex: FilingRouter.Index?
    var filingRouterIndexKey: Set<String>?
    /// Bumped by every filing that teaches the router, and recorded by the index built after it: a
    /// filing changes no folder, so the destination key alone would serve the index from before it.
    /// Separate from ``invalidateFilingRouterIndex()``, which drops the index, and with it Read
    /// scan's routing until the next scan.
    var filingFiledSinceSurveyGeneration = 0
    var filingRouterIndexFiledGeneration = 0
    /// Which survey the last To File scan placed its files with (``FilingSurveyInUse``). nil before
    /// the first scan. The header's survey menu reads it.
    @Published public internal(set) var filingSurveyInUse: FilingSurveyInUse?
    /// Sources' own surveys, read once per profile id: a profile is thousands of entries to decode.
    var sourceSurveyProfiles: [String: FolderProfile] = [:]
    /// Their learned memories, once their documents have been read — read once, like the profiles.
    var sourceSurveyMemories: [String: FilingMemory] = [:]
    /// Their artifact fingerprints, which key cached verdicts for a tree placed with one.
    var sourceSurveyFingerprints: [String: String] = [:]
    /// The tree whose folders are being learned right now, nil when none is.
    @Published public internal(set) var learningSourceSurveyRoot: String?
    /// What the last Learn Its Folders did, for the strip under To File's header: the folders it
    /// learned, or why it could not. Cleared by the strip's ✕ and by a scan of another tree.
    @Published public internal(set) var sourceSurveyNote: SourceSurveyNote?
    /// Where a replaced or forgotten source survey's folder goes: the Trash in the app, so a
    /// survey forgotten by mistake can be put back by hand. A test substitutes a plain removal.
    var sourceSurveyRetire: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    /// How many times the index was built. Only tests read it: a rebuild produces a value equal to
    /// the one it replaced, so reuse is otherwise invisible.
    var filingRouterIndexBuilds = 0

    /// Satellite folder → its homes, and the state that says whether to rebuild it. Derived from
    /// the persisted content indexes, ~10 MB of JSON: too much to decode per scan, and it doesn't
    /// change per scan. Keyed by the index files' modification dates, so a duplicates scan that
    /// writes new fingerprints is picked up by the next filing scan.
    var filingSatelliteHomes: [String: Set<String>] = [:]
    var filingSatelliteKey: [Date]?
    /// The provider root the map was built for. Its folders are relative to that tree, so filing
    /// help uses the map only when it answers for the same one.
    var filingSatelliteRoot: String?
    /// So a test can tell a reused map from a rebuilt one — same reason as `filingRouterIndexBuilds`.
    var filingSatelliteBuilds = 0

    /// Rebuilds ``filingSatelliteHomes`` when the indexes behind it have moved.
    func refreshSatelliteHomes(providerRoot: String?, fileManager fm: FileManager = .default) {
        guard let providerRoot, let profile = filingRoutingProfile,
              let directory = contentIndexDirectory
        else {
            filingSatelliteHomes = [:]
            filingSatelliteKey = nil
            filingSatelliteRoot = nil
            return
        }
        let hashURL = directory.appendingPathComponent("content-hash-index.json")
        let fpURL = directory.appendingPathComponent("content-fingerprint-index.json")
        let textlessURL = directory.appendingPathComponent("content-textless-index.json")
        let stamps = [hashURL, fpURL, textlessURL].map {
            (try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? nil
                ?? Date.distantPast
        }
        if filingSatelliteKey == stamps, filingSatelliteRoot == providerRoot { return }
        let index = DocumentIdentityIndex.build(
            hashes: ContentHashIndexStore.load(from: hashURL),
            fingerprints: ContentHashIndexStore.load(from: fpURL),
            textless: ContentHashIndexStore.load(from: textlessURL),
            providerRoot: providerRoot,
            existsOnDisk: { fm.fileExists(atPath: $0) })
        // Asked through the profile's own rule, not re-implemented — an inbox posing as the bigger
        // folder is what makes this relation read backwards. See `SatelliteFolders`.
        filingSatelliteHomes = SatelliteFolders.homesBySatellite(in: index) {
            profile.acceptsNewFiles($0)
        }
        filingSatelliteKey = stamps
        filingSatelliteRoot = providerRoot
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

    /// Derives content tokens from text already read, so a file's page is never extracted twice:
    /// the second half of `filingContentExtractor` on its own. The scan reads a page once and
    /// shares it between the keyword pass, the router and the classifier.
    public var filingTokensFromText: (@Sendable (String) -> Set<String>)?
    /// The full set of existing relative folders (uncapped), used only to mark a "Try another"
    /// verdict's segments new or existing, as the main scan does. Separate from the capped
    /// `filingLastTaxonomyFolders`, so a real folder beyond the classifier cap isn't labelled as
    /// one to create.
    public var filingLastExistingFolders: Set<String> = []
    /// Session-scoped "Try another" rejections keyed by file path. Persisted rejections are keyed
    /// by salient filename tokens, which token-less names ("IMG_0007", "Scan 12") don't have — this
    /// set is what stops those files from being re-offered the folder they just rejected.
    public var filingSessionRejections: [String: Set<String>] = [:]
    /// "Try another" re-asks in flight: suggestion id → the owning invocation's token. Each click
    /// fires an unstructured Task, so two rapid clicks would run two round-trips for one card and
    /// the last to return would win; `tryAnotherFolder` checks-and-inserts here at entry and
    /// ignores re-entrant calls. Published so the card can disable its button while its re-ask is
    /// out (`keys.contains`): a refused click that still looks clickable reads as a dead button.
    ///
    /// The value is per-invocation ownership. The key is the file's absolute path, stable across
    /// scans, and `clearFiling()` empties the dictionary as the only recovery from a round-trip
    /// that never returns (`FilingClassifier` has no timeout). Without the token, a stale
    /// round-trip's defer would release a re-armed key's guard and its late verdict would overwrite
    /// the recreated card, so both the release and the result write check the token first. Written
    /// only inside this module.
    @Published public internal(set) var filingTryAnotherInFlight: [String: UUID] = [:]

    /// Global sorting preference for the file trees.
    @Published public var sortOption: SortOption = .name {
        didSet {
            guard sortOption != oldValue else { return }
            // Invalidate prefetch cache for roots as they need re-sorting or re-scanning
            dropPrefetchedTrees()
            if sortOption == .tags {
                // Trees are built without Finder tags unless sorting by them (the per-file xattr
                // fetch dominates large scans; see TreeBuilder.includeTags), so there is nothing to
                // re-sort by. Reload from disk; the fresh walk includes tags because this option is
                // now current.
                noteScanConfigChanged()
                refreshSubject.send(.both)
            } else {
                // Re-sort off the main actor: re-sorting both large trees on it freezes the UI.
                Task { await self.resortTreesAndRefilter() }
            }
        }
    }
    
    /// Which file types the left pane shows, or `nil` for all. Per pane and per tab
    /// (`PaneTab.typeFilter`), never saved across launches: a filter left on from yesterday makes
    /// files look missing.
    ///
    /// Unlike `showHiddenFiles`, a change keeps the prefetched walks (they are unfiltered and don't
    /// depend on it) and prunes the selection afterwards, so a row the filter hides is never acted
    /// on unseen.
    @Published public var leftTypeFilter: PaneTypeFilter? = nil {
        didSet {
            guard leftTypeFilter != oldValue else { return }
            leftTypeFilterKeep = []
            Task { await self.applyFilters(); self.scheduleSelectionPrune() }
        }
    }
    /// Right-pane counterpart of `leftTypeFilter`.
    @Published public var rightTypeFilter: PaneTypeFilter? = nil {
        didSet {
            guard rightTypeFilter != oldValue else { return }
            rightTypeFilterKeep = []
            Task { await self.applyFilters(); self.scheduleSelectionPrune() }
        }
    }
    /// What each pane's type filter pass learned, or `nil` while that pane has no filter.
    @Published public internal(set) var leftTypeFilterFacts: PaneTypeFilterFacts?
    @Published public internal(set) var rightTypeFilterFacts: PaneTypeFilterFacts?
    /// Each pane's tree after Hidden and before its type filter: the whole folder, for the census,
    /// the Trash prompt's hidden count, Ask Claude, and telling a filtered-out row from a missing one.
    public internal(set) var leftTreeBeforeTypeFilter: [FileNode] = []
    public internal(set) var rightTreeBeforeTypeFilter: [FileNode] = []
    /// Paths this app just wrote into a pane (a new folder, a rename, a copy or move, an editor
    /// save), kept visible through the type filter until the pane moves or the filter changes.
    /// Without it New Folder would make a folder that vanishes at once: it holds no matches.
    internal var leftTypeFilterKeep: Set<String> = []
    internal var rightTypeFilterKeep: Set<String> = []
    /// Folders open in each pane (the Columns stack, or the outline's expanded folders), as the
    /// host last reported them (`setTypeFilterOpenFolders`). A type filter keeps them while they
    /// are open, matches or not, so opening a folder or changing the filter under an open column
    /// stack doesn't make it vanish from its parent and close the stack. Unlike the keep-set above,
    /// a filter change keeps them; closing the folder lets it go.
    internal var leftTypeFilterOpen: Set<String> = []
    internal var rightTypeFilterOpen: Set<String> = []

    /// Records the folders open in a pane, for the type filter's pass. Paths as the pane spells
    /// them; a column's composed path is matched to the walk's node id, which differs below a
    /// folder link (`TreeShape.position`). Re-runs the pass only when the pane is filtered and the
    /// set changed.
    public func setTypeFilterOpenFolders(_ folders: Set<String>, isLeft: Bool) {
        guard folders != (isLeft ? leftTypeFilterOpen : rightTypeFilterOpen) else { return }
        if isLeft { leftTypeFilterOpen = folders } else { rightTypeFilterOpen = folders }
        guard (isLeft ? leftTypeFilter : rightTypeFilter) != nil else { return }
        Task { await self.applyFilters() }
    }

    /// `leftTypeFilterOpen` or its right counterpart, plus each folder's node id where the walk
    /// spells it otherwise.
    func typeFilterOpenIDs(isLeft: Bool) -> Set<String> {
        let open = isLeft ? leftTypeFilterOpen : rightTypeFilterOpen
        guard !open.isEmpty, (isLeft ? leftTypeFilter : rightTypeFilter) != nil else { return [] }
        let tree = isLeft ? rawLeftTree : rawRightTree
        let root = paneTreeFolder(isLeft: isLeft) ?? ""
        var ids = open
        for path in open {
            if let position = TreeShape.position(of: path, under: root, in: tree, links: linkedFolders),
               let node = TreeShape.node(at: position, in: tree) {
                ids.insert(node.id)
            }
        }
        return ids
    }

    /// Records that the app itself just wrote `path`, so a type filter doesn't hide it. Both panes:
    /// either may show the folder it landed in, and a path the other pane doesn't list matches
    /// nothing there. A no-op while neither pane is filtered.
    public func noteOwnWrite(atPath path: String) {
        if leftTypeFilter != nil { leftTypeFilterKeep.insert(path) }
        if rightTypeFilter != nil { rightTypeFilterKeep.insert(path) }
    }

    /// Something asked the pane to show `path` (Reveal in Browse, a PDF banner, Ask Claude) and
    /// only the type filter hides it: clears that pane's filter so the request can land, and says
    /// so. The file was asked for by name, so it outranks an earlier filter. Returns whether it
    /// cleared anything; a path the pane shows, or doesn't hold at all, is left to the caller's own
    /// wait.
    @discardableResult
    public func clearTypeFilterHiding(_ path: String, isLeft: Bool) -> Bool {
        guard (isLeft ? leftTypeFilter : rightTypeFilter) != nil else { return false }
        let shown = isLeft ? leftTree : rightTree
        let before = isLeft ? leftTreeBeforeTypeFilter : rightTreeBeforeTypeFilter
        guard shown.findNodes(at: [path]).isEmpty, !before.findNodes(at: [path]).isEmpty else { return false }
        if isLeft { leftTypeFilter = nil } else { rightTypeFilter = nil }
        let name = (path as NSString).lastPathComponent
        banner = .success("Filter cleared to show “\(name)”")
        Logger.shared.info("[type-filter] Cleared the \(isLeft ? "left" : "right") pane's filter to show \(path)")
        return true
    }

    /// How many items inside these folders a type filter is hiding. A selected folder still carries
    /// everything in it to the Trash, a copy or a move, and the confirmation and the result say
    /// this number. `nodes` come from a pane's published tree, so their children are the filtered
    /// ones; the tree before the filter holds the rest.
    public func itemsHiddenByTypeFilter(inside nodes: [FileNode]) -> Int {
        typeFilterHiddenCounts(inside: nodes).values.reduce(0, +)
    }

    /// The tree a search in one pane checks "is it on the other side too?" against: the other
    /// pane's tree before its type filter. A filter changes what that pane shows, not what is on
    /// disk, so a file it hides is still on both sides. Nodes, not a `PaneTree`: projecting rows
    /// walks the whole tree, and the caller does that off the main actor.
    public func searchSideAnnotationNodes(forPaneIsLeft isLeft: Bool) -> [FileNode] {
        isLeft ? rightTreeBeforeTypeFilter : leftTreeBeforeTypeFilter
    }

    /// `itemsHiddenByTypeFilter` per folder id, for a result that names only what landed. A folder
    /// picked with something inside it counts once, as the outermost, as the Trash and a transfer
    /// take it (`pruneNestedNodes`). A folder node with no children wasn't read off a pane's tree,
    /// so there is nothing to measure it against.
    public func typeFilterHiddenCounts(inside nodes: [FileNode]) -> [String: Int] {
        var counts: [String: Int] = [:]
        let sides = [(leftTypeFilter, leftTreeBeforeTypeFilter), (rightTypeFilter, rightTreeBeforeTypeFilter)]
        for node in nodes.pruneNestedNodes() where node.isDirectory {
            guard let shown = node.children else { continue }
            for (filter, before) in sides where filter != nil {
                guard let whole = before.findNodes(at: [node.id]).first else { continue }
                let hidden = Self.countItems(in: whole.children ?? []) - Self.countItems(in: shown)
                if hidden > 0 { counts[node.id] = hidden }
                break
            }
        }
        return counts
    }

    /// Global toggle to show/hide hidden files (e.g. .DS_Store, .git)
    @Published public var showHiddenFiles: Bool = false {
        didSet {
            guard showHiddenFiles != oldValue else { return }
            dropPrefetchedTrees()
            Task { await self.applyFilters() }
            // Hidden items the watcher saw change since the walk are news now, or no longer.
            publishDiskChanges()
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

    /// Durable store of names the user deliberately meant (``KeptNamesStore``). Assigned by the app
    /// at launch; nil (tests, CLI) keeps nothing, so every risky name is reported.
    ///
    /// Keeping a name drops it from `riskyNames` at once, so Organize's list and its "Fix all"
    /// never rename what the user just said they meant. Withdrawing a keep doesn't re-add the row,
    /// since `riskyNames` is a scan's result; the live row badge does come back at once.
    public var keptNamesStore: KeptNamesStore? {
        didSet {
            keptNamesCancellable = keptNamesStore?.$names
                .dropFirst()
                .sink { [weak self] kept in
                    guard let self else { return }
                    // Announce the change on this object explicitly. The store is a separate
                    // `ObservableObject` behind a plain `var`, so views that render the kept set
                    // but watch only the manager (`DifferencesView`, whose name cells silence a
                    // badge on a kept name) would not re-render, and the badge would linger.
                    self.objectWillChange.send()
                    // Assign only when a row really goes: `removeAll(where:)` is a mutating access,
                    // so calling it unconditionally republishes `riskyNames`, re-rendering
                    // Organize's whole list on every keep, usually for nothing. The announcement
                    // above stays separate, so
                    // `keepingANameAnnouncesOnTheManagerEvenWithNothingToRemove` tests it on its
                    // own.
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

    /// When true (the default), ignoring an item also records it in `ignoredItemsStore`, and stored
    /// ignores apply to every scan. Off makes ignores session-only; the stored set is kept, just
    /// not applied. Set by the app from persisted settings.
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
    /// focus-relative paths to root-relative ones.
    ///
    /// Only while both panes share one focus: with divergent foci a focus-relative path names
    /// different items on the two sides, and the stored entry would later hide an unrelated pair
    /// (right pane in Docs, left at root: ignoring that row must not durably hide the root-level
    /// pair of the same name). Divergent-foci ignores stay session-only.
    private func persistIgnoredPathsDelta(from oldValue: Set<String>, to newValue: Set<String>) {
        guard !suppressIgnorePersistence, rememberIgnoredItems, let store = ignoredItemsStore,
              panesShareAPosition else { return }
        // The anchor pane's focus, not the left pane's (`ignoreAnchorIsLeft`). They differ only for
        // a pair whose sources land at different depths, exactly the pair a swap would re-read in
        // the wrong coordinates.
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

    /// Toggles the ignore state of focus-relative paths against the effective set, what the user
    /// sees, so a durably ignored node (in the store, not the session set) un-ignores instead of
    /// being ignored twice. When every target is already ignored it un-ignores them all, otherwise
    /// it ignores them all.
    ///
    /// Un-ignoring removes each target's exact entry and any covering ancestor entry ("docs"
    /// ignored, target "docs/report.txt") from both layers: the menu says "Include", so the item
    /// must become visible, not stay struck through with the toggle doing nothing.
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

    /// Root-relative identity of a focus-relative path (`focus` empty = pane root). Callers pass
    /// the anchor pane's focus (`ignoreAnchorFocus`); when both panes navigate together, the
    /// identity reads the same from either side.
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

    /// Monotonic token for `applyFilters()` passes: each claims the next value on entry. A pass
    /// publishes only while no newer pass has published (`lastPublishedFilterGeneration`), so
    /// overlapping off-main passes never publish out of order, yet an awaited pass still publishes
    /// when it's the freshest done. Readable in the module so a test can tell a pass that hasn't
    /// started from one suspended in its detached compute: this moves in `applyFilters()`'s
    /// synchronous prologue, `lastPublishedFilterGeneration` only at commit.
    internal private(set) var filterGeneration = 0
    /// Generation of the most recent `applyFilters()` pass that published its results.
    ///
    /// Readable outside this file as a test seam: it moves the moment a pass commits, the only
    /// trace a pass that publishes nothing leaves. Every published assignment after it is "assign
    /// only what changed", so a pass over cleared state (`invalidateDifferencesForPaneRetarget`'s
    /// insurance pass) touches none of them. A test must wait on this, not a guessed delay
    /// (docs/flaky-tests.md, "Fixed pumps and fixed sleeps").
    private(set) var lastPublishedFilterGeneration = 0
    /// Bumped by `didSet` on every write to its pane's published tree, so no writer can forget it,
    /// including `swap(&leftTree, &rightTree)` and tests assigning directly. A filter pass compares
    /// its new trees against the published ones off the main actor (the deep equality walk is
    /// O(nodes) and hitches the UI on large panes); the verdict holds only while nothing wrote that
    /// pane mid-flight, which this detects. Per pane, because passes overlap during a dual-pane
    /// load, and a shared version would send every other pass to the main-actor fallback compare.
    internal private(set) var publishedLeftTreeVersion = 0
    /// Right-pane counterpart of `publishedLeftTreeVersion`.
    internal private(set) var publishedRightTreeVersion = 0

    /// Bumped on every raw-tree publish (see `adoptRawTree`). Guards the off-main resort in
    /// `resortTreesAndRefilter()` against clobbering trees a load published mid-sort.
    internal var rawTreeGeneration = 0

    /// A deferred column listing, keyed by the pane that asked as well as the folder. Keyed by path
    /// alone, two panes on the same source (comparing a folder with itself) would have the left
    /// pane's request suppress the right's as a duplicate, and the right column would never fill:
    /// its `onAppear` has fired and nothing re-asks.
    internal struct ColumnGraftKey: Hashable {
        let isLeft: Bool
        let path: String
    }

    /// The listings running right now (`loadColumnChildren`). Deduping on it stops a column
    /// re-rendering mid-walk from queueing a second listing of the same folder; publishing it lets
    /// the column say "being read" rather than "can't be read".
    ///
    /// Cleared by `swapPanes`, because every key names a side: after a swap the set would mark the
    /// wrong pane as loading. `paneOrientationGeneration` keeps the listings themselves from
    /// landing on the wrong side.
    @Published internal var columnGraftsInFlight: Set<ColumnGraftKey> = []

    /// Listings that came back unreadable, so they aren't asked for again on every appear. A tree
    /// row's "Can’t be read" placeholder asks on `.onAppear`, and scrolling would restart the same
    /// doomed listing each time, flickering a spinner. Remembered until this side's tree is walked
    /// afresh (`adoptRawTree`): ⌘R, or navigating back in.
    ///
    /// It holds back only that passive ask. An explicit open always retries, since "unreadable" can
    /// be a slow dataless folder the deadline deferred (`loadColumnChildren`'s `passive`). Cleared
    /// by `swapPanes`, as the in-flight set is.
    internal var columnGraftsUnreadable: Set<ColumnGraftKey> = []

    /// Bumped when the panes change sides, and nothing else. A column listing lands on the main
    /// actor holding an `isLeft` captured before its await; a swap in between makes that name the
    /// other pane, and grafting there would write one pane's listing into the other's tree.
    ///
    /// Its own counter, not `rawTreeGeneration`, which bumps on every raw-tree publish including
    /// each graft: guarding on that would make two columns filling at once cancel each other.
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
        let index = PaneChildrenIndex(tree: leftPaneTree, treeRoot: treeRoot, links: linkedFolders)
        leftChildrenCache = (publishedLeftTreeVersion, treeRoot, index)
        return index
    }

    /// Right-pane counterpart of `leftChildrenIndex(treeRoot:)`.
    public func rightChildrenIndex(treeRoot: String) -> PaneChildrenIndex {
        if let cached = rightChildrenCache, cached.version == publishedRightTreeVersion, cached.root == treeRoot {
            return cached.index
        }
        let index = PaneChildrenIndex(tree: rightPaneTree, treeRoot: treeRoot, links: linkedFolders)
        rightChildrenCache = (publishedRightTreeVersion, treeRoot, index)
        return index
    }

    /// Path → children a drill or crumb mirrored onto this pane is pruned against: the tree before
    /// its type filter. A folder that pane's filter hides is still there, so the linked drill walks
    /// into it (and once open the filter keeps it) instead of stopping at the parent as if it were
    /// missing. With no filter on it is the cached index; with one it is built here, a walk of that
    /// pane's tree that only a mirrored click asks for.
    public func mirrorChildrenIndex(isLeft: Bool, treeRoot: String) -> PaneChildrenIndex {
        guard (isLeft ? leftTypeFilter : rightTypeFilter) != nil else {
            return isLeft ? leftChildrenIndex(treeRoot: treeRoot) : rightChildrenIndex(treeRoot: treeRoot)
        }
        let whole = isLeft
            ? PaneTree(side: .left, version: publishedLeftTreeVersion, nodes: leftTreeBeforeTypeFilter)
            : PaneTree(side: .right, version: publishedRightTreeVersion, nodes: rightTreeBeforeTypeFilter)
        return PaneChildrenIndex(tree: whole, treeRoot: treeRoot, links: linkedFolders)
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

    /// True when the left pane's folder has entries but the Hidden filter removed all of them, so
    /// the empty-pane placeholder can point at the Hidden toggle. Not `@Published`: read during
    /// renders `leftTree` already triggers. Read off the tree before the type filter: a folder the
    /// type filter emptied doesn't hold only hidden items, and saying so would send the user to the
    /// wrong button.
    public var leftTreeHasOnlyHiddenEntries: Bool { leftTreeBeforeTypeFilter.isEmpty && !rawLeftTree.isEmpty }
    /// Right-pane counterpart of `leftTreeHasOnlyHiddenEntries`.
    public var rightTreeHasOnlyHiddenEntries: Bool { rightTreeBeforeTypeFilter.isEmpty && !rawRightTree.isEmpty }
    /// True when the left pane's folder has visible entries but its type filter shows none of them.
    public var leftTreeIsEmptiedByTypeFilter: Bool {
        leftTypeFilter != nil && leftTree.isEmpty && !leftTreeBeforeTypeFilter.isEmpty
    }
    /// Right-pane counterpart of `leftTreeIsEmptiedByTypeFilter`.
    public var rightTreeIsEmptiedByTypeFilter: Bool {
        rightTypeFilter != nil && rightTree.isEmpty && !rightTreeBeforeTypeFilter.isEmpty
    }
    /// True while the left pane tree is being loaded from disk.
    @Published public var isLoadingLeftTree = false
    /// True while the right pane tree is being loaded from disk.
    @Published public var isLoadingRightTree = false

    /// Total number of files and folders in the left pane tree (recursive).
    @Published public var leftItemCount = 0
    /// Total number of files and folders in the right pane tree (recursive).
    @Published public var rightItemCount = 0

    /// When the walk behind each pane's published tree read the disk, or nil if the pane never
    /// loaded one. What Browse's status bar puts through `ScanFreshness`.
    ///
    /// Not `lastScanDate`, the comparison scan's clock: a Browse pane runs no comparison, and this
    /// is the walk that produced the rows on screen. Written by `adoptRawTree`, so every publish
    /// path (cold walk, shallow first paint, cache hit) stamps once, and a cache hit stamps the
    /// walk's time, not its own (`prefetchedTreeReadAt`).
    @Published public internal(set) var leftTreeReadAt: Date?
    /// Right-pane counterpart of `leftTreeReadAt`.
    @Published public internal(set) var rightTreeReadAt: Date?

    /// Whether the folder watcher has seen the left pane's folder change since the walk behind its
    /// listing started: "changed since you looked". Always false while nothing watches
    /// (``enableFolderWatching(history:latency:quiet:maxDelay:)``). It only ever adds a warning:
    /// false means no event arrived, not that the folder is current.
    @Published public internal(set) var leftChangedOnDisk = false
    /// Right-pane counterpart of `leftChangedOnDisk`.
    @Published public internal(set) var rightChangedOnDisk = false
    /// The ids behind `leftChangedOnDisk` — see ``PaneWatchState``.
    var leftWatch = PaneWatchState()
    /// Right-pane counterpart of `leftWatch`.
    var rightWatch = PaneWatchState()
    /// The watcher behind the two flags above; nil until the app enables it, and always nil in
    /// tests and the CLI.
    var folderWatcher: FolderWatcher?
    /// Told, on the main actor, which panes a batch of changes left showing a stale listing — the
    /// app's hook for its opt-in rescan. Never told about this process's own writes.
    public var onPanesChangedOnDisk: (@MainActor (PaneReloadScope) -> Void)?
    /// Panes whose news `tellPanesChanged` is holding back.
    var owedPaneChanges: (left: Bool, right: Bool) = (false, false)
    /// When `onPanesChangedOnDisk` was last told — the start of `paneNewsInterval`.
    var lastPaneNewsAt: Date?
    /// The fewest seconds between two tellings of `onPanesChangedOnDisk`: at most one opt-in
    /// rescan per interval, however busy the folder. A test sets it shorter.
    var paneNewsInterval: TimeInterval = 30
    /// The one pending wake that asks again for held news (`tellOwedPaneChanges`).
    var owedPaneNewsWake: Task<Void, Never>?
    /// Called as each pane load starts (`noteFolderWatchLoad`) — the seam a test uses to land a
    /// change inside a refresh without racing it. nil in the app.
    var folderWatchLoadWitness: (@MainActor (_ isLeft: Bool) -> Void)?

    // MARK: - Selection resolution index

    /// Path → node maps that resolve a selection in O(selection) instead of walking the ~40k-node
    /// tree on every render, which made the pane action bar appear late. Built lazily on first
    /// lookup after a tree change and cached against the published tree version, so a scan or
    /// navigation invalidates it at no eager cost.
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
        let index = leftNodeIndex()
        return paths.compactMap { index[$0] }
    }

    /// Right-pane counterpart of `leftNodes(for:)`.
    public func rightNodes(for paths: Set<String>) -> [FileNode] {
        guard !paths.isEmpty else { return [] }
        let index = rightNodeIndex()
        return paths.compactMap { index[$0] }
    }

    private func leftNodeIndex() -> [String: FileNode] {
        if leftNodeIndexCache?.version != publishedLeftTreeVersion {
            leftNodeIndexCache = (publishedLeftTreeVersion, Self.buildNodeIndex(leftTree))
        }
        return leftNodeIndexCache!.index
    }

    private func rightNodeIndex() -> [String: FileNode] {
        if rightNodeIndexCache?.version != publishedRightTreeVersion {
            rightNodeIndexCache = (publishedRightTreeVersion, Self.buildNodeIndex(rightTree))
        }
        return rightNodeIndexCache!.index
    }

    /// Deep trees by focused-folder path (pane roots and any folder visited since the last
    /// invalidation), walked ahead so switching providers doesn't block. Never holds shallow trees:
    /// the navigation fast path and the in-memory diff scan rely on cached trees being fully
    /// walked. The exception is a cycle- or depth-capped folder inside a deep tree: it carries
    /// `isUnexplored: true`, and `subtree(atPath:under:in:)` treats it as a miss so a drill-down
    /// re-walks from there instead of serving its empty children.
    ///
    /// Cleared by file operations, sort changes and force refresh, and, for only the walks listing
    /// one folder, by a file Edit writes itself (`prepareReread(afterWritingAt:)`). Not
    /// `@Published`: no view renders from it, and publishing it would re-render the whole window on
    /// every file operation.
    public var prefetchedTrees: [String: [FileNode]] = [:]
    /// The cache entries whose deep walk `paneNodeBudget` stopped: provenance the trees can't
    /// carry, since a budget-stopped folder and a permission-denied one wear the same
    /// `isUnexplored` mark. The warm scan branch reads it to banner a comparison over a truncated
    /// tree (`PartialComparison.of`'s walk-stopped overload). Written only beside a cache write and
    /// never read without its `prefetchedTrees` entry, so a cleared cache can't leak a stale bit.
    public var prefetchedTreeWalkStopped: Set<String> = []

    /// When the walk that produced each cache entry read the disk. A cache hit republishes a tree
    /// walked minutes ago, so stamping the moment it is served would have the status bar say
    /// `Scanned just now` over a listing nobody re-read. The stamp travels with the entry, like
    /// `prefetchedTreeWalkStopped`, and a slice inherits its root's: it is part of that walk.
    public var prefetchedTreeReadAt: [String: Date] = [:]

    /// The FSEvents id read when the walk behind each cache entry started
    /// (``FolderWatcher/currentEventId()``) — the stamp `prefetchedTreeReadAt` is, in the one unit
    /// that orders a walk against a change the folder watcher reports. Travels with the entry
    /// exactly as the read time does, and a slice inherits its root's.
    public var prefetchedTreeReadMark: [String: UInt64] = [:]

    /// Where the walk behind each cache entry read through a folder link: the resolved targets of
    /// the folder symlinks it listed outside its root (`FollowedLinks`). Absent for walks that
    /// followed none, nearly all of them.
    ///
    /// Below such a link the walk's ids name the target, so a write spelled as a pane row names it
    /// is under no prefix of the entry's key; `dropPrefetchedTrees(holding:)` reads this to see it.
    /// Written beside every cache write and cleared by every drop, like
    /// `prefetchedTreeWalkStopped`; a slice inherits its root's.
    public var prefetchedTreeLinkTargets: [String: Set<String>] = [:]
    /// The same record for the walk behind each pane's published tree, which the app asks when
    /// deciding which pane holds a file it just wrote (`ContentView.panesHolding`).
    ///
    /// The pane's, not the cache's, because the app asks after the write, when
    /// `prepareReread(afterWritingAt:)` has dropped the entry. Set by every publish
    /// (`adoptRawTree`), widened by a column's graft, moved by a swap and cleared with the pane's
    /// tree (`invalidatePaneTree`). While a moved pane's deep walk is out it describes the shallow
    /// first paint, which lists no link below the root. Not `@Published`: no view draws it.
    public internal(set) var leftTreeLinkTargets: Set<String> = []
    /// Right-pane counterpart of `leftTreeLinkTargets`.
    public internal(set) var rightTreeLinkTargets: Set<String> = []

    /// The link table pane loads and the comparison after them compose paths through: this Mac's
    /// own (`PathBoundary.discoveredLinkedFolders`) except in tests. One value for every step
    /// because they must agree: a pane caches a linked folder under the path this table composes,
    /// and the scan finds that entry only if it composes the same way. Tests inject their own, so
    /// nothing depends on the machine's iCloud links.
    var linkedFolders: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders

    /// Where the pane loads, their columns' grafts and the comparison after them read a folder whose
    /// contents are not on this Mac (`DatalessFolderReads`) — the app's shared one everywhere but a
    /// test, which injects one with a deadline it can wait out.
    var datalessFolderReads: DatalessFolderReads = .shared

    /// Drops every cached pane tree and its provenance, in one verb so the stores can't part
    /// company. Every invalidation of `prefetchedTrees` goes through here or its one-folder forms,
    /// ``dropPrefetchedTrees(holding:)`` and ``dropPrefetchedTrees(keeping:)``; clearing the trees
    /// alone would leave provenance bits to be re-read when the same path is next cached by a
    /// slice.
    public func dropPrefetchedTrees() {
        prefetchedTrees.removeAll()
        prefetchedTreeWalkStopped.removeAll()
        prefetchedTreeReadAt.removeAll()
        prefetchedTreeLinkTargets.removeAll()
        prefetchedTreeReadMark.removeAll()
    }

    /// Drops every cached walk but the one at `kept`, which keeps its provenance; with no walk at
    /// `kept`, drops everything, as ``dropPrefetchedTrees()`` does.
    ///
    /// For anything that re-roots one pane (a source switch, a Location edit) while the other still
    /// shows a walk this cache holds. That entry is the array on screen, so dropping it frees
    /// nothing, and the Compare after the switch reads cached trees only when both sides hit:
    /// without it, it walks both folders from disk and, at the node budget, can stop somewhere
    /// other than the pane's walk did and answer differently. Everything else goes, for memory.
    ///
    /// Never keeps a walk that couldn't list its folder (`isUnreadableRootWalk`): it knows nothing.
    /// Kept, the next Compare would compare against an empty side, and a pane switched back onto
    /// that folder would be served it empty until Refresh, even once access returned.
    ///
    /// Logged at DEBUG beside the `[load]` lines either way: a miss here is otherwise visible only
    /// as a slow scan.
    public func dropPrefetchedTrees(keeping kept: String?) {
        let before = prefetchedTrees.count
        guard let kept, let tree = prefetchedTrees[kept], !Self.isUnreadableRootWalk(tree, at: kept) else {
            let why = kept.map { folder in
                prefetchedTrees[folder] == nil ? "no walk is cached at “\(folder)”"
                    : "its walk could not list “\(folder)”, so the next one reads it"
            } ?? "it holds no walk"
            dropPrefetchedTrees()
            Logger.shared.debug("[cache] nothing to keep for the pane that stayed — \(why); "
                                + "dropped all \(before) cached walk(s)")
            return
        }
        let walkStopped = prefetchedTreeWalkStopped.contains(kept)
        let readAt = prefetchedTreeReadAt[kept]
        let linkTargets = prefetchedTreeLinkTargets[kept]
        let readMark = prefetchedTreeReadMark[kept]
        dropPrefetchedTrees()
        prefetchedTrees[kept] = tree
        if walkStopped { prefetchedTreeWalkStopped.insert(kept) }
        prefetchedTreeReadAt[kept] = readAt
        prefetchedTreeLinkTargets[kept] = linkTargets
        prefetchedTreeReadMark[kept] = readMark
        Logger.shared.debug("[cache] kept the walk at “\(kept)” for the pane that stayed; "
                            + "dropped the other \(before - 1) cached walk(s)")
    }

    /// Drops only the cached walks that list `folder` (its ancestor chain, and any walk reaching it
    /// through a linked folder or a folder symlink) with their provenance, keeping every other
    /// entry. For a write that adds one file, which makes exactly those entries stale.
    /// `dropPrefetchedTrees()` empties the lot, right for a file operation (it can touch many
    /// folders on both sides) and a sort change, but after Edit's ⌘N or Export as PDF it would make
    /// the next navigation anywhere a cold walk.
    ///
    /// "Lists" is ``folder(_:holds:links:)``, links included: the iCloud container's walk lists
    /// `~/Documents` under the link's name, as does every walk rooted above it, so a file created
    /// in `~/Documents/Finance` makes their entries stale though no key of theirs prefixes its
    /// path. Asked with `linkedFolders`, the table the walks were made with, and each entry's own
    /// `prefetchedTreeLinkTargets`. Returns how many entries went, for the caller's log line.
    @discardableResult
    public func dropPrefetchedTrees(holding folder: String) -> Int {
        let links = linkedFolders
        let stale = prefetchedTrees.keys.filter {
            Self.folder($0, holds: folder, links: links, linkTargets: prefetchedTreeLinkTargets[$0] ?? [])
        }
        for key in stale { dropPrefetchedTree(at: key) }
        return stale.count
    }

    /// Drops the cached walks the folder watcher's changes made stale: each walk that lists one of
    /// a change's `paths` (string math only, ``listedRoots(of:links:linkTargets:)``), and for a
    /// change marked `below`, each walk of a folder under one of them, since a removed or renamed
    /// folder takes the walks below it along and no event will name them.
    ///
    /// Only walks older than the change: a walk whose read mark is at or past the change's id
    /// started after it and listed it. An entry with no mark goes. Returns how many entries went.
    @discardableResult
    func dropPrefetchedTrees(changedBy changes: [(paths: [String], below: Bool, id: UInt64)]) -> Int {
        guard !changes.isEmpty, !prefetchedTrees.isEmpty else { return 0 }
        // Folded by folder first. A walk lists a path strictly below one of its roots exactly when
        // it lists that path's parent, so a burst of thousands of files in a few folders asks each
        // walk about a few folders, not every file; a first sync's 20,000 events against a few
        // dozen walks would be over a million comparisons on the main actor. A path that is a
        // walk's root is looked up by name.
        var parents: [String: UInt64] = [:]
        var exact: [String: UInt64] = [:]
        var below: [String: UInt64] = [:]
        for change in changes {
            for path in change.paths where !path.isEmpty {
                let parent = (path as NSString).deletingLastPathComponent
                parents[parent] = max(parents[parent] ?? 0, change.id)
                exact[path] = max(exact[path] ?? 0, change.id)
                if change.below { below[path] = max(below[path] ?? 0, change.id) }
            }
        }
        let links = linkedFolders
        let stale = prefetchedTrees.keys.filter { key in
            let mark = prefetchedTreeReadMark[key] ?? 0
            let listed = Self.listedRoots(of: key, links: links, linkTargets: prefetchedTreeLinkTargets[key] ?? [])
            for root in listed where (exact[root] ?? 0) > mark { return true }
            for (parent, id) in parents where id > mark && Self.tail(of: parent, in: listed) != nil { return true }
            for (path, id) in below where id > mark && PathBoundary.lexicalRelativize(key, under: path) != nil {
                return true
            }
            return false
        }
        for key in stale { dropPrefetchedTree(at: key) }
        return stale.count
    }

    /// One entry and its provenance, together.
    private func dropPrefetchedTree(at key: String) {
        prefetchedTrees[key] = nil
        prefetchedTreeWalkStopped.remove(key)
        prefetchedTreeReadAt[key] = nil
        prefetchedTreeLinkTargets[key] = nil
        prefetchedTreeReadMark[key] = nil
    }

    /// Whether a deep walk of `folder` (a pane's folder or a cached walk's root) lists `path`, a
    /// file the app just wrote: `path` is `folder` or under it, under a folder linked in at
    /// `folder` or any folder below it, or under a target in `linkTargets`. `path` is also tried
    /// symlink-resolved, for one handed over by a save panel rather than composed by a pane (an
    /// iCloud link-side path resolves to the real `~/Documents/…`), and for the targets, which are
    /// recorded resolved.
    ///
    /// Below `folder` too, because the walk substitutes a link wherever it lists one (`buildTree`'s
    /// `childURLs`): a walk of `~/Library/Mobile Documents` lists iCloud Drive's container and,
    /// through its link, `~/Documents`. Asked at the root alone, a write in `~/Documents/Finance`
    /// would leave that walk cached and the pane served the old tree. One hop only: a second would
    /// need a linked folder holding a container of its own, which no table has.
    ///
    /// A folder symlink the table doesn't name comes through `linkTargets`. The walk follows it:
    /// the link and its children keep the link's spelling, and from two levels down the listing
    /// comes back resolved. So a walk of `R` holding `R/link → T`, with `T` outside `R`, carries
    /// ids spelled `T/…`, a file opened from those rows is saved under that spelling, and no prefix
    /// of `R` names it (`OutOfQueueWriteRereadTests`). Finding such links here would mean
    /// traversing every cached tree on every write, so the walk records them (`FollowedLinks`) and
    /// the caller passes the record in: a cache entry's `prefetchedTreeLinkTargets`, or a pane's
    /// `leftTreeLinkTargets`. A container the table names below a target is listed too.
    ///
    /// Not a file symlink, which can leave a walk stale both ways. `R/f.txt → T/f.txt` lists no
    /// folder of `T`'s, but its node carries the target's size and date, so a rewrite spelled
    /// `T/f.txt` leaves the walk of `R` describing the old file; and a rewrite spelled through the
    /// link leaves a walk of `T` stale, since the drop asks about `R`. Closing either means
    /// matching the written file itself rather than its folder, which nothing here does yet.
    public nonisolated static func folder(_ folder: String, holds path: String,
                                          links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders,
                                          linkTargets: Set<String> = []) -> Bool {
        guard !PathBoundary.normalizedRoot(folder).isEmpty, !path.isEmpty else { return false }
        let raw = PathBoundary.normalizedRoot(path)
        if listedTail(of: raw, in: folder, links: links, linkTargets: linkTargets) != nil { return true }
        let resolved = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        return resolved != raw && listedTail(of: resolved, in: folder, links: links, linkTargets: linkTargets) != nil
    }

    /// ``folder(_:holds:links:linkTargets:)`` without its symlink-resolving second try — string
    /// math only, so it is cheap enough for every path in a burst of FSEvents, which arrive
    /// resolved already. Answers where `path` sits below the folder the walk lists it under
    /// (`""` for that folder itself), or nil when the walk does not list it.
    nonisolated static func listedTail(of path: String, in folder: String,
                                       links: PathBoundary.LinkedFolders,
                                       linkTargets: Set<String>) -> String? {
        guard !path.isEmpty else { return nil }
        return tail(of: PathBoundary.normalizedRoot(path),
                    in: listedRoots(of: folder, links: links, linkTargets: linkTargets))
    }

    /// Where a deep walk of `folder` lists from: the folder and the targets of the links it
    /// followed, and every target of a container at or below any of those. One container on a real
    /// Mac, and almost every walk follows no link, so this is one folder and at most two targets.
    /// Empty for an empty folder, which lists nothing.
    nonisolated static func listedRoots(of folder: String, links: PathBoundary.LinkedFolders,
                                        linkTargets: Set<String>) -> [String] {
        let expanded = PathBoundary.normalizedRoot(folder)
        guard !expanded.isEmpty else { return [] }
        let roots = [expanded] + linkTargets
        var listed = roots
        for (container, targets) in links
        where roots.contains(where: { PathBoundary.lexicalRelativize(container, under: $0) != nil }) {
            listed.append(contentsOf: targets.values)
        }
        return listed
    }

    /// Where `path` sits below the first of `listed` that holds it (`""` for one of them itself).
    nonisolated static func tail(of path: String, in listed: [String]) -> String? {
        for root in listed {
            if let tail = PathBoundary.lexicalRelativize(path, under: root) { return tail }
        }
        return nil
    }
    /// Focused-folder path each pane's published tree was last loaded for; distinguishes a
    /// same-focus refresh (keep showing the current tree while rebuilding) from a focus
    /// change (repaint shallow immediately) in `loadTree`.
    var lastLoadedLeftFocusPath: String? = nil
    var lastLoadedRightFocusPath: String? = nil
    
    @Published public var clipboardNodes: [FileNode] = []
    @Published public var clipboardIsCut: Bool = false
    /// `NSPasteboard.general.changeCount` as it stood after the app's own last ⌘C or ⌘X, or nil if
    /// it wrote none this launch.
    ///
    /// It keeps two clipboards behaving as one: while it equals the live count, SyncCloud owns the
    /// pasteboard, and `clipboardNodes` (which carries `isCut`, the only path that can move rather
    /// than copy) is what a paste means. Once anything else writes, the count moves and the
    /// pasteboard is the answer (`ClipboardSource.resolve`). Held here, beside the rest of the
    /// clipboard's state.
    @Published public var clipboardPasteboardChangeCount: Int? = nil
    
    /// Global UndoManager injected from SwiftUI environment. Re-wires the did-undo/did-redo
    /// observers that keep the "Undo Last Run" pairing honest (see `invalidateRunUndoPairing`).
    public var undoManager: UndoManager? {
        didSet {
            guard undoManager !== oldValue else { return }
            // A different manager is a different stack: a pairing armed against the old one must
            // not be validated against the new one's identically named groups (a window reopen
            // swaps managers). The armed-this-session flag resets too, since the old stack's runs
            // are unreachable and the "history changed" advice would point at nothing.
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
                    // actor), so hopping is safe. reverseLastSyncRun's own undo() also lands
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
    /// `logged: false` is for a batch whose grouped failure lines (`GroupedFailureLog`) already
    /// name every failure, the alert's included, so its line would only repeat the first.
    public func present(_ error: SyncError, retry: (@MainActor () -> Void)? = nil, logged: Bool = true) {
        currentError = error
        currentErrorRetry = retry
        if logged { Logger.shared.error(error.logDescription) }
    }

    /// The rows the last bulk transfer failed on, or nil when the last one was clean. Drives the
    /// Differences table's Failed filter — see ``TransferFailures`` for why this exists at all.
    @Published public internal(set) var lastTransferFailures: TransferFailures?

    /// When non-nil, a bulk sync is in progress: (completed count, total count). Used for progress indicator.
    @Published public var bulkSyncProgress: (completed: Int, total: Int)? = nil
    /// Cached "Apply to all" resolution for the current bulk run; cleared when bulk sync ends.
    internal var bulkApplyToAllResolution: CollisionResolution?
    /// True while a bulk run (`syncAll` or the verified-copy bulk copy) is in flight. Both write
    /// `bulkSyncProgress` and nil it in their defer, and syncAll's prepare phase suspends (detached
    /// stat pass, keep-both probing) before the progress overlay blocks input. Without a shared
    /// guard two runs could interleave there, reset `bulkApplyToAllResolution` mid-prompt, mix the
    /// progress counter, and tear down `bulkSyncProgress` while the other still uses it. Internal
    /// so tests can pin the refusals without racing a real run.
    var isBulkSyncRunning = false
    /// True while a `verifyAllWithChecksum` run is in flight; it and `isBulkSyncRunning` each
    /// refuse to start while the other runs. Verify All hashes both sides of every candidate, so
    /// overlapping a bulk sync (especially its prepare phase, where `bulkSyncProgress` is still
    /// nil) would checksum files mid-overwrite and could record bogus "identical" results in
    /// `verifiedIdenticalForCopy`. Internal so tests can pin the refusal without racing a real run.
    var isVerifyAllRunning = false

    /// Current subfolder path relative to the left pane root (empty = root). This is the pane's
    /// comparison scope, not just where it's looking: assigning it goes through `focusOn` →
    /// `syncPathsFromHistory` → `refreshSubject`, reloading the tree and rescanning. Where the pane
    /// is browsing inside that scope is `leftBrowsePath`.
    @Published public var leftRelativePath: String = "" {
        // What the pane just made stays visible only until it leaves the folder.
        didSet { if leftRelativePath != oldValue { leftTypeFilterKeep = [] } }
    }
    /// Current subfolder path relative to the right pane root (empty = root).
    @Published public var rightRelativePath: String = "" {
        didSet { if rightRelativePath != oldValue { rightTypeFilterKeep = [] } }
    }

    /// Where each pane's source opens, as a path relative to that pane's root: the origin its
    /// positions are quoted against.
    ///
    /// Supplied by the app, which owns the pane → source mapping, as a closure so it is read at the
    /// moment of decision: discovery republishes it, and a cached copy would answer with where a
    /// source used to open. The default answers `""` for both, so a test that doesn't set it sees
    /// both panes open at their roots.
    ///
    /// Linked navigation reads it, so a sibling pane isn't driven by one root-relative path into a
    /// doubled `Documents` or an unrelated folder at the top of the account. So does the durable
    /// ignore store's "both panes show the same thing" guard: compared raw, a mixed pair never
    /// matches, and Ignore would silently write nothing.
    @MainActor public var paneOpenAt: (_ isLeft: Bool) -> String = { _ in "" }

    /// Each pane's source id, supplied by the app and read at the moment of decision, as
    /// `paneOpenAt` is. Only the durable ignore store reads it, to decide which pane's coordinates
    /// its entries are quoted in (`ignoreAnchorIsLeft`). The default answers `""` for both, which
    /// picks the left pane.
    @MainActor public var paneSourceId: (_ isLeft: Bool) -> String = { _ in "" }

    /// Which pane's root the durable ignore set is measured from. It can't simply be the left one.
    /// `IgnoredItemsStore.pairKey` sorts its two ids, so one key serves the pair in either
    /// orientation, but sources land at `openAt`: one item is `Family/x` from an iCloud pane and
    /// `Documents/Family/x` from a OneDrive one. Quoted against whichever source is on the left,
    /// ⌘⇧S would re-read the entries in the other source's coordinates, where they match nothing:
    /// ignored rows come back, and the next Ignore stores the item again under its other spelling.
    ///
    /// So entries are quoted against the source whose id sorts first, the one the key names first.
    /// That is stable under a swap, and it is the choice `RootsMigration.rebaseIgnoredItems` makes
    /// when it moves stored entries, so the two agree. Falls back to the left pane when either id
    /// is unknown and there is nothing to sort.
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

    /// Whether a focus-relative path names the same item in both panes, the condition the durable
    /// ignore store's identity depends on. Anchor-relative, not a raw comparison of the two focus
    /// paths: iCloud lands at `""` and OneDrive at `Documents`, so two panes showing the same thing
    /// differ by the landing folder and the raw test never matches.
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

    /// Which pane the pane-scoped chords act on, once something said so explicitly (⌃⇥, or a click
    /// that selects in a pane). nil until then, which hands the question to
    /// `PaneLogic.focusedPaneIsLeft`'s selection-derived fallback.
    ///
    /// It does not feed the action bar, which is about a selection and draws where it is
    /// (`PaneLogic.activePane`). This answers "which pane am I working in", which the selection
    /// can't: letting go of a selection isn't leaving the pane. Held here, not in view state, so
    /// `swapPanes` swaps it with the other per-side facts.
    @Published public var focusedPaneSide: PaneTree.Side?
    /// Tracks the number of currently active file operations (Sync, Move, Delete, etc.).
    /// Used by the app-level guard to prevent accidental termination during critical tasks.
    /// Not `@Published`: the quit guard reads it imperatively; no view observes it.
    public var activeFileOperationsCount = 0
    /// Monotonic count of file operations ever started, never decremented, so a long async pass can
    /// tell an operation ran even when it started and finished during the pass, which
    /// `activeFileOperationsCount == 0` can't see. It answers two questions:
    ///
    /// - `autoVerifySameSizePairs` and `verifyAllWithChecksum` capture it at entry and discard
    ///   their batch if it moved by commit: did anything rewrite the bytes I hashed?
    /// - `confirmVerifiedCopy` compares it against the epoch stamped into the standing offer: were
    ///   those verdicts invalidated while the dialog was up?
    ///
    /// It covers only operations that have started: the bump is at enqueue time, the claim earlier
    /// at `preCountFileOperation()`. So the two questions take different guards and must not be
    /// unified. `confirmVerifiedCopy` also requires `activeFileOperationsCount == 0`, because it is
    /// about to write and a pending write must stop it; the scan pass doesn't, because a
    /// pre-counted operation the user declines never runs, and voiding a hashed batch for it costs
    /// coverage. Each guard explains itself at its site.
    ///
    /// Bumped in `enqueueFileOperation`, not with `activeFileOperationsCount`. The count moves at
    /// pre-count, so the quit guard and the hashing exclusions treat a pending transfer as in
    /// flight while its prompt is up. The epoch can't: a declined prompt runs no I/O, the bump
    /// can't be taken back, and it would void the auto-verify batch with no rescan to re-run it,
    /// leaving those rows listed as differences.
    internal private(set) var fileOperationsEpoch = 0

    /// Records that a file operation is about to run (`fileOperationsEpoch`). Called only from
    /// `enqueueFileOperation`, the serial queue every user file operation goes through. The
    /// orphaned-temp sweep is the one write that isn't, by design: it only removes age-gated
    /// `.tmp_<UUID>` staging artifacts, which can't make a differing pair hash identical
    /// (`sweepOrphanedTempArtifacts` explains).
    private func noteFileOperationBegan() {
        fileOperationsEpoch += 1
    }
    /// Real-time progress for the active bulk file operation. While it is set the window greys
    /// every action that writes to disk; each publisher names its run in
    /// ``Foundation/Progress/runLockReason`` for the tooltip that says why.
    @Published public var activeProgress: Progress? = nil {
        didSet {
            guard activeProgress !== oldValue else { return }
            if let finished = oldValue, let started = activeProgressStartedAt {
                lastFinishedRun = (started: started, ended: Date(), title: finished.runTitle,
                                   cancelled: finished.isCancelled)
            }
            activeProgressStartedAt = activeProgress.map { $0.firstPublished() }
        }
    }
    /// When the run on ``activeProgress`` was published, which orders it among the window's other
    /// runs, newest first, in the toolbar's capsule.
    public private(set) var activeProgressStartedAt: Date?
    /// The last run that ended: the minutes its log lines span, for its message's Show in Log in
    /// Activity. Its title is the run's own ("Merging “Photos”"), which names a notification of its
    /// ending. `cancelled` says it was stopped, so its ending is a stop, not a problem.
    public private(set) var lastFinishedRun: (started: Date, ended: Date, title: String?, cancelled: Bool)?
    /// Short-lived banner for operation completion toasts; its severity drives the icon, tint and
    /// dismissal.
    ///
    /// Every banner is also logged here at its severity, prefixed `[banner]`, so refusals stay
    /// findable: many guards refuse with nothing but a banner, which is gone in seconds. Sites that
    /// log a richer line too produce a near-duplicate pair; the `[banner]` line records what the
    /// user was shown.
    @Published public var banner: OperationBanner? = nil {
        didSet {
            guard let banner, banner.id != oldValue?.id else { return }
            switch banner.log {
            case .info, .loggedAtSite: Logger.shared.info("[banner] \(banner.message)")
            case .warn: Logger.shared.warning("[banner] \(banner.message)")
            case .error: Logger.shared.error("[banner] \(banner.message)")
            case .notMirrored: break
            }
        }
    }
    
    /// Combine subject that asks for a tree refresh from anywhere, without closure retain cycles.
    ///
    /// It carries which panes to walk: navigating one pane must not re-walk the other's root, which
    /// after any file operation or sort change (the prefetch cache is then empty) is a full cold
    /// walk of tens of thousands of nodes. Senders that change what a walk would produce (a
    /// finished file operation, a date-tolerance change, a sort needing fresh tags) send `.both`,
    /// and must. The narrow scopes come from `syncPathsFromHistory`, which knows one pane moved,
    /// through navigation or `retargetPane`.
    ///
    /// A narrow request never skips a load that is owed: `refreshTreesAndScan` unions a one-pane
    /// scope with any wider refresh in flight, so a `.leftOnly` arriving mid-launch widens back to
    /// `.both` rather than stranding the right pane.
    public let refreshSubject = PassthroughSubject<PaneReloadScope, Never>()
    
    /// Chains file operations so they run one after another (avoids concurrent copy/move/undo conflicts).
    private var fileOperationTask: Task<Void, Swift.Error> = Task {}

    /// Returns once every file operation claimed so far has finished; claims nothing itself.
    func fileOperationsSettled() async { _ = await fileOperationTask.result }

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
    /// Target of the in-flight refresh (both providers and focused subpaths), or nil. Lets
    /// refreshTreesAndScan dedupe the identical refreshes the launch bootstrap fires (the explicit
    /// initial refresh, and the provider-id onChange that resets navigation) instead of
    /// cancel-restarting them, which races and can strand a pane's load.
    var activeRefreshKey: RefreshKey?
    /// A refresh is reading the panes' folders or comparing them, from the moment it starts;
    /// `isScanning` rises only once both folders are read. Ask Claude's Scan Again waits on this.
    public var isRefreshing: Bool { activeRefreshKey != nil }
    /// Identity of a refresh target. Two concurrent refreshes with the same key would load the
    /// same thing, so the later one is skipped; a different key is real navigation and supersedes.
    struct RefreshKey: Equatable {
        let leftId: String
        let leftPath: String
        let rightId: String
        let rightPath: String
        let leftRel: String
        let rightRel: String
        /// `scanConfigGeneration` at key construction, so a refresh requested after a
        /// scan-affecting change never reads as a duplicate of one started before it. Otherwise the
        /// dedupe would swallow the follow-up refresh a config didSet requests while a same-target
        /// refresh is in flight (switching to the Tags sort mid-scan would leave the panes tag-less
        /// and old-sorted).
        let config: Int
        /// Which panes this refresh walks. In the key so a one-pane and a two-pane refresh of one
        /// target aren't mistaken for each other: a tab switch's `.leftOnly` in flight would
        /// otherwise swallow a later `.both`, and the right pane would keep a tree nobody reloaded.
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
        /// Here rather than a `switch` at the call site because the one caller is a closure in
        /// `ContentView.body`, where no test can reach it. `String(describing:)` would yield
        /// `leftOnly`, a case name a log reader hasn't been told the meaning of. (The widening line
        /// deliberately keeps the case name: it names the request it received.)
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

    /// Prepares a user-initiated force refresh: drops the prefetch cache and bumps the scan-config
    /// epoch. The bump is essential: `refreshTreesAndScan` dedupes on a `RefreshKey` that includes
    /// `scanConfigGeneration`, so a forced rescan during a same-target refresh would otherwise be
    /// swallowed as a duplicate and do nothing. Here because `noteScanConfigChanged` is internal.
    public func prepareForcedRescan() {
        dropPrefetchedTrees()
        noteScanConfigChanged()
    }

    /// Prepares the re-read after the app wrote one file itself, outside the file-operation queue
    /// (Edit's ⌘N, Export as PDF): drops only the cached walks that list its folder
    /// (``dropPrefetchedTrees(holding:)``) and bumps the epoch, for `prepareForcedRescan`'s reason.
    /// Without the drop, a pane that finished a deep walk would be served it, taken before the file
    /// existed (`OutOfQueueWriteRereadTests`).
    public func prepareReread(afterWritingAt path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        noteOwnWrite(atPath: path)
        let before = prefetchedTrees.count
        let dropped = dropPrefetchedTrees(holding: folder)
        noteScanConfigChanged()
        Logger.shared.debug("[reread] \(path) was written outside the queue; dropped \(dropped) of "
                            + "\(before) cached walk(s) listing its folder")
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
    
    /// Synchronously counts a file operation that is committed but not yet queueable:
    /// `transferItems`, which counts before its confirmation modal so the quit guard and the
    /// hashing exclusions treat a pending transfer as in flight while the dialog is up. Pair it
    /// with `enqueueFileOperation(alreadyCounted: true)`, or with `cancelPreCountedFileOperation()`
    /// when the user declines; the completion decrement is shared and unconditional.
    ///
    /// **It counts only, and must not claim a queue position here.** The modal can stay open for
    /// minutes, and a slot claimed in front of it would hold every later operation that long. The
    /// undo and redo handlers, which have no such gap, use `claimFileOperationSlot()`, which also
    /// fixes the operation's position before its `Task` exists.
    public func preCountFileOperation() {
        activeFileOperationsCount += 1
    }

    /// Reverts a `preCountFileOperation()` whose operation will never be enqueued because the user
    /// declined its prompt. Only for that pairing: enqueued operations are decremented by
    /// `enqueueFileOperation`'s completion handler. The epoch needs no revert: the pre-count never
    /// bumped it, so a declined prompt leaves no trace.
    public func cancelPreCountedFileOperation() {
        activeFileOperationsCount = max(0, activeFileOperationsCount - 1)
    }

    /// Synchronously claims this operation's position in the serial file-operation queue, before
    /// the `Task` that runs it exists.
    ///
    /// A claim, not an ordering convention. `enqueueFileOperation` claims without a suspension, so
    /// two callers already on the main actor claim in call order, but that rests on the caller's
    /// isolation and, for callers that spawn a `Task` first, on main-actor jobs being FIFO. Neither
    /// is checkable at the call site, and a future `Task.detached { await
    /// manager.enqueueFileOperation { … } }` would bring the race back silently: a ⌘Z that deletes
    /// the folded files out of a merge's keeper before restoring the originals. A slot fixes the
    /// order in the caller's own synchronous main-actor stretch.
    ///
    /// It does everything `enqueueFileOperation`'s prologue does: the count, the epoch bump and the
    /// chain claim. Pass the slot to exactly one `enqueueFileOperation(slot:)`, without
    /// `alreadyCounted`.
    ///
    /// **Claiming blocks every later operation until this one finishes**, so the confirmation-gated
    /// transfer path uses `preCountFileOperation()` instead: a slot claimed before its modal would
    /// hold the queue for the length of the dialog. The undo and redo handlers start their `Task`
    /// at once, so they claim.
    ///
    /// Dropping a slot without enqueuing it is safe: it releases its position on `deinit`, so an
    /// unused claim can't wedge the queue.
    public func claimFileOperationSlot() -> FileOperationSlot {
        claimFileOperationSlot(alreadyCounted: false)
    }

    private func claimFileOperationSlot(alreadyCounted: Bool) -> FileOperationSlot {
        if !alreadyCounted { activeFileOperationsCount += 1 }
        noteFileOperationBegan()
        let predecessor = fileOperationTask
        let slot = FileOperationSlot(predecessor: predecessor)
        // The successor's claim chains on this: it waits for our predecessor, then for our body's
        // completion signal, so operations run in claim order.
        //
        // The chain captures the signal, never the slot: holding the slot would keep it alive for
        // the whole chain and disarm the `deinit` release that stops an unused claim from wedging
        // the queue.
        let released = slot.released
        fileOperationTask = Task { _ = await predecessor.result; await released.wait() }
        return slot
    }

    /// Enqueues a file operation to run after every earlier one. Manages
    /// `activeFileOperationsCount`, and refreshes the UI and prunes the selection on completion.
    /// - Parameter alreadyCounted: True when the caller already counted it with
    ///   `preCountFileOperation()`, so it isn't counted twice.
    /// - Parameter slot: A position claimed by `claimFileOperationSlot()` in the caller's own
    ///   synchronous main-actor stretch. Pass one whenever this operation's order relative to
    ///   another matters: the order is then fixed at claim time, wherever this is called from.
    ///   Mutually exclusive with `alreadyCounted`, since the claim already counted it.
    @discardableResult
    public func enqueueFileOperation<T: Sendable>(
        alreadyCounted: Bool = false,
        slot: FileOperationSlot? = nil,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        // The epoch moves here, unconditionally: this is the last point before the work is queued,
        // and every user file operation (transfers, undo/redo, bulk sync, duplicates, name
        // normalization, automations, filing) reaches the disk through this call. The count moves
        // here only if the caller didn't pre-count (`preCountFileOperation`).
        //
        // **Straight-line, never `await MainActor.run`: that hop makes the queue order a race.**
        // `MainActor.run` is a nonisolated async function, so awaiting it from the main actor hops
        // off to the generic executor and back (SE-0338): two suspensions before
        // `fileOperationTask` is claimed below. Two callers could come back in either order, read
        // the same predecessor, and run concurrently or reversed.
        //
        // Undo is where that bites. A merge's ⌘Z pops two registrations in a deliberate order:
        // restore the redundant copies from the Trash first, delete the folded files out of the
        // keeper second, so a failed restore still leaves the folded files in the keeper rather
        // than leaving neither. Both handlers spawn a `Task` that calls this method, and that order
        // must survive to the claim.
        //
        // What this guarantees: with no suspension before the claim, the queue order is the call
        // order for callers already on the main actor, and for callers that spawn a `Task` and call
        // from it (the undo and redo handlers) only because equal-priority main-actor jobs run
        // FIFO. Nothing enforces the first condition; a `Task.detached { await
        // manager.enqueueFileOperation { … } }` would bring the race back silently.
        //
        // `slot:` makes the order structural: the caller claims synchronously
        // (`claimFileOperationSlot()`) before its Task exists, so neither this method's isolation
        // nor the scheduler can reorder two claims. `FileOperationQueueOrderTests` pins both
        // halves: unslotted call order for main-actor callers, and slotted order across
        // deliberately inverted off-main enqueues.
        let claimed = slot ?? claimFileOperationSlot(alreadyCounted: alreadyCounted)
        let previousTask = claimed.predecessor
        let newTask = Task.detached(priority: .userInitiated) {
            _ = await previousTask.result
            // A move whose original was parked and not put back still succeeds: the sink collects
            // it for this operation, and the leftover is presented below.
            let leftovers = ParkedSourceLeftovers()
            let res = await ParkedSourceLeftovers.$current.withValue(leftovers) { await operation() }
            let parked = leftovers.recorded
            await MainActor.run { [weak self] in
                if let first = parked.first {
                    for extra in parked.dropFirst() {
                        // An undo's leftover is the item it moved back from, not an original.
                        Logger.shared.error(extra.undoing
                            ? "Moved back, but the item it moved back from, \(extra.original.path), is still in its folder as \(extra.parked.lastPathComponent)"
                            : "Moved, but the original \(extra.original.path) is still in its folder as \(extra.parked.lastPathComponent)")
                    }
                    self?.present(first.undoing
                        ? .undoneButMovedItemParked(originalPath: first.original.path,
                                                    parkedPath: first.parked.path,
                                                    additional: parked.count - 1)
                        : .movedButOriginalParked(originalPath: first.original.path,
                                                  parkedPath: first.parked.path,
                                                  additional: parked.count - 1))
                }
                // File operations mutate the filesystem; cached prefetched roots are stale after any write.
                self?.dropPrefetchedTrees()
                // A refresh already in flight walked mid-operation disk state; the post-op
                // refresh below must supersede it, not dedupe against it.
                self?.noteScanConfigChanged()
                self?.activeFileOperationsCount = max(0, (self?.activeFileOperationsCount ?? 1) - 1)
                self?.scheduleSelectionPrune()
                self?.refreshSubject.send(.both)
            }
            // Hands the queue on after the cleanup above: the successor's claim waits on exactly
            // this. Holding `claimed` strongly here keeps its `deinit` release (the unused-claim
            // valve) from firing while the operation runs.
            claimed.release()
            return res
        }
        return await newTask.value
    }
    
    public func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool {
        // Strip currentPath only at a path-component boundary (PathBoundary's semantics), so a pane
        // rooted at "/root/ab" never claims "/root/abc/x" by a bare string prefix. A node outside
        // the pane root keeps its absolute path.
        let rPath = PathBoundary.relativize(node.id, under: currentPath) ?? node.id
        // Path layers only, no pattern matching: this predicate drives the rows' ignored look and
        // the context menu's Ignore/Include label, whose click lands in `toggleIgnored`, which can
        // edit only the path layers. Counting pattern matches would promise an "Include" the toggle
        // can't deliver and mirror a phantom entry into the durable store. Pattern-hidden items are
        // managed in Settings, not per row.
        return Self.isIgnoredPath(rPath, ignored: effectiveIgnoredPaths)
    }
    
    /// Records which rows a bulk transfer couldn't move, or clears the record after a clean run.
    /// Called by both bulk paths, unconditionally, where each removes its successes, empty
    /// `failures` included: a clean run must clear the previous run's failures, or the Failed
    /// filter keeps offering rows that have since gone through.
    internal func recordTransferFailures(_ failures: [(FileDifference, Error)]) {
        guard !failures.isEmpty else {
            // Assigning nil over nil would republish on every clean run, and every published write
            // on the manager re-evaluates the window's body.
            if lastTransferFailures != nil { lastTransferFailures = nil }
            return
        }
        lastTransferFailures = TransferFailures(ids: Set(failures.map { $0.0.id }))
    }

    /// Removes resolved differences from both the published list and the raw backing list.
    /// `applyFilters()` rebuilds `differences` from `rawDifferences`, so removing from the
    /// published list alone would let any filter change before the next rescan resurrect rows
    /// that were already synced.
    internal func removeResolvedDifferences(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        differences.removeAll { ids.contains($0.id) }
        rawDifferences.removeAll { ids.contains($0.id) }
        // A resolved row is gone from both lists; leaving its id marked in-flight would keep
        // the pane swap (and Verify All) refused forever after a successful sync.
        syncingDifferenceIds.subtract(ids)
    }

    /// Removes resolved differences by id and by pending-copy identity. Callers working on captured
    /// values (guided review's frozen queue, a Copy Remaining subset) can outlive a rescan, which
    /// regenerates every row UUID, so an id-only removal would no-op and the resolved row would
    /// linger until the next rescan. Matching this way is safe for replace and plain copies, which
    /// equalized the two sides; a keep-both leaves the destination differing, but the operation's
    /// own rescan re-adds whatever still differs.
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

    /// Stamps `isSyncing` on the published rows in one write. `differences` is `@Published`, whose
    /// wrapper has a getter and a setter but no `_modify`, so `differences[i].isSyncing = x` copies
    /// the whole array, writes it back and publishes, per row: marking m of n rows is O(n·m)
    /// copying plus m `objectWillChange` sends on the main actor. For Sync All over ~29,000 rows
    /// that is seconds of main-thread time; one read-out and one write-back take milliseconds.
    ///
    /// The `!= value` test makes a redundant stamp free, and the `changed` guard keeps a no-op from
    /// republishing at all, as in `applyFilters()`: republishing an unchanged list rebuilds the
    /// whole pane `List` and can eat a click.
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
        /// Each pane's tree after Hidden but before the type filter; the same array as the pane's
        /// tree when it has no type filter.
        var leftTreeBeforeTypeFilter: [FileNode] = []
        var rightTreeBeforeTypeFilter: [FileNode] = []
        /// `nil` for a pane with no type filter.
        var leftTypeFilterFacts: PaneTypeFilterFacts? = nil
        var rightTypeFilterFacts: PaneTypeFilterFacts? = nil
    }

    /// Reapplies `showHiddenFiles` and `ignoredPaths` to the raw trees and differences, and
    /// publishes. The filtering (full walks of both trees plus a pass over every raw difference)
    /// runs off the main actor: with tens of thousands of nodes it would freeze every window.
    /// Overlapping passes are safe: the last-started pass wins, and stale results never overwrite
    /// fresher ones.
    public func applyFilters() async {
        filterGeneration += 1
        let generation = filterGeneration

        let rawLeft = rawLeftTree
        let rawRight = rawRightTree
        let rawDiffs = rawDifferences
        let showHidden = showHiddenFiles
        let leftTypes = leftTypeFilter, rightTypes = rightTypeFilter
        let leftKeep = leftTypeFilterKeep.union(typeFilterOpenIDs(isLeft: true))
        let rightKeep = rightTypeFilterKeep.union(typeFilterOpenIDs(isLeft: false))
        let ignored = effectiveIgnoredPaths
        let patterns = ignorePatterns
        let verifiedSame = verifiedSameDifferenceIds
        let syncingIds = syncingDifferenceIds
        let dropDriveDateNoise = ignoreGoogleDriveNewerDateOnly && lastRightProviderType == .googleDrive
        // Snapshot the published trees so the tree-changed comparisons run in the detached compute:
        // deep equality is an O(nodes) walk, and on the main actor it hitches the UI on large
        // panes.
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
                dropDriveDateNoise: dropDriveDateNoise,
                leftTypeFilter: leftTypes,
                rightTypeFilter: rightTypes,
                leftTypeFilterKeep: leftKeep,
                rightTypeFilterKeep: rightKeep
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
        // The snapshot is stale if a sync resolved rows (`removeResolvedDifferences`) or marked or
        // cleared in-flight state while the detached compute ran; publishing it verbatim would
        // resurrect resolved rows and reinstall a stale `isSyncing`. Reconcile against live state:
        // keep only rows still in `rawDifferences`, and re-stamp `isSyncing` from
        // `syncingDifferenceIds` in both directions.
        //
        // Skipped when neither input moved, the ordinary case. Both halves are then no-ops: every
        // row in `state.differences` was filtered from the same `rawDifferences`, and
        // `computeFilteredState` guarantees every row already carries the flag this loop would
        // stamp. Over ~29,000 differences that saves ~5 ms of main-actor time per pass.
        //
        // The skip decision is kept in one variable because the publish gate below needs the same
        // answer; two spellings of one condition would drift when a third input joins the reconcile
        // pass.
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
        // Assign only what changed. A load+scan cycle runs several filter passes, and republishing
        // an unchanged tree makes SwiftUI rebuild the whole pane List; a rebuild landing between an
        // NSTableView mouse-down and mouse-up drops the click. The off-main tree comparisons are
        // trusted only while nothing wrote that pane's published tree since (its
        // `published*TreeVersion`); after a mid-flight write, fall back to a live compare for that
        // pane.
        if leftVersion == publishedLeftTreeVersion ? leftTreeChanged : (self.leftTree != state.leftTree) {
            self.leftTree = state.leftTree
        }
        if rightVersion == publishedRightTreeVersion ? rightTreeChanged : (self.rightTree != state.rightTree) {
            self.rightTree = state.rightTree
        }
        if self.leftItemCount != state.leftItemCount { self.leftItemCount = state.leftItemCount }
        if self.rightItemCount != state.rightItemCount { self.rightItemCount = state.rightItemCount }
        self.leftTreeBeforeTypeFilter = state.leftTreeBeforeTypeFilter
        self.rightTreeBeforeTypeFilter = state.rightTreeBeforeTypeFilter
        if self.leftTypeFilterFacts != state.leftTypeFilterFacts { self.leftTypeFilterFacts = state.leftTypeFilterFacts }
        if self.rightTypeFilterFacts != state.rightTypeFilterFacts { self.rightTypeFilterFacts = state.rightTypeFilterFacts }
        // The rows' deep compare is trusted on the same terms as the trees': only while nothing
        // wrote the published list since entry, and only when the reconcile pass was skipped, which
        // is what makes `reconciledDifferences` the same value as the `state.differences` compared
        // off-main. Otherwise, compare live.
        let differencesNeedPublishing = reconcileWasSkipped
            && publishedDifferencesVersion == entryDifferencesVersion
            ? differencesChanged
            : self.differences != reconciledDifferences
        if differencesNeedPublishing { self.differences = reconciledDifferences }
    }

    /// One line on whether the filter gate is skipping anything, for the scan breadcrumb in
    /// `~/sync-cloud.log`. `applyFilters()` skips its reconcile pass whenever neither input moved
    /// mid-compute, saving ~5 ms of main-actor time a pass; without this, nothing outside the tests
    /// shows whether that fast path fires on a real tree.
    ///
    /// Once per scan, not per pass, so it doesn't bury the log; counts are since launch, since one
    /// scan's passes are too few for a ratio. Split from the logging call so tests can assert the
    /// numbers without a scan fixture or racing the logger's async handoff. Worded for a reader: it
    /// lands in the Activity Log beside `[scan] … completed`.
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
        dropDriveDateNoise: Bool,
        leftTypeFilter: PaneTypeFilter? = nil,
        rightTypeFilter: PaneTypeFilter? = nil,
        leftTypeFilterKeep: Set<String> = [],
        rightTypeFilterKeep: Set<String> = []
    ) -> FilteredState {
        let leftBeforeType = filterTree(rawLeftTree, showHidden: showHidden)
        let rightBeforeType = filterTree(rawRightTree, showHidden: showHidden)
        // The type filter narrows only what each pane shows: it runs after Hidden, on each pane's
        // tree alone, and never touches `differences` below. No filter, no pass.
        let leftTyped = leftTypeFilter.map { PaneTypeFilterPass.apply($0, to: leftBeforeType, keep: leftTypeFilterKeep) }
        let rightTyped = rightTypeFilter.map { PaneTypeFilterPass.apply($0, to: rightBeforeType, keep: rightTypeFilterKeep) }
        let leftTree = leftTyped?.tree ?? leftBeforeType
        let rightTree = rightTyped?.tree ?? rightBeforeType

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
        // `isSyncing`, so a rebuild mid-operation would strip it from every row.
        //
        // **The postcondition is unconditional: every returned row has `isSyncing ==
        // syncingDifferenceIds.contains(id)`, the empty set included.** `applyFilters()` skips its
        // reconcile pass on the strength of it. Skipping this loop on an empty set would instead
        // rest on nothing ever writing `isSyncing` into `rawDifferences`, which nothing enforces,
        // and a break would show a spinner with no operation behind it. So the guard asks only
        // whether the loop is provably a no-op; the extra check is a short-circuiting read, off the
        // main actor.
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
            differences: filteredDifferences,
            leftTreeBeforeTypeFilter: leftBeforeType,
            rightTreeBeforeTypeFilter: rightBeforeType,
            leftTypeFilterFacts: leftTyped?.facts,
            rightTypeFilterFacts: rightTyped?.facts
        )
    }

    /// How many times `resortTreesAndRefilter` has taken a snapshot and sorted it. Test-only, like
    /// `publishedLeftTreeVersion`: a retry that happened looks the same as one that was never
    /// needed, so without the count a test can't tell the interleaving it set up from one that
    /// never occurred. See `aSupersededResortTriesAgainInsteadOfLeavingAPaneOnTheOldOrder`.
    internal private(set) var resortPasses = 0

    /// Called on the main actor by `resortTreesAndRefilter` after it snapshots the trees and before
    /// it suspends into the off-main sort. nil in the app. A test seam, like `paneSearchSnapshot`:
    /// the supersede the retry handles has to land inside that suspension, and `Task.yield()` can't
    /// reliably put it there.
    internal var resortDidSnapshot: (() -> Void)?

    /// Re-sorts both raw trees off the main actor, then refilters.
    ///
    /// **A pass superseded mid-sort tries again rather than giving up**, or a pane is silently left
    /// on the previous sort order. `rawTreeGeneration` moves when a fresh tree is adopted (already
    /// sorted by the current option), but also for `supersedeInFlightPaneWork`, which doesn't hand
    /// every pane a fresh tree: a source or browse-tab switch re-walks only the moving pane, and
    /// the sibling's raw tree keeps the old order with nothing to re-sort it.
    ///
    /// Retrying is safe because each pass publishes only when the generation held still across its
    /// own await, so it never overwrites a newer tree. A retry re-snapshots whatever is current,
    /// sorting an already-sorted tree idempotently, so it is correct whatever moved the generation.
    /// Passes stop once one publishes.
    ///
    /// - Parameter attempts: how many snapshots to try before giving up. Bounded because each pass
    ///   sorts both trees; a progressive load publishes shallow then deep, so two supersedes in a
    ///   row is ordinary and three passes clears it. Giving up leaves the pane on the old order and
    ///   logs a warning.
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
    
    /// Whether any component of `path` begins with a dot. The one filter in
    /// ``computeFilteredState`` that is on by default (`showHiddenFiles` starts false), so it runs
    /// over the whole difference list on every rebuild. `components(separatedBy:)` allocates an
    /// array and a String per component per call: over ~29,000 differences that is ~37 ms a pass,
    /// against ~2 ms for the byte scan below. Most scans find far fewer differences, where both
    /// costs round to nothing, but the large ones recur.
    ///
    /// **The scan can only prove the answer is false, which is what makes it safe.** A component
    /// satisfying `hasPrefix(".")` starts with the byte `0x2E`, so if no component starts with it,
    /// `false` is certain. When the scan finds a candidate the original expression decides, because
    /// the two disagree there: `hasPrefix` compares grapheme clusters, so `"." + U+0301` is one
    /// cluster that isn't `"."` and reads as visible, while a byte scan would call it hidden.
    /// `theScanAgreesWithTheOriginalExpression` pins the equivalence; change the fallback and it
    /// fails.
    ///
    /// The fallback also keeps this agreeing with ``filterTree``, which hides pane rows by
    /// `node.name.hasPrefix(".")`: a byte-only answer would drop such a name from the difference
    /// list while the pane beside it still listed it. Reading UTF-8 is safe because it is
    /// self-synchronising: the bytes for `.` and `/` never occur inside a multi-byte scalar.
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

    /// The left pane's tabs: Browse's strip, and the Organize/Storage rail's, which is the same
    /// pane at 220pt. Seeded with one tab whose provider id is a placeholder the host replaces on
    /// launch; `FileSyncManager` doesn't know which providers exist.
    ///
    /// See `PaneTab` for why the active entry here is a stale snapshot by construction: the live
    /// position is `leftRelativePath` and friends, and this list holds only what is parked.
    @Published public var leftPaneTabs = PaneTabList(single: PaneTab(providerId: ""))
    /// The right pane's tabs — Compare's right-hand side. Independent of the left list; ⇄ swaps
    /// the two wholesale, exactly as it swaps the paths they are lists of.
    @Published public var rightPaneTabs = PaneTabList(single: PaneTab(providerId: ""))

    /// What a pane's search field holds, asked of the host when a tab is parked. A tab owns its
    /// query, but the field is the host's `@State`, and `Sync` can't see `PaneSearchFieldState`
    /// (which also carries a walk index and a reveal nonce derived from a tree the parked tab isn't
    /// showing). So that direction crosses here; the other needs nothing, since every tab verb
    /// returns the tab it applied and the host reads the query off it. Unset outside the app, so
    /// tests of the tab verbs park an empty query.
    public var paneSearchSnapshot: (@MainActor (Bool) -> (query: String, isExpanded: Bool))?
    
    // Navigation and scanning live in the FileSyncManager+Navigation and +Scanning extensions.
    
    /// Resolves one difference by copying or moving the file between the panes: the single-row
    /// sync. On failure it presents a retryable error (`present(retry:)`) that re-invokes this
    /// exact call; bulk syncs go through `syncAll`, which owns the "Apply to all" collision flow
    /// and the progress overlay. An existing destination prompts Replace / Keep Both / Skip before
    /// it is overwritten.
    /// - Parameters:
    ///   - difference: The discrepancy to resolve (from/to paths follow its `action`).
    ///   - isMove: If true, moves the file; otherwise copies.
    ///   - fileManager: Optional override for tests (defaults to `self.fileManager`).
    ///   - confirmed: True when the calling UI already is the user's confirmation for this transfer
    ///     (a Retry click on its failure alert, a review-card accept), so `transferConfirmer` is
    ///     skipped and one gesture never asks twice.
    /// - Returns: Whether the operation ran (Replace, Keep Both or a plain copy); false when the
    ///   user skipped at a collision prompt or it failed. The only reliable "did it happen" signal:
    ///   the post-operation rescan regenerates row UUIDs, so the differences list can't tell
    ///   (guided review records outcomes from this).
    @discardableResult
    /// - Parameter newerDestinationNote: said in the confirmation and the collision prompt: a copy
    ///   sent against the engine's suggestion overwrites the newer file.
    public func syncFile(_ difference: FileDifference, isMove: Bool = false, fileManager: FileManaging? = nil, confirmed: Bool = false,
                         newerDestinationNote: String? = nil) async -> Bool {
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

        // A row that copies from a link is refused even one at a time. The comparison reads the
        // link as what it points to (a folder of 300 items, say), but the copy writes the link
        // itself: the next scan reads both sides through it as in sync, and edits in "the copy"
        // change the originals. No choice of the user's makes that copy right, so unlike the other
        // `HeldBack` cases this one is refused here too, not only in bulk.
        if difference.heldBack == .sourceIsSymbolicLink {
            Logger.shared.info("Sync of \(difference.relativePath) refused: \(fromURL.path) is a symbolic link")
            banner = .refusal("“\(fromURL.lastPathComponent)” is a link, so a copy would be a link too, not what it points to — nothing was \(isMove ? "moved" : "copied")", log: .warn)
            return false
        }

        // Verify All's exclusion guard, mirrored in the write direction: Verify All refuses
        // to START while anything is writing, but a transfer starting MID-verify could still
        // overwrite a file as it's hashed — the pair can read "identical" against bytes that
        // no longer exist, poisoning the copy-to-match-dates offer.
        guard !isVerifyAllRunning else {
            banner = .refusal("Wait for Verify All to finish before syncing", log: .info)
            return false
        }

        // The other half of syncAll's "a single row may be mid-flight" guard. syncAll latches
        // `isBulkSyncRunning` before its confirmation prompt, whose modal spins the run loop, so
        // between the latch and `markSyncing(toSyncIDs)` a queued syncFile for a row in the bulk
        // set would pass the guards above and both flows would handle it. `syncingDifferenceIds` is
        // a set, not a refcount, so whichever defer runs first releases the id the other still
        // owns, and a syncFile parked at its prompt becomes invisible to Verify All's exclusion
        // guard.
        guard !isBulkSyncRunning else {
            banner = .refusal("Wait for the current operation to finish before syncing", log: .info)
            return false
        }

        // Mark the row as syncing before any prompt can hold this call: Verify All's exclusion
        // guard reads `syncingDifferenceIds` so a syncFile parked at a prompt is visible to it (a
        // modal spins the run loop, and a queued Verify All could hash the file this sync is about
        // to overwrite). The defer releases the mark on every exit, so no early return leaks an id,
        // which would refuse Verify All and pane swaps for the session. On success the row is
        // already removed, and clearSyncing on a removed row is a no-op.
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
                destinationDirectory: toURL.deletingLastPathComponent().path,
                newerDestinationNote: newerDestinationNote
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
                isDirectory: isDirectory,
                newerDestinationNote: newerDestinationNote
            ))
            switch resolution {
            case .skip, .merge:
                // A single-row sync never offers Merge; a stray `.merge` gets the safe reading.
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

        // The stat above is stale by the time the operation runs: the collision prompt holds this
        // call indefinitely, and the queue can add more. A file that appears at a destination the
        // stat saw as missing (placeholder hydration, another sync client) would be replaced
        // without its prompt; syncAll's promptShownSinceStatPass loop closes the same gap. So
        // re-stat once right before enqueueing. The window between this stat and the queued
        // operation running is accepted: the operation runs detached, where no prompt is possible.
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
                try Self.ensureParentDirectoryExists(for: resolvedToURL, fileManager: activeFM, mirroring: fromURL)
                
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
                retry: { [weak self] in Task { await self?.syncFile(difference, isMove: isMove, confirmed: true,
                                                                    newerDestinationNote: newerDestinationNote) } }
            )
            return false
        } else {
            Logger.shared.info("Synced file: \(difference.relativePath)")
            if let from = result.from, let to = result.to {
                let actionName = "Sync \(difference.relativePath.components(separatedBy: "/").last ?? "")"
                if isMove {
                    self.registerMoveUndo(items: [(from: from, to: to, overwritten: result.trashed)], actionName: actionName, fileManager: activeFM)
                }
                // Registration is synchronous; the awaited value is the detached identity
                // walk (see `registerCopyUndo(items:)`), so the sync does not report done
                // until its undo is fully armed. One file, so the walk is one stat.
                let identityWalk = isMove ? nil : self.registerCopyUndo(items: [(source: from, destination: to, overwritten: result.trashed)], actionName: actionName, fileManager: activeFM)
                // Durable Sync History. Size comes free from the difference (source side); checksum
                // is nil at op time (see the bulk path's note). Recorded in the registration's own
                // turn, before the await, so the pairing names this sync's group and nothing that
                // lands on the stack during the walk.
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
                await identityWalk?.value
            }
            removeResolvedDifferences(matching: [difference])
            return true
        }
    }

    /// Removes selected paths that no longer exist in the trees (after a move or delete, say) to
    /// avoid ghost selections. A pane whose tree is still loading is skipped: progressive loading
    /// publishes a shallow tree before the deep walk finishes, and pruning against it would wipe a
    /// valid deeper selection.
    ///
    /// Looked up in the per-version path index the action bar uses, so a publish walks each tree
    /// once for both. Skipped outright when the pane has no selection, the common case.
    public func pruneSelection() {
        if !isLoadingLeftTree, !selectedLeftPaths.isEmpty {
            let index = leftNodeIndex()
            let prunedLeft = selectedLeftPaths.filter { index[$0] != nil }
            if prunedLeft != selectedLeftPaths {
                selectedLeftPaths = prunedLeft
            }
        }
        if !isLoadingRightTree, !selectedRightPaths.isEmpty {
            let index = rightNodeIndex()
            let prunedRight = selectedRightPaths.filter { index[$0] != nil }
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

    // File operations live in FileOperations.swift.

    // Diff algorithms live in FileDiffEngine.swift.
}


/// What Try Another says on one card.
public struct FilingTryAnotherNote: Equatable, Sendable {
    public let text: String
    /// This file's folder asks each time, so Try Another used this Mac; the card may offer to send
    /// its first page to Claude, on a click.
    public let offersClaudeWithPage: Bool
    public init(text: String, offersClaudeWithPage: Bool = false) {
        self.text = text
        self.offersClaudeWithPage = offersClaudeWithPage
    }
}

/// One Try Another that reached Claude, for the chat's running line.
public struct FilingTryAnotherReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable { case answered, failed, stopped }
    public let fileName: String
    /// The file's path, so two files of one name count as two; empty where unknown.
    public let filePath: String
    public let outcome: Outcome
    public let costUSD: Double
    public let modelName: String
    public init(fileName: String, filePath: String = "", outcome: Outcome, costUSD: Double, modelName: String) {
        self.fileName = fileName; self.filePath = filePath; self.outcome = outcome; self.costUSD = costUSD; self.modelName = modelName
    }
}
