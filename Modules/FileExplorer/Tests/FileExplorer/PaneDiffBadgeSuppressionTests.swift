import Testing
import SwiftUI
import Sync
@testable import FileExplorer

/// Pins the difference accessories (status glyph, contained-count pill) to the comparison panes: the
/// single-source rail has no other pane to differ from. `FileTreeView.init` empties the index for
/// the rail, the single gate both presentations read.
@MainActor
@Suite struct PaneDiffBadgeSuppressionTests {

    /// Two differences under `Health/`: the folder earns a contained-count pill and one of the
    /// files earns a status glyph.
    private var populatedIndex: DiffStatusIndex {
        DiffStatusIndex(
            differences: [
                FileDifference(relativePath: "Health/report.pdf", leftItemPath: "/root/Health/report.pdf",
                               rightItemPath: "/other/Health/report.pdf", type: .missingOnRight,
                               action: .copyToRight, description: "test"),
                FileDifference(relativePath: "Health/scan.pdf", leftItemPath: "/root/Health/scan.pdf",
                               rightItemPath: "/other/Health/scan.pdf", type: .missingOnRight,
                               action: .copyToRight, description: "test"),
            ],
            rootPath: "/root"
        )
    }

    private func pane(isSingleSource: Bool) -> FileTreeView {
        FileTreeView(
            tree: PaneTree(side: .left, version: 0, nodes: []),
            otherTree: PaneTree(side: .right, version: 0, nodes: []),
            isLoading: false, currentPath: "/root",
            selection: .constant([]), otherSelection: [],
            isLeft: true, delegate: NoOpFileActionDelegate(),
            diffIndex: populatedIndex,
            isSingleSource: isSingleSource
        )
    }

    /// Comparison pane: the badges survive `init` untouched, which also proves the fixture badges
    /// something for the rail assertion below.
    @Test func testComparisonPaneKeepsItsBadges() {
        let rendered = pane(isSingleSource: false).diffIndex
        #expect(rendered.containedDiffCount(forNodeId: "/root/Health") == 2)
        #expect(rendered.status(forNodeId: "/root/Health/report.pdf") == .missingOnRight)
    }

    /// The single-source rail: nothing to badge, whatever the host hands in.
    @Test func testSingleSourceRailDropsEveryBadge() {
        let rendered = pane(isSingleSource: true).diffIndex
        #expect(rendered.containedDiffCount(forNodeId: "/root/Health") == 0)
        #expect(rendered.status(forNodeId: "/root/Health/report.pdf") == nil)
        // And the whole index is empty, so a folder or file this test didn't name can't badge either.
        #expect(rendered == .empty)
    }
}
