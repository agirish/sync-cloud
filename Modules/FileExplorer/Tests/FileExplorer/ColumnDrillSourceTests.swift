import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// Clicking a folder must open its column — whichever half of the click actually fires.
///
/// A column row is `.draggable`, and `TapGesture` fails outright if the pointer drifts even
/// slightly, because the drag claims the gesture. `NSTableView` meanwhile selects on mouse-down
/// regardless. So a click can land as selection-without-tap: the folder highlights and its column
/// never opens, which is what the user reported and what the log showed as `[sel]` lines with no
/// `[tap]` beside them.
///
/// Navigation therefore hangs off whichever source commits, not off the gesture. These pin the
/// source the gesture cannot cover — a selection driven through the real `NSTableView`, which is
/// exactly "the List committed it and the tap did not".
@MainActor
@Suite struct ColumnDrillSourceTests {

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

    final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
    }

    static let root = "/root"

    /// Folders first (`a0…a5`), then files, so a row index maps predictably to a kind.
    private static func tree() -> PaneTree {
        let folders = (0..<6).map { a -> FileNode in
            let dir = "\(root)/a\(a)"
            let kids = (0..<7).map { FileNode(id: "\(dir)/k\($0).pdf", name: "k\($0).pdf", isDirectory: false) }
            return FileNode(id: dir, name: "a\(a)", isDirectory: true, children: kids)
        }
        let files = (0..<4).map { FileNode(id: "\(root)/z\($0).pdf", name: "z\($0).pdf", isDirectory: false) }
        return PaneTree(side: .left, version: 1, nodes: folders + files)
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let index: PaneChildrenIndex

        var body: some View {
            PaneColumnsView(
                tree: tree, otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: index, treeRoot: ColumnDrillSourceTests.root,
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "Right",
                isSingleSource: false, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in }
            )
        }
    }

    private func mount(_ box: Box) -> NSWindow {
        let tree = Self.tree()
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let host = NSHostingView(rootView: Harness(box: box, tree: tree, index: index))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    /// Pumps layout while letting the main dispatch queue drain.
    ///
    /// `await` is load-bearing and no amount of runloop spinning replaces it. A `@MainActor` test
    /// body *occupies* the main queue, so a `DispatchQueue.main.async` block — which is how the pane
    /// defers its navigation — cannot run until the body suspends. Pumping with `CFRunLoopRunInMode`
    /// or `RunLoop.main.run` reported "the column never opened" while the block sat queued and ran
    /// after the assertions, at teardown. Suspending is what releases the queue.
    private func pump(_ window: NSWindow, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
    }

    private func tables(_ view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView { found.append(t) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    /// The reported bug: a folder selected without the tap firing must still open its column.
    @Test func testAListCommittedFolderSelectionOpensItsColumn() async throws {
        let box = Box()
        let window = mount(box)
        await pump(window, seconds: 0.6)
        let table = try #require(tables(window.contentView!).first)
        #expect(tables(window.contentView!).count == 1, "should rest as one column")

        // Row 2 is folder `a2`. Driving the table is the List committing WITHOUT a tap.
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        await pump(window, seconds: 0.8)

        #expect(box.selection == ["\(Self.root)/a2"], "the table's selection never reached the pane")
        #expect(box.browsePath.components == ["a2"],
                "a folder selected without a tap did not open its column (browse = \(box.browsePath.components))")
        #expect(tables(window.contentView!).count == 2, "no second column materialised")
    }

    /// A file selected the same way closes deeper columns rather than opening one.
    @Test func testAListCommittedFileSelectionClosesDeeperColumns() async throws {
        let box = Box()
        let window = mount(box)
        box.browsePath = PaneBrowsePath(components: ["a2"])
        await pump(window, seconds: 0.8)
        #expect(tables(window.contentView!).count == 2)

        // Row 6 in the ROOT column is `z0.pdf` (six folders precede it).
        let root = try #require(tables(window.contentView!).first)
        root.selectRowIndexes(IndexSet(integer: 6), byExtendingSelection: false)
        await pump(window, seconds: 0.8)

        #expect(box.selection == ["\(Self.root)/z0.pdf"])
        #expect(box.browsePath.components.isEmpty,
                "selecting a file left deeper columns open (browse = \(box.browsePath.components))")
    }

    /// Selecting the folder already open must not churn the stack — the deferred navigation
    /// recomputes the same path, and `PaneBrowsePath` has to make that a no-op rather than a
    /// rebuild, or every click on the trail would tear down the columns to its right.
    @Test func testReselectingTheOpenFolderLeavesTheStackAlone() async throws {
        let box = Box()
        let window = mount(box)
        box.browsePath = PaneBrowsePath(components: ["a2"])
        await pump(window, seconds: 0.8)

        let root = try #require(tables(window.contentView!).first)
        root.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        await pump(window, seconds: 0.8)

        #expect(box.browsePath.components == ["a2"])
        #expect(tables(window.contentView!).count == 2, "the open column was torn down and not replaced")
    }
}
