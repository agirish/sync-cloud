import Testing
import Sync
@testable import FileExplorer

/// `FileContextMenu.resolvedSelection`: a right-click acts on the whole multi-selection only when
/// the clicked node is part of it; otherwise on the clicked node alone.
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

    /// A selection spanning a folder and something inside it resolves to the folder alone, the
    /// reason for the trailing `.pruneNestedNodes()`. Without it Copy/Move/Delete would hand the
    /// handler a superset, and the confirmation would count children their parent already covers.
    /// The delete path's twin is `PaneTreeSelectedNodesTests` in Sync; neither prune may drift.
    @Test func testFolderAndDescendantPruneToTheFolder() {
        let dir = tree[2]
        let nodes = FileContextMenu.resolvedSelection(
            node: dir, selection: ["/root/dir", "/root/dir/c.txt"], tree: tree)
        #expect(nodes.map(\.id) == ["/root/dir"])
    }

    /// The prune is about ancestry, not path-prefix spelling: a sibling whose path merely starts
    /// with the folder's characters is not inside it and survives.
    @Test func testPrefixTwinIsNotTreatedAsNested() {
        let twin = FileNode(id: "/root/dir2", name: "dir2", isDirectory: true)
        let nodes = FileContextMenu.resolvedSelection(
            node: tree[2], selection: ["/root/dir", "/root/dir2"], tree: tree + [twin])
        #expect(Set(nodes.map(\.id)) == ["/root/dir", "/root/dir2"])
    }
}
