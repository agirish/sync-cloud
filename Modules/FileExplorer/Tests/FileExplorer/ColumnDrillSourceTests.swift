import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// Clicking a folder must open its column, whichever half of the click fires. `TapGesture` fails
/// if the pointer drifts even slightly, while `NSTableView` selects on mouse-down regardless, so a
/// click can select without tapping: the folder highlights and its column never opens (`[sel]`
/// log lines with no `[tap]`). Navigation therefore follows whichever source commits. These pin
/// the source the gesture can't cover: a selection driven through the real `NSTableView`.
@MainActor
@Suite struct ColumnDrillSourceTests {

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
        /// Counts every `onNavigate` delivery, including ones that recompute the current path. The
        /// reselect test ends where it started, so only this shows the deferred navigation ran.
        var navigations = 0
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
        /// The modifiers the pane reads a click here as carrying; `[]` is a plain click, the
        /// premise of every test below. Pinned because unpinned, `paneClickModifiers` falls back to
        /// `NSEvent.modifierFlags`, and a ⇧ held at the Mac would cancel the navigation.
        var modifiers: NSEvent.ModifierFlags = []

        var body: some View {
            PaneColumnsView(
                tree: tree, otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: index, treeRoot: ColumnDrillSourceTests.root,
                browsePath: $box.browsePath,
                onNavigate: { box.navigations += 1; box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "Right",
                isSingleSource: false, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in }, onBackgroundDeselect: { _ in }
            )
            .environment(\.paneClickModifiers, modifiers)
        }
    }

    private func mount(_ box: Box, modifiers: NSEvent.ModifierFlags = []) -> NSWindow {
        let tree = Self.tree()
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let host = NSHostingView(rootView: Harness(box: box, tree: tree, index: index,
                                                   modifiers: modifiers))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    /// Pumps layout until `condition` holds, letting the main dispatch queue drain between polls.
    ///
    /// The `await` matters: a `@MainActor` test body occupies the main queue, so the pane's
    /// `DispatchQueue.main.async` navigation can't run until the body suspends. Spinning the run
    /// loop instead leaves the block queued until teardown.
    ///
    /// The deadline bounds only a failing run; polling costs a passing run nothing and gives a
    /// starved one the whole deadline. On timeout it `#require`s, naming the wait, because falling
    /// through would report "browse = []", the very defect the suite catches.
    private func settle(_ window: NSWindow, _ premise: String, deadline: TimeInterval = 20,
                        until condition: () -> Bool) async throws {
        let start = Date()
        let end = start.addingTimeInterval(deadline)
        while !condition() && Date() < end {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
        try #require(condition(),
                     "\(premise) — never held; gave up after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
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
        try await settle(window, "the root column mounted") { !tables(window.contentView!).isEmpty }
        let table = try #require(tables(window.contentView!).first)
        #expect(tables(window.contentView!).count == 1, "should rest as one column")

        // Row 2 is folder `a2`. Driving the table is the List committing without a tap.
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        try await settle(window, "the selection opened a2's column") {
            box.browsePath.components == ["a2"] && tables(window.contentView!).count == 2
        }

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
        try await settle(window, "a2's column opened") { tables(window.contentView!).count == 2 }

        // Row 6 in the root column is `z0.pdf` (six folders precede it).
        let root = try #require(tables(window.contentView!).first)
        root.selectRowIndexes(IndexSet(integer: 6), byExtendingSelection: false)
        try await settle(window, "selecting a file closed the deeper column") { box.browsePath.components.isEmpty }

        #expect(box.selection == ["\(Self.root)/z0.pdf"])
        #expect(box.browsePath.components.isEmpty,
                "selecting a file left deeper columns open (browse = \(box.browsePath.components))")
    }

    /// Selecting the folder already open must not churn the stack: the deferred navigation
    /// recomputes the same path, and `PaneBrowsePath` must make that a no-op, or every click on the
    /// trail would tear down the columns to its right.
    @Test func testReselectingTheOpenFolderLeavesTheStackAlone() async throws {
        let box = Box()
        let window = mount(box)
        box.browsePath = PaneBrowsePath(components: ["a2"])
        try await settle(window, "a2's column opened") { tables(window.contentView!).count == 2 }

        let root = try #require(tables(window.contentView!).first)
        let navigationsBefore = box.navigations
        root.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        // The end state equals the start state, so polling for it would pass before the navigation
        // ran. Wait for the delivery, then drain a fixed number of turns (not wall time, so a
        // starved run still drains) to let any churn reach the view tree.
        try await settle(window, "the reselect delivered its navigation") { box.navigations > navigationsBefore }
        for _ in 0..<30 {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }

        #expect(box.navigations > navigationsBefore, "the reselect never delivered its navigation")
        #expect(box.browsePath.components == ["a2"])
        #expect(tables(window.contentView!).count == 2, "the open column was torn down and not replaced")
    }

    /// The other half of the rule: a ⇧-click selects and does not navigate, because ⇧ is the list's
    /// range-select and navigating would collapse the selection to the clicked row. Unpinned, a ⇧
    /// held at the Mac would make the tests above fail this way.
    ///
    /// Not vacuous: `selection` is written before the guard, so waiting for it proves the commit
    /// reached the guard, and the missing navigation is then about the guard, not the clock.
    @Test func testAShiftHeldSelectionSelectsWithoutOpeningAColumn() async throws {
        let box = Box()
        let window = mount(box, modifiers: .shift)
        try await settle(window, "the root column mounted") { !tables(window.contentView!).isEmpty }
        let table = try #require(tables(window.contentView!).first)

        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        try await settle(window, "the selection reached the pane") {
            box.selection == ["\(Self.root)/a2"]
        }
        // Past the guard by now; drain turns so a navigation that was queued would land.
        for _ in 0..<30 {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }

        #expect(box.navigations == 0, "a ⇧-click navigated")
        #expect(box.selection == ["\(Self.root)/a2"], "a ⇧-click did not select")
        #expect(box.browsePath.components.isEmpty,
                "a ⇧-click opened a column (browse = \(box.browsePath.components))")
        #expect(tables(window.contentView!).count == 1, "a ⇧-click opened a second column")
    }

    /// The pin is a test seam and must stay one: nothing in the app sets it, so every guard in
    /// `PaneColumnsView` still asks the live keyboard.
    @Test func testTheShippedClickModifiersAreStillTheLiveKeyboard() {
        #expect(EnvironmentValues().paneClickModifiers == nil)
    }
}
