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

    // MARK: - RowNode

    /// `RowNode` equality is (side, version, path). Same reasoning as `PaneTree`: a path
    /// identifies one node per published tree, and changing that node's contents requires a
    /// republish, which moves the stamp. These pin the two directions that matter.
    @Test func testRowNodeDiffersWhenTheTreeWasRepublished() {
        let m = FileSyncManager()
        m.leftTree = [node("a")]
        let before = m.leftPaneTree.row(node("a"))
        m.leftTree = [node("a"), node("b")]          // any republish moves the stamp
        let after = m.leftPaneTree.row(node("a"))
        #expect(before != after)
    }

    /// Different paths within the SAME publish are never conflated — the case that would make a
    /// row render its neighbour's contents.
    @Test func testRowNodeDistinguishesPathsWithinOnePublish() {
        let m = FileSyncManager()
        m.leftTree = [node("a"), node("b")]
        let t = m.leftPaneTree
        #expect(t.row(node("a")) != t.row(node("b")))
        #expect(t.row(node("a")) == t.row(node("a")))
    }

    /// A folder node's `children` are deliberately NOT compared — that is the entire point, since
    /// recursing them is what cost 2,162 ms of main thread per refresh. Safe because differing
    /// children cannot coexist with an unchanged stamp on a real published tree.
    @Test func testRowNodeIgnoresChildren() {
        let m = FileSyncManager()
        m.leftTree = []
        let t = m.leftPaneTree
        let thin = FileNode(id: "/r/d", name: "d", isDirectory: true, children: [node("x")])
        let fat  = FileNode(id: "/r/d", name: "d", isDirectory: true, children: [node("x"), node("y")])
        #expect(t.row(thin) == t.row(fat))
    }

    /// Opposite panes never conflate, mirroring the `PaneTree` case.
    @Test func testRowNodeSameVersionOppositeSidesDiffer() {
        let l = RowNode(side: .left, version: 4, node: node("a"))
        let r = RowNode(side: .right, version: 4, node: node("a"))
        #expect(l != r)
    }
}
