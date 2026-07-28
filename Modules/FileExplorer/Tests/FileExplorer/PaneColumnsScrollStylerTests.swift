import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// The column stack's overscroll must be CAPPED — not removed, which stops it dead at each edge,
/// and not open-ended, which scrolls it into an empty pane. The styler must also target the STACK's
/// scroll view rather than one of the columns' lists; those two mistakes look identical from the
/// outside, since either way some scroll view ends up modified.
@Suite struct PaneColumnsScrollStylerRuleTests {

    /// A column's scroll view (an `NSTableView` document) must be walked past; the stack's (anything
    /// else) is the one to take.
    @MainActor
    @Test func testItSkipsAColumnsListAndTakesTheStacksScrollView() {
        let stack = NSScrollView()
        stack.documentView = NSView()          // the row of columns

        let columnList = NSScrollView()
        columnList.documentView = NSTableView() // one column's list
        stack.documentView?.addSubview(columnList)

        let probe = NSView()
        columnList.documentView?.addSubview(probe)

        let found = PaneColumnsScrollStyler.StylerView.findStackScrollView(from: probe)
        #expect(found === stack, "the walk stopped at a column's own list instead of the stack")
    }

    /// Nothing to find is answered with nil rather than a guess.
    @MainActor
    @Test func testItRefusesWhenThereIsNoStackScroller() {
        let columnList = NSScrollView()
        columnList.documentView = NSTableView()
        let probe = NSView()
        columnList.documentView?.addSubview(probe)

        #expect(PaneColumnsScrollStyler.StylerView.findStackScrollView(from: probe) == nil)
    }
}

/// End to end: the real pane, mounted, with its horizontal elasticity actually off.
@MainActor
@Suite struct PaneColumnsScrollStylerTests {

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

    private static func tree() -> PaneTree {
        let top = (0..<6).map { a -> FileNode in
            let dir = "\(root)/a\(a)"
            let mids = (0..<6).map { b -> FileNode in
                let bPath = "\(dir)/b\(b)"
                return FileNode(id: bPath, name: "b\(b)", isDirectory: true,
                                children: (0..<5).map { FileNode(id: "\(bPath)/f\($0).pdf", name: "f\($0).pdf", isDirectory: false) })
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
                childrenIndex: index, treeRoot: PaneColumnsScrollStylerTests.root,
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in }
            )
        }
    }

    private func pump(_ window: NSWindow, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
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

    @Test func testTheMountedStackKeepsItsBounceButBounded() async throws {
        let box = Box()
        let tree = Self.tree()
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let host = NSHostingView(rootView: Harness(box: box, tree: tree, index: index))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()

        // Three columns in a 520pt pane: 630pt of content, so the stack really scrolls.
        box.browsePath = PaneBrowsePath(components: ["a2", "b3"])
        await pump(window, seconds: 1.5)

        let all = scrollViews(window.contentView!)
        let stack = try #require(all.first { !($0.documentView is NSTableView) }, "no stack scroll view")
        let columns = all.filter { $0.documentView is NSTableView }
        #expect(columns.count == 3, "expected three column lists, found \(columns.count)")

        // Elasticity stays ON — the give is wanted; it is the clip view that caps it.
        #expect(stack.horizontalScrollElasticity == .allowed,
                "the stack lost its bounce entirely, which stops it dead at each edge")
        #expect(stack.contentView is BoundedElasticClipView,
                "the stack's overscroll is unbounded — it can still scroll into an empty pane")
        // The columns' own bounce is deliberately untouched, and their clip views must not have
        // been swapped either: the styler has exactly one target.
        #expect(columns.allSatisfy { $0.verticalScrollElasticity != .none },
                "a column list lost its vertical bounce — the styler disarmed the wrong scroll view")
        #expect(columns.allSatisfy { !($0.contentView is BoundedElasticClipView) },
                "a column list got the bounded clip view — the styler targeted the wrong scroll view")

        // The stack still scrolls normally inside its content.
        let extent = max(0, (stack.documentView?.frame.width ?? 0) - stack.contentSize.width)
        #expect(extent > 0, "fixture does not overflow, so the overscroll assertions are vacuous")
    }
}

/// The cap itself, driven directly over a clip view — the arithmetic that decides how far a bounce
/// may travel, independent of whether SwiftUI hands us a scroll view to install it on.
@MainActor
@Suite struct BoundedElasticClipViewTests {

    /// A clip view 200pt wide over 600pt of content: 400pt of real scrolling, plus the cap at each
    /// end and nothing beyond.
    private func clip() -> BoundedElasticClipView {
        let view = BoundedElasticClipView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        view.documentView = document
        return view
    }

    /// Mid-gesture, the slack is available and capped.
    @Test func testOverscrollPastTheStartIsCappedDuringAGesture() {
        let slack = BoundedElasticClipView.maximumOverscroll
        let view = clip()
        view.beginLiveScroll()
        #expect(view.constrainBoundsRect(NSRect(x: -5000, y: 0, width: 200, height: 100)).origin.x == -slack)
    }

    @Test func testOverscrollPastTheEndIsCappedDuringAGesture() {
        let slack = BoundedElasticClipView.maximumOverscroll
        let view = clip()
        view.beginLiveScroll()
        // 600 content − 200 viewport = 400 of real travel, then the cap.
        #expect(view.constrainBoundsRect(NSRect(x: 5000, y: 0, width: 200, height: 100)).origin.x == 400 + slack)
    }

    /// Some give must actually survive — a cap of zero is just the hard stop again.
    @Test func testASmallOverscrollIsAllowedThroughDuringAGesture() {
        let view = clip()
        view.beginLiveScroll()
        #expect(view.constrainBoundsRect(NSRect(x: -12, y: 0, width: 200, height: 100)).origin.x == -12)
        #expect(BoundedElasticClipView.maximumOverscroll > 0)
    }

    /// **The spring.** With no gesture in flight there is no slack at all, so an out-of-bounds
    /// position stops being legal and the stack is pulled home. Granting the slack unconditionally
    /// is what left it stuck out of bounds: `constrainBoundsRect` is the restoring force, not just
    /// a limit.
    @Test func testWithNoGestureInFlightThereIsNoSlack() {
        let view = clip()
        #expect(view.constrainBoundsRect(NSRect(x: -5000, y: 0, width: 200, height: 100)).origin.x == 0)
        #expect(view.constrainBoundsRect(NSRect(x: 5000, y: 0, width: 200, height: 100)).origin.x == 400)
    }

    /// …and the gesture ending is what removes it.
    @Test func testEndingTheGestureWithdrawsTheSlack() {
        let view = clip()
        view.beginLiveScroll()
        #expect(view.isLiveScrolling)
        #expect(view.constrainBoundsRect(NSRect(x: -30, y: 0, width: 200, height: 100)).origin.x == -30)
        view.endLiveScroll()
        #expect(!view.isLiveScrolling)
        #expect(view.constrainBoundsRect(NSRect(x: -30, y: 0, width: 200, height: 100)).origin.x == 0)
    }

    /// Ending a gesture from an overscrolled position brings the stack back into bounds rather
    /// than leaving it parked there — the reported "it does scroll over bounds but gets stuck".
    @Test func testEndingAGestureReturnsAnOverscrolledStackToBounds() {
        let view = clip()
        view.beginLiveScroll()
        view.setBoundsOrigin(NSPoint(x: -40, y: 0))
        #expect(view.bounds.origin.x < 0, "fixture never left bounds — the assertion below is vacuous")
        view.endLiveScroll()
        #expect(view.bounds.origin.x == 0, "the stack stayed overscrolled after the gesture ended")
    }

    /// Scrolling inside the content is untouched, gesture or not.
    @Test func testOrdinaryScrollingIsUnaffected() {
        let proposed = NSRect(x: 150, y: 0, width: 200, height: 100)
        #expect(clip().constrainBoundsRect(proposed).origin.x == 150)
        let live = clip()
        live.beginLiveScroll()
        #expect(live.constrainBoundsRect(proposed).origin.x == 150)
    }

    /// The bounce may never open a gap wide enough to read as a missing column — the report that
    /// started this was "scrolling past left to emptiness", and a column is at least 140pt.
    @Test func testTheCapIsNarrowerThanTheNarrowestColumn() {
        #expect(BoundedElasticClipView.maximumOverscroll < PaneViewMode.minimumColumnWidth / 2)
    }
}
