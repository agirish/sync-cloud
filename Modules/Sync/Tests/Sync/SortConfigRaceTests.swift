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
            CloudProvider(id: "l", displayName: "Left", imageName: "folder", path: "/left", type: .iCloud),
            CloudProvider(id: "r", displayName: "Right", imageName: "folder", path: "/right", type: .iCloud)
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
        await manager.adoptFreshDeepTree(staleTree, builtWith: .name, isLeft: true, focusPath: "/root")

        #expect(manager.leftTree.map(\.name) == ["c.txt", "b.txt", "a.txt"], "published tree must follow the LIVE sort option")
        #expect(manager.prefetchedTrees["/root"] == nil, "a stale-mode tree must never enter the cache")
    }

    @MainActor
    @Test func testCurrentSortDeepTreeIsCached() async {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.sortOption = .size

        let tree = [node("c.txt", size: 3), node("b.txt", size: 2)]
        await manager.adoptFreshDeepTree(tree, builtWith: .size, isLeft: true, focusPath: "/root")

        #expect(manager.leftTree.map(\.name) == ["c.txt", "b.txt"])
        #expect(manager.prefetchedTrees["/root"] != nil, "a current-mode deep tree still feeds the cache")
    }
}
