import Testing
import Sync
@testable import FileExplorer

/// Covers the pure drag & drop rules for the comparison panes: which nodes a drag carries
/// (PaneDropLogic.dragNodes) and which drops are allowed (PaneDropLogic.canDrop).
@Suite struct PaneDropLogicTests {

    // MARK: - canDrop

    @Test func testCrossPaneDropIsAllowed() {
        #expect(PaneDropLogic.canDrop(
            draggedIds: ["/left/a.txt"], sourceIsLeft: true, targetIsLeft: false,
            targetDirectoryPath: "/right/dir"))
        #expect(PaneDropLogic.canDrop(
            draggedIds: ["/right/b.txt"], sourceIsLeft: false, targetIsLeft: true,
            targetDirectoryPath: "/left/dir"))
    }

    @Test func testSamePaneDropIsRejected() {
        #expect(!PaneDropLogic.canDrop(
            draggedIds: ["/left/a.txt"], sourceIsLeft: true, targetIsLeft: true,
            targetDirectoryPath: "/left/dir"))
        #expect(!PaneDropLogic.canDrop(
            draggedIds: ["/right/a.txt"], sourceIsLeft: false, targetIsLeft: false,
            targetDirectoryPath: "/right/dir"))
    }

    @Test func testDropOntoDraggedItemItselfIsRejected() {
        // Possible when both panes point at overlapping folders.
        #expect(!PaneDropLogic.canDrop(
            draggedIds: ["/shared/dir"], sourceIsLeft: true, targetIsLeft: false,
            targetDirectoryPath: "/shared/dir"))
    }

    @Test func testDropIntoDescendantOfDraggedFolderIsRejected() {
        #expect(!PaneDropLogic.canDrop(
            draggedIds: ["/shared/dir"], sourceIsLeft: true, targetIsLeft: false,
            targetDirectoryPath: "/shared/dir/sub/deeper"))
        // Any one offending dragged item poisons the whole drop.
        #expect(!PaneDropLogic.canDrop(
            draggedIds: ["/left/ok.txt", "/shared/dir"], sourceIsLeft: true, targetIsLeft: false,
            targetDirectoryPath: "/shared/dir/sub"))
    }

    @Test func testSiblingWithCommonPrefixIsNotTreatedAsDescendant() {
        // "/shared/dir2" merely shares a string prefix with "/shared/dir".
        #expect(PaneDropLogic.canDrop(
            draggedIds: ["/shared/dir"], sourceIsLeft: true, targetIsLeft: false,
            targetDirectoryPath: "/shared/dir2"))
    }

    @Test func testTrailingSlashOnTargetIsNormalized() {
        #expect(!PaneDropLogic.canDrop(
            draggedIds: ["/shared/dir"], sourceIsLeft: true, targetIsLeft: false,
            targetDirectoryPath: "/shared/dir/"))
        #expect(!PaneDropLogic.canDrop(
            draggedIds: ["/shared/dir"], sourceIsLeft: true, targetIsLeft: false,
            targetDirectoryPath: "/shared/dir/sub/"))
    }

    @Test func testEmptyDragIsRejected() {
        #expect(!PaneDropLogic.canDrop(
            draggedIds: [], sourceIsLeft: true, targetIsLeft: false,
            targetDirectoryPath: "/right/dir"))
    }

    // MARK: - dragNodes

    private let tree = [
        FileNode(id: "/root/a.txt", name: "a.txt", isDirectory: false),
        FileNode(id: "/root/b.txt", name: "b.txt", isDirectory: false),
        FileNode(id: "/root/dir", name: "dir", isDirectory: true, children: [
            FileNode(id: "/root/dir/c.txt", name: "c.txt", isDirectory: false),
        ]),
    ]

    @Test func testDragOfUnselectedRowCarriesJustThatRow() {
        let nodes = PaneDropLogic.dragNodes(
            for: tree[0], selection: ["/root/b.txt"], tree: tree)
        #expect(nodes.map(\.id) == ["/root/a.txt"])
    }

    @Test func testDragInsideSelectionCarriesWholeSelection() {
        let nodes = PaneDropLogic.dragNodes(
            for: tree[0], selection: ["/root/a.txt", "/root/b.txt"], tree: tree)
        #expect(Set(nodes.map(\.id)) == ["/root/a.txt", "/root/b.txt"])
    }

    @Test func testDragWithEmptySelectionCarriesDraggedRow() {
        let nodes = PaneDropLogic.dragNodes(for: tree[1], selection: [], tree: tree)
        #expect(nodes.map(\.id) == ["/root/b.txt"])
    }

    @Test func testNestedSelectionIsPrunedToParentFolder() {
        let dir = tree[2]
        let nodes = PaneDropLogic.dragNodes(
            for: dir, selection: ["/root/dir", "/root/dir/c.txt"], tree: tree)
        #expect(nodes.map(\.id) == ["/root/dir"])
    }

    @Test func testDraggedFolderIsSlimmedOfChildren() {
        let nodes = PaneDropLogic.dragNodes(for: tree[2], selection: [], tree: tree)
        #expect(nodes.map(\.id) == ["/root/dir"])
        #expect(nodes[0].children == nil)
    }
}
