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
}
