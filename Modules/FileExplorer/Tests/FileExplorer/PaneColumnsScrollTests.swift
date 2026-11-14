import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// The column stack's scrolling is native, and must stay that way: SwiftUI configures it
/// (horizontal `.allowed`, vertical `.none`) and AppKit's rubber band is bounded and momentum-aware.
/// A custom `NSClipView` grants vertical slack that drags the stack down, and slack gated on live
/// scroll ends before the momentum phase, a dead stop instead of a bounce. Swap the clip view or kill
/// the elasticity and the mounted assertions fail.
@MainActor
@Suite struct PaneColumnsScrollTests {

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
                delegate: NoOpFileActionDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in }, onBackgroundDeselect: { _ in }
            )
            // Place the drill's reveal outright (`EnvironmentValues.paneColumnRevealAnimation`): this
            // window is offscreen and never key, so with the display asleep or in Low Power Mode an
            // animation in it never advances and the reveal's scroll never lands.
            // `testTheMountedStackAtRestIsLeftAlone` needs the stack resting at the far end.
            .environment(\.paneColumnRevealAnimation, nil)
        }
    }

    /// A fixed window of layout passes, floored (`LayoutPumpWait.pumpFloor`).
    private func pump(_ window: NSWindow, seconds: Double) async {
        _ = await LayoutPumpWait.pump(window, upTo: seconds) { false }
    }

    /// Mounts the pane with three columns open in a 520pt window: 630pt of content, so the stack
    /// genuinely scrolls. The caller keeps the window alive.
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
        // Bounded: until three lists are up and the drill's reveal has reached the stack's far end.
        // Only the lists are required; the tests that need the reveal wait for it themselves.
        let lists = { PaneRowRevealTests.scrollViews(window.contentView!).filter { $0.documentView is NSTableView } }
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            guard lists().count == 3,
                  let stack = PaneRowRevealTests.scrollViews(window.contentView!)
                      .first(where: { !($0.documentView is NSTableView) }) else { return false }
            let extent = max(0, (stack.documentView?.frame.width ?? 0) - stack.contentSize.width)
            return extent > 0 && stack.contentView.bounds.origin.x >= extent - 1
        }
        try #require(lists().count == 3, "three columns never mounted: \(lists().count) after \(settled.pumps) passes")

        let all = PaneRowRevealTests.scrollViews(window.contentView!)
        let stack = try #require(all.first { !($0.documentView is NSTableView) }, "no stack scroll view")
        let columns = all.filter { $0.documentView is NSTableView }
        return (window, stack, columns)
    }

    /// Origins well outside the clip view's legal band, one per edge of each axis, far enough out
    /// that no rounding could pass for slack.
    private func overTravelOrigins(_ clip: NSClipView) -> [NSPoint] {
        let far: CGFloat = 300
        let document = clip.documentView?.frame ?? .zero
        return [NSPoint(x: document.minX - far, y: 0),
                NSPoint(x: document.maxX + far, y: 0),
                NSPoint(x: 0, y: document.minY - far),
                NSPoint(x: 0, y: document.maxY + far)]
    }

    @Test func testTheMountedStackScrollsNatively() async throws {
        let (window, stack, columns) = try await mountThreeColumns()
        defer { _ = window }
        #expect(columns.count == 3, "expected three column lists, found \(columns.count)")

        // The stack really scrolls, so none of the assertions below hold vacuously.
        let extent = max(0, (stack.documentView?.frame.width ?? 0) - stack.contentSize.width)
        #expect(extent > 0, "fixture does not overflow, so the scrolling assertions are vacuous")

        // Horizontal bounce is AppKit's own: present, bounded, momentum-aware. `.none` would stop
        // the stack dead at each edge.
        #expect(stack.horizontalScrollElasticity != .none,
                "the stack lost its bounce — it stops dead at each edge")
        // Vertically the stack must be inert: SwiftUI sets `.none` for a horizontal-only
        // ScrollView, which keeps a scroll gesture from dragging the columns downward.
        #expect(stack.verticalScrollElasticity == .none,
                "the stack can be displaced vertically — a scroll will pull the columns down")

        // The clip view is the framework's, not ours, asserted two ways. SwiftUI's class varies by
        // OS (macOS 27 installs `HostingClipView`), so no exact `NSClipView` check. First, provenance:
        // a clip view this module defines comes from this module's bundle.
        #expect(Bundle(for: type(of: stack.contentView))
                != Bundle(for: PaneColumnsOverscrollReturn.WatchdogView.self),
                "the stack's clip view is a subclass this module defines — the machinery is back (\(type(of: stack.contentView)))")

        // Second, behaviour: travel past the content on both axes must return the legal origin, at
        // rest and during a live scroll (a clip view that gates slack on live scroll clamps at rest).
        // The live phase waits for the notification: an observer on `queue: .main` runs enqueued,
        // not inside `post`. Ours is registered last, and blocks run in registration order, so once
        // ours has run any earlier gate has too.
        for phase in ["at rest", "during a live scroll"] {
            if phase != "at rest" {
                var delivered = false
                let token = NotificationCenter.default.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: stack, queue: .main
                ) { _ in MainActor.assumeIsolated { delivered = true } }
                defer { NotificationCenter.default.removeObserver(token) }
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification,
                                               object: stack)
                let deadline = Date().addingTimeInterval(10)
                while !delivered, Date() < deadline {
                    window.layoutIfNeeded()
                    try? await Task.sleep(nanoseconds: 4_000_000)
                }
                try #require(delivered,
                             "the live-scroll notification was never delivered, so the probe below would measure a clip view that was never told a gesture started")
            }
            for proposed in overTravelOrigins(stack.contentView) {
                let constrained = stack.contentView.constrainBoundsRect(
                    NSRect(origin: proposed, size: stack.contentView.bounds.size)).origin
                let legal = BoundedResolveView.legalOrigin(for: proposed, clip: stack.contentView)
                #expect(abs(constrained.x - legal.x) < 0.5 && abs(constrained.y - legal.y) < 0.5,
                        "\(phase) the clip view granted travel past the content: asked for \(proposed) it returned \(constrained), not the legal \(legal)")
            }
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification,
                                        object: stack)

        // The columns' own lists keep their native vertical bounce (a List's clip view is a private
        // SwiftUI subclass, so no class check).
        #expect(columns.allSatisfy { $0.verticalScrollElasticity != .none },
                "a column list lost its vertical bounce")
    }

    /// The watchdog guards the stack's scroll view, not a column's list: resolution is the one
    /// thing the synthetic tests below can't pin.
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
        _ = await LayoutPumpWait.pump(window, upTo: 10) { watchdog.resolvedScroller != nil }
        #expect(watchdog.resolvedScroller === stack,
                "the watchdog resolved the wrong scroll view — a column's list would now be fought over")
    }

    /// The watchdog never disturbs the mounted stack at rest: one that nudged legal resting
    /// positions would fight every scroll. (The pull itself is driven synthetically in
    /// `PaneColumnsOverscrollReturnRuleTests`: SwiftUI's clip view clamps a programmatic
    /// `setBoundsOrigin`, so no mounted fixture can strand the stack.)
    @Test func testTheMountedStackAtRestIsLeftAlone() async throws {
        let (window, stack, _) = try await mountThreeColumns()
        defer { _ = window }
        let clip = stack.contentView

        // Wait for the drill's own reveal to the far end first: under load it can land seconds
        // later, inside the assertion window. The extent is recomputed per pass, as layout can land
        // late too; floored on passes (`LayoutPumpWait`) because a slow VM runs the seconds out first.
        let (revealed, pumps) = await LayoutPumpWait.pump(window, upTo: 15) {
            let extent = max(0, (stack.documentView?.frame.width ?? 0) - stack.contentSize.width)
            return extent > 0 && clip.bounds.origin.x >= extent - 1
        }
        // Required: at x=0 the origin is legal and the check below would hold whatever the watchdog did.
        try #require(revealed,
                     "the drill's reveal never reached the stack's far end (origin \(clip.bounds.origin.x), \(pumps) passes) — the rest below is not the rest this test is about")

        // Then genuine rest: the origin holding still for a full second.
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

    /// The jitter probe must observe its own column's scroll view and emit when that column travels
    /// vertically: silent instrumentation would read as a healthy pane.
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

        // Both halves share a process-wide switch: as two tests they would interleave at their
        // `await`s and flip the flag under each other.
        let wasEnabled = PaneScrollTrace.isEnabled
        defer { PaneScrollTrace.isEnabled = wasEnabled }

        // Asked for: the probe must emit.
        PaneScrollTrace.isEnabled = true
        let before = probe.linesLogged
        clip.scroll(to: NSPoint(x: 0, y: min(30, scrollable)))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        // Two main-thread hops away (a bounds notification, then a 250ms coalescing flush), which
        // other suites can starve: a longer timeout can't buy a main-actor turn, the pass floor can.
        let emitted = await LayoutPumpWait.pump(window, upTo: 15) { probe.linesLogged > before }
        #expect(emitted.held,
                "the probe never reported the column's travel, after \(emitted.pumps) passes")

        // Not asked for, as it ships: travel writes nothing. The log is capped at 5 MB, so a
        // per-frame line would evict the sync runs and errors it is kept for.
        PaneScrollTrace.isEnabled = false
        let afterTracing = probe.linesLogged
        clip.scroll(to: NSPoint(x: 0, y: 0))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        await pump(window, seconds: 0.8)
        #expect(probe.linesLogged == afterTracing,
                "the travel trace wrote to the log with the diagnostic switched off")
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

    /// Past the start, past the end, displaced vertically (the document exactly fills the clip, so
    /// any y is illegal), and in range (its own home).
    @Test(arguments: [
        (NSPoint(x: -40, y: 0), NSPoint(x: 0, y: 0)),
        (NSPoint(x: 5000, y: 0), NSPoint(x: 400, y: 0)),
        (NSPoint(x: 100, y: -30), NSPoint(x: 100, y: 0)),
        (NSPoint(x: 150, y: 0), NSPoint(x: 150, y: 0)),
    ])
    func testTheHomeForAnOrigin(origin: NSPoint, home: NSPoint) {
        #expect(PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: origin, clip: clip()) == home,
                "the home for \(origin)")
    }

    /// A document narrower than the clip (three columns in a wide pane): home collapses to the
    /// document's leading edge.
    @Test func testAFittingDocumentsHomeIsItsLeadingEdge() {
        let view = NSClipView(frame: NSRect(x: 0, y: 0, width: 772, height: 100))
        view.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
        #expect(PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(
            for: NSPoint(x: -60, y: 0), clip: view) == NSPoint(x: 0, y: 0))
        #expect(PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(
            for: NSPoint(x: 45, y: 0), clip: view) == NSPoint(x: 0, y: 0))
    }

    /// The pull's threshold is sub-visible but nonzero: SwiftUI parks clips at fractional origins,
    /// and with no slack the watchdog would correct them every quiescence interval, forever.
    @Test func testTheToleranceClearsPixelAlignmentButNotVisibleStrandings() {
        #expect(PaneColumnsOverscrollReturn.WatchdogView.tolerance >= 1,
                "sub-point pixel alignment must never trigger a pull")
        #expect(PaneColumnsOverscrollReturn.WatchdogView.tolerance <= 8,
                "a stranding this size is visible — the watchdog would ignore real bugs")
    }
}

/// The watchdog's full cycle (observe, wait for rest, pull home), over a synthetic scroll view
/// whose clip can actually be stranded. SwiftUI's clip view clamps a programmatic
/// `setBoundsOrigin`, so this permissive clip stands in for the lost-phase elastic gesture's
/// out-of-range bounds.
@MainActor
@Suite struct PaneColumnsOverscrollReturnCycleTests {

    /// A 200pt scroll view over 600pt of content, with the watchdog mounted inside the document
    /// view, where the SwiftUI `.background` puts it in the real stack.
    private func mount(documentWidth: CGFloat = 600) -> (window: NSWindow, scroller: NSScrollView, clip: NSClipView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = StrandableClipView()
        scroller.contentView = clip
        let document = NSView(frame: NSRect(x: 0, y: 0, width: documentWidth, height: 100))
        scroller.documentView = document
        let watchdog = PaneColumnsOverscrollReturn.WatchdogView()
        // The code under test decides the pull home; how long it takes to paint depends on whether
        // CoreAnimation is ticking, which on an offscreen never-key window under load it may not
        // be. See `pullDuration` and `docs/flaky-tests.md`, "The machine decides the verdict —
        // throttled CoreAnimation".
        watchdog.pullDuration = 0
        document.addSubview(watchdog)
        window.contentView?.addSubview(scroller)
        // Builds the layer tree now instead of at the window's first display cycle. A clip with no
        // layer skips AppKit's pixel alignment, and the cycle that gives it one aligns whatever
        // origin it finds, so an origin set before then would move under no code of ours. See
        // `docs/flaky-tests.md`, "A clip view parked before its window's first display cycle is
        // pixel-aligned later, by AppKit".
        window.displayIfNeeded()
        return (window, scroller, clip)
    }

    /// Pins the shipped pull duration: every mount here injects `pullDuration = 0`, so a default
    /// drifting to zero would delete the bounce with the suite still green (`docs/flaky-tests.md`,
    /// "The machine decides the verdict — throttled CoreAnimation").
    @Test func thePullHomeShipsAnimated() {
        #expect(PaneColumnsOverscrollReturn.WatchdogView.defaultPullDuration == 0.25)
        // A freshly built watchdog takes it: the injection is a test affordance, not the default.
        #expect(PaneColumnsOverscrollReturn.WatchdogView().pullDuration == 0.25)
    }

    @Test func testAStrandedClipIsPulledHomeOnceAtRest() async {
        let (window, _, clip) = mount()
        defer { _ = window }
        await idle(seconds: 0.3)  // let the watchdog arm

        // Stranded past the left edge and displaced vertically, as the lost-phase gesture leaves it.
        clip.setBoundsOrigin(NSPoint(x: -40, y: 12))
        #expect(clip.bounds.origin == NSPoint(x: -40, y: 12),
                "fixture failed to strand the clip — the pull below is vacuous")

        await expectPulledHome(clip, to: NSPoint(x: 0, y: 0), "the watchdog left the clip stranded past the left edge, at")
    }

    @Test func testAClipStrandedPastTheEndIsPulledToTheEnd() async {
        let (window, _, clip) = mount()
        defer { _ = window }
        await idle(seconds: 0.3)

        clip.setBoundsOrigin(NSPoint(x: 460, y: 0))  // 400 is the last legal origin
        #expect(clip.bounds.origin.x == 460, "fixture failed to strand the clip")

        await expectPulledHome(clip, to: NSPoint(x: 400, y: 0), "the watchdog left the clip stranded past the right edge, at")
    }

    /// A legal rest made illegal by the viewport growing under it (the preview closing) is pulled
    /// back by `legalOrigin`'s clamp. Pinned here, not mounted: a real `NSClipView` re-constrains
    /// itself when its frame grows, so a mounted close never reaches this code.
    @Test func testARestTheGrownViewportMadeIllegalIsPulledBack() async throws {
        let (window, scroller, clip) = mount()
        defer { _ = window }
        await idle(seconds: 0.3)

        // Resting legally at the far end of a 200pt viewport over 600pt of content.
        clip.setBoundsOrigin(NSPoint(x: 400, y: 0))
        await idle(seconds: PaneColumnsOverscrollReturn.WatchdogView.quiescence * 4)
        try #require(clip.bounds.origin.x == 400,
                     "the far-end rest was pulled before the viewport ever grew — nothing below measures growth")

        // The preview closes: the stack gets 300pt back and 400 is suddenly 300 past the end.
        scroller.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        scroller.tile()
        try #require(clip.bounds.width == 500,
                     "the viewport did not grow (clip \(clip.bounds.width)pt) — the origin is still legal")

        // Re-armed as the app does (`updateNSView` calls `rearm()`): the watchdog observes bounds,
        // not frame, so a viewport growing on its own wakes nothing.
        let watchdog = try #require(
            scroller.documentView?.subviews.compactMap {
                $0 as? PaneColumnsOverscrollReturn.WatchdogView
            }.first, "the watchdog is not mounted in the document view")
        watchdog.rearm()

        await expectPulledHome(clip, to: NSPoint(x: 100, y: 0), "a rest the grown viewport made illegal was left stranded at")
    }

    /// Absence has no observable to wait on, so this holds a fixed window, but first waits a full
    /// quiescence period so the watchdog demonstrably had its chance.
    @Test func testAnInRangeRestIsNeverTouched() async {
        let (window, _, clip) = mount()
        defer { _ = window }
        await idle(seconds: 0.3)

        clip.setBoundsOrigin(NSPoint(x: 150, y: 0))
        await idle(seconds: PaneColumnsOverscrollReturn.WatchdogView.quiescence * 4)
        #expect(clip.bounds.origin == NSPoint(x: 150, y: 0),
                "the watchdog moved a clip resting inside its legal range")
    }

    /// The loop-breaker: SwiftUI parks clip origins fractionally off home, and pulling those would
    /// correct the same fraction every quiescence interval, visible as jitter.
    @Test(.machinePinned(.layoutMetrics)) func testAFractionalOffsetIsLeftAloneNotCorrectedForever() async throws {
        let (window, _, clip) = mount()
        defer { _ = window }
        await idle(seconds: 0.3)

        // `setBoundsOrigin` itself pixel-rounds (−0.4 lands as −0.5 on this backing), so the pin is
        // against the value that landed: what matters is that the watchdog never "corrects" it to
        // zero. It rounds only once the clip has a layer; without one, the window's next display
        // cycle would round it during the wait and read as a correction.
        try #require(clip.layer != nil, "the clip has no layer yet, so AppKit would align the park later")
        clip.setBoundsOrigin(NSPoint(x: -0.4, y: 0.33))
        let parked = clip.bounds.origin
        #expect(parked != .zero, "fixture failed to park the clip off the mathematical home")
        await idle(seconds: PaneColumnsOverscrollReturn.WatchdogView.quiescence * 6)
        #expect(clip.bounds.origin == parked,
                "the watchdog corrected a sub-point offset — the repeating-pull loop is back")
    }

    /// A fitting document dragged out and stranded still returns: the tolerance exempts pixel
    /// fractions, not real strandings.
    @Test func testAStrandedFittingDocumentIsPulledToItsLeadingEdge() async {
        let (window, _, clip) = mount(documentWidth: 120)
        defer { _ = window }
        await idle(seconds: 0.3)

        clip.setBoundsOrigin(NSPoint(x: -60, y: 0))
        #expect(clip.bounds.origin.x == -60, "fixture failed to strand the fitting document")

        await expectPulledHome(clip, to: NSPoint(x: 0, y: 0), "a stranded fitting document was not pulled home, at")
    }

    /// An inset clip legally rests at a negative origin (`-insets.top`); clamping it to the
    /// document edge would pull forever on any inset list.
    @Test func testAnInsetClipsRestingOriginIsLegal() {
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        clip.automaticallyAdjustsContentInsets = false
        clip.contentInsets = NSEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
        clip.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let resting = NSPoint(x: 0, y: -20)
        #expect(PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(for: resting, clip: clip) == resting,
                "an inset clip's natural rest was judged out of range — that is the pull loop")
    }
}

/// The column-list watchdog: the same treatment on the lists' vertical axis, driven through the
/// probe that also logs their travel. A list can park in overscroll after the same lost-phase
/// gesture, so the same synthetic-strand shape.
@MainActor
@Suite struct PaneColumnListWatchdogTests {

    /// A table-backed scroll view (what a column's List is to the resolver), with the probe mounted
    /// as a frame-matched sibling, as SwiftUI lays out a `.background`.
    private func mount() -> (window: NSWindow, clip: NSClipView, probe: PaneColumnJitterProbe.ProbeView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = StrandableClipView()
        // In a titled window AppKit gives the clip an automatic top inset, which widens the legal
        // band and legalizes the very park the test strands; zeroed, so the fixture's legality is
        // exactly its document edges.
        clip.automaticallyAdjustsContentInsets = false
        scroller.contentView = clip
        // A row-less NSTableView as the document auto-sizes back to the clip, so the document is a
        // plain 600pt view holding the table; the resolver still matches its enclosing scroll view.
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        document.addSubview(NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 50)))
        scroller.documentView = document
        let probe = PaneColumnJitterProbe.ProbeView()
        // The code under test decides the pull home; how long it takes to paint depends on whether
        // CoreAnimation is ticking, which on an offscreen never-key window under load it may not
        // be. See `pullDuration` and `docs/flaky-tests.md`, "The machine decides the verdict —
        // throttled CoreAnimation".
        probe.pullDuration = 0
        probe.label = "test col"
        probe.frame = scroller.frame
        window.contentView?.addSubview(scroller)
        window.contentView?.addSubview(probe)
        return (window, clip, probe)
    }

    /// Pins the shipped pull duration, as `thePullHomeShipsAnimated` does for the stack watchdog.
    @Test func theListPullHomeShipsAnimated() {
        #expect(PaneColumnJitterProbe.ProbeView.defaultPullDuration == 0.25)
        // A freshly built probe takes it: the injection is a test affordance, not the default.
        #expect(PaneColumnJitterProbe.ProbeView().pullDuration == 0.25)
    }

    /// The live signature: parked stretched above the top, pulled flat once at rest.
    @Test(.machinePinned(.layoutMetrics)) func testAListParkedInTopOverscrollIsPulledHome() async throws {
        let (window, clip, probe) = mount()
        defer { _ = window }
        await idle(seconds: 0.3)
        try #require(probe.resolvedClip === clip, "probe failed to resolve its list")

        clip.setBoundsOrigin(NSPoint(x: 0, y: -17.5))
        #expect(clip.bounds.origin.y == -17.5, "fixture failed to park the list — the pull is vacuous")

        await expectPulledHome(clip, to: NSPoint(x: 0, y: 0), "the list stayed parked in top overscroll, at")
    }

    /// A list parked past its bottom comes back to the last legal line.
    @Test func testAListParkedPastTheBottomIsPulledToTheEnd() async throws {
        let (window, clip, probe) = mount()
        defer { _ = window }
        await idle(seconds: 0.3)
        try #require(probe.resolvedClip === clip, "probe failed to resolve its list")

        clip.setBoundsOrigin(NSPoint(x: 0, y: 560))  // 500 is the last legal origin
        await expectPulledHome(clip, to: NSPoint(x: 0, y: 500), "the list stayed parked past its bottom, at")
    }

    /// A legally scrolled rest, where a reading user is parked, is never touched.
    @Test func testALegallyScrolledRestIsNeverTouchedByTheListWatchdog() async throws {
        let (window, clip, probe) = mount()
        defer { _ = window }
        await idle(seconds: 0.3)
        try #require(probe.resolvedClip === clip, "probe failed to resolve its list")

        clip.setBoundsOrigin(NSPoint(x: 0, y: 250))
        await idle(seconds: PaneColumnsOverscrollReturn.WatchdogView.quiescence * 4)
        #expect(clip.bounds.origin == NSPoint(x: 0, y: 250),
                "the watchdog moved a list resting at a legal scroll position")
    }
}

/// The gesture-axis lock: a vertical trackpad scroll's leaked horizontal deltas must not move the
/// stack, which would show as a sideways wiggle once a second column is open.
@MainActor
@Suite struct WheelGestureTrackerTests {

    @Test func testAVerticalDragEngagesTheLock() {
        let tracker = WheelGestureTracker()
        drag(tracker, dx: 2, dy: -14)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.02))
    }

    @Test func testAHorizontalDragDoesNot() {
        let tracker = WheelGestureTracker()
        drag(tracker, dx: -20, dy: 3)
        #expect(!tracker.shouldHoldHorizontalDrift(at: 0.02))
    }

    /// The decision is made once, from the first real deltas: a vertical drag that wobbles
    /// horizontal mid-flight stays a vertical drag.
    @Test func testTheFirstRealDeltasDecideForTheWholeGesture() {
        let tracker = WheelGestureTracker()
        drag(tracker, dx: 1, dy: -10)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: -9, dy: 2, at: 0.02)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.03),
                "a mid-gesture wobble re-decided the axis")
    }

    /// Momentum inherits the drag's decision and keeps the lock alive while it delivers.
    @Test func testMomentumInheritsTheDecisionAndItsEndReleasesIt() {
        let tracker = WheelGestureTracker()
        drag(tracker, dx: 0, dy: -12)
        tracker.ingest(phase: .ended, momentumPhase: [], dx: 0, dy: 0, at: 0.02)
        tracker.ingest(phase: [], momentumPhase: .changed, dx: -30, dy: -4, at: 0.05)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.06),
                "momentum's own deltas re-decided the axis — their direction is history, not intent")
        tracker.ingest(phase: [], momentumPhase: .ended, dx: 0, dy: 0, at: 0.4)
        #expect(!tracker.shouldHoldHorizontalDrift(at: 0.41))
    }

    /// A gesture that ends with no momentum releases the lock by going quiet; a stale lock would
    /// defeat the drill's own programmatic auto-scroll after the next click.
    @Test func testTheLockDecaysWhenEventsStopArriving() {
        let tracker = WheelGestureTracker()
        drag(tracker, dx: 0, dy: -12)
        tracker.ingest(phase: .ended, momentumPhase: [], dx: 0, dy: 0, at: 0.02)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.05), "still within the recency window")
        #expect(!tracker.shouldHoldHorizontalDrift(at: 0.02 + WheelGestureTracker.staleness + 0.01),
                "the lock outlived its events — the next programmatic scroll will be fought")
    }

    /// A new gesture starts undecided and held, so a vertical scroll can't leak its first frames;
    /// the previous gesture's decision does not carry over.
    @Test func testANewGestureStartsUndecidedAndHeld() {
        let tracker = WheelGestureTracker()
        drag(tracker, dx: 0, dy: -12)
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0.05)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.06),
                "an undecided opening was not held — its first frames can leak")
        tracker.ingest(phase: .changed, momentumPhase: [], dx: -18, dy: 2, at: 0.07)
        #expect(!tracker.shouldHoldHorizontalDrift(at: 0.08),
                "the previous gesture's vertical decision leaked into the new one")
    }

    /// A touch-down's first samples are directionally noisy, so the verdict needs accumulated
    /// travel and the opening stays held until it arrives.
    @Test func testANoisyOpeningCannotMisdecideTheAxis() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        // The misleading first sample: horizontally dominant, but only 2 points of it.
        tracker.ingest(phase: .changed, momentumPhase: [], dx: -2, dy: -1, at: 0.01)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.02),
                "two noisy points decided the gesture — the flicker regression is back")
        // The drag's real direction arrives.
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -9, at: 0.03)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.04),
                "a vertical drag with a noisy opening was not held")
    }

    /// Phase-less devices (a mouse wheel) never send `.began`; a quiet gap starts their next
    /// logical gesture, so an old verdict can't govern a scroll made half a second later.
    @Test func testAQuietGapStartsAFreshGestureForPhaselessDevices() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: [], momentumPhase: [], dx: 0, dy: -12, at: 0)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.01), "a mouse's vertical scroll was not held")
        tracker.ingest(phase: [], momentumPhase: [], dx: -12, dy: 0, at: 0.5)
        #expect(!tracker.shouldHoldHorizontalDrift(at: 0.51),
                "a stale vertical verdict held the stack against a later horizontal mouse scroll")
    }

    // MARK: - Traditional (non-phased) scroll wheels
    //
    // A plain wheel sends no phases, so the trackpad's clears never reach it and the lock could stick.

    /// Each wheel click is its own gesture, so a ⇧-wheel after a vertical click is not held.
    @Test func testAWheelMouseRedecidesEveryEvent() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: [], momentumPhase: [], dx: 0, dy: -10, at: 0)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.01), "a vertical wheel click must engage the lock")

        tracker.ingest(phase: [], momentumPhase: [], dx: -10, dy: 0, at: 0.02)
        #expect(!tracker.shouldHoldHorizontalDrift(at: 0.03),
                "a ⇧-wheel horizontal scroll was held against the user by a lock still reading 'vertical'")
    }

    /// The lock must still decay for a wheel mouse, so a burst of vertical clicks can't defeat the
    /// drill's programmatic auto-scroll once the hand stops.
    @Test func testAWheelMouseLockDecaysOnQuiet() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: [], momentumPhase: [], dx: 0, dy: -10, at: 0)
        #expect(!tracker.shouldHoldHorizontalDrift(at: WheelGestureTracker.staleness + 0.01))
    }

    /// A trackpad gesture's own events must not be mistaken for ungrouped ones: `.ended` carries an
    /// empty momentumPhase, and re-deciding there would drop the lock before momentum arrives.
    @Test func testAPhasedGestureIsNeverTreatedAsUngrouped() {
        let tracker = WheelGestureTracker()
        drag(tracker, dx: 1, dy: -12)
        tracker.ingest(phase: .ended, momentumPhase: [], dx: 0, dy: 0, at: 0.02)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.03),
                "`.ended` was read as an ungrouped event and cleared the decision early")
    }

    // MARK: - Scoping the hold to the gesture's own pane
    //
    // One app-wide tracker serves up to three column stacks; unscoped, a flick in pane A would make
    // pane B's watchdog revert B's own programmatic reveal. The scoped query answers per asking view.

    /// Two sibling panes in one window, for the scoped queries below.
    private func twoPanes() -> (window: NSWindow, paneA: NSView, paneB: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let paneA = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let paneB = NSView(frame: NSRect(x: 260, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(paneA)
        window.contentView?.addSubview(paneB)
        return (window, paneA, paneB)
    }

    /// A vertical gesture holds the pane it is in, and only that pane.
    @Test func testAGestureHoldsOnlyThePaneItIsIn() {
        let (window, paneA, paneB) = twoPanes()
        defer { _ = window }
        let tracker = WheelGestureTracker()
        let inA = paneA.convert(NSPoint(x: 40, y: 40), to: nil)
        drag(tracker, dx: 1, dy: -12, window: window, at: inA)
        #expect(tracker.shouldHoldHorizontalDrift(for: paneA, at: 0.02),
                "the gesture's own pane was not held — the original leak is back")
        #expect(!tracker.shouldHoldHorizontalDrift(for: paneB, at: 0.02),
                "a gesture in pane A held pane B — its programmatic reveal will be reverted")
    }

    /// Momentum events carry the pointer's current location, which can wander over the other pane;
    /// the hold stays with the pane the drag happened in.
    @Test func testMomentumCannotMigrateTheHoldToThePaneThePointerWandersOver() {
        let (window, paneA, paneB) = twoPanes()
        defer { _ = window }
        let tracker = WheelGestureTracker()
        let inA = paneA.convert(NSPoint(x: 40, y: 40), to: nil)
        let inB = paneB.convert(NSPoint(x: 40, y: 40), to: nil)
        drag(tracker, dx: 0, dy: -12, window: window, at: inA)
        tracker.ingest(phase: .ended, momentumPhase: [], dx: 0, dy: 0,
                       window: window, locationInWindow: inA, at: 0.02)
        tracker.ingest(phase: [], momentumPhase: .changed, dx: 0, dy: -4,
                       window: window, locationInWindow: inB, at: 0.05)
        #expect(tracker.shouldHoldHorizontalDrift(for: paneA, at: 0.06),
                "momentum's wandering pointer unguarded the pane the gesture was made in")
        #expect(!tracker.shouldHoldHorizontalDrift(for: paneB, at: 0.06),
                "momentum's wandering pointer migrated the hold onto a pane the gesture never touched")
    }

    /// A gesture with no window to attribute it to holds everywhere: fail open.
    @Test func testAnUnattributableGestureHoldsEverywhere() {
        let (window, paneA, paneB) = twoPanes()
        defer { _ = window }
        let tracker = WheelGestureTracker()
        drag(tracker, dx: 1, dy: -12)
        #expect(tracker.shouldHoldHorizontalDrift(for: paneA, at: 0.02),
                "an unattributable vertical gesture stopped holding — the original leak is back")
        #expect(tracker.shouldHoldHorizontalDrift(for: paneB, at: 0.02),
                "an unattributable vertical gesture stopped holding — the original leak is back")
    }

    /// The scoped query still answers false outside a hold-worthy gesture, whatever the location.
    @Test func testTheScopedQueryStillReleasesForAHorizontalGesture() {
        let (window, paneA, _) = twoPanes()
        defer { _ = window }
        let tracker = WheelGestureTracker()
        let inA = paneA.convert(NSPoint(x: 40, y: 40), to: nil)
        drag(tracker, dx: -18, dy: 2, window: window, at: inA)
        #expect(!tracker.shouldHoldHorizontalDrift(for: paneA, at: 0.02),
                "a horizontal gesture was held against its own pane")
    }

    /// Attribution is frozen at the gesture's start: AppKit routes a phased gesture to the view it
    /// began over however far the pointer travels (a Magic Mouse moves under the swiping hand).
    @Test func testPointerDriftDuringTheDragCannotMigrateTheHold() {
        let (window, paneA, paneB) = twoPanes()
        defer { _ = window }
        let tracker = WheelGestureTracker()
        let inA = paneA.convert(NSPoint(x: 40, y: 40), to: nil)
        let inB = paneB.convert(NSPoint(x: 40, y: 40), to: nil)
        drag(tracker, dx: 0, dy: -6, window: window, at: inA)
        // Still the same drag (same gesture, same `.changed` phase), but the pointer has slid over
        // the neighbouring pane.
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -8,
                       window: window, locationInWindow: inB, at: 0.02)
        #expect(tracker.shouldHoldHorizontalDrift(for: paneA, at: 0.03),
                "the pointer drifting out of pane A unguarded the pane the drag is actually in")
        #expect(!tracker.shouldHoldHorizontalDrift(for: paneB, at: 0.03),
                "the pointer drifting into pane B migrated the hold onto a pane the drag never touched")
    }

    /// The freeze is per gesture, not a latch: the next gesture attributes to where it starts.
    @Test func testANewGestureAttributesToWhereItStarts() {
        let (window, paneA, paneB) = twoPanes()
        defer { _ = window }
        let tracker = WheelGestureTracker()
        let inA = paneA.convert(NSPoint(x: 40, y: 40), to: nil)
        let inB = paneB.convert(NSPoint(x: 40, y: 40), to: nil)
        drag(tracker, dx: 1, dy: -12, window: window, at: inA)
        // A fresh gesture, begun in the other pane.
        drag(tracker, dx: 1, dy: -12, window: window, at: inB, t: 0.02)
        #expect(tracker.shouldHoldHorizontalDrift(for: paneB, at: 0.04),
                "the new gesture's own pane was not held — the first gesture latched the attribution")
        #expect(!tracker.shouldHoldHorizontalDrift(for: paneA, at: 0.04),
                "the previous gesture's pane is still held — attribution latched instead of re-arming")
    }

    /// Two panes in two windows at the same in-window location: the only shape where the window
    /// check does any work.
    @Test func testAGestureIsScopedToItsOwnWindow() {
        let (windowA, paneA, _) = twoPanes()
        let (windowB, paneB, _) = twoPanes()
        defer { _ = (windowA, windowB) }
        let tracker = WheelGestureTracker()
        let point = paneA.convert(NSPoint(x: 40, y: 40), to: nil)
        #expect(paneB.bounds.contains(paneB.convert(point, from: nil)),
                "the two panes are not at the same in-window point — location alone would discriminate")
        drag(tracker, dx: 1, dy: -12, window: windowA, at: point)
        #expect(tracker.shouldHoldHorizontalDrift(for: paneA, at: 0.02),
                "the gesture's own pane was not held")
        #expect(!tracker.shouldHoldHorizontalDrift(for: paneB, at: 0.02),
                "a gesture in one window held a pane in another — the window check does nothing")
    }

    /// Two stacks built as real scroll views, each with a band at the bottom the clip's bounds
    /// exclude: where AppKit puts the horizontal scroller under "Show scroll bars: Always".
    private func twoScrollingPanes() -> (window: NSWindow, a: NSScrollView, b: NSScrollView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        func pane(x: CGFloat) -> NSScrollView {
            let scroller = NSScrollView(frame: NSRect(x: x, y: 0, width: 200, height: 100))
            // AppKit reserves the band: a clip frame set by hand is undone by the scroll view's tiling.
            scroller.scrollerStyle = .legacy
            scroller.hasHorizontalScroller = true
            scroller.hasVerticalScroller = false
            scroller.autohidesScrollers = false
            scroller.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            window.contentView?.addSubview(scroller)
            scroller.tile()
            return scroller
        }
        return (window, pane(x: 0), pane(x: 260))
    }

    /// A gesture over the stack's own horizontal scroller is outside the clip's bounds, so
    /// containment is the enclosing scroll view, which receives the deltas a column's list forwards.
    @Test func testAGestureOnTheStacksScrollerBandStillHoldsThatStack() throws {
        let (window, a, b) = twoScrollingPanes()
        defer { _ = window }
        let clipA = a.contentView
        let band = try #require(a.horizontalScroller?.frame,
                                "the fixture reserved no scroller band — there is no strip to pin")
        let onScroller = a.convert(NSPoint(x: band.midX, y: band.midY), to: nil)
        try #require(!clipA.bounds.contains(clipA.convert(onScroller, from: nil)),
                     "the fixture point is inside the clip — it pins nothing")
        try #require(a.bounds.contains(a.convert(onScroller, from: nil)),
                     "the fixture point is outside the stack's scroll view too — it pins nothing")

        let tracker = WheelGestureTracker()
        drag(tracker, dx: 1, dy: -12, window: window, at: onScroller)
        #expect(tracker.shouldHoldHorizontalDrift(for: clipA, at: 0.02),
                "a gesture on the stack's own scroller band held nothing — the vertical leak is back for that strip")
        #expect(!tracker.shouldHoldHorizontalDrift(for: b.contentView, at: 0.02),
                "widening containment to the scroll view leaked the hold into the other pane")
    }
}

/// The lock's enforcement on the stack, over the strandable harness: while a vertical gesture
/// delivers, leaked horizontal drift is reverted on the spot; once it releases, horizontal movement
/// is the stack's own business again.
@MainActor
@Suite struct PaneColumnsAxisLockTests {

    /// Never lands where the hold puts it: every revert to x comes back at x+0.5, as an animated
    /// SwiftUI scroll moving the clip against the hold would.
    private final class FightingClipView: NSClipView {
        var fightsBack = false
        private(set) var setCount = 0
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
        override func setBoundsOrigin(_ newOrigin: NSPoint) {
            setCount += 1
            let origin = fightsBack ? NSPoint(x: newOrigin.x + 0.5, y: newOrigin.y) : newOrigin
            super.setBoundsOrigin(origin)
        }
    }

    private func mount(clip: NSClipView = StrandableClipView()) -> (window: NSWindow, clip: NSClipView, watchdog: PaneColumnsOverscrollReturn.WatchdogView, lock: WheelGestureTracker) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let lock = WheelGestureTracker()
        let stack = addStack(to: window, x: 0, clip: clip, lock: lock)
        return (window, clip, stack.watchdog, lock)
    }

    @Test func testLeakedHorizontalDriftIsRevertedDuringAVerticalGesture() async throws {
        let (window, clip, watchdog, lock) = mount()
        defer { _ = window }
        await idle(seconds: 0.3)
        try #require(watchdog.resolvedScroller != nil, "watchdog failed to arm")

        // A vertical drag dated ahead of the wall clock (`beginVerticalDragAhead`): the revert is a
        // runloop hop away by design (reverting inside the bounds notification recurses until the
        // stack guard kills the app), and under load that hop can land past the 100ms recency
        // window. Attributed to this stack so the scoped path is the one exercised.
        beginVerticalDragAhead(lock, window: window,
                               at: clip.convert(NSPoint(x: 20, y: 20), to: nil))

        // One leaked horizontal delta strands the stack sideways.
        clip.setBoundsOrigin(NSPoint(x: 9, y: 0))
        try #require(clip.bounds.origin.x == 9, "fixture failed to strand the clip")

        // Only the hold's enforcement can put it back to 0: 9 is legal, so the quiescence return
        // never touches it. The pass floor makes the deadline mean something under starvation.
        let held = await LayoutPumpWait.poll(upTo: 60) { clip.bounds.origin.x == 0 }
        #expect(held.held,
                "a vertical gesture's leaked delta moved the stack and the hold never reverted it, after \(held.passes) passes")
    }

    /// A scroll that keeps fighting the hold gets at most one revert per runloop turn, never a
    /// recursion inside the notification until the stack guard kills the app.
    @Test func testAFightingScrollCannotRecurseTheHold() async throws {
        let clip = FightingClipView()
        let (window, _, watchdog, lock) = mount(clip: clip)
        defer { _ = window }
        await idle(seconds: 0.3)
        try #require(watchdog.resolvedScroller != nil, "watchdog failed to arm")

        // The clip never lands on the held position. Dated ahead and attributed, as above, so the
        // only net for the recursion crash runs through the scoped path the app takes.
        beginVerticalDragAhead(lock, window: window,
                               at: clip.convert(NSPoint(x: 20, y: 20), to: nil))
        // Counted from here: mounting alone racks up setBoundsOrigin calls.
        let mountSets = clip.setCount
        clip.fightsBack = true
        clip.setBoundsOrigin(NSPoint(x: 9, y: 0))

        // Keep the runloop turning for a while; an in-notification revert would recurse thousands
        // of frames deep inside the first setBoundsOrigin call.
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        // Reaching this line is most of the assertion; ~50 turns elapse, so per-turn enforcement
        // stays in that order where recursion would pile up thousands.
        let fightSets = clip.setCount - mountSets
        #expect(fightSets < 500,
                "the hold fought a moving scroll \(fightSets) times — per-turn bounding is gone")
        // More than the strand's own set: the hold really did engage and fight, once per turn.
        #expect(fightSets > 1, "the fixture never engaged the hold at all — nothing was pinned")
    }

    /// Two stacks share one lock and a vertical gesture is in pane A: A's drift is reverted, B's own
    /// scroll stays. A's revert landing makes B's untouched origin a real absence.
    @Test func testAGestureInOnePaneDoesNotHoldTheOtherPanesStack() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { _ = window }
        let lock = WheelGestureTracker()
        let paneA = addStack(to: window, x: 0, lock: lock)
        let paneB = addStack(to: window, x: 260, lock: lock)
        await idle(seconds: 0.3)
        try #require(paneA.watchdog.resolvedScroller != nil, "pane A's watchdog failed to arm")
        try #require(paneB.watchdog.resolvedScroller != nil, "pane B's watchdog failed to arm")

        // A vertical drag in pane A, dated ahead of the wall clock as above.
        beginVerticalDragAhead(lock, window: window,
                               at: paneA.clip.convert(NSPoint(x: 20, y: 20), to: nil))

        // B scrolls itself (the reveal's stand-in) and A drifts; both legal, so only the hold can move them.
        paneB.clip.setBoundsOrigin(NSPoint(x: 9, y: 0))
        paneA.clip.setBoundsOrigin(NSPoint(x: 9, y: 0))
        try #require(paneA.clip.bounds.origin.x == 9, "fixture failed to strand pane A")
        try #require(paneB.clip.bounds.origin.x == 9, "fixture failed to scroll pane B")

        // Floored as above; the assertion after it depends on this having actually waited.
        let heldA = await LayoutPumpWait.poll(upTo: 60) { paneA.clip.bounds.origin.x == 0 }
        #expect(heldA.held,
                "the gesture's own pane was never held — the original leak is back, after \(heldA.passes) passes")
        #expect(paneB.clip.bounds.origin.x == 9,
                "a vertical gesture in pane A reverted pane B's own scroll — B's reveal is defeated again")
    }

    /// `PaneColumnHoldGate.isStackHeld`, asked before a reveal scrolls, is scoped per stack: else a
    /// flick in one pane stalls the other's reveal. The only test that catches an unscoped gate;
    /// pane A answering true keeps B's false from being vacuous.
    @Test func testTheRevealsHoldQuestionIsScopedToItsOwnPane() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { _ = window }
        let lock = WheelGestureTracker()
        let paneA = addStack(to: window, x: 0, lock: lock, gate: PaneColumnHoldGate())
        let paneB = addStack(to: window, x: 260, lock: lock, gate: PaneColumnHoldGate())
        await idle(seconds: 0.3)

        // Before any gesture, neither pane defers a reveal.
        #expect(!paneA.gate!.isStackHeld && !paneB.gate!.isStackHeld,
                "a stack reported held with no gesture in flight — every reveal would be deferred")

        // A vertical drag in pane A, dated ahead of the wall clock as above.
        beginVerticalDragAhead(lock, window: window,
                               at: paneA.clip.convert(NSPoint(x: 20, y: 20), to: nil))

        #expect(paneA.gate!.isStackHeld,
                "the gesture's own pane did not report held — its reveal will be issued into the hold and reverted")
        #expect(!paneB.gate!.isStackHeld,
                "a gesture in pane A held pane B's gate — B's reveal is stalled by a flick it has nothing to do with")
    }

    /// A gate with no watchdog, or one not yet resolved, reads not held: there is nothing to
    /// revert, and failing closed would defer every reveal made before the ancestor walk lands.
    @Test func testAnUnresolvedGateNeverDefersAReveal() throws {
        let gate = PaneColumnHoldGate()
        #expect(!gate.isStackHeld, "a gate with no watchdog reported held — every reveal would wait")

        let watchdog = PaneColumnsOverscrollReturn.WatchdogView()
        watchdog.pullDuration = 0        // see `pullDuration`
        let lock = WheelGestureTracker()
        watchdog.axisLock = lock
        watchdog.holdGate = gate
        // Unattributed and vertical: the lock holds everywhere, so only the missing scroll view can
        // make this false.
        beginVerticalDragAhead(lock)
        try #require(lock.shouldHoldHorizontalDrift(for: NSView()),
                     "the fixture's own lock is not holding — the gate's false below proves nothing")
        #expect(!gate.isStackHeld,
                "a watchdog that has resolved no scroll view reported held — reveals would wait on a stack it is not guarding")
    }

    /// A pane parks at most one deferred reveal, and can drop it. Several drivers schedule reveals
    /// and each chain retains the pane's captures and `ScrollViewProxy` for its whole budget; an
    /// `asyncAfter` block can't be cancelled, so the cancellable lives on the gate. Measured as
    /// deallocation, because retention is the claim.
    @Test func testAPaneParksOneDeferredRevealAndDropsTheRest() {
        final class Probe {}
        let gate = PaneColumnHoldGate()
        // Long enough that nothing below races a deadline: every deallocation asserted here comes
        // from a replacement or a cancel, never from the block having run.
        let farOut: TimeInterval = 600
        let generation = gate.beginReveal()

        weak var first: Probe?
        do {
            let probe = Probe()
            first = probe
            gate.deferReveal(generation: generation, by: farOut) { _ = probe }
        }
        #expect(first != nil,
                "a parked reveal does not retain its captures at all — every assertion below would pass vacuously")

        // A second reveal replaces the first rather than joining it.
        weak var second: Probe?
        do {
            let probe = Probe()
            second = probe
            gate.deferReveal(generation: gate.beginReveal(), by: farOut) { _ = probe }
        }
        #expect(first == nil,
                "a second reveal left the first chain parked — a pane under a sustained hold accumulates one chain per driver, each holding the pane for the whole budget")
        #expect(second != nil, "the replacement was not parked")

        // And a teardown drops what is parked.
        gate.cancelPendingReveal()
        #expect(second == nil,
                "cancelling left the chain holding the pane — a reveal outliving the pane it was revealing is exactly what a queued block cannot notice on its own")
    }

    /// A superseded reveal can't park, nor evict the reveal that superseded it: its queued
    /// attempts (`async`, `asyncAfter(+revealRetryDelay)`) can't be cancelled, and a second reveal
    /// within 0.25s is routine, so the stale retry would replace the newer chain.
    @Test func testASupersededRevealCannotPark() {
        final class Probe {}
        let gate = PaneColumnHoldGate()
        let farOut: TimeInterval = 600

        let older = gate.beginReveal()
        let newer = gate.beginReveal()
        #expect(!gate.isCurrent(older), "a reveal is still current after a later one began")
        #expect(gate.isCurrent(newer), "the reveal that just began is not current")

        weak var live: Probe?
        do {
            let probe = Probe()
            live = probe
            gate.deferReveal(generation: newer, by: farOut) { _ = probe }
        }
        #expect(live != nil,
                "the current reveal could not park at all — the eviction assertion below would pass vacuously")

        weak var stale: Probe?
        do {
            let probe = Probe()
            stale = probe
            gate.deferReveal(generation: older, by: farOut) { _ = probe }
        }
        #expect(stale == nil,
                "a superseded reveal parked its chain — an older reveal's queued retry is unstoppable, so this is how one reinstates itself over the reveal that replaced it")
        #expect(live != nil,
                "a superseded reveal's park evicted the live chain — the newer reveal's wait is gone and what replaced it was refused, so nothing is left waiting at all")
    }

    /// A teardown cancel is final: an attempt queued within `revealRetryDelay` of it still runs, and
    /// must not park a fresh chain afterwards. The bound comes from the cancel, not the fail-open path.
    @Test func testATeardownCancelSupersedesTheRevealThatQueuedIt() {
        final class Probe {}
        let gate = PaneColumnHoldGate()
        let generation = gate.beginReveal()
        #expect(gate.isCurrent(generation),
                "the reveal that just began is not current — the assertion below would pass vacuously")

        gate.cancelPendingReveal()
        #expect(!gate.isCurrent(generation),
                "a teardown cancel left the in-flight reveal current — its queued attempts still speak for a pane that is gone")

        weak var late: Probe?
        do {
            let probe = Probe()
            late = probe
            gate.deferReveal(generation: generation, by: 600) { _ = probe }
        }
        #expect(late == nil,
                "an attempt queued before teardown parked a fresh chain after the cancel — the cancel bounded nothing, which is the property the cancellable was moved onto the gate for")
    }

    @Test func testHorizontalScrollingIsUntouchedOutsideAVerticalGesture() async throws {
        let (window, clip, watchdog, lock) = mount()
        defer { _ = window }
        await idle(seconds: 0.3)
        try #require(watchdog.resolvedScroller != nil, "watchdog failed to arm")

        lock.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0)
        lock.ingest(phase: .changed, momentumPhase: [], dx: -18, dy: 2)

        clip.setBoundsOrigin(NSPoint(x: 120, y: 0))
        #expect(clip.bounds.origin.x == 120,
                "the lock held the stack during a HORIZONTAL gesture — columns can no longer scroll")
    }
}

/// Lets any proposed bounds through, the way the rubber band's in-flight state does.
private final class StrandableClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
}

/// Lets the main actor turn for `seconds` without laying anything out, floored like every wait.
@MainActor private func idle(seconds: Double) async {
    _ = await LayoutPumpWait.poll(upTo: seconds) { false }
}

/// Waits for the watchdog to move the clip, floored on passes: the pull arrives on a main-actor
/// turn, and a congested run has fewer turns per second. Returns the pass count for the message.
/// `poll`, not `pump`: pumping would disarm the runaway-layout guards (`LayoutPumpWait.poll`).
@MainActor private func waitForOrigin(_ clip: NSClipView, toBecome expected: NSPoint,
                                      timeout: Double = 15) async -> (held: Bool, passes: Int) {
    await LayoutPumpWait.poll(upTo: timeout) { clip.bounds.origin == expected }
}

/// `waitForOrigin`, expected to hold: fails with where the clip was left and the pass count.
@MainActor private func expectPulledHome(_ clip: NSClipView, to expected: NSPoint, _ what: String,
                                         sourceLocation: SourceLocation = #_sourceLocation) async {
    let settled = await waitForOrigin(clip, toBecome: expected)
    #expect(settled.held,
            """
            \(what) \(clip.bounds.origin) (gave up after \(settled.passes) passes — a handful \
            means the run was starved, not that the watchdog is broken)
            """, sourceLocation: sourceLocation)
}

/// A 200pt stack over 600pt of content at `x` in `window`, its watchdog on `lock` (and `gate`).
@MainActor private func addStack(
    to window: NSWindow, x: CGFloat, clip: NSClipView = StrandableClipView(),
    lock: WheelGestureTracker, gate: PaneColumnHoldGate? = nil
) -> (clip: NSClipView, watchdog: PaneColumnsOverscrollReturn.WatchdogView, gate: PaneColumnHoldGate?) {
    let scroller = NSScrollView(frame: NSRect(x: x, y: 0, width: 200, height: 100))
    clip.automaticallyAdjustsContentInsets = false
    scroller.contentView = clip
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
    scroller.documentView = document
    let watchdog = PaneColumnsOverscrollReturn.WatchdogView()
    watchdog.pullDuration = 0    // see `pullDuration`
    watchdog.axisLock = lock
    if let gate { watchdog.holdGate = gate }
    document.addSubview(watchdog)
    window.contentView?.addSubview(scroller)
    return (clip, watchdog, gate)
}

/// A vertical drag delivering events at `location`, dated an hour ahead of the wall clock so the
/// lock reads "in flight" for the whole test however late enforcement lands.
@MainActor private func beginVerticalDragAhead(_ lock: WheelGestureTracker, window: NSWindow? = nil,
                                               at location: NSPoint = .zero) {
    drag(lock, dx: 1, dy: -12, window: window, at: location, t: CFAbsoluteTimeGetCurrent() + 3600)
}

/// A drag's opening: `.began` at `t`, then one `.changed` of (`dx`, `dy`) 10 ms later.
@MainActor private func drag(_ tracker: WheelGestureTracker, dx: CGFloat, dy: CGFloat,
                             window: NSWindow? = nil, at location: NSPoint = .zero, t: TimeInterval = 0) {
    tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                   window: window, locationInWindow: location, at: t)
    tracker.ingest(phase: .changed, momentumPhase: [], dx: dx, dy: dy,
                   window: window, locationInWindow: location, at: t + 0.01)
}
