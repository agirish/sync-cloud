import Testing
import Foundation
import Sync
@testable import FileExplorer

/// Pins the ignored row decoration to the comparison panes: "Ignore in comparison" scopes the
/// Left↔Right diff, and on the single-source rail a struck-through name could never be un-marked.
/// `FileTreeView.rowIsIgnored` is the one choke point tree and columns both ask.
@MainActor
@Suite struct PaneRowIgnoredDecorationTests {

    /// Reports every node as ignored and counts the asks, so the single-source case can be shown to
    /// skip the query rather than discard its answer (the column row runs it per row, per click).
    @MainActor private final class AlwaysIgnoredDelegate: NoOpFileActions {
        var askCount = 0
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool {
            askCount += 1
            return true
        }
    }

    private func node(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true)
    }

    /// Comparison pane: an ignored node still reads as ignored, so deleting the decoration can't
    /// pass as a fix.
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
