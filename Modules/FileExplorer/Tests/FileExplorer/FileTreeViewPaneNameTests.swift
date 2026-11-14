import Testing
import Foundation
import SwiftUI
import Sync
@testable import FileExplorer

/// FileTreeView's otherPaneName resolution, the copy/move target shown in the context menu. With no
/// provider name plumbed in, it falls back to the spatial label of the opposite pane.
@MainActor
@Suite struct FileTreeViewPaneNameTests {

    private func treeView(isLeft: Bool, otherPaneName: String?,
                          isSingleSource: Bool = false,
                          currentPath: String = "/x", rootPath: String? = nil) -> FileTreeView {
        FileTreeView(
            tree: PaneTree(side: isLeft ? .left : .right, version: 0, nodes: []),
            otherTree: PaneTree(side: isLeft ? .right : .left, version: 0, nodes: []),
            isLoading: false, currentPath: currentPath,
            selection: .constant([]), otherSelection: [],
            isLeft: isLeft, delegate: NoOpFileActionDelegate(),
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

    /// The receiving side of the download scoping. `CloudDownloadRoutingTests` pins the routing
    /// decision, but only against tokens a test made up: a pane that derived its own token wrongly
    /// (hardcoded, or reading the wrong flag) would route perfectly, to the wrong pane.
    @Test func testEachPaneSurfaceDerivesItsOwnToken() {
        #expect(treeView(isLeft: true, otherPaneName: nil).paneToken == .left)
        #expect(treeView(isLeft: false, otherPaneName: nil).paneToken == .right)
        // The single-source rail passes isLeft: true and must not be confusable with the left pane.
        #expect(treeView(isLeft: true, otherPaneName: nil, isSingleSource: true).paneToken == .singleSource)
    }

    /// A pane built the way `ContentView` builds one, passing no `downloadChannel`, subscribes to the
    /// app's own `NotificationCenter`. Every suite that mounts a pane hands it a private channel ("A
    /// mounted view is a live subscriber, in every suite at once" in `docs/flaky-tests.md`), so only
    /// this test sees the default. Mutation: `= NotificationCenter()` on the parameter must fail it.
    ///
    /// Constructed, not mounted: a `FileTreeView` value holds no subscription until SwiftUI builds
    /// its body, so reading the property here puts nothing on `.default`.
    @Test func testAPaneMountsOnTheAppsChannelByDefault() {
        #expect(treeView(isLeft: true, otherPaneName: nil).downloadChannel === NotificationCenter.default)
    }

    /// A republish's badge-memo clear is scoped to the folder the pane shows, not its provider root;
    /// the two diverge whenever a pane is focused on a subfolder.
    @Test func testTheBadgeMemoClearIsScopedToTheShownFolder() {
        let focused = treeView(isLeft: true, otherPaneName: nil,
                               currentPath: "/provider/sub", rootPath: "/provider")
        #expect(focused.badgeMemoRoot == "/provider/sub")
        #expect(focused.rootPath == "/provider")   // the two really do differ here
    }
}
