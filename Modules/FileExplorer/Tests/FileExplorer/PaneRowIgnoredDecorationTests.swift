import Testing
import Foundation
import Sync
@testable import FileExplorer

/// Pins the ignored row decoration to the COMPARISON panes.
///
/// "Ignore in comparison" scopes the Left↔Right diff, and `FileContextMenu` already drops the verb
/// on the single-source rail (there is no other pane to compare against). The rail still drew
/// the struck-through name, though, so the rail showed folders marked as excluded from something a lens scan
/// does not do — with no way to un-mark them. `FileTreeView.rowIsIgnored` is the one choke point
/// both presentations (tree and columns) ask, so pinning it here covers both.
@MainActor
@Suite struct PaneRowIgnoredDecorationTests {

    /// Reports every node as ignored, and counts the asks — so the single-source case can be shown
    /// to SKIP the query rather than merely discard its answer (the column row runs this per row,
    /// per click).
    @MainActor private final class AlwaysIgnoredDelegate: FileActionDelegate {
        var askCount = 0
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
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool {
            askCount += 1
            return true
        }
    }

    private func node(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true)
    }

    /// Comparison pane: an ignored node still reads as ignored. Guards against "fix" by simply
    /// deleting the decoration.
    @Test func testComparisonPaneStillStrikesIgnoredRows() {
        let delegate = AlwaysIgnoredDelegate()
        #expect(FileTreeView.rowIsIgnored(node("/root/TODO"), currentPath: "/root",
                                          delegate: delegate, isSingleSource: false))
        #expect(delegate.askCount == 1)
    }

    /// The single-source rail: plain, and the delegate is never consulted.
    @Test func testSingleSourceRailNeverStrikes() {
        let delegate = AlwaysIgnoredDelegate()
        #expect(!FileTreeView.rowIsIgnored(node("/root/TODO"), currentPath: "/root",
                                           delegate: delegate, isSingleSource: true))
        #expect(delegate.askCount == 0)
    }
}
