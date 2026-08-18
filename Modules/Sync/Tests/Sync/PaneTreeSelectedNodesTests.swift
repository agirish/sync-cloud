import Testing
@testable import Sync

/// `PaneTree.selectedNodes(at:)` is the pane's delete-path resolver — `onDeleteCommand` calls it
/// to turn the selection into the nodes the confirmation names and the handler acts on.
///
/// It had **no tests at all**. Its trailing `.pruneNestedNodes()` is the load-bearing half: a
/// selection spanning a folder AND something inside it must resolve to the folder alone, or the
/// delete confirmation names and counts children that trashing their parent already covers. The
/// disk outcome was always right (`deleteItems` prunes again before trashing) — the dialog the
/// user answers is what breaks.
///
/// This is deliberately the twin of `ContextMenuSelectionTests.testFolderAndDescendantPruneToTheFolder`
/// over in FileExplorer, which pins the same prune on the context-menu path through
/// `FileContextMenu.resolvedSelection`. They are **separate helpers with the same rule**, so each
/// needs its own pin; the comment at `FileContextMenu.resolvedSelection` points here for exactly
/// that reason.
@Suite struct PaneTreeSelectedNodesTests {

    private let tree = [
        FileNode(id: "/root/a.txt", name: "a.txt", isDirectory: false),
        FileNode(id: "/root/b.txt", name: "b.txt", isDirectory: false),
        FileNode(id: "/root/dir", name: "dir", isDirectory: true, children: [
            FileNode(id: "/root/dir/c.txt", name: "c.txt", isDirectory: false),
        ]),
    ]

    private func paneTree(_ nodes: [FileNode]) -> PaneTree {
        PaneTree(side: .left, version: 1, nodes: nodes)
    }

    @Test func testFolderAndDescendantPruneToTheFolder() {
        let nodes = paneTree(tree).selectedNodes(at: ["/root/dir", "/root/dir/c.txt"])
        #expect(nodes.map(\.id) == ["/root/dir"])
    }

    /// Ancestry, not path-prefix spelling: `/root/dir2` merely starts with `/root/dir`'s
    /// characters and is not inside it, so selecting both keeps both.
    @Test func testPrefixTwinIsNotTreatedAsNested() {
        let twin = FileNode(id: "/root/dir2", name: "dir2", isDirectory: true)
        let nodes = paneTree(tree + [twin]).selectedNodes(at: ["/root/dir", "/root/dir2"])
        #expect(Set(nodes.map(\.id)) == ["/root/dir", "/root/dir2"])
    }

    /// A flat selection is passed through untouched — the prune must not be over-eager.
    @Test func testFlatSelectionSurvivesIntact() {
        let nodes = paneTree(tree).selectedNodes(at: ["/root/a.txt", "/root/b.txt"])
        #expect(Set(nodes.map(\.id)) == ["/root/a.txt", "/root/b.txt"])
    }

    /// A descendant selected WITHOUT its parent is not pruned — there is no selected ancestor
    /// covering it, so it must survive on its own.
    @Test func testDescendantAloneIsKept() {
        let nodes = paneTree(tree).selectedNodes(at: ["/root/dir/c.txt"])
        #expect(nodes.map(\.id) == ["/root/dir/c.txt"])
    }

    @Test func testEmptySelectionResolvesToNothing() {
        #expect(paneTree(tree).selectedNodes(at: []).isEmpty)
    }

    /// A path no longer in the tree (a stale selection surviving a refresh) resolves to nothing
    /// rather than to a fabricated node — `onDeleteCommand`'s `isEmpty` guard is what turns that
    /// into "do nothing" instead of a confirmation for a file that is gone.
    @Test func testVanishedPathResolvesToNothing() {
        #expect(paneTree(tree).selectedNodes(at: ["/root/gone.txt"]).isEmpty)
    }
}

/// **The prune's ordering is by bytes now, and the two orderings must agree about ancestry.**
///
/// `pruneNestedNodes` sorts so parents come first, then drops anything inside an accepted parent.
/// It sorted by `id.count` — a grapheme count, an O(path) walk — inside the comparator, so it ran
/// O(n log n) times rather than n, re-walking two full absolute paths per comparison. `utf8.count`
/// is O(1) and preserves what the prune actually depends on: an ancestor's path is a byte PREFIX of
/// its descendants', so it is strictly shorter in bytes too.
///
/// The case worth pinning is the one where the two counts disagree — a non-ASCII name makes a path
/// longer in bytes than in Characters, so a shallower folder can sort after a deeper one under the
/// old comparator and before it under the new. Ancestry must survive either way.
@Suite struct PruneOrderingTests {

    private func node(_ path: String) -> FileNode {
        FileNode(id: path, name: String(path.split(separator: "/").last ?? ""), isDirectory: true)
    }

    @Test func anAncestorIsKeptAndItsDescendantsDropped() {
        let pruned = [node("/r/a/b/c.txt"), node("/r/a"), node("/r/a/b")].pruneNestedNodes()
        #expect(pruned.map(\.id) == ["/r/a"])
    }

    /// **Where the two counts disagree.** "/r/文書" is 5 Characters and 11 bytes; a sibling
    /// "/r/aaaaaaaa" is 11 Characters and 11 bytes. The ancestor must still lead its own subtree
    /// whichever way the comparator counts.
    @Test func aNonASCIIAncestorStillComesBeforeItsChildren() {
        let ancestor = "/r/文書"
        let child = "/r/文書/deep/file.txt"
        #expect(ancestor.count != ancestor.utf8.count, "the fixture stopped exercising the disagreement")

        let pruned = [node(child), node("/r/aaaaaaaa"), node(ancestor)].pruneNestedNodes()
        #expect(Set(pruned.map(\.id)) == [ancestor, "/r/aaaaaaaa"],
                "the non-ASCII ancestor did not lead its own subtree; got \(pruned.map(\.id))")
    }

    /// Siblings are all kept — the prune drops descendants, not equals.
    @Test func siblingsAreAllKept() {
        let pruned = [node("/r/a"), node("/r/b"), node("/r/c")].pruneNestedNodes()
        #expect(Set(pruned.map(\.id)) == ["/r/a", "/r/b", "/r/c"])
    }

    /// A path that merely shares a prefix is not inside it — "/r/ab" is not under "/r/a".
    @Test func aPrefixThatIsNotAComponentBoundaryIsNotNested() {
        let pruned = [node("/r/a"), node("/r/ab")].pruneNestedNodes()
        #expect(Set(pruned.map(\.id)) == ["/r/a", "/r/ab"])
    }
}
