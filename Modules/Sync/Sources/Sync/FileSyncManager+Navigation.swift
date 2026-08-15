import Events
import Foundation

/// Back/forward stack for one pane's focused relative path. Each pane owns an independent
/// history, so the back button in a pane's header only undoes that pane's navigation.
/// `Sendable` because a parked tab carries one (`PaneTab`), and a public struct's conformance is
/// not inferred across a module boundary the way an internal one's is. Two value fields, no
/// reference types: the conformance is a statement of what this already was.
public struct PaneNavigationHistory: Equatable, Sendable {
    /// Visited relative paths, oldest first. Always contains at least the root entry `""`.
    public private(set) var entries: [String] = [""]
    /// Index of the current entry.
    public private(set) var index: Int = 0

    public init() {}

    public var current: String { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }

    /// Appends `path` as the new current entry, trimming any forward entries first.
    public mutating func push(_ path: String) {
        if index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(path)
        index = entries.count - 1
    }

    /// Steps back one entry; no-op at the oldest entry.
    public mutating func goBack() {
        if canGoBack { index -= 1 }
    }

    /// Steps forward one entry; no-op at the newest entry.
    public mutating func goForward() {
        if canGoForward { index += 1 }
    }

    /// Back to the initial root-only state.
    public mutating func reset() {
        entries = [""]
        index = 0
    }
}

extension FileSyncManager {

    // MARK: - Navigation Methods

    /// Sets the focused subfolder for one pane and appends to that pane's history.
    /// - Parameters:
    ///   - relativePath: Subfolder path relative to the pane root (e.g. `"Documents/Projects"`).
    ///   - isLeft: `true` if the user drilled into this folder from the left pane; `false` for the right pane.
    public func focusOn(relativePath: String, isLeft: Bool) {
        // Already showing this folder in this pane → no-op (mirrors focusBoth), so re-focusing the
        // current folder doesn't stack a duplicate history entry that makes Back appear to stall.
        guard (isLeft ? leftRelativePath : rightRelativePath) != relativePath else { return }
        clearSessionIgnoredPaths()
        // Re-rooting replaces the tree this pane's columns were walking, so the column stack is
        // about to name folders relative to a root that no longer applies. Reset rather than prune:
        // the new tree is a different scope, not a changed one.
        resetBrowsePath(isLeft: isLeft)
        if isLeft {
            leftHistory.push(relativePath)
        } else {
            rightHistory.push(relativePath)
        }
        syncPathsFromHistory()
    }

    /// Sets the focused subfolder for both panes at once (⌥-click on a pane breadcrumb).
    /// Panes already focused on `relativePath` keep their history untouched, so Back in each
    /// pane still undoes exactly that pane's last move. No-op when both panes are already there.
    public func focusBoth(relativePath: String) {
        guard leftRelativePath != relativePath || rightRelativePath != relativePath else { return }
        clearSessionIgnoredPaths()
        // Only the panes that actually move lose their column stack, matching the history rule
        // directly below — a pane already focused there keeps both.
        if leftRelativePath != relativePath { resetBrowsePath(isLeft: true); leftHistory.push(relativePath) }
        if rightRelativePath != relativePath { resetBrowsePath(isLeft: false); rightHistory.push(relativePath) }
        syncPathsFromHistory()
    }

    // MARK: - Column stack

    /// Drops a pane back to its resting single column.
    @MainActor func resetBrowsePath(isLeft: Bool) {
        if isLeft {
            if !leftBrowsePath.isEmpty || leftBrowsePath.canAdvance { leftBrowsePath.reset() }
        } else {
            if !rightBrowsePath.isEmpty || rightBrowsePath.canAdvance { rightBrowsePath.reset() }
        }
    }

    /// A pane's location as one path: its comparison scope joined with where it is browsing.
    ///
    /// The two are separate state on purpose (see `PaneBrowsePath`), but that is an implementation
    /// distinction, not something to make the user hold. The header's path line renders this, so
    /// walking into a column moves the breadcrumb exactly as re-rooting does — one location, one
    /// readout, and no way for the header to describe a folder the pane is not showing.
    public func combinedRelativePath(isLeft: Bool) -> String {
        let focus = isLeft ? leftRelativePath : rightRelativePath
        let browse = (isLeft ? leftBrowsePath : rightBrowsePath).relativePath
        if focus.isEmpty { return browse }
        if browse.isEmpty { return focus }
        return focus + "/" + browse
    }

    /// Routes a click on that joined path back to whichever half owns it.
    ///
    /// A crumb inside the scope is a browse move — cheap, no rescan. A crumb *above* the scope is
    /// the only way back out, so it re-roots. Without this split, clicking an ancestor while three
    /// columns deep would either do nothing or re-scan for a folder you were already looking at.
    @MainActor public func navigatePane(isLeft: Bool, toCombinedPath combined: String) {
        let focus = isLeft ? leftRelativePath : rightRelativePath
        let side = isLeft ? "left" : "right"
        // Logged because this whole routing was previously silent: a crumb click that navigated
        // nowhere left not one line behind, which is what let a dead root crumb go unexplained.
        let target = combined.isEmpty ? "root" : combined
        if focus.isEmpty {
            Logger.shared.debug("[crumb] \(side) pane browses to \(target) (scope at root)")
            setBrowsePath(isLeft: isLeft, PaneBrowsePath(relativePath: combined))
        } else if combined == focus {
            Logger.shared.debug("[crumb] \(side) pane returns to its scope \(target)")
            setBrowsePath(isLeft: isLeft, PaneBrowsePath())
        } else if combined.hasPrefix(focus + "/") {
            Logger.shared.debug("[crumb] \(side) pane browses to \(target) inside scope \(focus)")
            setBrowsePath(isLeft: isLeft, PaneBrowsePath(relativePath: String(combined.dropFirst(focus.count + 1))))
        } else {
            // Above the comparison scope — genuinely a re-root, history and all.
            Logger.shared.debug("[crumb] \(side) pane re-roots to \(target) from scope \(focus)")
            focusOn(relativePath: combined, isLeft: isLeft)
        }
    }

    /// The both-panes form of `navigatePane`: the ⌥-click, and every plain crumb click while the
    /// seam link is on.
    ///
    /// It must route **each pane through its own halves**, which is precisely what `focusBoth` —
    /// the call this replaced — could not do. `focusBoth` compares only the focus paths, so with
    /// both panes scoped at their root (the normal state: you walk into folders by clicking
    /// columns, which never re-roots) a click on the root crumb asked it to focus `""` while both
    /// panes already *were* focused on `""`, and its guard returned. The crumb was dead: three
    /// columns deep with the panes linked, the only way back out was `‹`, one column at a time.
    /// Every other crumb "worked" by re-rooting both panes — a tree reload and a full rescan for a
    /// folder the panes were already showing.
    ///
    /// Routing each side through `navigatePane` fixes both halves at once: a crumb inside a pane's
    /// scope moves its columns, a crumb above it re-roots that pane, and the two decisions are made
    /// independently because the panes' scopes need not agree.
    ///
    /// `otherIndex` prunes the sibling's new stack against the tree it actually has — the same
    /// honesty a mirrored column drill applies (see `applyColumnNavigation`), since the two sides
    /// are being compared precisely because they differ. It is an autoclosure so the common case
    /// that lands both panes at their root never pays for building the index.
    @MainActor public func navigateBothPanes(
        toCombinedPath combined: String,
        from isLeft: Bool,
        otherIndex: @autoclosure () -> PaneChildrenIndex,
        otherTreeRoot: String
    ) {
        let otherFocusBefore = isLeft ? rightRelativePath : leftRelativePath
        navigatePane(isLeft: isLeft, toCombinedPath: combined)
        navigatePane(isLeft: !isLeft, toCombinedPath: combined)

        // Only a browse move can be pruned here. If the sibling re-rooted, its tree is being
        // reloaded and `otherTreeRoot`/`otherIndex` describe the tree it just left — the prune that
        // runs on the next republish is the one that applies.
        guard (isLeft ? rightRelativePath : leftRelativePath) == otherFocusBefore,
              !(isLeft ? rightBrowsePath : leftBrowsePath).isEmpty else { return }
        pruneBrowsePath(isLeft: !isLeft, against: otherIndex(), treeRoot: otherTreeRoot)
    }

    /// Sets a pane's column stack outright. Public because the mirroring decision needs both
    /// panes' children indices, which only the app layer holds.
    @MainActor public func setBrowsePath(isLeft: Bool, _ path: PaneBrowsePath) {
        if isLeft {
            if leftBrowsePath != path { leftBrowsePath = path }
        } else {
            if rightBrowsePath != path { rightBrowsePath = path }
        }
    }

    /// Applies a column drill, optionally mirroring it onto the sibling pane.
    ///
    /// The mirror is *pruned* against the other pane's tree rather than copied outright. The two
    /// sides are being compared precisely because they differ, so a folder opened on one may not
    /// exist on the other; pruning walks that pane as deep as it genuinely can and stops. That
    /// lands it on the deepest folder the two still share, instead of on an empty column claiming a
    /// folder that isn't there — and a pane that shares nothing simply returns to its root column.
    ///
    /// `mirror` is decided by the caller because it depends on the seam link, the ⌥ key and the
    /// layout, none of which belong down here.
    ///
    /// `otherIndex` is an autoclosure so an unmirrored click doesn't pay for it. Swift evaluates
    /// arguments eagerly, so the plain parameter ran the caller's
    /// `rightChildrenIndex(treeRoot:)` on **every** column click — and that is a cache miss, i.e. a
    /// full walk of the other pane's ~40k-node tree, whenever that pane is in Tree mode (nothing
    /// else warms its index there) and its tree has republished since the last click. That is
    /// main-thread work inside the click handler, spent on a mirror the seam link had switched off.
    @MainActor public func applyColumnNavigation(
        _ path: PaneBrowsePath,
        isLeft: Bool,
        mirror: Bool,
        otherIndex: @autoclosure () -> PaneChildrenIndex,
        otherTreeRoot: String
    ) {
        let side = isLeft ? "left" : "right"
        let from = (isLeft ? leftBrowsePath : rightBrowsePath).depth
        setBrowsePath(isLeft: isLeft, path)
        guard mirror else {
            // Columns navigation logged NOTHING until now, which is why the log covering the two
            // 2026-07-27 layout crashes was silent for the 80 minutes leading up to one of them:
            // walking columns writes no history entry and runs no scan, so not one line was left
            // behind describing what the user was actually doing.
            Logger.shared.debug("[columns] \(side) pane depth \(from) → \(path.depth) at \(path.relativePath.isEmpty ? "root" : path.relativePath)")
            return
        }
        // The mirror is the expensive half: `pruned` walks the other pane's children index, and
        // building that index is a full pass over its tree when the cache is cold.
        let started = CFAbsoluteTimeGetCurrent()
        let mirrored = path.pruned(against: otherIndex(), treeRoot: otherTreeRoot)
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        setBrowsePath(isLeft: !isLeft, mirrored)
        Logger.shared.debug(
            "[columns] \(side) pane depth \(from) → \(path.depth) at \(path.relativePath.isEmpty ? "root" : path.relativePath); "
            + "mirrored to depth \(mirrored.depth) in \(String(format: "%.1fms", elapsed))")
    }

    /// Re-resolves a pane's column stack against a freshly published tree, dropping any trailing
    /// folders that no longer exist.
    ///
    /// Must run on every republish. The stack is folder names resolved against a tree that has just
    /// been rebuilt, so a folder deleted here — externally, or by the user's own Delete — would
    /// otherwise leave columns rendering nothing while `currentDirectory` still names it, which is
    /// where New Folder and paste would then act. Assigns only on a real change so an unaffected
    /// stack costs no publish.
    ///
    /// **Never against a tree that is not loaded.** An empty tree is not the answer "these folders
    /// are gone" — it is "there is nothing to ask yet", and pruning against it can only ever return
    /// the root. `invalidateComparisonState` drops both trees synchronously, so every caller that
    /// re-points a pane publishes an empty tree one view update before the reload refills it; the
    /// republish prune then fires on that empty publish and flattens a stack that was perfectly
    /// valid. That is what made **every browse-tab switch land the pane back at its root**: the
    /// switch restores the outgoing tab's column stack, and the prune wiped it before the tree the
    /// stack belongs to had finished loading.
    ///
    /// `lastLoadedFocusPath` is the discriminator, and it is exactly the one needed: set when a
    /// walk completes, cleared by `invalidateComparisonState`. So a tree that is genuinely empty
    /// because its root has no children still prunes — that is a real answer — while a tree that is
    /// empty because it was dropped does not. `pruneSelection` skips a loading pane for the same
    /// reason, and predates this by long enough that the omission here was plainly an oversight
    /// rather than a decision.
    @MainActor public func pruneBrowsePath(isLeft: Bool, against index: PaneChildrenIndex, treeRoot: String) {
        // **Both halves of `pruneSelection`'s guard, and the second is not optional.** Progressive
        // loading publishes a SHALLOW tree — the root's children and nothing under them — before the
        // deep walk finishes, and that publish sets `lastLoadedFocusPath` like any other. Guarding
        // on the marker alone therefore still prunes, just against a tree one level deep: the stack
        // collapses to its first component instead of to the root. That is not a smaller version of
        // the bug, it is the same bug wearing a plausible answer, and it is what shipped when only
        // half of this guard was copied across.
        guard (isLeft ? lastLoadedLeftFocusPath : lastLoadedRightFocusPath) != nil,
              !(isLeft ? isLoadingLeftTree : isLoadingRightTree) else { return }
        if isLeft {
            let pruned = leftBrowsePath.pruned(against: index, treeRoot: treeRoot)
            if pruned != leftBrowsePath { leftBrowsePath = pruned }
        } else {
            let pruned = rightBrowsePath.pruned(against: index, treeRoot: treeRoot)
            if pruned != rightBrowsePath { rightBrowsePath = pruned }
        }
    }

    /// Whether this pane's `‹` has anywhere to go — the column stack first, then the focus history.
    ///
    /// One button, one meaning: "undo my last navigation". A pane can be three columns deep without
    /// having re-rooted once, so gating the arrow on the focus history alone left it dead exactly
    /// where the Columns view leans on it hardest — in a narrow pane, where the single column
    /// replaces its contents and `‹` is the only way back out.
    public func canGoBack(isLeft: Bool) -> Bool {
        let browse = isLeft ? leftBrowsePath : rightBrowsePath
        return !browse.isEmpty || (isLeft ? leftHistory : rightHistory).canGoBack
    }

    /// Counterpart of `canGoBack(isLeft:)`. Forward walks back into a column `‹` stepped out of
    /// before it considers the focus history, so the two arrows stay each other's inverse.
    public func canGoForward(isLeft: Bool) -> Bool {
        let browse = isLeft ? leftBrowsePath : rightBrowsePath
        return browse.canAdvance || (isLeft ? leftHistory : rightHistory).canGoForward
    }

    /// Navigates one pane back: out of a column if it is inside one, otherwise to the previous
    /// entry in its own focus history.
    @MainActor public func goBack(isLeft: Bool) {
        // Columns first. Browsing costs no history entry (it never re-roots), so if the pane is
        // inside a column stack that is unambiguously the most recent navigation to undo.
        //
        // Deliberately returns WITHOUT `clearSessionIgnoredPaths()`: that clear belongs to a change
        // of comparison scope, and stepping out of a column changes only where you are looking. An
        // item ignored for this session stays ignored while you walk around.
        if isLeft ? leftBrowsePath.popLast() : rightBrowsePath.popLast() {
            let browse = isLeft ? leftBrowsePath : rightBrowsePath
            Logger.shared.debug("Stepped \(isLeft ? "left" : "right") pane out to column depth \(browse.depth)")
            return
        }
        if isLeft {
            guard leftHistory.canGoBack else { return }
            leftHistory.goBack()
        } else {
            guard rightHistory.canGoBack else { return }
            rightHistory.goBack()
        }
        clearSessionIgnoredPaths()
        let pane = isLeft ? "left" : "right"
        let target = (isLeft ? leftHistory : rightHistory).current
        Logger.shared.info("User navigated \(pane) pane back to \(target.isEmpty ? "root" : target)")
        syncPathsFromHistory()
    }

    /// Navigates one pane forward: back into a column `‹` stepped out of, otherwise to the next
    /// entry in its own focus history. The inverse of `goBack(isLeft:)`, in the same order.
    @MainActor public func goForward(isLeft: Bool) {
        if isLeft ? leftBrowsePath.advance() : rightBrowsePath.advance() {
            let browse = isLeft ? leftBrowsePath : rightBrowsePath
            Logger.shared.debug("Stepped \(isLeft ? "left" : "right") pane into column depth \(browse.depth)")
            return
        }
        if isLeft {
            guard leftHistory.canGoForward else { return }
            leftHistory.goForward()
        } else {
            guard rightHistory.canGoForward else { return }
            rightHistory.goForward()
        }
        clearSessionIgnoredPaths()
        let pane = isLeft ? "left" : "right"
        let target = (isLeft ? leftHistory : rightHistory).current
        Logger.shared.info("User navigated \(pane) pane forward to \(target.isEmpty ? "root" : target)")
        syncPathsFromHistory()
    }

    /// Resets both panes to root, clears selection, resets both history stacks, and drops all
    /// comparison state. Called when a pane's provider changes: differences and trees scanned
    /// against the old roots carry absolute paths and copy directions that no longer match what
    /// the panes claim to show, so leaving them clickable until the rescan lands (seconds on
    /// network volumes) misdirects sync arrows and context-menu copy/move targets.
    @MainActor public func resetNavigation() {
        Logger.shared.info("User reset navigation to root.")
        invalidateComparisonState()
        clearSessionIgnoredPaths()
        if !selectedLeftPaths.isEmpty { selectedLeftPaths = [] }
        if !selectedRightPaths.isEmpty { selectedRightPaths = [] }

        if leftHistory != PaneNavigationHistory() { leftHistory.reset() }
        if rightHistory != PaneNavigationHistory() { rightHistory.reset() }
        // Both trees are about to be replaced by ones from different roots; a column stack naming
        // folders in the old ones is meaningless, not merely stale.
        resetBrowsePath(isLeft: true)
        resetBrowsePath(isLeft: false)
        syncPathsFromHistory()
    }

    /// Drops every piece of state that is only meaningful for the pane roots it was built
    /// against: differences (raw and published), checksum-verification results, both pane
    /// trees, and the scanned flag — synchronously, so no observer ever sees rows for roots
    /// the panes no longer show. Also supersedes in-flight loads, scans, and filter passes,
    /// which hold pre-change snapshots and must not publish over the cleared state. Call
    /// whenever a pane's provider or its root path changes; the caller's rescan repopulates
    /// (with `hasScanned` false and `differences` empty the UI shows "No Scan Performed",
    /// never a false "Everything is in sync").
    /// - Parameter keepingPrefetchedTrees: retain the fast-path cache. **Only correct when the pane
    ///   roots are unchanged** — a move *within* one root, where every cached subtree still
    ///   describes the same folders on the same disk. A tab switch is that: the cache is keyed by
    ///   absolute path, and serving the arriving focus from it is the same fast path breadcrumb and
    ///   drill-down navigation already take, which is why those are instant and a tab switch was
    ///   not. Clearing it there threw away the one thing that could make the switch free, and cost
    ///   a ~100ms disk walk to rebuild a tree that was already in memory. Default `false`, because
    ///   a *root* change genuinely does make the cache dead weight.
    @MainActor public func invalidateComparisonState(keepingPrefetchedTrees: Bool = false) {
        // Keyed by absolute path, so it survives exactly as far as the roots do.
        if !keepingPrefetchedTrees { prefetchedTrees.removeAll() }
        rawLeftTree = []
        rawRightTree = []
        if !leftTree.isEmpty { leftTree = [] }
        if !rightTree.isEmpty { rightTree = [] }
        if leftItemCount != 0 { leftItemCount = 0 }
        if rightItemCount != 0 { rightItemCount = 0 }
        lastLoadedLeftFocusPath = nil
        lastLoadedRightFocusPath = nil

        // The differences half (plus the in-flight supersedence and the fresh filter pass) is
        // shared with the retarget-only invalidation below; everything runs in this one
        // synchronous main-actor block, so no observer can see a half-cleared intermediate.
        invalidateDifferencesForPaneRetarget()
    }

    /// The differences-only subset of `invalidateComparisonState`: drops the published diff
    /// results — differences (raw and published), checksum-verification results, the pending
    /// copy-identical offer, and the scan-freshness fields — and supersedes in-flight loads,
    /// scans, and filter passes, WITHOUT touching the pane trees, navigation, selections, or
    /// any lens state (`duplicateGroups` et al. survive untouched).
    ///
    /// For the suppressed provider-change paths (the Duplicates lens's "Compare copies" hand-off and its
    /// restore): those repoint both panes while deliberately suppressing the provider-id
    /// onChange — the full reset there would wipe the duplicate results the user must be
    /// able to return to (see `pendingSwapProviderChanges`) — but skipping ALL invalidation
    /// left the OLD comparison's differences published and actionable during the re-scan
    /// window (`isScanning` false while trees load), where a row click ran syncFile on
    /// absolute paths from roots the panes no longer show. Call this synchronously before the
    /// re-focus + refresh; the rescan repopulates (with `hasScanned` false and `differences`
    /// empty the UI shows "No Scan Performed", never a false "Everything is in sync").
    @MainActor public func invalidateDifferencesForPaneRetarget() {
        supersedeInFlightPaneWork()
        rawDifferences = []
        if !differences.isEmpty { differences = [] }
        verifiedSameDifferenceIds.removeAll()
        verifiedIdenticalForCopy = nil
        lastRightProviderType = nil
        lastScanProviders = nil
        lastScanRootNames = nil
        lastScanDate = nil
        if hasScanned { hasScanned = false }

        // A filter pass that snapshotted state before this clear may still publish after it.
        // Start a fresh pass over the cleared raws: its newer generation supersedes the stale
        // one, so any resurrection is corrected within one (in-memory, ms-scale) pass.
        Task { await self.applyFilters() }
    }

    /// Cancels/supersedes work in flight for the current pane orientation and roots: per-pane
    /// tree loads (cancelled, and their spinner-cleanup tokens invalidated), a pending or
    /// running scan (its publish is generation-gated), and any off-main resort snapshot.
    @MainActor private func supersedeInFlightPaneWork() {
        activeLoadLeftTask?.cancel()
        activeLoadRightTask?.cancel()
        leftLoadGeneration += 1
        rightLoadGeneration += 1
        rawTreeGeneration += 1
        scanRequestGeneration += 1
        pendingScanRequest = nil
        // The next refresh must supersede any in-flight one, never dedupe against it: that
        // refresh's loads were just cancelled and its scan publish gated off, so treating a
        // same-target follow-up as a duplicate would leave the cleared panes blank.
        noteScanConfigChanged()
    }

    /// Swaps the left and right panes wholesale: focused relative paths, selections, each
    /// pane's navigation history, both trees (raw and published) with their counts and
    /// loading/focus bookkeeping, and every difference — remapped via `FileDifference.mirrored()`
    /// so paths, sizes, direction arrows, and actions all flip with the pane labels. Everything
    /// moves in one synchronous update, so observers never see a half-swapped intermediate
    /// (e.g. flipped column labels over rows whose arrows still point the pre-swap way).
    ///
    /// Refused (returns `false`, with a warning banner) while any file operation or sync is in
    /// flight: those operations captured pre-swap paths and directions, and remapping the rows
    /// under them would show arrows that no longer match what the running operation does.
    /// Also refused during Verify All: a run completing after the swap would publish a
    /// `verifiedIdenticalForCopy` offer built from pre-swap differences, and the follow-up
    /// copy would run in the pre-swap direction under mismatched labels.
    ///
    /// The provider ids live in @AppStorage (ContentView) and are swapped there in lockstep;
    /// this method owns only the manager's paired @Published state. It does not itself trigger
    /// a rescan — the caller drives the single post-swap refresh once the provider ids are
    /// swapped too.
    @MainActor @discardableResult public func swapPanes() -> Bool {
        guard activeFileOperationsCount == 0,
              !isBulkSyncRunning,
              bulkSyncProgress == nil,
              !isVerifyAllRunning,
              syncingDifferenceIds.isEmpty else {
            // `isBulkSyncRunning` is set at the very start of syncAll — before markSyncing and
            // bulkSyncProgress — so it's the only flag up during the confirm-prompt window, where
            // a swap would mirror the rows out from under a snapshot the running sync still holds.
            Logger.shared.warning("Ignored pane swap while file operations are in flight")
            banner = .warning("Can't swap panes while an operation is running")
            return false
        }
        Logger.shared.info("User swapped the left and right panes")

        // In-flight loads/scans/filter passes were built for the pre-swap orientation and
        // must not publish over the swapped state; the caller's refresh rebuilds them.
        supersedeInFlightPaneWork()

        swap(&leftRelativePath, &rightRelativePath)
        swap(&selectedLeftPaths, &selectedRightPaths)
        // Travels with the selection: the pane the user was working in is now the other one, and
        // a focused side left behind aims ⌘F, ⌘[ and ⇧⌘N at the pane their content just left.
        // `nil` stays nil — with focus still implicit the fallback reads the selection, which the
        // line above has already moved.
        focusedPaneSide = focusedPaneSide?.opposite

        swap(&leftHistory, &rightHistory)
        // Travels with the tree it indexes, like the history beside it: after a swap the left pane
        // shows what the right one did, so it must be looking at the same folder within it.
        swap(&leftBrowsePath, &rightBrowsePath)
        // **The two LISTS swap, not the two active tabs.** ⇄ already moves each pane's location
        // wholesale to the other side, and a tab list is a list of locations for one pane — so
        // moving the pane without its parked tabs would leave a strip whose other tabs belong to
        // the folder tree that just left. The active entries stay correct by construction: each is
        // a snapshot of the pane it travelled with.
        swap(&leftPaneTabs, &rightPaneTabs)

        swap(&rawLeftTree, &rawRightTree)
        swap(&leftTree, &rightTree)
        swap(&leftItemCount, &rightItemCount)
        swap(&lastLoadedLeftFocusPath, &lastLoadedRightFocusPath)
        swap(&isLoadingLeftTree, &isLoadingRightTree)

        // Remap rather than clear: the scan results stay valid after a swap (same folders,
        // same files), only their side labels flip — and remapping keeps the list actionable
        // instead of flashing empty until the rescan lands (seconds on network volumes).
        rawDifferences = rawDifferences.map { $0.mirrored() }
        differences = differences.map { $0.mirrored() }
        // verifiedSameDifferenceIds survives deliberately: mirrored() preserves ids and
        // checksum equality is symmetric. The pending copy-identical offer does not — its
        // captured differences and left→right wording are pre-swap.
        verifiedIdenticalForCopy = nil
        // The Drive date-noise filter is right-pane-specific; the provider just changed sides,
        // and the post-swap rescan re-learns the new right pane's type.
        lastRightProviderType = nil
        // The name-check provider pair stays valid across a swap — same two roots — but its
        // side labels flip with everything else. Same for the Path column's root names.
        lastScanProviders = lastScanProviders.map { ($0.right, $0.left) }
        lastScanRootNames = lastScanRootNames.map { ($0.right, $0.left) }

        // Same stale-filter-pass insurance as invalidateComparisonState: a pass holding a
        // pre-swap snapshot may publish after this method; a fresh pass over the swapped
        // raws supersedes it within one in-memory recompute.
        Task { await self.applyFilters() }
        return true
    }

    /// Publishes each pane's current history entry into its relative path and triggers a refresh.
    func syncPathsFromHistory() {
        if leftRelativePath != leftHistory.current { leftRelativePath = leftHistory.current }
        if rightRelativePath != rightHistory.current { rightRelativePath = rightHistory.current }
        refreshSubject.send()
    }

}
