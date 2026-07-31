import Testing
import Sync
@testable import FileExplorer

/// Covers FileContextMenu.resolvedSelection: right-clicking acts on the whole multi-selection
/// only when the clicked node is part of it; otherwise it acts on just the clicked node.
@Suite struct ContextMenuSelectionTests {

    private let tree = [
        FileNode(id: "/root/a.txt", name: "a.txt", isDirectory: false),
        FileNode(id: "/root/b.txt", name: "b.txt", isDirectory: false),
        FileNode(id: "/root/dir", name: "dir", isDirectory: true, children: [
            FileNode(id: "/root/dir/c.txt", name: "c.txt", isDirectory: false),
        ]),
    ]
    private var clicked: FileNode { tree[0] }

    @Test func testEmptySelectionResolvesToClickedNode() {
        let nodes = FileContextMenu.resolvedSelection(node: clicked, selection: [], tree: tree)
        #expect(nodes.map(\.id) == ["/root/a.txt"])
    }

    @Test func testClickInsideSelectionResolvesToWholeSelection() {
        let nodes = FileContextMenu.resolvedSelection(
            node: clicked, selection: ["/root/a.txt", "/root/b.txt"], tree: tree)
        #expect(Set(nodes.map(\.id)) == ["/root/a.txt", "/root/b.txt"])
    }

    @Test func testClickOutsideSelectionResolvesToClickedNodeOnly() {
        let nodes = FileContextMenu.resolvedSelection(
            node: clicked, selection: ["/root/b.txt"], tree: tree)
        #expect(nodes.map(\.id) == ["/root/a.txt"])
    }

    @Test func testNestedNodeIsFoundInTree() {
        let nested = FileNode(id: "/root/dir/c.txt", name: "c.txt", isDirectory: false)
        let nodes = FileContextMenu.resolvedSelection(node: nested, selection: [], tree: tree)
        #expect(nodes.map(\.id) == ["/root/dir/c.txt"])
    }

    /// A selection spanning a folder AND something inside it resolves to the folder alone.
    ///
    /// This is the assertion the whole trailing `.pruneNestedNodes()` exists for: without it a
    /// context-menu Copy/Move/Delete hands the handler a superset, so the confirmation names and
    /// counts children that the single operation on their parent already covers.
    ///
    /// It lived in `PaneDropLogicTests` (via `PaneDropLogic.dragNodes`, which wrapped this call)
    /// until cross-pane drag & drop was removed in `4d55246` — and every other test here uses a
    /// FLAT selection, so deleting that suite left the prune on this still-live path unpinned.
    /// Its sibling on the delete path is `PaneTreeSelectedNodesTests` over in Sync: two separate
    /// helpers applying the same prune, and neither may drift.
    @Test func testFolderAndDescendantPruneToTheFolder() {
        let dir = tree[2]
        let nodes = FileContextMenu.resolvedSelection(
            node: dir, selection: ["/root/dir", "/root/dir/c.txt"], tree: tree)
        #expect(nodes.map(\.id) == ["/root/dir"])
    }

    /// The prune is about ancestry, not path-prefix spelling: a sibling whose path merely starts
    /// with the folder's characters is NOT inside it and must survive.
    @Test func testPrefixTwinIsNotTreatedAsNested() {
        let twin = FileNode(id: "/root/dir2", name: "dir2", isDirectory: true)
        let nodes = FileContextMenu.resolvedSelection(
            node: tree[2], selection: ["/root/dir", "/root/dir2"], tree: tree + [twin])
        #expect(Set(nodes.map(\.id)) == ["/root/dir", "/root/dir2"])
    }
}
