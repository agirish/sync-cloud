import Foundation
import Testing
@testable import Sync

/// Pins what keeps sort changes, in-flight loads and refresh dedupe consistent:
/// - `publishedLeftTreeVersion`/`publishedRightTreeVersion` bump in `didSet` on every write to the
///   published trees, so `applyFilters`' off-main equality checks see any mid-flight write, even
///   from code that knows nothing about the mechanism.
/// - `RefreshKey` carries the scan-config epoch, so a refresh after a scan-affecting change (Tags
///   sort, date tolerance, auto-verify, an invalidation, a file operation) supersedes an in-flight
///   same-target refresh instead of being deduped away.
/// - `adoptFreshDeepTree` re-sorts a deep tree walked under a since-changed sort option and never
///   caches it: a cached tree is served verbatim, so a stale-mode tree would poison the cache (for
///   Tags, with no way to recover the missing metadata).
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

        // A direct external assignment, which must bump without any manual call.
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

        // A non-Tags sort change re-sorts in memory and requests no reload, so the key may stay;
        // what matters is that invalidation supersedes:
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

        // A walk that started under .name (ascending by name, which here is ascending by size:
        // the wrong order for .size, which sorts descending).
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
    /// scan-config epoch and clears the cache. A tree walked before that change must not write
    /// itself back: the cache serves trees verbatim, so it would show pre-operation state as current.
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

    /// A re-sort superseded mid-flight tries again instead of leaving a pane on the old order.
    /// `resortTreesAndRefilter` sorts snapshots off the main actor and publishes only if
    /// `rawTreeGeneration` held still. Invalidation is pane-scoped: `retargetPane` and `applyTab`
    /// bump the generation via `supersedeInFlightPaneWork` but re-walk only the pane that moved, so
    /// the sibling's raw tree survives in the old order, and nothing else would correct it.
    ///
    /// Driven through `sortOption`'s `didSet`, the only thing that starts one in the app, and
    /// interleaved through `resortDidSnapshot`, which fires between the snapshot and the suspension:
    /// the only window where a supersede bites. A `Task.yield()` there doesn't hold; the retarget
    /// lands before the snapshot. `resortPasses` keeps this from proving nothing: a retried pass and
    /// a never-superseded one end with identical trees, and only the pass count tells them apart.
    @MainActor
    @Test func aSupersededResortTriesAgainInsteadOfLeavingAPaneOnTheOldOrder() async {
        let manager = FileSyncManager(fileManager: MockFileManager())
        // The right pane is the survivor: name order, which for these sizes is the exact reverse of
        // `.size` (descending), so a pane left on the old option is unmistakable.
        manager.rawRightTree = [node("a.txt", size: 1), node("b.txt", size: 2), node("c.txt", size: 3)]
        manager.rightTree = manager.rawRightTree

        // The source switch, fired from inside the sort's window. It drops the left pane's tree and
        // re-walks only the left, so nothing else will put the right pane's tree right. Armed for
        // the first pass only: left installed, it would supersede the retry and test the give-up.
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
    /// `attempts: 1` is the smallest "every publish loses" case. Called directly, not through
    /// `sortOption`, whose `didSet` would enqueue a second, three-attempt pass into the same counter.
    @MainActor
    @Test func aResortThatKeepsBeingSupersededGivesUpRatherThanSpinning() async {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.rawRightTree = [node("b.txt", size: 2), node("a.txt", size: 1)]

        let passesBefore = manager.resortPasses
        manager.resortDidSnapshot = { [weak manager] in manager?.rawTreeGeneration += 1 }
        await manager.resortTreesAndRefilter(attempts: 1)
        #expect(manager.resortPasses - passesBefore == 1, "an `attempts: 1` pass tried more than once")
        // Unchanged: giving up leaves the previous state, never something half-written. (`.name`
        // is live, so a successful pass would have reordered these two.)
        #expect(manager.rawRightTree.map(\.name) == ["b.txt", "a.txt"])
    }

    /// A superseded load resuming after `adoptFreshDeepTree`'s awaits must not clear its successor's
    /// spinner: the loading flag keeps `pruneSelection` off the successor's interim shallow tree, so
    /// releasing it early can wipe valid deep selections.
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
