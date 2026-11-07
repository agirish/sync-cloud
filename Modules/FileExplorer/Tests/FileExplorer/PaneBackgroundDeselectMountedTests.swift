import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// Where the deselect target lands once the pane is mounted: `PaneBackgroundDeselectTests` pins the
/// decision, this pins the wiring.
///
/// Neither can pin the click itself. A `swift test` process can't make a window key, so a synthetic
/// click never commits a selection; the end-to-end proof is a `[deselect]` line in a live session's
/// log.
@MainActor
@Suite struct PaneBackgroundDeselectMountedTests {

    final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
        var deselects: [Int?] = []
    }

    static let root = "/root"

    /// Small folders on purpose: three rows per column leave real empty area below them, the area
    /// this feature is about.
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
                delegate: NoOpFileActionDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in },
                onBackgroundDeselect: { box.deselects.append($0) }
            )
        }
    }

    /// Polls for a condition instead of sleeping a fixed interval; a fixed settle holds the main
    /// thread long enough to starve other mounted suites in the parallel run. Returns whether the
    /// condition held, so a caller can assert on it.
    ///
    /// The loop is `LayoutPumpWait.pump`; see `pumpFloor` there for why a wall-clock deadline alone
    /// doesn't bound a congested main actor.
    @discardableResult
    private func settle(_ window: NSWindow, timeout: Double = 5,
                        until condition: () -> Bool) async -> Bool {
        await LayoutPumpWait.pump(window, upTo: timeout, until: condition).held
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
            return PaneRowRevealTests.scrollViews(root).filter { $0.documentView is NSTableView }.count == expected
        }

        let all = PaneRowRevealTests.scrollViews(window.contentView!)
        let stack = try #require(all.first { !($0.documentView is NSTableView) }, "no stack scroll view")
        let columns = all.filter { $0.documentView is NSTableView }
        return (window, stack, columns, box)
    }

    /// Recognizers this feature installs, told apart from SwiftUI's by their delegate: the mounted
    /// tables already carry four of AppKit's and SwiftUI's.
    private func deselectRecognizers(_ view: NSView) -> [NSGestureRecognizer] {
        view.gestureRecognizers.filter { $0.delegate is PaneBackgroundDeselect.CatcherView }
    }

    /// Every column carries the target, on its own table, exactly once. Fails if `column` drops its
    /// `.background(PaneBackgroundDeselect { … })`, if `PaneListResolver` resolves only the first
    /// column, or if a rebuilt list keeps its old recognizer: drilling replaces the column stack,
    /// and a recognizer kept per drill would fire the deselect many times per click.
    @Test func testEveryColumnCarriesTheDeselectTarget() async throws {
        let (window, _, columns, _) = try await mount(paneWidth: 520, depth: ["a2", "b1"])
        defer { _ = window }

        #expect(columns.count == 3, "fixture should open three columns, got \(columns.count)")
        // Waiting for a recognizer to appear can't make this pass falsely: the assertion below
        // still runs, and fails, if the wait times out. It only stops a slow install reading as a
        // missing one.
        let tables = columns.compactMap { $0.documentView as? NSTableView }
        await settle(window) { tables.allSatisfy { self.deselectRecognizers($0).count == 1 } }
        for (index, table) in tables.enumerated() {
            #expect(deselectRecognizers(table).count == 1,
                    "column \(index) should carry exactly one deselect recognizer")
        }
    }

    /// The premise for putting the recognizer on the table, not the clip view: SwiftUI stretches
    /// its table to fill the viewport, so the empty area below the rows belongs to the table and a
    /// click there hit-tests straight to it. If a future SwiftUI stops stretching, this fails and
    /// the attachment point needs revisiting.
    @Test func testTheColumnTablesFillTheirViewports() async throws {
        let (window, _, columns, _) = try await mount(paneWidth: 520, depth: ["a2", "b1"])
        defer { _ = window }

        let column = try #require(columns.first)
        let table = try #require(column.documentView as? NSTableView)
        #expect(table.numberOfRows <= 4, "fixture should leave real empty area below the rows")
        #expect(table.bounds.height == column.contentView.bounds.height,
                "table \(table.bounds.height)pt vs viewport \(column.contentView.bounds.height)pt")
    }

    /// The stack's content fills its viewport when the columns don't: the trailing filler takes the
    /// slack beside two 210pt columns in a 900pt pane (less `columnStackTrailingGutter`), so a
    /// click there deselects instead of doing nothing. Fails if the filler leaves the `HStack`.
    @Test func testTheTrailingFillerTakesTheSlackBesideTheColumns() async throws {
        let (window, stack, columns, _) = try await mount(paneWidth: 900, depth: ["a2"])
        defer { _ = window }

        #expect(columns.count == 2, "fixture should open two columns, got \(columns.count)")
        let content = try #require(stack.documentView)
        let viewport = 900 - PaneViewMode.columnStackTrailingGutter
        // The premise: the columns alone leave real slack in the viewport.
        let columnsWidth = columns.reduce(0) { $0 + $1.bounds.width }
        #expect(columnsWidth < viewport, "columns \(columnsWidth)pt should not fill a \(viewport)pt viewport")
        #expect(content.bounds.width == viewport,
                "content \(content.bounds.width)pt should span the viewport, filler included")
    }
}
