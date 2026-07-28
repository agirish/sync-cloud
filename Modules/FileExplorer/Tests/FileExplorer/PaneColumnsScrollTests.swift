import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// The column stack's scrolling is NATIVE, and must stay that way.
///
/// Three commits (`63bb6cf` → `60fd18f` → `7021b28`) tried to tame the stack's horizontal
/// overscroll by hand — first switching elasticity off, then swapping in a custom `NSClipView`
/// that capped and gated the slack. Each round fixed its predecessor's symptom and shipped a new
/// one, because the swap replaced a clip view SwiftUI had configured with one it hadn't:
///
/// - The custom constrain granted ±44pt of **vertical** slack during a gesture, on a stack whose
///   native vertical elasticity SwiftUI sets to `.none` — the axis was locked until the swap
///   unlocked it. That is how a horizontal Miller-column stack ended up displaced *downward* by
///   a scroll gesture.
/// - The slack was gated on `willStart`/`didEndLiveScroll`, and `didEndLiveScroll` fires at
///   finger-lift — before the momentum phase, which is where a flick actually meets the edge.
///   Result: a dead stop instead of a bounce, plus a 0.22s snap-home animation racing the
///   momentum events still arriving — the jank when flinging back to the first column.
///
/// AppKit's own rubber band is bounded, momentum-aware and self-returning, and SwiftUI already
/// configures the stack correctly (horizontal `.allowed`, vertical `.none`). These tests pin that
/// configuration so the machinery is not reintroduced: the moment something swaps the clip view
/// or kills the elasticity again, the mounted assertions fail.
@MainActor
@Suite struct PaneColumnsScrollTests {

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
                childrenIndex: index, treeRoot: PaneColumnsScrollTests.root,
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

    /// Mounts the pane with three columns open in a 520pt window — 630pt of content, so the
    /// stack genuinely scrolls. Returns the window (kept alive by the caller), the stack's
    /// scroll view and the columns' lists.
    private func mountThreeColumns() async throws -> (window: NSWindow, stack: NSScrollView, columns: [NSScrollView]) {
        let box = Box()
        let tree = Self.tree()
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let host = NSHostingView(rootView: Harness(box: box, tree: tree, index: index))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()

        box.browsePath = PaneBrowsePath(components: ["a2", "b3"])
        await pump(window, seconds: 1.5)

        let all = scrollViews(window.contentView!)
        let stack = try #require(all.first { !($0.documentView is NSTableView) }, "no stack scroll view")
        let columns = all.filter { $0.documentView is NSTableView }
        return (window, stack, columns)
    }

    @Test func testTheMountedStackScrollsNatively() async throws {
        let (window, stack, columns) = try await mountThreeColumns()
        defer { _ = window }
        #expect(columns.count == 3, "expected three column lists, found \(columns.count)")

        // The stack really scrolls, so none of the assertions below hold vacuously.
        let extent = max(0, (stack.documentView?.frame.width ?? 0) - stack.contentSize.width)
        #expect(extent > 0, "fixture does not overflow, so the scrolling assertions are vacuous")

        // Horizontal bounce is AppKit's own: present, bounded, momentum-aware. `.none` is the
        // dead stop that was reported as "no bounce effect"; reintroduce it and this fails.
        #expect(stack.horizontalScrollElasticity != .none,
                "the stack lost its bounce — it stops dead at each edge")
        // Vertically the stack must be inert: SwiftUI sets `.none` for a horizontal-only
        // ScrollView, and this is what keeps a scroll gesture from dragging the columns downward.
        #expect(stack.verticalScrollElasticity == .none,
                "the stack can be displaced vertically — a scroll will pull the columns down")

        // The clip view is SwiftUI's own, exactly `NSClipView`. A custom subclass here means the
        // swap is back — and with it whatever constraint relaxations it carries. (Note this is a
        // class check, not a behavior check: a mutation run showed `isFlipped` self-corrects once
        // the document is reattached, so flippedness detects nothing.)
        #expect(type(of: stack.contentView) == NSClipView.self,
                "the stack's clip view was swapped for a custom subclass — the machinery is back")

        // The columns' own lists keep their native vertical bounce. (No class check here: a
        // List's clip view is a private SwiftUI subclass, so `NSClipView.self` is the wrong
        // expectation — the stack's plain `NSClipView` is the special case, not the rule.)
        #expect(columns.allSatisfy { $0.verticalScrollElasticity != .none },
                "a column list lost its vertical bounce")
    }

    /// The watchdog must be guarding the STACK's scroll view — resolution is the one thing the
    /// synthetic tests below cannot pin, and targeting a column's list instead would look
    /// identical from the outside.
    @Test func testTheMountedWatchdogGuardsTheStacksScrollView() async throws {
        let (window, stack, _) = try await mountThreeColumns()
        defer { _ = window }

        var watchdogs: [PaneColumnsOverscrollReturn.WatchdogView] = []
        func walk(_ v: NSView) {
            if let w = v as? PaneColumnsOverscrollReturn.WatchdogView { watchdogs.append(w) }
            for sub in v.subviews { walk(sub) }
        }
        walk(window.contentView!)
        let watchdog = try #require(watchdogs.first, "no watchdog mounted in the columns stack")
        #expect(watchdog.resolvedScroller === stack,
                "the watchdog resolved the wrong scroll view — a column's list would now be fought over")
    }

    /// The watchdog must never disturb the mounted stack at rest. After the drill's own
    /// auto-scroll settles, nothing may move the stack again — a watchdog that nudges legal
    /// resting positions would fight every scroll the user makes.
    ///
    /// (The pull itself is driven synthetically in `PaneColumnsOverscrollReturnRuleTests`: the
    /// mounted stack cannot be stranded from test code, because SwiftUI's own clip view clamps
    /// programmatic `setBoundsOrigin` — only the lost-phase elastic gesture reaches the stranded
    /// state, and no bounds-setting fixture reproduces that routing.)
    @Test func testTheMountedStackAtRestIsLeftAlone() async throws {
        let (window, stack, _) = try await mountThreeColumns()
        defer { _ = window }
        let clip = stack.contentView

        // Wait for genuine rest first: the drill's own deferred auto-scroll can land late under a
        // loaded parallel run, and a baseline read before it lands fails this test against the
        // scroll, not the watchdog. Rest = the origin holding still for a full second.
        var settled = clip.bounds.origin
        var heldSince = Date()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, Date().timeIntervalSince(heldSince) < 1.0 {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
            if clip.bounds.origin != settled {
                settled = clip.bounds.origin
                heldSince = Date()
            }
        }

        await pump(window, seconds: 0.8)
        #expect(clip.bounds.origin == settled,
                "the watchdog moved a stack that was resting in range")
    }

    /// The jitter probe must observe its OWN column's scroll view and genuinely emit when that
    /// column travels vertically — silent instrumentation would read as a healthy pane.
    @Test func testTheJitterProbeReportsAColumnsVerticalTravel() async throws {
        let (window, _, columns) = try await mountThreeColumns()
        defer { _ = window }
        // Shrink the window so a column's six rows genuinely overflow it and can scroll.
        window.setContentSize(NSSize(width: 520, height: 100))
        await pump(window, seconds: 0.5)

        var probes: [PaneColumnJitterProbe.ProbeView] = []
        func walk(_ v: NSView) {
            if let p = v as? PaneColumnJitterProbe.ProbeView { probes.append(p) }
            for sub in v.subviews { walk(sub) }
        }
        walk(window.contentView!)
        #expect(probes.count == columns.count, "expected one probe per column")

        let probe = try #require(probes.first { $0.resolvedClip != nil }, "no probe resolved a clip")
        let clip = try #require(probe.resolvedClip)
        #expect(clip.documentView is NSTableView, "the probe's clip does not host a table")
        #expect(columns.contains { $0.contentView === clip },
                "a probe observed something other than a column's own list")

        let scrollable = (clip.documentView?.frame.height ?? 0) - clip.bounds.height
        #expect(scrollable > 10, "fixture column does not overflow, so the emission check is vacuous")

        let before = probe.linesLogged
        clip.scroll(to: NSPoint(x: 0, y: min(30, scrollable)))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        let deadline = Date().addingTimeInterval(5)
        while probe.linesLogged == before, Date() < deadline {
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        #expect(probe.linesLogged > before, "the probe never reported the column's travel")
    }
}

/// The watchdog's two pieces of pure logic, pinned directly: which scroll view is the stack's,
/// and where "home" is for a stranded origin.
@MainActor
@Suite struct PaneColumnsOverscrollReturnRuleTests {

    /// A column's scroll view (an `NSTableView` document) must be walked past; the stack's
    /// (anything else) is the one to take.
    @Test func testItSkipsAColumnsListAndTakesTheStacksScrollView() {
        let stack = NSScrollView()
        stack.documentView = NSView()          // the row of columns
        let columnList = NSScrollView()
        columnList.documentView = NSTableView() // one column's list
        stack.documentView?.addSubview(columnList)
        let probe = NSView()
        columnList.documentView?.addSubview(probe)

        let found = PaneColumnsOverscrollReturn.WatchdogView.findStackScrollView(from: probe)
        #expect(found === stack, "the walk stopped at a column's own list instead of the stack")
    }

    /// Nothing to find is answered with nil rather than a guess.
    @Test func testItRefusesWhenThereIsNoStackScroller() {
        let columnList = NSScrollView()
        columnList.documentView = NSTableView()
        let probe = NSView()
        columnList.documentView?.addSubview(probe)

        #expect(PaneColumnsOverscrollReturn.WatchdogView.findStackScrollView(from: probe) == nil)
    }

    /// A clip view 200pt wide over 600pt of content: home for any origin is inside [0, 400].
    private func clip() -> NSClipView {
        let view = NSClipView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        return view
    }

    @Test func testHomeForAnOriginPastTheStartIsTheStart() {
        let home = PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: NSPoint(x: -40, y: 0), clip: clip())
        #expect(home == NSPoint(x: 0, y: 0))
    }

    @Test func testHomeForAnOriginPastTheEndIsTheEnd() {
        let home = PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: NSPoint(x: 5000, y: 0), clip: clip())
        #expect(home == NSPoint(x: 400, y: 0))
    }

    @Test func testAVerticalDisplacementIsPulledFlat() {
        // The document exactly fills the clip vertically, so any y offset is illegal.
        let home = PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: NSPoint(x: 100, y: -30), clip: clip())
        #expect(home == NSPoint(x: 100, y: 0))
    }

    @Test func testAnInRangeOriginIsItsOwnHome() {
        let origin = NSPoint(x: 150, y: 0)
        #expect(PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: origin, clip: clip()) == origin)
    }
}

/// The watchdog's full cycle — observe, wait for rest, pull home — driven over a synthetic
/// scroll view whose clip can actually be stranded.
///
/// The real stranded state is reachable only through the lost-phase elastic gesture: SwiftUI's
/// own clip view clamps programmatic `setBoundsOrigin`, so no bounds-setting fixture can strand
/// the mounted stack (tried; the origin snapped straight back). This permissive clip view stands
/// in for the elastic state — out-of-range bounds that nothing re-constrains — which is exactly
/// the state the watchdog exists to notice.
@MainActor
@Suite struct PaneColumnsOverscrollReturnCycleTests {

    /// Lets any proposed bounds through, the way the rubber band's in-flight state does.
    private final class StrandableClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
    }

    /// A 200pt scroll view over 600pt of content, with the watchdog mounted inside the document
    /// view — the same position the SwiftUI `.background` gives it in the real stack.
    private func mount() -> (window: NSWindow, scroller: NSScrollView, clip: NSClipView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = StrandableClipView()
        scroller.contentView = clip
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        scroller.documentView = document
        document.addSubview(PaneColumnsOverscrollReturn.WatchdogView())
        window.contentView?.addSubview(scroller)
        return (window, scroller, clip)
    }

    private func pump(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    /// Waits on the observable rather than sleeping a fixed interval and hoping: under a full
    /// parallel test run, other main-actor work can starve the watchdog's 140ms timer well past
    /// any polite fixed window — which is exactly how these tests first flaked.
    private func waitForOrigin(_ clip: NSClipView, toBecome expected: NSPoint,
                               timeout: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if clip.bounds.origin == expected { return true }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return clip.bounds.origin == expected
    }

    @Test func testAStrandedClipIsPulledHomeOnceAtRest() async {
        let (window, _, clip) = mount()
        defer { _ = window }
        await pump(seconds: 0.3)  // let the watchdog arm

        // Stranded past the left edge and displaced vertically, as the lost-phase gesture leaves it.
        clip.setBoundsOrigin(NSPoint(x: -40, y: 12))
        #expect(clip.bounds.origin == NSPoint(x: -40, y: 12),
                "fixture failed to strand the clip — the pull below is vacuous")

        #expect(await waitForOrigin(clip, toBecome: NSPoint(x: 0, y: 0)),
                "the watchdog left the clip stranded past the left edge, at \(clip.bounds.origin)")
    }

    @Test func testAClipStrandedPastTheEndIsPulledToTheEnd() async {
        let (window, _, clip) = mount()
        defer { _ = window }
        await pump(seconds: 0.3)

        clip.setBoundsOrigin(NSPoint(x: 460, y: 0))  // 400 is the last legal origin
        #expect(clip.bounds.origin.x == 460, "fixture failed to strand the clip")

        #expect(await waitForOrigin(clip, toBecome: NSPoint(x: 400, y: 0)),
                "the watchdog left the clip stranded past the right edge, at \(clip.bounds.origin)")
    }

    /// Absence has no observable to wait on, so this one holds the fixed window — but waits
    /// FIRST for a full quiescence period to elapse, so the watchdog demonstrably had its chance.
    @Test func testAnInRangeRestIsNeverTouched() async {
        let (window, _, clip) = mount()
        defer { _ = window }
        await pump(seconds: 0.3)

        clip.setBoundsOrigin(NSPoint(x: 150, y: 0))
        await pump(seconds: PaneColumnsOverscrollReturn.WatchdogView.quiescence * 4)
        #expect(clip.bounds.origin == NSPoint(x: 150, y: 0),
                "the watchdog moved a clip resting inside its legal range")
    }
}
