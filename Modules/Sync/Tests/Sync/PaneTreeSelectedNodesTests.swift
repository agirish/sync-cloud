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
