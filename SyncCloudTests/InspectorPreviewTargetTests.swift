import Testing
import Foundation
import Sync
@testable import SyncCloud

/// Which file the Info inspector previews (`ContentView.inspectorPreview`): a Get Info target first,
/// in whichever tree holds it or as its own node; otherwise the one item selected in the pane the
/// inspector follows. Files only.
@Suite struct InspectorPreviewTargetTests {
    private static func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false)
    }
    private static func folder(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true)
    }

    private func target(infoPath: String? = nil, infoNode: FileNode? = nil, followsLeft: Bool = true,
                        left: [FileNode] = [], right: [FileNode] = [],
                        selectedLeft: Set<String> = [], selectedRight: Set<String> = [],
                        rightRoot: String = "/R") -> (node: FileNode, isLeft: Bool)? {
        ContentView.inspectorPreview(
            infoPath: infoPath, infoNode: infoNode, followsLeft: followsLeft,
            selectedLeft: selectedLeft, selectedRight: selectedRight,
            leftNodes: { paths in left.filter { paths.contains($0.id) } },
            rightNodes: { paths in right.filter { paths.contains($0.id) } },
            rightRoot: rightRoot)
    }

    @Test func theFollowedPanesOneFileIsPreviewed() {
        let a = Self.file("/L/a.pdf"), b = Self.file("/R/b.pdf")
        #expect(target(left: [a], right: [b], selectedLeft: [a.id])?.node.id == a.id)
        let right = target(followsLeft: false, left: [a], right: [b], selectedLeft: [a.id], selectedRight: [b.id])
        #expect(right?.node.id == b.id && right?.isLeft == false)
    }

    @Test func aFolderOrSeveralItemsHaveNoPreview() {
        let f = Self.folder("/L/docs"), a = Self.file("/L/a.pdf"), c = Self.file("/L/c.pdf")
        #expect(target(left: [f], selectedLeft: [f.id]) == nil)
        #expect(target(left: [a, c], selectedLeft: [a.id, c.id]) == nil)
    }

    /// Get Info wins over the selection, from whichever tree holds the file.
    @Test func aGetInfoTargetWinsFromEitherTree() {
        let a = Self.file("/L/a.pdf"), b = Self.file("/R/b.pdf")
        let fromRight = target(infoPath: b.id, left: [a], right: [b], selectedLeft: [a.id])
        #expect(fromRight?.node.id == b.id && fromRight?.isLeft == false)
    }

    /// A Get Info target no tree holds (a differences row outside the pane's folder, a file the
    /// filter hides) is previewed from its own node, filed with the pane whose root it is under.
    @Test func aGetInfoTargetNoTreeHoldsUsesItsOwnNode() {
        let outside = Self.file("/R/far/away.pdf")
        let hit = target(infoPath: outside.id, infoNode: outside)
        #expect(hit?.node.id == outside.id && hit?.isLeft == false)
        let leftSide = Self.file("/L/elsewhere.pdf")
        #expect(target(infoPath: leftSide.id, infoNode: leftSide)?.isLeft == true)
        #expect(target(infoPath: "/R/Rx/sibling.pdf", infoNode: Self.file("/R/Rx/sibling.pdf"), rightRoot: "/R/R")?.isLeft == true,
                "a path merely sharing the right root's prefix was filed with the right pane")
        // A node for some other path is not used.
        #expect(target(infoPath: outside.id, infoNode: Self.file("/R/other.pdf")) == nil)
        #expect(target(infoPath: "/R/far", infoNode: Self.folder("/R/far")) == nil)
    }
}
