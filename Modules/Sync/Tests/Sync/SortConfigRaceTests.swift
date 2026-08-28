import Foundation
import Testing
@testable import Sync

/// Pins the machinery that keeps sort changes, in-flight loads, and refresh dedupe
/// consistent with each other:
/// - `publishedLeftTreeVersion`/`publishedRightTreeVersion` bump via `didSet` on EVERY
///   write to the published trees, so `applyFilters`' off-main equality verdicts can
///   detect any mid-flight write — including ones from code that knows nothing about
///   the mechanism.
/// - `RefreshKey` carries the scan-config epoch, so a refresh requested after a
///   scan-affecting change (Tags sort, date tolerance, auto-verify, an invalidation, a
///   file operation) supersedes an in-flight same-target refresh instead of being
///   swallowed by the duplicate-refresh dedupe.
/// - `adoptFreshDeepTree` re-sorts a deep tree whose walk captured a since-changed sort
///   option, and never caches it (a cached tree is served verbatim, so a stale-mode tree
///   would poison the cache — for Tags, with no way to recover the missing metadata).
@Suite struct SortConfigRaceTests {

    private func node(_ name: String, size: Int? = nil) -> FileNode {
        FileNode(id: "/root/\(name)", name: name, isDirectory: false, fileSize: size)
    }

    // MARK: - Published-tree version contract

    @MainActor
    @Test func testPublishedTreeVersionsBumpOnEveryWrite() {
        let manager = FileSyncManager(fileManager: MockFileManager())

        let l0 = manager.publishedLeftTreeVersion
        let r0 = manager.publishedRightTreeVersion

        // A direct external assignment — the write pattern the manual-bump design missed.
        manager.leftTree = [node("a.txt")]
        #expect(manager.publishedLeftTreeVersion == l0 + 1)
        #expect(manager.publishedRightTreeVersion == r0)

        manager.rightTree = [node("b.txt")]
        #expect(manager.publishedRightTreeVersion == r0 + 1)

        // swap() writes both properties; both versions must move.
        let l1 = manager.publishedLeftTreeVersion
        let r1 = manager.publishedRightTreeVersion
        #expect(manager.swapPanes())
        #expect(manager.publishedLeftTreeVersion > l1)
        #expect(manager.publishedRightTreeVersion > r1)
    }

    @MainActor
    @Test func testInvalidateComparisonStateBumpsVersionsViaClear() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.leftTree = [node("a.txt")]
        manager.rightTree = [node("b.txt")]

        let l = manager.publishedLeftTreeVersion
        let r = manager.publishedRightTreeVersion
        manager.invalidateComparisonState()
        #expect(manager.publishedLeftTreeVersion == l + 1)
        #expect(manager.publishedRightTreeVersion == r + 1)
        #expect(manager.leftTree.isEmpty)
    }

    // MARK: - Refresh dedupe vs. config changes

    private func providers() -> (CloudProvider, CloudProvider) {
        (
            CloudProvider(id: "l", displayName: "Left", imageName: "folder", rootPath: "/left", type: .iCloud),
            CloudProvider(id: "r", displayName: "Right", imageName: "folder", rootPath: "/right", type: .iCloud)
        )
    }

    @MainActor
    @Test func testRefreshKeyIsStableWhileNothingChanges() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let (left, right) = providers()
        // The launch bootstrap depends on identical back-to-back refreshes deduping.
        #expect(manager.makeRefreshKey(left: left, right: right) == manager.makeRefreshKey(left: left, right: right))
    }

    @MainActor
    @Test func testScanAffectingChangesChangeTheRefreshKey() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let (left, right) = providers()

        var previous = manager.makeRefreshKey(left: left, right: right)
        func expectKeyMoved(_ what: String) {
            let current = manager.makeRefreshKey(left: left, right: right)
            #expect(current != previous, "expected \(what) to change the refresh key")
            previous = current
        }

        manager.dateToleranceSeconds = 42
        expectKeyMoved("date tolerance")

        manager.autoVerifySameSizeDuringScan = true
        expectKeyMoved("auto-verify toggle")

        manager.sortOption = .tags
        expectKeyMoved("switch to the Tags sort")

        // A non-tags sort change re-sorts in memory — no reload is requested, so the key
        // may stay; what matters is invalidation superseding:
        manager.invalidateComparisonState()
        expectKeyMoved("comparison-state invalidation")
    }

    @MainActor
    @Test func testOnlyTagsSortChangeRequestsAReload() {
        let manager = FileSyncManager(fileManager: MockFileManager())

        let before = manager.scanConfigGeneration
        manager.sortOption = .size
        #expect(manager.scanConfigGeneration == before, "in-memory resort must not invalidate in-flight refreshes")

        manager.sortOption = .tags
        #expect(manager.scanConfigGeneration > before, "the Tags sort needs a from-disk reload; its refresh must supersede")
    }

    // MARK: - Stale-sort deep-tree adoption

    @MainActor
    @Test func testStaleSortDeepTreeIsResortedToLiveOptionAndNotCached() async {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.sortOption = .size

        // A walk that started under .name (ascending by name = ascending by size here,
        // i.e. the wrong order for .size, which sorts descending).
        let staleTree = [node("a.txt", size: 1), node("b.txt", size: 2), node("c.txt", size: 3)]
        await manager.adoptFreshDeepTree(staleTree, builtWith: .name, isLeft: true, focusPath: "/root",
                                         loadToken: manager.leftLoadGeneration, configToken: manager.scanConfigGeneration)

        #expect(manager.leftTree.map(\.name) == ["c.txt", "b.txt", "a.txt"], "published tree must follow the LIVE sort option")
        #expect(manager.prefetchedTrees["/root"] == nil, "a stale-mode tree must never enter the cache")
    }

    @MainActor
    @Test func testCurrentSortDeepTreeIsCached() async {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.sortOption = .size

        let tree = [node("c.txt", size: 3), node("b.txt", size: 2)]
        await manager.adoptFreshDeepTree(tree, builtWith: .size, isLeft: true, focusPath: "/root",
                                         loadToken: manager.leftLoadGeneration, configToken: manager.scanConfigGeneration)

        #expect(manager.leftTree.map(\.name) == ["c.txt", "b.txt"])
        #expect(manager.prefetchedTrees["/root"] != nil, "a current-mode deep tree still feeds the cache")
    }

    /// A file operation (or any scan-affecting change) finishing while a load runs bumps the
    /// scan-config epoch and clears the cache; a tree walked BEFORE that change must not write
    /// itself back — the cache fast path serves cached trees verbatim, so it would present
    /// pre-operation state as current until the next invalidation.
    @MainActor
    @Test func testStaleConfigEpochTreeNeverEntersCache() async {
        let manager = FileSyncManager(fileManager: MockFileManager())

        let staleConfigToken = manager.scanConfigGeneration
        manager.noteScanConfigChanged()   // a file operation landed while this load's walk ran

        await manager.adoptFreshDeepTree([node("a.txt", size: 1)], builtWith: .name, isLeft: true,
                                         focusPath: "/root",
                                         loadToken: manager.leftLoadGeneration, configToken: staleConfigToken)

        #expect(manager.leftTree.map(\.name) == ["a.txt"], "the tree itself still publishes — only the cache is off-limits")
        #expect(manager.prefetchedTrees["/root"] == nil, "a pre-operation tree must never resurrect the cleared cache")
    }

    // MARK: - A superseded re-sort

    /// **A re-sort superseded mid-flight tries again, instead of leaving a pane on the old order.**
    ///
    /// `resortTreesAndRefilter` snapshots both raw trees, sorts them off the main actor, and
    /// publishes only if `rawTreeGeneration` held still. Giving up was right while every supersede
    /// came with fresh, correctly-ordered trees for BOTH panes. It stopped being right when
    /// invalidation became pane-scoped: `retargetPane` (a source switch) and `applyTab` (a browse
    /// tab switch) bump the generation via `supersedeInFlightPaneWork` while re-walking only the
    /// pane that moved, so the sibling's raw tree survives — ordered by the option the discarded
    /// sort was replacing, with nothing to correct it until that pane next reloads.
    ///
    /// Driven through `sortOption`'s own `didSet`, because that is the only thing that starts one of
    /// these in the app, and interleaved through `resortDidSnapshot` — the seam that fires between
    /// the snapshot and the suspension, which is the only window in which the supersede reproduces
    /// the bug. **A `Task.yield()` was tried first and did not hold**: the resort had not taken its
    /// turn, so the retarget landed BEFORE the snapshot, the first pass was never superseded, and
    /// the trees came out sorted for the wrong reason.
    ///
    /// **The `resortPasses` assertion is what stops this proving nothing**, and it is what caught
    /// that. Both worlds — retry-saved and never-superseded — end with identical trees; only the
    /// pass count tells them apart, so it is asserted alongside the ordering rather than trusted.
    @MainActor
    @Test func aSupersededResortTriesAgainInsteadOfLeavingAPaneOnTheOldOrder() async {
        let manager = FileSyncManager(fileManager: MockFileManager())
        // The RIGHT pane is the survivor: name order, which for these sizes is the exact reverse of
        // `.size` (descending), so a pane left on the old option is unmistakable.
        manager.rawRightTree = [node("a.txt", size: 1), node("b.txt", size: 2), node("c.txt", size: 3)]
        manager.rightTree = manager.rawRightTree

        // The source switch, fired from inside the sort's own window. It drops the LEFT pane's tree
        // and re-walks only the left, so the right pane's tree is the one nothing else will put
        // right. Armed for the FIRST pass only — leaving it installed would supersede the retry too
        // and measure the give-up path instead.
        var supersededOnce = false
        manager.resortDidSnapshot = { [weak manager] in
            guard !supersededOnce, let manager else { return }
            supersededOnce = true
            manager.retargetPane(isLeft: true, landing: "")
        }

        let passesBefore = manager.resortPasses
        manager.sortOption = .size          // the didSet enqueues the re-sort

        await waitUntil("the re-sort published") { manager.rightTree.first?.name == "c.txt" }
        #expect(supersededOnce, "the seam never fired, so no re-sort was superseded and this proves nothing")
        #expect(manager.resortPasses - passesBefore >= 2,
                "the pass was not superseded, so this measured a first pass that succeeded on its own — it proves nothing about the retry")
        #expect(manager.rawRightTree.map(\.name) == ["c.txt", "b.txt", "a.txt"],
                "the pane that was not re-walked kept the previous sort order")
        #expect(manager.rightTree.map(\.name) == ["c.txt", "b.txt", "a.txt"],
                "the raw tree was re-sorted but never republished through applyFilters")
    }

    /// The bound is real: a pass that keeps being superseded stops rather than spinning.
    ///
    /// `attempts: 1` is the smallest case of "every publish loses", and it is also the shape the old
    /// code had — so this pins what giving up now costs, which is exactly what it always cost.
    /// Called directly rather than through `sortOption`, whose `didSet` would enqueue a second,
    /// three-attempt pass into the same pass counter.
    @MainActor
    @Test func aResortThatKeepsBeingSupersededGivesUpRatherThanSpinning() async {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.rawRightTree = [node("b.txt", size: 2), node("a.txt", size: 1)]

        let passesBefore = manager.resortPasses
        manager.resortDidSnapshot = { [weak manager] in manager?.rawTreeGeneration += 1 }
        await manager.resortTreesAndRefilter(attempts: 1)
        #expect(manager.resortPasses - passesBefore == 1, "an `attempts: 1` pass tried more than once")
        // Unchanged, which is the point: giving up leaves the state the old code always left, never
        // something half-written. (`.name` is live here, so a successful pass WOULD have reordered
        // these two — the absence of that is the measurement.)
        #expect(manager.rawRightTree.map(\.name) == ["b.txt", "a.txt"])
    }

    /// A superseded load resuming after adoptFreshDeepTree's awaits must not clear the
    /// SUCCESSOR's spinner: the loading flag is what keeps pruneSelection off the successor's
    /// interim shallow tree, so releasing it early can wipe valid deep selections.
    @MainActor
    @Test func testSupersededLoadDoesNotClearSuccessorsSpinner() async {
        let manager = FileSyncManager(fileManager: MockFileManager())

        let staleLoadToken = manager.leftLoadGeneration
        manager.leftLoadGeneration += 1     // a newer load owns the pane now
        manager.isLoadingLeftTree = true    // …and is still mid-walk

        await manager.adoptFreshDeepTree([node("a.txt", size: 1)], builtWith: .name, isLeft: true,
                                         focusPath: "/root",
                                         loadToken: staleLoadToken, configToken: manager.scanConfigGeneration)

        #expect(manager.isLoadingLeftTree, "only the pane's current load may release its spinner")

        // The pane's current load, by contrast, does release it.
        await manager.adoptFreshDeepTree([node("a.txt", size: 1)], builtWith: .name, isLeft: true,
                                         focusPath: "/root",
                                         loadToken: manager.leftLoadGeneration, configToken: manager.scanConfigGeneration)
        #expect(!manager.isLoadingLeftTree)
    }
}
