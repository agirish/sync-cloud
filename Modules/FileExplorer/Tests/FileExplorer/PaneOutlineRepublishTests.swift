import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// The worst failure `PaneTree`/`PaneRow` memoization can introduce: a pane that silently stops
/// updating because a stale value compared equal to a fresh one. The other tests for it are
/// value-level (`PaneTreeStampTests`) and would pass even if the view never re-rendered.
///
/// This hosts a real `FileTreeView` and asserts that the rows AppKit laid out track a republish:
/// the laid-out result, not the constant.
@MainActor
@Suite struct PaneOutlineRepublishTests {

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

    private func file(_ name: String) -> FileNode {
        FileNode(id: "/root/\(name)", name: name, isDirectory: false)
    }

    /// A channel of this suite's own, so the panes it mounts are deaf to every other suite's
    /// download posts. A mounted `FileTreeView` subscribes to `.cloudDownloadRequested` whether the
    /// test wants it or not, and on `.default` these left panes would take the `.left` posts
    /// `CloudDownloadWiringTests` makes and fail that suite. See `docs/flaky-tests.md`, "A mounted
    /// view is a live subscriber, in every suite at once".
    private let downloads = NotificationCenter()

    private func view(_ tree: PaneTree) -> FileTreeView {
        FileTreeView(
            tree: tree,
            otherTree: PaneTree(side: .right, version: 0, nodes: []),
            isLoading: false,
            currentPath: "/root",
            selection: .constant([]),
            otherSelection: [],
            isLeft: true,
            delegate: StubDelegate(),
            downloadChannel: downloads
        )
    }

    /// Lays the view out in a window and returns the row count AppKit resolved. A `List` bridges to
    /// `NSTableView`; without a window and a layout pass it has no rows, so nil means "couldn't
    /// observe", which the caller treats as inconclusive, not as a pass.
    private func laidOutRowCount(_ root: FileTreeView) -> Int? {
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        // Dropped again before returning: the hosting view is the last reference to the SwiftUI
        // graph, which holds the pane's live notification subscription. Not `close()`: a `.titled`
        // window is released on close, which over-releases this local and kills the process with no
        // verdict (`docs/flaky-tests.md`, "The wait that hangs instead of failing").
        defer { window.contentView = nil }
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

    /// A republished tree with different contents must reach the laid-out rows. If this fails while
    /// `PaneTreeStampTests` passes, the memoization is over-matching and the pane has gone stale.
    @Test func testRepublishedTreeReachesTheLaidOutRows() throws {
        let one = PaneTree(side: .left, version: 1, nodes: [file("a")])
        guard let before = laidOutRowCount(view(one)) else {
            // Headless AppKit didn't materialize the table; recorded as a known issue rather than
            // passing vacuously, so a green run never implies this ran.
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

    /// The pane must render its own tree, not the opposite pane's: a mix-up the types allow (both
    /// sides are `PaneTree`) and no value-level test can see.
    @Test func testPaneRendersItsOwnTreeNotTheOtherPanes() throws {
        let mine = PaneTree(side: .left, version: 1, nodes: [file("a"), file("b")])
        let theirs = PaneTree(side: .right, version: 1, nodes: [file("x")])
        let v = FileTreeView(
            tree: mine, otherTree: theirs, isLoading: false, currentPath: "/root",
            selection: .constant([]), otherSelection: [], isLeft: true, delegate: StubDelegate(),
            downloadChannel: downloads
        )
        guard let rows = laidOutRowCount(v) else {
            // Same environment gate and rule as the test above: a bare `return` would report a pass
            // in which nothing was measured (the shape `ReviewFactsTests.skippedBecauseRoot`
            // documents).
            withKnownIssue("List did not bridge to an NSTableView in this environment") {
                Issue.record("no NSTableView")
            }
            return
        }
        #expect(rows == 2)          // mine, not theirs (which has 1)
    }
}
