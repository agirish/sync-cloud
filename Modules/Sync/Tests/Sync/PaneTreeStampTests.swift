import Testing
import Foundation
import Events
@testable import Sync

/// `PaneTree` compares only its publish stamp, never its ~40,000 nodes — that is the whole point
/// of the type (it keeps SwiftUI's body-output comparison off a recursive `FileNode.==`). The
/// safety of that shortcut rests entirely on ONE invariant owned by `FileSyncManager`: the pane's
/// version counter advances on every assignment to the published tree, so a stamp can never be
/// reused for different contents.
///
/// These tests pin that invariant directly. Without it, a stale tree would compare equal to a
/// fresh one and the pane would silently stop updating — a far worse failure than the slow
/// compare this replaced, and one no rendering test would catch.
@MainActor
@Suite struct PaneTreeStampTests {

    private func node(_ name: String) -> FileNode {
        FileNode(id: "/r/\(name)", name: name, isDirectory: false)
    }

    /// The load-bearing invariant: every publish moves the stamp, so before ≠ after for ANY
    /// change. Asserted through the manager's own accessor, not the raw counter, so it covers
    /// the accessor reading the matching counter for its side.
    @Test func testEveryPublishAdvancesTheStamp() {
        let m = FileSyncManager()

        let empty = m.leftPaneTree
        m.leftTree = [node("a")]
        let one = m.leftPaneTree
        #expect(empty != one)

        m.leftTree = [node("a"), node("b")]
        let two = m.leftPaneTree
        #expect(one != two)
        #expect(empty != two)

        // Same for the right pane, via its own counter.
        let rEmpty = m.rightPaneTree
        m.rightTree = [node("a")]
        #expect(rEmpty != m.rightPaneTree)
    }

    /// Even re-publishing an IDENTICAL array advances the stamp. This is the direction that is
    /// safe to get "wrong" (a redundant re-render, never a missed one) — pinned so nobody later
    /// adds an equality guard to the `didSet` and turns it into the unsafe direction.
    @Test func testRepublishingEqualContentsStillAdvancesTheStamp() {
        let m = FileSyncManager()
        m.leftTree = [node("a")]
        let first = m.leftPaneTree
        m.leftTree = [node("a")]
        let second = m.leftPaneTree

        #expect(first.nodes == second.nodes)   // contents identical…
        #expect(first != second)               // …stamp still moved
    }

    /// A stamp read twice with no publish in between is the same value — the memoization this
    /// type exists to enable. Mutation check: if `==` compared `nodes` instead of the stamp this
    /// would still pass, so it is paired with the two tests above, which it cannot.
    @Test func testStampIsStableWithoutAPublish() {
        let m = FileSyncManager()
        m.leftTree = [node("a")]
        #expect(m.leftPaneTree == m.leftPaneTree)
    }

    /// The two panes keep independent counters, so a bare version is only meaningful with its
    /// side. Nothing pairs `tree` with `otherTree` today (SwiftUI compares a property against
    /// its own prior value), but the discriminator is what keeps that from being silently wrong.
    @Test func testSameVersionOnOppositeSidesIsNotEqual() {
        let left = PaneTree(side: .left, version: 7, nodes: [node("a")])
        let right = PaneTree(side: .right, version: 7, nodes: [node("a")])
        #expect(left != right)
    }

    /// The contract stated plainly: equal stamp ⇒ equal, regardless of contents. The manager
    /// invariant above is what guarantees this case cannot arise from real published trees.
    @Test func testEqualStampsCompareEqualEvenWithDifferentNodes() {
        let a = PaneTree(side: .left, version: 3, nodes: [node("a")])
        let b = PaneTree(side: .left, version: 3, nodes: [node("b"), node("c")])
        #expect(a == b)
    }

    // MARK: - PaneRow

    /// `PaneRow` equality is (side, version, path). Same reasoning as `PaneTree`: a path
    /// identifies one node per published tree, and changing that node's contents requires a
    /// republish, which moves the stamp. These pin the two directions that matter.
    @Test func testPaneRowDiffersWhenTheTreeWasRepublished() {
        let m = FileSyncManager()
        m.leftTree = [node("a")]
        let before = m.leftPaneTree.rows[0]
        m.leftTree = [node("a"), node("b")]          // any republish moves the stamp
        let after = m.leftPaneTree.rows[0]
        #expect(before.id == after.id)               // same path…
        #expect(before != after)                     // …but a newer publish
    }

    /// Different paths within the SAME publish are never conflated — the case that would make a
    /// row render its neighbour's contents.
    @Test func testPaneRowDistinguishesPathsWithinOnePublish() {
        let m = FileSyncManager()
        m.leftTree = [node("a"), node("b")]
        let t = m.leftPaneTree
        #expect(t.rows[0] != t.rows[1])
        #expect(t.rows[0] == t.rows[0])
    }

    /// A folder node's `children` are deliberately NOT compared — that is the entire point, since
    /// recursing them is what cost 2,162 ms of main thread per refresh. Safe because differing
    /// children cannot coexist with an unchanged stamp on a real published tree.
    @Test func testPaneRowIgnoresChildren() {
        let thin = FileNode(id: "/r/d", name: "d", isDirectory: true, children: [node("x")])
        let fat  = FileNode(id: "/r/d", name: "d", isDirectory: true, children: [node("x"), node("y")])
        let a = PaneRow.project([thin], side: .left, version: 1)[0]
        let b = PaneRow.project([fat], side: .left, version: 1)[0]
        #expect(a == b)
    }

    /// Opposite panes never conflate, mirroring the `PaneTree` case.
    @Test func testPaneRowSameVersionOppositeSidesDiffer() {
        let l = PaneRow(side: .left, version: 4, node: node("a"), children: nil)
        let r = PaneRow(side: .right, version: 4, node: node("a"), children: nil)
        #expect(l != r)
    }

    // MARK: - Row projection and its cache

    /// The row projection is CACHED per publish (`leftRowsCache`), which makes stale rows a real
    /// new failure vector: a wrong cache key would pin the pane to whatever tree it first
    /// rendered. This is the test that would catch it.
    @Test func testRowProjectionCacheInvalidatesOnEveryRepublish() {
        let m = FileSyncManager()
        m.leftTree = [node("a")]
        #expect(m.leftPaneTree.rows.map(\.id) == ["/r/a"])

        m.leftTree = [node("b"), node("c")]
        #expect(m.leftPaneTree.rows.map(\.id) == ["/r/b", "/r/c"])

        m.leftTree = []
        #expect(m.leftPaneTree.rows.isEmpty)
    }

    /// Reading twice with no publish in between must reuse the cache, not re-walk the tree — the
    /// whole reason the cache exists (the accessor is read once per pane per render).
    @Test func testRowProjectionIsStableWithoutARepublish() {
        let m = FileSyncManager()
        m.leftTree = [node("a")]
        #expect(m.leftPaneTree.rows == m.leftPaneTree.rows)
    }

    /// The two panes' caches are independent: republishing one must not serve the other's rows,
    /// and each row must carry its OWN pane's side (both counters sit at the same integer here,
    /// which is exactly the collision `side` exists to prevent).
    @Test func testPanesProjectTheirOwnRowsIndependently() {
        let m = FileSyncManager()
        m.leftTree = [node("left-only")]
        m.rightTree = [node("right-only")]
        #expect(m.publishedLeftTreeVersion == m.publishedRightTreeVersion)   // same integer…
        #expect(m.leftPaneTree.rows.map(\.id) == ["/r/left-only"])
        #expect(m.rightPaneTree.rows.map(\.id) == ["/r/right-only"])
        #expect(m.leftPaneTree.rows.allSatisfy { $0.side == .left })
        #expect(m.rightPaneTree.rows.allSatisfy { $0.side == .right })
        #expect(m.leftPaneTree.rows[0] != m.rightPaneTree.rows[0])          // …still not conflated
    }

    /// `OutlineGroup` decides whether a row gets a disclosure triangle from `children == nil` vs
    /// `[]`. `FileNode` uses nil for a file and `[]` for an empty directory, so the projection
    /// must preserve that distinction exactly — collapsing it would either hide a folder's
    /// triangle or give every file one.
    @Test func testProjectionPreservesNilVersusEmptyChildren() {
        let file = FileNode(id: "/r/f.txt", name: "f.txt", isDirectory: false)                 // nil
        let emptyDir = FileNode(id: "/r/d", name: "d", isDirectory: true, children: [])        // []
        let fullDir = FileNode(id: "/r/e", name: "e", isDirectory: true, children: [node("x")])
        let rows = PaneRow.project([file, emptyDir, fullDir], side: .left, version: 1)
        #expect(rows[0].children == nil)
        #expect(rows[1].children?.isEmpty == true)
        #expect(rows[2].children?.count == 1)
        // …and recursively, so a nested file keeps its leaf-ness.
        #expect(rows[2].children?[0].children == nil)
    }

    /// Nested rows inherit the tree's stamp, so a deep row memoizes on the same terms as a
    /// top-level one rather than silently comparing as equal across publishes.
    @Test func testProjectionStampsNestedRowsToo() {
        let dir = FileNode(id: "/r/d", name: "d", isDirectory: true, children: [node("x")])
        let rows = PaneRow.project([dir], side: .right, version: 9)
        let child = rows[0].children![0]
        #expect(child.side == .right)
        #expect(child.version == 9)
        #expect(child.id == "/r/x")
    }

    /// `FileRowInfo` must carry every scalar the row renders; dropping one would blank part of a
    /// row rather than fail loudly.
    @Test func testRowInfoCarriesEveryRenderedScalar() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let n = FileNode(id: "/r/f.txt", name: "f.txt", isDirectory: false,
                         modificationDate: when, fileSize: 1234)
        let info = FileRowInfo(n)
        #expect(info.id == "/r/f.txt")
        #expect(info.name == "f.txt")
        #expect(info.isDirectory == false)
        #expect(info.modificationDate == when)
        #expect(info.fileSize == 1234)
    }
}
