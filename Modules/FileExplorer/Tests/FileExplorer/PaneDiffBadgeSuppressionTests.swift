import Testing
import SwiftUI
import Sync
@testable import FileExplorer

/// Pins the difference accessories — a row's status glyph and a folder's contained-count pill —
/// to the COMPARISON panes.
///
/// A difference is a statement about the other pane, and the single-source rail has no other pane. It was
/// badging its folders from whatever Compare last scanned, so the rail showed counts against a
/// provider it isn't looking at. `FileTreeView.init` empties the index for the rail, which is the
/// single gate: the tree rows, and `PaneColumnsView` (handed this same stored property), all read
/// it, so asserting on the property covers both presentations.
@MainActor
@Suite struct PaneDiffBadgeSuppressionTests {

    private struct StubDelegate: FileActionDelegate {
        func handleRefresh() {}
        func handleOpenInEditor(_ path: String) {}
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

    /// Two differences under `Health/`, mirroring the reported screenshot: the folder earns a
    /// contained-count pill and one of the files earns a status glyph.
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
            isLeft: true, delegate: StubDelegate(),
            diffIndex: populatedIndex,
            isSingleSource: isSingleSource
        )
    }

    /// The fixture is only meaningful if it actually badges something — without this the rail
    /// assertion below would pass against an index that was empty all along.
    @Test func testFixtureBadgesTheFolderAndTheFile() {
        let index = populatedIndex
        #expect(index.containedDiffCount(forNodeId: "/root/Health") == 2)
        #expect(index.status(forNodeId: "/root/Health/report.pdf") == .missingOnRight)
    }

    /// Comparison pane: the badges survive the trip through `init` untouched.
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
