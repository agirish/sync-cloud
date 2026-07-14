import Events
import Foundation

/// Back/forward stack for one pane's focused relative path. Each pane owns an independent
/// history, so the back button in a pane's header only undoes that pane's navigation.
public struct PaneNavigationHistory: Equatable {
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
        if leftRelativePath != relativePath { leftHistory.push(relativePath) }
        if rightRelativePath != relativePath { rightHistory.push(relativePath) }
        syncPathsFromHistory()
    }

    /// Navigates one pane to the previous entry in its own history stack.
    @MainActor public func goBack(isLeft: Bool) {
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

    /// Navigates one pane to the next entry in its own history stack.
    @MainActor public func goForward(isLeft: Bool) {
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
    @MainActor public func invalidateComparisonState() {
        supersedeInFlightPaneWork()
        // Drop the prefetch cache too (keyed by absolute path): after a provider/root change the
        // old root's fully-walked tree is dead weight, and this method documents clearing "both
        // pane trees" — the fast-path cache is part of that state and its rescan repopulates it.
        prefetchedTrees.removeAll()
        rawLeftTree = []
        rawRightTree = []
        if !leftTree.isEmpty { leftTree = [] }
        if !rightTree.isEmpty { rightTree = [] }
        if leftItemCount != 0 { leftItemCount = 0 }
        if rightItemCount != 0 { rightItemCount = 0 }
        lastLoadedLeftFocusPath = nil
        lastLoadedRightFocusPath = nil

        rawDifferences = []
        if !differences.isEmpty { differences = [] }
        verifiedSameDifferenceIds.removeAll()
        verifiedIdenticalForCopy = nil
        lastRightProviderType = nil
        lastScanProviders = nil
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
        swap(&leftHistory, &rightHistory)

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
        // side labels flip with everything else.
        lastScanProviders = lastScanProviders.map { ($0.right, $0.left) }

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
