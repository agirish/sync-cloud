import Testing
import SwiftUI
import Sync
@testable import FileExplorer

/// Coverage for FileTreeView's otherPaneName resolution — the copy/move target shown in
/// the context menu. When no provider name is plumbed in, it must fall back to the
/// spatial label of the OPPOSITE pane (the historical wording).
@MainActor
@Suite struct FileTreeViewPaneNameTests {

    /// No-op delegate so a FileTreeView can be constructed outside the app.
    private struct StubDelegate: FileActionDelegate {
        func handleRefresh() {}
        func handleFocus(_ node: FileNode) {}
        func handleCopy(_ nodes: [FileNode]) {}
        func handleMove(_ nodes: [FileNode]) {}
        func handleDelete(_ nodes: [FileNode]) {}
        func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
        func handlePaste(_ targetDir: FileNode) {}
        func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
        func handlePasteToPath(_ path: String) {}
        func handleDrop(_ nodes: [FileNode], toPath path: String, isMove: Bool) {}
        func handleRename(_ node: FileNode) {}
        func handleCreateFolder(at path: String) {}
        func handleGetInfo(for path: String) {}
        func handleSort(_ option: SortOption) {}
        func handleIgnore(_ nodes: [FileNode]) {}
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
    }

    private func treeView(isLeft: Bool, otherPaneName: String?) -> FileTreeView {
        FileTreeView(
            tree: [], otherTree: [], isLoading: false, currentPath: "/x",
            selection: .constant([]), otherSelection: [],
            isLeft: isLeft, delegate: StubDelegate(), ignoredPaths: [],
            otherPaneName: otherPaneName
        )
    }

    @Test func testProviderNamePassesThrough() {
        #expect(treeView(isLeft: true, otherPaneName: "Dropbox").otherPaneName == "Dropbox")
        #expect(treeView(isLeft: false, otherPaneName: "iCloud").otherPaneName == "iCloud")
    }

    @Test func testNilFallsBackToOppositeSpatialLabel() {
        // The left pane's copy target is the RIGHT pane, and vice versa.
        #expect(treeView(isLeft: true, otherPaneName: nil).otherPaneName == "Right")
        #expect(treeView(isLeft: false, otherPaneName: nil).otherPaneName == "Left")
    }
}
