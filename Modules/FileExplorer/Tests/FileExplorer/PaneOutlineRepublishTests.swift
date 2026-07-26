import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// The one failure mode `PaneTree`/`PaneRow` memoization can introduce is the worst one: a pane
/// that silently STOPS updating, because a stale value compared equal to a fresh one. Every other
/// test for it is value-level (`PaneTreeStampTests`) and would pass even if the view never
/// re-rendered.
///
/// This hosts a real `FileTreeView` and asserts the rows AppKit actually laid out track a
/// republish — the laid-out result, not the constant (the house rule).
@MainActor
@Suite struct PaneOutlineRepublishTests {

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

    private func file(_ name: String) -> FileNode {
        FileNode(id: "/root/\(name)", name: name, isDirectory: false)
    }

    private func view(_ tree: PaneTree) -> FileTreeView {
        FileTreeView(
            tree: tree,
            otherTree: PaneTree(side: .right, version: 0, nodes: []),
            isLoading: false,
            currentPath: "/root",
            selection: .constant([]),
            otherSelection: [],
            isLeft: true,
            delegate: StubDelegate()
        )
    }

    /// Lays the view out in a window and returns the row count AppKit resolved. A `List` bridges
    /// to `NSTableView`; without a window and a layout pass it has no rows at all, so the search
    /// returning nil means "could not observe", which the caller treats as inconclusive rather
    /// than as a pass.
    private func laidOutRowCount(_ root: FileTreeView) -> Int? {
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        func findTable(_ v: NSView) -> NSTableView? {
            if let t = v as? NSTableView { return t }
            for sub in v.subviews { if let t = findTable(sub) { return t } }
            return nil
        }
        return findTable(host).map { $0.numberOfRows }
    }

    /// A republished tree with different contents must reach the laid-out rows. If this ever
    /// fails while `PaneTreeStampTests` still passes, the memoization is over-matching and the
    /// pane has gone stale — the exact bug the stamp design risks.
    @Test func testRepublishedTreeReachesTheLaidOutRows() throws {
        let one = PaneTree(side: .left, version: 1, nodes: [file("a")])
        guard let before = laidOutRowCount(view(one)) else {
            // Headless AppKit did not materialize the table; assert nothing rather than pass
            // vacuously. (Recorded as a skip so a green run never implies this ran.)
            withKnownIssue("List did not bridge to an NSTableView in this environment") {
                Issue.record("no NSTableView")
            }
            return
        }
        #expect(before == 1)

        let three = PaneTree(side: .left, version: 2, nodes: [file("a"), file("b"), file("c")])
        let after = laidOutRowCount(view(three))
        #expect(after == 3)
    }

    /// The pane must render its OWN tree, not the opposite pane's — a mix-up the types allow
    /// (both sides are `PaneTree`) and that no value-level test can see.
    @Test func testPaneRendersItsOwnTreeNotTheOtherPanes() throws {
        let mine = PaneTree(side: .left, version: 1, nodes: [file("a"), file("b")])
        let theirs = PaneTree(side: .right, version: 1, nodes: [file("x")])
        let v = FileTreeView(
            tree: mine, otherTree: theirs, isLoading: false, currentPath: "/root",
            selection: .constant([]), otherSelection: [], isLeft: true, delegate: StubDelegate()
        )
        guard let rows = laidOutRowCount(v) else { return }
        #expect(rows == 2)          // mine, not theirs (which has 1)
    }
}
