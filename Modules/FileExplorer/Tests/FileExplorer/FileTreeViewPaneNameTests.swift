import Testing
import Foundation
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
        func handleRename(_ node: FileNode) {}
        func handleCreateFolder(at path: String) {}
        func handleGetInfo(for path: String) {}
        func handleSort(_ option: SortOption) {}
        func handleIgnore(_ nodes: [FileNode]) {}
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
    }

    private func treeView(isLeft: Bool, otherPaneName: String?,
                          isSingleSource: Bool = false,
                          currentPath: String = "/x", rootPath: String? = nil) -> FileTreeView {
        FileTreeView(
            tree: PaneTree(side: isLeft ? .left : .right, version: 0, nodes: []),
            otherTree: PaneTree(side: isLeft ? .right : .left, version: 0, nodes: []),
            isLoading: false, currentPath: currentPath,
            selection: .constant([]), otherSelection: [],
            isLeft: isLeft, delegate: StubDelegate(),
            otherPaneName: otherPaneName,
            rootPath: rootPath,
            isSingleSource: isSingleSource
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

    /// The RECEIVING side of the download scoping. `CloudDownloadRoutingTests` pins the routing
    /// decision, but only against tokens a test made up: a pane that derived its own token wrongly
    /// — hardcoded, or reading the wrong flag — would route perfectly, to the wrong pane.
    @Test func testEachPaneSurfaceDerivesItsOwnToken() {
        #expect(treeView(isLeft: true, otherPaneName: nil).paneToken == .left)
        #expect(treeView(isLeft: false, otherPaneName: nil).paneToken == .right)
        // The Tidy rail passes isLeft: true and must NOT be confusable with the left pane.
        #expect(treeView(isLeft: true, otherPaneName: nil, isSingleSource: true).paneToken == .singleSource)
    }

    /// The receiving half of the shipped default: a pane built the way `ContentView` builds one —
    /// passing no `downloadChannel` — subscribes to the app's own `NotificationCenter`.
    ///
    /// Every suite that MOUNTS a pane now hands it a private channel instead (mechanism 9), which
    /// is what keeps them out of each other's posts and also means not one of them touches this
    /// default any more. Retarget it — `= NotificationCenter()` on the parameter — and every one of
    /// those suites stays green while the app's panes go deaf to the app's own Download button.
    ///
    /// Constructed, not mounted: a `FileTreeView` value holds no subscription until SwiftUI builds
    /// its body, so reading the property here puts nothing on `.default`.
    @Test func testAPaneMountsOnTheAppsChannelByDefault() {
        #expect(treeView(isLeft: true, otherPaneName: nil).downloadChannel === NotificationCenter.default)
    }

    /// A republish's badge-memo clear is scoped to the folder the pane is SHOWING, not to its
    /// provider root. The two diverge whenever a pane is focused on a subfolder, and clearing the
    /// provider root would drop entries no row of this pane can serve — the over-broad clear the
    /// scoping exists to stop.
    @Test func testTheBadgeMemoClearIsScopedToTheShownFolder() {
        let focused = treeView(isLeft: true, otherPaneName: nil,
                               currentPath: "/provider/sub", rootPath: "/provider")

        #expect(focused.badgeMemoRoot == "/provider/sub")
        #expect(focused.rootPath == "/provider")   // the two really do differ here
    }
}
