import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// **A row the host selects on the user's behalf is brought into view** (TE47).
///
/// The open document is selected in the left pane — by Edit's rail, by every hand-off into Edit, by
/// Reveal in Browse, by the header's "in <folder>", by ⌘N — and a selection is not a reveal: the
/// search suite measured that on the shipped build (a hit 70 rows down selected at y = 2330 with
/// the viewport showing 0…500). These tests measure ARRIVAL, the way that suite does — the row
/// inside its `NSTableView`'s visible rectangle, and in Columns the column inside the stack's
/// visible span — never a call returning.
///
/// Each case first establishes that its fixture could have failed: the row starts off screen, and
/// selecting it alone (no reveal) leaves it there.
@MainActor
@Suite(.serialized) struct PaneRowRevealTests {

    typealias Stub = PaneSearchTreeRevealTests.StubDelegate

    static let root = "/root"
    /// A folder long enough that a row near its end is several screens below the fold.
    static let rowCount = 150
    static let targetIndex = 140
    static func name(_ i: Int) -> String { String(format: "note %03d.md", i) }

    // MARK: Fixtures

    final class Box: ObservableObject {
        @Published var selection: Set<String> = []
        @Published var browsePath = PaneBrowsePath()
        @Published var reveal: PaneRowReveal?
        private var token = 0

        /// The host's act: the selection written, and a fresh reveal asked for it.
        func reveal(_ path: String) {
            token &+= 1
            reveal = PaneRowReveal(path: path, token: token)
        }
    }

    /// `rowCount` files at the root (`depth == 0`), or the same files at the bottom of a chain
    /// `a0/b0/c0` `depth` folders deep, each level with two sibling folders so the columns have
    /// something to list.
    static func tree(depth: Int) -> PaneTree {
        let levels = ["a", "b", "c", "d"]
        func files(in folder: String) -> [FileNode] {
            (0..<rowCount).map { FileNode(id: "\(folder)/\(name($0))", name: name($0), isDirectory: false) }
        }
        func level(_ index: Int, in folder: String) -> [FileNode] {
            guard index < depth else { return files(in: folder) }
            return (0..<2).map { branch in
                let child = "\(folder)/\(levels[index])\(branch)"
                return FileNode(id: child, name: "\(levels[index])\(branch)", isDirectory: true,
                                children: branch == 0 ? level(index + 1, in: child) : [])
            }
        }
        return PaneTree(side: .left, version: 1, nodes: level(0, in: root))
    }

    static func deepestFolder(depth: Int) -> String {
        ([root] + ["a0", "b0", "c0", "d0"].prefix(depth)).joined(separator: "/")
    }

    static func target(depth: Int) -> String { "\(deepestFolder(depth: depth))/\(name(targetIndex))" }

    struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let viewMode: PaneViewMode
        let defaults: UserDefaults

        var body: some View {
            FileTreeView(
                tree: tree,
                otherTree: PaneTree(side: .right, version: 1, nodes: []),
                isLoading: false,
                currentPath: PaneRowRevealTests.root,
                selection: $box.selection,
                otherSelection: [],
                isLeft: true,
                delegate: Stub(),
                rowReveal: box.reveal,
                viewMode: viewMode,
                // Off, so selecting a file raises no preview: the preview's arrival is itself a
                // trigger that reveals the deepest column, and with it on, the Columns control
                // below would pass with no row reveal at all.
                previewEnabled: .constant(false),
                childrenIndex: PaneChildrenIndex(tree: tree, treeRoot: PaneRowRevealTests.root),
                browsePath: $box.browsePath,
                onColumnNavigate: { box.browsePath = $0 }
            )
            .equatable()
            .defaultAppStorage(defaults)
            // Offscreen, never-key window: an animated scroll never advances here. See
            // `paneColumnRevealAnimation`; the destination is identical unanimated.
            .environment(\.paneColumnRevealAnimation, nil)
        }
    }

    struct Mounted {
        let window: NSWindow
        let box: Box
        let tree: PaneTree
    }

    static func mount(_ viewMode: PaneViewMode, depth: Int = 0, width: CGFloat = 700,
                      box: Box = Box()) -> Mounted {
        let tree = tree(depth: depth)
        let host = NSHostingView(rootView: Harness(box: box, tree: tree, viewMode: viewMode,
                                                   defaults: ScratchDefaults("pane-row-reveal")))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return Mounted(window: window, box: box, tree: tree)
    }

    static func tables(_ view: NSView) -> [NSTableView] { PaneSearchTreeRevealTests.tables(view) }

    static func scrollViews(_ view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// The table listing `folder`'s files — the one with `rowCount` rows — and the row's index in it.
    static func table(listing count: Int, in window: NSWindow) -> NSTableView? {
        tables(window.contentView!).first { $0.numberOfRows == count }
    }

    /// Whether the target row is inside its table's visible rectangle, by AppKit's own geometry.
    static func rowIsVisible(_ window: NSWindow, index: Int) -> Bool {
        guard let table = table(listing: rowCount, in: window), table.numberOfRows > index,
              let scroll = table.enclosingScrollView else { return false }
        return scroll.documentVisibleRect.intersects(table.rect(ofRow: index))
    }

    /// The horizontal stack in Columns, and whether the table listing the files lies inside the
    /// part of it the clip is showing.
    static func stack(_ window: NSWindow) -> NSScrollView? {
        scrollViews(window.contentView!).first { !($0.documentView is NSTableView) && $0.documentView != nil }
    }

    static func deepestColumnIsVisible(_ window: NSWindow) -> Bool {
        guard let stack = stack(window), let document = stack.documentView,
              let table = table(listing: rowCount, in: window),
              let column = table.enclosingScrollView else { return false }
        let frame = column.convert(column.bounds, to: document)
        let clip = stack.contentView.bounds
        return frame.minX >= clip.minX - 1 && frame.maxX <= clip.maxX + 1
    }

    /// Pumps until a marker queued now — past both reveal attempts — has fired, and reports whether
    /// `condition` ever held on the way. How an ABSENCE is bounded by the queue rather than a clock
    /// (see `ColumnPreviewRevealTests.maxOriginDrift`).
    static func everHolds(_ window: NSWindow, _ condition: () -> Bool) async -> Bool {
        final class Marker { var fired = false }
        let marker = Marker()
        DispatchQueue.main.asyncAfter(deadline: .now() + FileTreeView.searchRevealRetryDelay + 0.3) {
            MainActor.assumeIsolated { marker.fired = true }
        }
        var held = false
        _ = await LayoutPumpWait.pump(window, upTo: 30) {
            if condition() { held = true }
            return marker.fired
        }
        return held || condition()
    }

    // MARK: The rule

    /// Only while the named row is the WHOLE selection — the rule both presentations ask.
    @Test func aRevealIsAnsweredOnlyWhileItsRowIsTheSelection() {
        let reveal = PaneRowReveal(path: "/r/a.md", token: 1)
        #expect(FileTreeView.revealsRow(reveal, selection: ["/r/a.md"]) == "/r/a.md")
        #expect(FileTreeView.revealsRow(reveal, selection: []) == nil)
        #expect(FileTreeView.revealsRow(reveal, selection: ["/r/b.md"]) == nil)
        // A multi-selection that happens to include it is the user's, not the reveal's.
        #expect(FileTreeView.revealsRow(reveal, selection: ["/r/a.md", "/r/b.md"]) == nil)
        #expect(FileTreeView.revealsRow(nil, selection: ["/r/a.md"]) == nil)
    }

    /// The pane's gate lets the reveal through: a new token is a change even for the same path.
    @Test func aRepeatedRevealOfTheSamePathIsANewRequest() {
        #expect(PaneRowReveal(path: "/r/a.md", token: 1) != PaneRowReveal(path: "/r/a.md", token: 2))
    }

    // MARK: Tree

    @Test("Tree: a row 140 of 150 down is scrolled into view, not just selected")
    func theTreeBringsTheRevealedRowIntoView() async throws {
        let mounted = Self.mount(.tree)
        let window = mounted.window
        let listed = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.table(listing: Self.rowCount, in: window) != nil
        }
        try #require(listed.held, "the tree never listed its \(Self.rowCount) rows")
        let target = Self.target(depth: 0)
        #expect(!Self.rowIsVisible(window, index: Self.targetIndex),
                "the fixture must start with the row below the fold")

        // Selected, not revealed: the control. The row stays where it was.
        mounted.box.selection = [target]
        let byItself = await Self.everHolds(window) { Self.rowIsVisible(window, index: Self.targetIndex) }
        #expect(!byItself, "selecting the row alone scrolled it into view — the reveal below would prove nothing")

        mounted.box.reveal(target)
        let revealed = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.rowIsVisible(window, index: Self.targetIndex)
        }
        #expect(revealed.held, "the revealed row is still below the fold (\(revealed.pumps) pumps)")
    }

    /// **Never fight the user.** A request for a row the user has since moved off is not answered.
    @Test func theTreeIgnoresARevealForARowThatIsNotTheSelection() async throws {
        let mounted = Self.mount(.tree)
        let window = mounted.window
        _ = await LayoutPumpWait.pump(window, upTo: 10) { Self.table(listing: Self.rowCount, in: window) != nil }
        mounted.box.selection = ["\(Self.root)/\(Self.name(1))"]
        mounted.box.reveal(Self.target(depth: 0))
        let moved = await Self.everHolds(window) { Self.rowIsVisible(window, index: Self.targetIndex) }
        #expect(!moved, "the pane scrolled to a row the user is not on")
    }

    /// A pane that was not on screen when the reveal was asked for — Edit's pane folded behind the
    /// rail, a workspace switch mounting it — answers it when it appears.
    @Test func theTreeAnswersAStandingRevealWhenItAppears() async throws {
        let box = Box()
        let target = Self.target(depth: 0)
        box.selection = [target]
        box.reveal(target)
        let window = Self.mount(.tree, box: box).window
        let revealed = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.rowIsVisible(window, index: Self.targetIndex)
        }
        #expect(revealed.held, "a pane mounted with the reveal standing opened at the top (\(revealed.pumps) pumps)")
    }

    // MARK: Columns

    @Test("Columns: a row 140 of 150 down its column is scrolled into view")
    func theColumnBringsTheRevealedRowIntoView() async throws {
        let mounted = Self.mount(.columns)
        let window = mounted.window
        let listed = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.table(listing: Self.rowCount, in: window) != nil
        }
        try #require(listed.held, "the column never listed its \(Self.rowCount) rows")
        let target = Self.target(depth: 0)
        #expect(!Self.rowIsVisible(window, index: Self.targetIndex),
                "the fixture must start with the row below the fold")

        mounted.box.selection = [target]
        let byItself = await Self.everHolds(window) { Self.rowIsVisible(window, index: Self.targetIndex) }
        #expect(!byItself, "selecting the row alone scrolled it into view — the reveal below would prove nothing")

        mounted.box.reveal(target)
        let revealed = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.rowIsVisible(window, index: Self.targetIndex)
        }
        #expect(revealed.held, "the revealed row is still below the fold (\(revealed.pumps) pumps)")
    }

    /// **The column itself must be on screen**, or the row's scroll shows nothing. Four columns
    /// deep in a 700pt pane, scrolled back to the first column: the reveal brings the deepest
    /// column into view AND its row.
    @Test("Columns: the revealed row's column is scrolled into view too")
    func theStackBringsTheRevealedColumnIntoView() async throws {
        let depth = 3
        let mounted = Self.mount(.columns, depth: depth)
        let window = mounted.window
        mounted.box.browsePath = PaneBrowsePath(components: ["a0", "b0", "c0"])
        let opened = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.table(listing: Self.rowCount, in: window) != nil
        }
        try #require(opened.held, "the deepest column never opened")
        let stack = try #require(Self.stack(window), "no column stack")
        let content = stack.documentView?.frame.width ?? 0
        try #require(content > stack.contentView.bounds.width,
                     "the stack fits its \(stack.contentView.bounds.width)pt clip (\(content)pt) — a hidden column is impossible here")
        // Select the row FIRST, then wait out the drill's own reveal and anything the selection
        // set going, and only then put the stack back at its first column. So the control is
        // "selected, and still off screen" — the selection is not what brings the column back —
        // and it is read at once rather than over a window. An absence held over a window is what
        // another suite's column-width commit can break (docs/flaky-tests.md, "Process-wide
        // state, and suites running in parallel": `@AppStorage` notifies by key name, and the
        // width driver reveals the deepest column in every pane alive). Measured: the windowed
        // form of this control failed once in a full-package run and never under `--filter`.
        let target = Self.target(depth: depth)
        mounted.box.selection = [target]
        _ = await Self.everHolds(window) { false }
        let clip = stack.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
        stack.reflectScrolledClipView(clip)
        window.layoutIfNeeded()
        #expect(!Self.deepestColumnIsVisible(window),
                "the fixture must start with the selected row's column off screen")

        mounted.box.reveal(target)
        let revealed = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.deepestColumnIsVisible(window) && Self.rowIsVisible(window, index: Self.targetIndex)
        }
        #expect(revealed.held,
                "column visible \(Self.deepestColumnIsVisible(window)), row visible \(Self.rowIsVisible(window, index: Self.targetIndex)) after \(revealed.pumps) pumps")
    }

    @Test func theColumnsIgnoreARevealForARowThatIsNotTheSelection() async throws {
        let mounted = Self.mount(.columns)
        let window = mounted.window
        _ = await LayoutPumpWait.pump(window, upTo: 10) { Self.table(listing: Self.rowCount, in: window) != nil }
        mounted.box.selection = ["\(Self.root)/\(Self.name(1))"]
        mounted.box.reveal(Self.target(depth: 0))
        let moved = await Self.everHolds(window) { Self.rowIsVisible(window, index: Self.targetIndex) }
        #expect(!moved, "the column scrolled to a row the user is not on")
    }

    @Test func theColumnsAnswerAStandingRevealWhenTheyAppear() async throws {
        let box = Box()
        let target = Self.target(depth: 0)
        box.selection = [target]
        box.reveal(target)
        let window = Self.mount(.columns, box: box).window
        let revealed = await LayoutPumpWait.pump(window, upTo: 10) {
            Self.rowIsVisible(window, index: Self.targetIndex)
        }
        #expect(revealed.held, "a column mounted with the reveal standing opened at the top (\(revealed.pumps) pumps)")
    }

    // MARK: The gate

    /// `FileTreeView` is `.equatable()`: a reveal the gate compared away would never re-render the
    /// pane, and `.onChange` would never see it.
    @Test func theRevealIsInThePanesEqualityGate() {
        func pane(_ reveal: PaneRowReveal?) -> FileTreeView {
            FileTreeView(tree: PaneTree(side: .left, version: 1, nodes: []),
                         otherTree: PaneTree(side: .right, version: 1, nodes: []),
                         isLoading: false, currentPath: "/r", selection: .constant([]),
                         otherSelection: [], isLeft: true, delegate: Stub(), rowReveal: reveal)
        }
        #expect(pane(nil) == pane(nil))
        #expect(pane(PaneRowReveal(path: "/r/a", token: 1)) != pane(PaneRowReveal(path: "/r/a", token: 2)))
        #expect(pane(nil) != pane(PaneRowReveal(path: "/r/a", token: 1)))
    }
}
