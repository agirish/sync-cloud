import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// Clicking a folder must open its column — whichever half of the click actually fires.
///
/// `TapGesture` fails outright if the pointer drifts even slightly, while `NSTableView` selects on
/// mouse-down regardless. So a click can land as selection-without-tap: the folder highlights and
/// its column never opens, which is what the user reported and what the log showed as `[sel]` lines
/// with no `[tap]` beside them.
///
/// The row was also `.draggable` when this was first diagnosed, and the drag was blamed for the
/// drift. Cross-pane drag has since been removed — that competition is why it never worked — and
/// the drift is unchanged, so `TapGesture`'s own strictness was always the cause.
///
/// Navigation therefore hangs off whichever source commits, not off the gesture. These pin the
/// source the gesture cannot cover — a selection driven through the real `NSTableView`, which is
/// exactly "the List committed it and the tap did not".
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
        /// Counts every `onNavigate` delivery, including ones that recompute the current path.
        /// The reselect test needs it: its end state equals its start state, so the only way to
        /// know the deferred navigation actually ran — rather than asserting into a window it
        /// never reached — is to watch the delivery itself.
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
        /// What the pane reads a click here as carrying. `[]` is a plain click — the premise of
        /// every test below, which is why it is pinned rather than left to the room. See
        /// `paneClickModifiers`: unpinned, the guard asks `NSEvent.modifierFlags`, and a ⇧ held by
        /// whoever is at the Mac silently cancels the navigation these assert on.
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
    /// `await` is load-bearing and no amount of runloop spinning replaces it. A `@MainActor` test
    /// body *occupies* the main queue, so a `DispatchQueue.main.async` block — which is how the pane
    /// defers its navigation — cannot run until the body suspends. Pumping with `CFRunLoopRunInMode`
    /// or `RunLoop.main.run` reported "the column never opened" while the block sat queued and ran
    /// after the assertions, at teardown. Suspending is what releases the queue.
    ///
    /// The deadline bounds only a FAILING run. A fixed real-time pump here is unwinnable under a
    /// loaded parallel suite — the deferred-navigation hop drains seconds late while the wall
    /// clock runs regardless, so a 0.8s window expired before `onNavigate` ran and both drill
    /// tests failed at ~9.5s with `browsePath` still at its initial value. Polling the observable
    /// costs a passing run nothing and gives a starved one the whole deadline.
    ///
    /// Falling through on timeout is what made this suite's flake so hard to read. The deadline
    /// would expire, the body would carry on, and the assertions *after* the wait would report the
    /// end state — "browse = []", "no second column materialised" — which is precisely the
    /// dropped-click defect the suite exists to catch. The premise never having held at all looks
    /// nothing like that from the outside, so `#require` it: a wait that gives up now says so, and
    /// says which wait it was.
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

        // Row 2 is folder `a2`. Driving the table is the List committing WITHOUT a tap.
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

        // Row 6 in the ROOT column is `z0.pdf` (six folders precede it).
        let root = try #require(tables(window.contentView!).first)
        root.selectRowIndexes(IndexSet(integer: 6), byExtendingSelection: false)
        try await settle(window, "selecting a file closed the deeper column") { box.browsePath.components.isEmpty }

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
        try await settle(window, "a2's column opened") { tables(window.contentView!).count == 2 }

        let root = try #require(tables(window.contentView!).first)
        let navigationsBefore = box.navigations
        root.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        // The end state here EQUALS the start state, so polling for it would pass before the
        // deferred navigation even ran. Wait for the delivery itself, then drain a fixed number
        // of queue turns — turns, not wall time, so a starved run still gets real drains — to
        // let any churn the navigation caused reach the view tree.
        try await settle(window, "the reselect delivered its navigation") { box.navigations > navigationsBefore }
        for _ in 0..<30 {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }

        #expect(box.navigations > navigationsBefore, "the reselect never delivered its navigation")
        #expect(box.browsePath.components == ["a2"])
        #expect(tables(window.contentView!).count == 2, "the open column was torn down and not replaced")
    }

    /// The other half of the rule the three tests above depend on: a ⇧-click selects and does
    /// **not** navigate, because ⇧ is the list's own range-select and a navigation would collapse
    /// the multi-selection back to the row just clicked.
    ///
    /// This is also the mechanism behind this suite's flake, pinned deliberately. The guard used to
    /// read `NSEvent.modifierFlags` — the machine's live keyboard — so this state was reachable
    /// with no modifier in the test at all, just someone holding ⇧ at the Mac while the full suite
    /// ran. What it produced is `testAListCommittedFolderSelectionOpensItsColumn`'s exact reported
    /// failure: `browsePath == []` and one column, after the whole 20s deadline.
    ///
    /// The absence assertion is not vacuous, and the ordering is the reason. `selection` is written
    /// *before* the guard, so waiting for it proves the commit path ran and got as far as the
    /// guard; only then is "and the navigation did not happen" a claim about the guard rather than
    /// about the clock.
    @Test func testAShiftHeldSelectionSelectsWithoutOpeningAColumn() async throws {
        let box = Box()
        let window = mount(box, modifiers: .shift)
        try await settle(window, "the root column mounted") { !tables(window.contentView!).isEmpty }
        let table = try #require(tables(window.contentView!).first)

        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        try await settle(window, "the selection reached the pane") {
            box.selection == ["\(Self.root)/a2"]
        }
        // Past the guard by now; drain turns so a navigation that WAS queued would land.
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
    /// `PaneColumnsView` still asks the keyboard exactly as it did before. That is the whole
    /// behaviour-preservation claim for the production change, so it is asserted rather than
    /// assumed.
    @Test func testTheShippedClickModifiersAreStillTheLiveKeyboard() {
        #expect(EnvironmentValues().paneClickModifiers == nil)
    }
}
