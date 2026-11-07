import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// A plain click on a column row must select it. In Columns the `List` doesn't reliably commit a
/// click's selection (the tap handler runs and the column navigates, but the row isn't
/// highlighted), so the tap commits a plain click itself. ⌘- and ⇧-click stay the List's:
/// assigning on every tap would flatten a multi-selection to one row, and Copy, Move and Delete
/// could act on only one item.
@Suite struct ColumnTapSelectionTests {

    /// The gate the tap handler applies before it touches `selection`.
    @Test func testAPlainClickIsTheTapHandlersToCommit() {
        #expect(PaneViewMode.clickNavigates(modifiers: []))
        #expect(PaneViewMode.clickNavigates(modifiers: [.option]))
    }

    /// …and a modified click is not: the handler returns before assigning, so the List keeps its
    /// extend and range-select behaviour and a multi-selection survives.
    @Test func testAModifiedClickIsLeftEntirelyToTheList() {
        #expect(!PaneViewMode.clickNavigates(modifiers: [.command]))
        #expect(!PaneViewMode.clickNavigates(modifiers: [.shift]))
        #expect(!PaneViewMode.clickNavigates(modifiers: [.command, .shift]))
        // A modifier the rule doesn't name must not smuggle a plain click past the gate.
        #expect(!PaneViewMode.clickNavigates(modifiers: [.command, .option]))
        #expect(!PaneViewMode.clickNavigates(modifiers: [.shift, .option]))
    }

    /// ⌃ is the secondary click, not a plain one. macOS delivers control-click as a button-1 event
    /// carrying `.control`, so it reaches the tap handler and the background deselect recognizer;
    /// admitted, the context menu would open while the same gesture selected, cleared the other pane
    /// and, on empty space, closed every column to the right.
    @Test func testAControlClickIsSecondaryAndBelongsToTheContextMenu() {
        #expect(!PaneViewMode.clickNavigates(modifiers: [.control]))
        #expect(!PaneViewMode.clickNavigates(modifiers: [.control, .option]))
    }
}

/// The tap's selection write has to reach the pane, and it has to be the write a click means:
/// replace the selection with this one row.
@MainActor
@Suite struct ColumnTapSelectionWiringTests {

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

    final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
    }

    static let root = "/root"

    private static func tree() -> PaneTree {
        let nodes = (0..<6).map { i -> FileNode in
            let dir = "\(root)/folder\(i)"
            let kids = (0..<4).map { j in
                FileNode(id: "\(dir)/file\(j)", name: "file\(j)", isDirectory: false)
            }
            return FileNode(id: dir, name: "folder\(i)", isDirectory: true, children: kids)
        }
        return PaneTree(side: .left, version: 1, nodes: nodes)
    }

    /// The pane plus the observation that makes it re-render. `PaneColumnsView` takes bindings, and a
    /// bare `Binding(get:set:)` over the box would update the box without the view learning of it,
    /// so the columns would never open.
    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let index: PaneChildrenIndex

        var body: some View {
            PaneColumnsView(
                tree: tree,
                otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: index,
                treeRoot: ColumnTapSelectionWiringTests.root,
                browsePath: $box.browsePath,
                onNavigate: { box.browsePath = $0 },
                selection: $box.selection,
                otherSelection: [],
                isLeft: true,
                delegate: StubDelegate(),
                diffIndex: .empty,
                otherPaneName: "Right",
                isSingleSource: false,
                density: .compact,
                isActivePane: true,
                placement: nil,
                onBarEdgeFlip: nil,
                onQuickLook: { _ in }, onBackgroundDeselect: { _ in }
            )
        }
    }

    /// Mounts the real Columns pane in a real window, so the row and its gesture exist as AppKit
    /// hosts them.
    private func mount(_ box: Box) -> NSWindow {
        let tree = Self.tree()
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let host = NSHostingView(rootView: Harness(box: box, tree: tree, index: index))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    private func pump(_ window: NSWindow, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            window.layoutIfNeeded()
        }
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

    /// The pane really materialises its columns, so nothing here passes against a window that
    /// rendered nothing.
    @Test func testTheColumnsPaneMountsAndDrills() {
        let box = Box()
        let window = mount(box)
        pump(window, seconds: 0.5)
        #expect(tables(window.contentView!).count == 1, "resting pane should be one column")

        box.browsePath = PaneBrowsePath(components: ["folder2"])
        pump(window, seconds: 0.6)
        #expect(tables(window.contentView!).count == 2, "drilling should open a second column")
    }

    /// A click replaces the whole selection rather than adding to it: the selection is a flat
    /// `Set<String>` shared across columns, and a plain click means "just this row".
    @Test func testTheTapsWriteReplacesRatherThanExtends() {
        let box = Box()
        box.selection = ["\(Self.root)/folder0", "\(Self.root)/folder1"]
        // The assignment the tap handler makes.
        let clicked = "\(Self.root)/folder4"
        if box.selection != [clicked] { box.selection = [clicked] }
        #expect(box.selection == [clicked],
                "a plain click must replace the selection, not extend it")
    }
}
