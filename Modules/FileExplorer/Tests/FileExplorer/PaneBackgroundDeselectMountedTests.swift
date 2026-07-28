import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// Where the deselect target actually lands once the pane is mounted, which is the half
/// `PaneBackgroundDeselectTests` cannot see: that file pins the *decision*, this one pins the
/// *wiring*.
///
/// Neither can pin the click itself. A `swift test` process cannot make a window key, so a
/// synthetic click never commits a selection — the end-to-end proof is a `[deselect]` line in a
/// live session's log, not an assertion here.
@MainActor
@Suite struct PaneBackgroundDeselectMountedTests {

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
        var deselects: [Int?] = []
    }

    static let root = "/root"

    /// Small folders on purpose: three rows per column leaves real empty area below them, which is
    /// the area this whole feature is about.
    private static func tree() -> PaneTree {
        let top = (0..<4).map { a -> FileNode in
            let dir = "\(root)/a\(a)"
            let mids = (0..<3).map { b -> FileNode in
                let bPath = "\(dir)/b\(b)"
                return FileNode(id: bPath, name: "b\(b)", isDirectory: true,
                                children: (0..<3).map { FileNode(id: "\(bPath)/f\($0).pdf", name: "f\($0).pdf", isDirectory: false) })
            }
            return FileNode(id: dir, name: "a\(a)", isDirectory: true, children: mids)
        }
        return PaneTree(side: .left, version: 1, nodes: top)
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let index: PaneChildrenIndex

        var body: some View {
            PaneColumnsView(
                tree: tree, otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: index, treeRoot: PaneBackgroundDeselectMountedTests.root,
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in },
                onBackgroundDeselect: { box.deselects.append($0) }
            )
        }
    }

    /// Polls for a condition rather than sleeping a fixed interval.
    ///
    /// The fixed 1.5s settle this started with held the main thread long enough, five tests over,
    /// to starve two unrelated mounted suites into failing under the parallel run — they passed
    /// alone and passed on `main`, which is what pointed at the harness rather than the change.
    /// Returns whether the condition was met, so a caller can assert on it instead of assuming.
    @discardableResult
    private func settle(_ window: NSWindow, timeout: Double = 5,
                        until condition: () -> Bool = { false }) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            window.layoutIfNeeded()
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
        return condition()
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { found.append(s) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    private func mount(paneWidth: CGFloat, depth: [String]) async throws
        -> (window: NSWindow, stack: NSScrollView, columns: [NSScrollView], box: Box) {
        let box = Box()
        let tree = Self.tree()
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let host = NSHostingView(rootView: Harness(box: box, tree: tree, index: index))
        host.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()

        box.browsePath = PaneBrowsePath(components: depth)
        // The columns opening is the neutral signal: it is the drill completing, not anything this
        // file asserts about.
        let expected = depth.count + 1
        await settle(window) { [weak window] in
            guard let root = window?.contentView else { return false }
            return scrollViews(root).filter { $0.documentView is NSTableView }.count == expected
        }

        let all = scrollViews(window.contentView!)
        let stack = try #require(all.first { !($0.documentView is NSTableView) }, "no stack scroll view")
        let columns = all.filter { $0.documentView is NSTableView }
        return (window, stack, columns, box)
    }

    /// Recognizers this feature installs, told apart from SwiftUI's own by their target — the
    /// mounted tables carry four of AppKit's and SwiftUI's before this adds one.
    private func deselectRecognizers(_ view: NSView) -> [NSGestureRecognizer] {
        view.gestureRecognizers.filter { $0.delegate is PaneBackgroundDeselect.CatcherView }
    }

    /// Every column carries the target, on its own table.
    ///
    /// Mutation-tested: dropping the `.background(PaneBackgroundDeselect { … })` from `column`
    /// fails this. It also failed for real before `PaneListResolver` was frame-anchored — only the
    /// first column resolved, which is the defect that fix records.
    @Test func testEveryColumnCarriesTheDeselectTarget() async throws {
        let (window, _, columns, _) = try await mount(paneWidth: 520, depth: ["a2", "b1"])
        defer { _ = window }

        #expect(columns.count == 3, "fixture should open three columns, got \(columns.count)")
        // Waiting for a recognizer to APPEAR cannot make this pass falsely — the assertion below
        // still runs, and still fails, if the wait times out. It only stops a slow install from
        // reading as a missing one.
        let tables = columns.compactMap { $0.documentView as? NSTableView }
        await settle(window) { tables.allSatisfy { self.deselectRecognizers($0).count == 1 } }
        for (index, table) in tables.enumerated() {
            #expect(deselectRecognizers(table).count == 1,
                    "column \(index) should carry exactly one deselect recognizer")
        }
    }

    /// The premise for putting the recognizer on the table rather than the clip view, asserted
    /// rather than assumed: SwiftUI stretches its table to fill the viewport, so the empty area
    /// below the rows belongs to the table and a click there hit-tests straight to it.
    ///
    /// The fixture's columns hold three rows in a 520pt pane, so there is a great deal of empty
    /// area — if a future SwiftUI stops stretching, this fails and the attachment point needs
    /// revisiting.
    @Test func testTheColumnTablesFillTheirViewports() async throws {
        let (window, _, columns, _) = try await mount(paneWidth: 520, depth: ["a2", "b1"])
        defer { _ = window }

        let column = try #require(columns.first)
        let table = try #require(column.documentView as? NSTableView)
        #expect(table.numberOfRows <= 4, "fixture should leave real empty area below the rows")
        #expect(table.bounds.height == column.contentView.bounds.height,
                "table \(table.bounds.height)pt vs viewport \(column.contentView.bounds.height)pt")
    }

    /// A rebuilt list must not leave its old recognizer behind. Drilling replaces the column stack
    /// wholesale, and one recognizer accumulated per drill would fire the deselect many times per
    /// click — and worse, an orphaned recognizer's target is unowned.
    @Test func testDrillingDoesNotAccumulateRecognizers() async throws {
        let (window, _, columns, _) = try await mount(paneWidth: 520, depth: ["a2", "b1"])
        defer { _ = window }

        let tables = columns.compactMap { $0.documentView as? NSTableView }
        await settle(window) { tables.allSatisfy { !self.deselectRecognizers($0).isEmpty } }
        for table in tables {
            #expect(deselectRecognizers(table).count <= 1)
        }
    }

    /// The stack's content fills the pane when the columns do not, which is the trailing filler
    /// doing its job: two 210pt columns in a 900pt pane leave 480pt of dead space, and clicking it
    /// should deselect rather than do nothing.
    ///
    /// Mutation-tested: removing `trailingDeselectFiller` from the `HStack` leaves the content at
    /// the columns' own width and fails this.
    @Test func testTheTrailingFillerTakesTheSlackBesideTheColumns() async throws {
        let (window, stack, columns, _) = try await mount(paneWidth: 900, depth: ["a2"])
        defer { _ = window }

        #expect(columns.count == 2, "fixture should open two columns, got \(columns.count)")
        let content = try #require(stack.documentView)
        // The premise: the columns alone leave real slack in a 900pt pane.
        let columnsWidth = columns.reduce(0) { $0 + $1.bounds.width }
        #expect(columnsWidth < 900, "columns \(columnsWidth)pt should not fill a 900pt pane")
        #expect(content.bounds.width == 900,
                "content \(content.bounds.width)pt should span the pane, filler included")
    }

    /// A click cannot be synthesized into this harness at all — neither the empty area nor a row
    /// responds, because a `swift test` process cannot make its window key. Pinned so the next
    /// person does not spend the afternoon rediscovering it: the end-to-end proof for this feature
    /// is a `[deselect]` line in a live session's log.
    @Test func testSyntheticClicksCannotDriveThisHarness() async throws {
        let (window, _, columns, box) = try await mount(paneWidth: 520, depth: ["a2", "b1"])
        defer { _ = window }

        let column = columns[1]
        let frame = column.convert(column.bounds, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: CGPoint(x: frame.midX, y: frame.minY + 40), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
        // No condition to wait on — this asserts an ABSENCE, so it waits a bounded interval and
        // leans on the mounted-columns check above to keep it from passing vacuously.
        await settle(window, timeout: 0.3)
        #expect(columns.count == 3, "fixture must really be mounted, or the absence below is empty")
        #expect(box.deselects.isEmpty,
                "if this ever fires, the harness gained real clicks — write the end-to-end test it was blocking")
    }
}
