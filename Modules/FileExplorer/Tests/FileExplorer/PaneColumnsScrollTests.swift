import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// The column stack's scrolling is native, and must stay that way.
///
/// Hand-rolled overscroll handling breaks it: a custom `NSClipView` replaces the one SwiftUI
/// configured. Any vertical slack it grants unlocks an axis SwiftUI sets to `.none`, so a scroll
/// gesture displaces a horizontal Miller-column stack downward. Slack gated on
/// `willStart`/`didEndLiveScroll` ends at finger-lift, before the momentum phase where a flick
/// meets the edge, giving a dead stop instead of a bounce, and a snap-home animation that races the
/// momentum events still arriving.
///
/// AppKit's own rubber band is bounded, momentum-aware and self-returning, and SwiftUI already
/// configures the stack correctly (horizontal `.allowed`, vertical `.none`). These tests pin that
/// configuration: swap the clip view or kill the elasticity and the mounted assertions fail.
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
            // Place the drill's reveal outright instead of easing it (see
            // `EnvironmentValues.paneColumnRevealAnimation`). This window is offscreen and never
            // key, so with the display asleep (an unattended CI runner's normal state) or in Low
            // Power Mode, an animation in it never advances and the reveal's scroll never lands.
            //
            // `testTheMountedStackAtRestIsLeftAlone` depends on it: its premise is a stack resting
            // at the far end after the reveal. With the reveal inert it would assert about a stack
            // at x=0, a much weaker claim, so it requires the reveal it waits for.
            .environment(\.paneColumnRevealAnimation, nil)
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

    /// Mounts the pane with three columns open in a 520pt window: 630pt of content, so the stack
    /// genuinely scrolls. Returns the window (kept alive by the caller), the stack's scroll view
    /// and the columns' lists.
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

        let all = PaneRowRevealTests.scrollViews(window.contentView!)
        let stack = try #require(all.first { !($0.documentView is NSTableView) }, "no stack scroll view")
        let columns = all.filter { $0.documentView is NSTableView }
        return (window, stack, columns)
    }

    /// Origins well outside the clip view's legal band, one per edge of each axis. Far enough out
    /// that no rounding could pass for slack, and both axes because vertical give, on an axis
    /// SwiftUI locked, is what a user would see.
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

        // The clip view is the framework's, not ours, asserted two ways, because the thing to catch
        // is our own subclass returning and neither half says that alone. (SwiftUI's class varies
        // by OS: macOS 27 installs its own `HostingClipView`, so an exact `NSClipView` check is
        // wrong.)
        //
        // First, provenance: a clip view this module defines is vended by this module's bundle;
        // SwiftUI's comes from SwiftUI.framework, whichever subclass it picks.
        #expect(Bundle(for: type(of: stack.contentView))
                != Bundle(for: PaneColumnsOverscrollReturn.WatchdogView.self),
                "the stack's clip view is a subclass this module defines — the machinery is back (\(type(of: stack.contentView)))")

        // Second, behaviour: ask the clip view to travel past its content on both axes and require
        // the legal origin back, unchanged. Grants past the content, especially vertical, are what
        // displace the stack.
        //
        // Both phases are probed, because a clip view that gates its slack on
        // `willStartLiveScroll`/`didEndLiveScroll` clamps correctly at rest. Fails against a clip
        // view that grants ±44pt during a live scroll. (The elastic bounce asserted above is
        // unaffected: AppKit's rubber band is driven from inside a real gesture, not by a posted
        // notification.)
        //
        // The live phase must wait for the notification to be delivered, and require it. A gate
        // observer registered with `queue: .main` runs enqueued, not inside `post`, so probing
        // straight after posting reads a clip view not yet told the gesture started, and the live
        // half would pass over the slack it is for. Our observer is registered last on the same
        // notification and object, and blocks run in registration order on one queue, so when ours
        // has run any earlier one has too.
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

        // The columns' own lists keep their native vertical bounce. (No class check: a List's clip
        // view is a private SwiftUI subclass.)
        #expect(columns.allSatisfy { $0.verticalScrollElasticity != .none },
                "a column list lost its vertical bounce")
    }

    /// The watchdog must guard the stack's scroll view. Resolution is the one thing the synthetic
    /// tests below can't pin, and targeting a column's list instead would look identical from
    /// outside.
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

    /// The watchdog must never disturb the mounted stack at rest. After the drill's own auto-scroll
    /// settles, nothing may move the stack again: a watchdog that nudges legal resting positions
    /// would fight every scroll the user makes.
    ///
    /// (The pull itself is driven synthetically in `PaneColumnsOverscrollReturnRuleTests`:
    /// SwiftUI's clip view clamps a programmatic `setBoundsOrigin`, so only the lost-phase elastic
    /// gesture can strand the mounted stack, and no bounds-setting fixture reproduces that.)
    @Test func testTheMountedStackAtRestIsLeftAlone() async throws {
        let (window, stack, _) = try await mountThreeColumns()
        defer { _ = window }
        let clip = stack.contentView

        // Wait for the drill's own auto-scroll first: it reveals the newest column by scrolling the
        // stack to its max extent, and under a loaded run it can land seconds after the mount's
        // pump, inside the assertion window below. The extent is recomputed per pass because layout
        // can land late too. Floored on layout passes (`LayoutPumpWait`), not just seconds, because
        // a slow hosted VM can run the seconds out first.
        let (revealed, pumps) = await LayoutPumpWait.pump(window, upTo: 15) {
            let extent = max(0, (stack.documentView?.frame.width ?? 0) - stack.contentSize.width)
            return extent > 0 && clip.bounds.origin.x >= extent - 1
        }
        // Required, not merely waited for: falling out of the loop leaves the stack at x=0, where
        // the origin is legal and the watchdog has nothing to do, so the assertion below would hold
        // whatever the watchdog did at the far end.
        try #require(revealed,
                     "the drill's reveal never reached the stack's far end (origin \(clip.bounds.origin.x), \(pumps) passes) — the rest below is not the rest this test is about")

        // Then for genuine rest: a baseline read while anything still moves fails this test against
        // that movement. Rest is the origin holding still for a full second.
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

        // Both halves live in one test because they share a process-wide switch: as two tests they
        // interleave at their `await` points and each flips the flag under the other. Owning the
        // flag for the whole test removes the ordering question.
        let wasEnabled = PaneScrollTrace.isEnabled
        defer { PaneScrollTrace.isEnabled = wasEnabled }

        // Asked for: the probe must emit. Silent instrumentation would report a healthy pane no
        // matter what the pane did.
        PaneScrollTrace.isEnabled = true
        let before = probe.linesLogged
        clip.scroll(to: NSPoint(x: 0, y: min(30, scrollable)))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        // The emission is two main-thread hops away (a bounds-change notification, then the probe's
        // 250ms coalescing flush), and under a full parallel run other main-actor work can starve
        // those hops. A bigger timeout can't buy a main-actor turn, so this waits on layout passes
        // with `LayoutPumpWait.pump`, which floors them.
        let emitted = await LayoutPumpWait.pump(window, upTo: 15) { probe.linesLogged > before }
        #expect(emitted.held,
                "the probe never reported the column's travel, after \(emitted.pumps) passes")

        // Not asked for, as it ships: the same travel back must write nothing. `LogFileWriter` caps
        // the log at 5 MB and trims it, so a per-frame line would evict the sync runs and errors
        // the log is kept for.
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

    /// A document narrower than the clip: the left pane resting with three columns in a wide pane.
    /// Home collapses to the document's leading edge. A zero-based clamp gives the same x only
    /// because the document sits at zero, and a dragged-and-stranded fitting stack must still
    /// return.
    @Test func testAFittingDocumentsHomeIsItsLeadingEdge() {
        let view = NSClipView(frame: NSRect(x: 0, y: 0, width: 772, height: 100))
        view.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
        #expect(PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(
            for: NSPoint(x: -60, y: 0), clip: view) == NSPoint(x: 0, y: 0))
        #expect(PaneColumnsOverscrollReturn.WatchdogView.legalOrigin(
            for: NSPoint(x: 45, y: 0), clip: view) == NSPoint(x: 0, y: 0))
    }

    /// The pull's threshold exists and is sub-visible: SwiftUI parks clips at fractional origins,
    /// and a watchdog with no slack for that would correct them every quiescence interval, forever.
    /// The cycle suite drives the behaviour; this pins the constant's range so tightening it can't
    /// bring the loop back.
    @Test func testTheToleranceClearsPixelAlignmentButNotVisibleStrandings() {
        #expect(PaneColumnsOverscrollReturn.WatchdogView.tolerance >= 1,
                "sub-point pixel alignment must never trigger a pull")
        #expect(PaneColumnsOverscrollReturn.WatchdogView.tolerance <= 8,
                "a stranding this size is visible — the watchdog would ignore real bugs")
    }
}

/// The watchdog's full cycle (observe, wait for rest, pull home), driven over a synthetic scroll
/// view whose clip can actually be stranded.
///
/// The real stranded state is reachable only through the lost-phase elastic gesture: SwiftUI's
/// clip view clamps a programmatic `setBoundsOrigin`, so no bounds-setting fixture can strand the
/// mounted stack. This permissive clip view stands in for the elastic state, out-of-range bounds
/// that nothing re-constrains, which is what the watchdog exists to notice.
@MainActor
@Suite struct PaneColumnsOverscrollReturnCycleTests {

    /// A 200pt scroll view over 600pt of content, with the watchdog mounted inside the document
    /// view, where the SwiftUI `.background` puts it in the real stack.
    private func mount() -> (window: NSWindow, scroller: NSScrollView, clip: NSClipView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = StrandableClipView()
        scroller.contentView = clip
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
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

    /// Pins the shipped pull duration, which no other test reads. Every mount here injects
    /// `pullDuration = 0` so CoreAnimation starvation can't decide the verdict, so a default
    /// drifting to zero would delete the bounce for real users with the suite still green.
    /// `docs/flaky-tests.md` ("The machine decides the verdict — throttled CoreAnimation"): pin the
    /// default, or the fix costs the coverage it bought.
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

        let settled = await waitForOrigin(clip, toBecome: NSPoint(x: 0, y: 0))
        #expect(settled.held,
                """
                the watchdog left the clip stranded past the left edge, at \(clip.bounds.origin) \
                (gave up after \(settled.passes) passes — a handful means the run was starved, \
                not that the watchdog is broken)
                """)
    }

    @Test func testAClipStrandedPastTheEndIsPulledToTheEnd() async {
        let (window, _, clip) = mount()
        defer { _ = window }
        await idle(seconds: 0.3)

        clip.setBoundsOrigin(NSPoint(x: 460, y: 0))  // 400 is the last legal origin
        #expect(clip.bounds.origin.x == 460, "fixture failed to strand the clip")

        let settled = await waitForOrigin(clip, toBecome: NSPoint(x: 400, y: 0))
        #expect(settled.held,
                """
                the watchdog left the clip stranded past the right edge, at \(clip.bounds.origin) \
                (gave up after \(settled.passes) passes — a handful means the run was starved, \
                not that the watchdog is broken)
                """)
    }

    /// A rest that was legal becomes illegal because the viewport grew under it, the case the
    /// preview's un-driven falling edge leaves to this watchdog. The tests above move the origin
    /// and leave the viewport alone; this does the reverse, and only `legalOrigin`'s clamp closes
    /// the gap.
    ///
    /// Pinned here, not through a mounted pane: a real pane's `NSClipView` re-constrains itself
    /// when its frame grows, so the mounted close never reaches this code
    /// (`ColumnPreviewRevealTests`'s close test passes even without the clamp). What this covers is
    /// a clip that doesn't self-correct, the state a phase-less gesture leaves behind.
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

        // Re-armed the way the app re-arms it. Resizing a clip posts a frame notification, but the
        // watchdog observes the bounds one, so a viewport growing on its own wakes nothing. In the
        // pane, the SwiftUI update that closed the preview wakes it (`updateNSView` calls `rearm()`
        // on every pass); a harness that skipped this would pin a path the app never takes.
        let watchdog = try #require(
            scroller.documentView?.subviews.compactMap {
                $0 as? PaneColumnsOverscrollReturn.WatchdogView
            }.first, "the watchdog is not mounted in the document view")
        watchdog.rearm()

        let settled = await waitForOrigin(clip, toBecome: NSPoint(x: 100, y: 0))
        #expect(settled.held,
                """
                a rest the grown viewport made illegal was left stranded at \(clip.bounds.origin) \
                (gave up after \(settled.passes) passes — a handful means the run was starved, \
                not that the watchdog is broken)
                """)
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

    /// The loop-breaker. SwiftUI parks clip origins fractionally off the mathematical home, and
    /// pulling those would correct the same fraction every quiescence interval, each pull an
    /// animated `setBoundsOrigin` visible as jitter. A sub-tolerance offset must be left where it
    /// is, forever.
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

    /// A fitting document dragged out and stranded must still return: the tolerance exempts pixel
    /// fractions, not real strandings, and content narrower than the clip is the state the left
    /// pane rests in.
    @Test func testAStrandedFittingDocumentIsPulledToItsLeadingEdge() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clip = StrandableClipView()
        scroller.contentView = clip
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 100))
        scroller.documentView = document
        let watchdog = PaneColumnsOverscrollReturn.WatchdogView()
        watchdog.pullDuration = 0        // see `pullDuration` — CoreAnimation may not be ticking here
        document.addSubview(watchdog)
        window.contentView?.addSubview(scroller)
        defer { _ = window }
        await idle(seconds: 0.3)

        clip.setBoundsOrigin(NSPoint(x: -60, y: 0))
        #expect(clip.bounds.origin.x == -60, "fixture failed to strand the fitting document")

        let settled = await waitForOrigin(clip, toBecome: NSPoint(x: 0, y: 0))
        #expect(settled.held,
                """
                a stranded fitting document was not pulled home, at \(clip.bounds.origin) \
                (gave up after \(settled.passes) passes — a handful means the run was starved, \
                not that the watchdog is broken)
                """)
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
/// probe that also logs their travel.
///
/// A list can park in overscroll (a log reads `y 0.0 → -17.5`, then `-17.5 → 0.0` some time later
/// on an unrelated event). The same lost-phase gesture as the stack's, and the same
/// synthetic-strand test shape, because the real state is only reachable through the broken gesture
/// routing.
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
        // A row-less NSTableView as the document auto-sizes itself back to the clip, collapsing the
        // scrollable extent. So the document is a plain view that keeps its 600pt, with the table
        // inside it; the resolver still matches, since it measures the table's enclosing scroll
        // view.
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

    /// Pins the shipped pull duration, which no other test reads. Every mount here injects
    /// `pullDuration = 0` so CoreAnimation starvation can't decide the verdict, so a default
    /// drifting to zero would delete the bounce for real users with the suite still green. Same
    /// pin, same reason, as `thePullHomeShipsAnimated` on the stack watchdog.
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

        let settled = await waitForOrigin(clip, toBecome: NSPoint(x: 0, y: 0))
        #expect(settled.held,
                """
                the list stayed parked in top overscroll, at \(clip.bounds.origin) \
                (gave up after \(settled.passes) passes — a handful means the run was starved, \
                not that the watchdog is broken)
                """)
    }

    /// A list parked past its bottom comes back to the last legal line.
    @Test func testAListParkedPastTheBottomIsPulledToTheEnd() async throws {
        let (window, clip, probe) = mount()
        defer { _ = window }
        await idle(seconds: 0.3)
        try #require(probe.resolvedClip === clip, "probe failed to resolve its list")

        clip.setBoundsOrigin(NSPoint(x: 0, y: 560))  // 500 is the last legal origin
        let settled = await waitForOrigin(clip, toBecome: NSPoint(x: 0, y: 500))
        #expect(settled.held,
                """
                the list stayed parked past its bottom, at \(clip.bounds.origin) \
                (gave up after \(settled.passes) passes — a handful means the run was starved, \
                not that the watchdog is broken)
                """)
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
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 2, dy: -14, at: 0.01)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.02))
    }

    @Test func testAHorizontalDragDoesNot() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: -20, dy: 3, at: 0.01)
        #expect(!tracker.shouldHoldHorizontalDrift(at: 0.02))
    }

    /// The decision is made once, from the first real deltas: a vertical drag that wobbles
    /// horizontal mid-flight stays a vertical drag.
    @Test func testTheFirstRealDeltasDecideForTheWholeGesture() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -10, at: 0.01)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: -9, dy: 2, at: 0.02)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.03),
                "a mid-gesture wobble re-decided the axis")
    }

    /// Momentum inherits the drag's decision and keeps the lock alive while it delivers.
    @Test func testMomentumInheritsTheDecisionAndItsEndReleasesIt() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 0, dy: -12, at: 0.01)
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
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 0, dy: -12, at: 0.01)
        tracker.ingest(phase: .ended, momentumPhase: [], dx: 0, dy: 0, at: 0.02)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.05), "still within the recency window")
        #expect(!tracker.shouldHoldHorizontalDrift(at: 0.02 + WheelGestureTracker.staleness + 0.01),
                "the lock outlived its events — the next programmatic scroll will be fought")
    }

    /// A new gesture starts undecided, and an undecided opening holds, so a vertical scroll can't
    /// leak its first frames while the verdict accumulates. The previous gesture's decision must
    /// not carry over either way: here the old one was vertical, and the new one earns a horizontal
    /// verdict that releases the hold.
    @Test func testANewGestureStartsUndecidedAndHeld() {
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 0, dy: -12, at: 0.01)
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0.05)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.06),
                "an undecided opening was not held — its first frames can leak")
        tracker.ingest(phase: .changed, momentumPhase: [], dx: -18, dy: 2, at: 0.07)
        #expect(!tracker.shouldHoldHorizontalDrift(at: 0.08),
                "the previous gesture's vertical decision leaked into the new one")
    }

    /// A trackpad touch-down's first samples are directionally noisy, so deciding on the very first
    /// delta can misread a vertical scroll as horizontal and unlock the whole gesture (seen as the
    /// first column flickering). The verdict needs accumulated travel, and the noisy opening stays
    /// held until it arrives.
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
    // A plain wheel mouse sends none of the trackpad's phases: phase and momentumPhase are both
    // empty on every event, so the trackpad's clears are unreachable for it, and the lock could
    // stick permanently for anyone not on a touch surface.

    /// Each wheel click is its own gesture, so a horizontal one is horizontal even after a vertical
    /// one. Otherwise the first vertical click latches `verticalDominant` and `enforceHold` reverts
    /// the stack against every later ⇧-wheel.
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
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12, at: 0.01)
        tracker.ingest(phase: .ended, momentumPhase: [], dx: 0, dy: 0, at: 0.02)
        #expect(tracker.shouldHoldHorizontalDrift(at: 0.03),
                "`.ended` was read as an ungrouped event and cleared the decision early")
    }

    // MARK: - Scoping the hold to the gesture's own pane
    //
    // One app-wide monitor feeds one tracker, but up to three column stacks consult it (both
    // comparison panes and the single-source rail). Unscoped, a vertical flick in pane A, its
    // momentum keeping `lastEventAt` fresh, would make pane B's watchdog revert B's own
    // programmatic reveal and hide its deepest column. The scoped query answers per asking view.

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
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                       window: window, locationInWindow: inA, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12,
                       window: window, locationInWindow: inA, at: 0.01)
        #expect(tracker.shouldHoldHorizontalDrift(for: paneA, at: 0.02),
                "the gesture's own pane was not held — the original leak is back")
        #expect(!tracker.shouldHoldHorizontalDrift(for: paneB, at: 0.02),
                "a gesture in pane A held pane B — its programmatic reveal will be reverted")
    }

    /// Momentum events carry the gesture's window but the pointer's current location, which can
    /// wander over the other pane while the flick coasts. The hold must stay with the pane the drag
    /// happened in; migrating would unguard the leaking pane and hold an innocent one.
    @Test func testMomentumCannotMigrateTheHoldToThePaneThePointerWandersOver() {
        let (window, paneA, paneB) = twoPanes()
        defer { _ = window }
        let tracker = WheelGestureTracker()
        let inA = paneA.convert(NSPoint(x: 40, y: 40), to: nil)
        let inB = paneB.convert(NSPoint(x: 40, y: 40), to: nil)
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                       window: window, locationInWindow: inA, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 0, dy: -12,
                       window: window, locationInWindow: inA, at: 0.01)
        tracker.ingest(phase: .ended, momentumPhase: [], dx: 0, dy: 0,
                       window: window, locationInWindow: inA, at: 0.02)
        tracker.ingest(phase: [], momentumPhase: .changed, dx: 0, dy: -4,
                       window: window, locationInWindow: inB, at: 0.05)
        #expect(tracker.shouldHoldHorizontalDrift(for: paneA, at: 0.06),
                "momentum's wandering pointer unguarded the pane the gesture was made in")
        #expect(!tracker.shouldHoldHorizontalDrift(for: paneB, at: 0.06),
                "momentum's wandering pointer migrated the hold onto a pane the gesture never touched")
    }

    /// A gesture the monitor can't attribute (no window on the event, or a test driving `ingest`
    /// without one) holds everywhere, so the same-pane leak stays fixed even when scoping has
    /// nothing to go on.
    @Test func testAnUnattributableGestureHoldsEverywhere() {
        let (window, paneA, paneB) = twoPanes()
        defer { _ = window }
        let tracker = WheelGestureTracker()
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12, at: 0.01)
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
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                       window: window, locationInWindow: inA, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: -18, dy: 2,
                       window: window, locationInWindow: inA, at: 0.01)
        #expect(!tracker.shouldHoldHorizontalDrift(for: paneA, at: 0.02),
                "a horizontal gesture was held against its own pane")
    }

    /// Attribution is frozen at the gesture's start, and the pointer moving mid-drag must not move
    /// it: the case excluding momentum alone doesn't cover.
    ///
    /// AppKit routes a phased gesture to the view it began over however far the pointer travels,
    /// and on a Magic Mouse the pointer travels, since the hand that swipes moves the device.
    /// Re-attributing on every `.changed` would hand the hold to whichever pane the pointer
    /// reached, unguarding the leaking pane and holding an innocent one against its own
    /// programmatic reveal.
    @Test func testPointerDriftDuringTheDragCannotMigrateTheHold() {
        let (window, paneA, paneB) = twoPanes()
        defer { _ = window }
        let tracker = WheelGestureTracker()
        let inA = paneA.convert(NSPoint(x: 40, y: 40), to: nil)
        let inB = paneB.convert(NSPoint(x: 40, y: 40), to: nil)
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                       window: window, locationInWindow: inA, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 0, dy: -6,
                       window: window, locationInWindow: inA, at: 0.01)
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
    /// Otherwise one drag in pane A would own the hold for the rest of the session.
    @Test func testANewGestureAttributesToWhereItStarts() {
        let (window, paneA, paneB) = twoPanes()
        defer { _ = window }
        let tracker = WheelGestureTracker()
        let inA = paneA.convert(NSPoint(x: 40, y: 40), to: nil)
        let inB = paneB.convert(NSPoint(x: 40, y: 40), to: nil)
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                       window: window, locationInWindow: inA, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12,
                       window: window, locationInWindow: inA, at: 0.01)
        // A fresh gesture, begun in the other pane.
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                       window: window, locationInWindow: inB, at: 0.02)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12,
                       window: window, locationInWindow: inB, at: 0.03)
        #expect(tracker.shouldHoldHorizontalDrift(for: paneB, at: 0.04),
                "the new gesture's own pane was not held — the first gesture latched the attribution")
        #expect(!tracker.shouldHoldHorizontalDrift(for: paneA, at: 0.04),
                "the previous gesture's pane is still held — attribution latched instead of re-arming")
    }

    /// Two panes in two separate windows, at the same in-window location. Location containment
    /// alone can't tell them apart, so this is the only shape in which the window check does any
    /// work; every other scoped test builds both panes in one window.
    @Test func testAGestureIsScopedToItsOwnWindow() {
        let (windowA, paneA, _) = twoPanes()
        let (windowB, paneB, _) = twoPanes()
        defer { _ = (windowA, windowB) }
        let tracker = WheelGestureTracker()
        let point = paneA.convert(NSPoint(x: 40, y: 40), to: nil)
        #expect(paneB.bounds.contains(paneB.convert(point, from: nil)),
                "the two panes are not at the same in-window point — location alone would discriminate")
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                       window: windowA, locationInWindow: point, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12,
                       window: windowA, locationInWindow: point, at: 0.01)
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
            // The band is reserved by AppKit, not by hand: a clip frame set here is undone by the
            // scroll view's own tiling, and a legacy always-visible scroller is the configuration
            // ("Show scroll bars: Always") this is about.
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

    /// The fail-closed counterpart of the unattributable fail-open above: a gesture with the
    /// pointer over the stack's own horizontal scroller is outside the clip's bounds, so
    /// clip-scoped containment would hold nothing for that band and let the vertical leak through.
    /// Containment is the enclosing scroll view, which is what receives the deltas a column's list
    /// forwards up.
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
        tracker.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                       window: window, locationInWindow: onScroller, at: 0)
        tracker.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12,
                       window: window, locationInWindow: onScroller, at: 0.01)
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

        // A vertical drag is delivering events now, dated ahead of the wall clock so the lock reads
        // "in flight" for the whole test however late enforcement lands. The revert is a runloop
        // hop away by design (reverting synchronously inside the bounds notification recurses until
        // the stack guard kills the app), and under load that hop can land past the lock's real
        // 100ms recency window, where enforcement no-ops. Recency decay is
        // `WheelGestureTrackerTests`' subject; this one's is the plumbing: notification → coalesced
        // hop → revert to the held rest.
        //
        // Attributed to this stack on purpose: `ingest` with no window takes the unattributed
        // fallback, and the scoped path (window match, scroll-view containment) would go untested
        // from the enforcement side.
        beginVerticalDragAhead(lock, window: window,
                               at: clip.convert(NSPoint(x: 20, y: 20), to: nil))

        // One leaked horizontal delta strands the stack sideways.
        clip.setBoundsOrigin(NSPoint(x: 9, y: 0))
        try #require(clip.bounds.origin.x == 9, "fixture failed to strand the clip")

        // Only the hold's enforcement can put the origin back to 0: 9 is inside the legal range, so
        // the quiescence return never touches it. The deadline only bounds a failing run, since a
        // pass exits on the observable, and the enforcement hop can drain many seconds in under
        // load. The pass floor is what makes the deadline mean something: under starvation the
        // seconds can run out before the first sleep returns.
        let held = await LayoutPumpWait.poll(upTo: 60) { clip.bounds.origin.x == 0 }
        #expect(held.held,
                "a vertical gesture's leaked delta moved the stack and the hold never reverted it, after \(held.passes) passes")
    }

    /// Something keeps re-scrolling the stack against the hold, as an animated SwiftUI scroll can
    /// mid-gesture, and the enforcement must stay bounded, one revert per runloop turn at most,
    /// instead of recursing inside the notification until the stack guard kills the app.
    @Test func testAFightingScrollCannotRecurseTheHold() async throws {
        let clip = FightingClipView()
        let (window, _, watchdog, lock) = mount(clip: clip)
        defer { _ = window }
        await idle(seconds: 0.3)
        try #require(watchdog.resolvedScroller != nil, "watchdog failed to arm")

        // Vertical gesture in flight; the clip refuses to land on the held position (every revert
        // to 0 comes back half a point off, forever). Dated ahead of the wall clock like the test
        // above, so the "engaged and fought" bound can't starve. Attributed to this stack for the
        // same reason: the only regression net for the recursion crash must run through the scoped
        // path the app takes.
        beginVerticalDragAhead(lock, window: window,
                               at: clip.convert(NSPoint(x: 20, y: 20), to: nil))
        // Counted from here: mounting alone racks up setBoundsOrigin calls, and a lower bound that
        // included them would hold even with enforceHold's revert deleted.
        let mountSets = clip.setCount
        clip.fightsBack = true
        clip.setBoundsOrigin(NSPoint(x: 9, y: 0))

        // Keep the runloop turning for a while; an in-notification revert would recurse thousands
        // of frames deep inside the first setBoundsOrigin call.
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        // Reaching this line at all is most of the assertion. The set count pins boundedness: ~50
        // runloop turns elapse, so per-turn enforcement stays in that order, while recursion would
        // pile up thousands before the first turn ended.
        let fightSets = clip.setCount - mountSets
        #expect(fightSets < 500,
                "the hold fought a moving scroll \(fightSets) times — per-turn bounding is gone")
        // More than the strand's own set: the hold really did engage and fight, once per turn.
        #expect(fightSets > 1, "the fixture never engaged the hold at all — nothing was pinned")
    }

    /// At the enforcement level: two stacks share the app's one lock, a vertical gesture is located
    /// in pane A, and both clips drift horizontally. A's drift is the gesture's leak and must be
    /// reverted; B's is B's own (its programmatic reveal, in the app) and must stay where B put it.
    /// A's revert landing proves the enforcement ran, so B's untouched origin is not a vacuous
    /// absence.
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

        // A vertical drag in pane A, dated ahead of the wall clock so the lock reads "in flight"
        // however late enforcement lands (as in the tests above).
        beginVerticalDragAhead(lock, window: window,
                               at: paneA.clip.convert(NSPoint(x: 20, y: 20), to: nil))

        // Pane B scrolls itself (the programmatic reveal's stand-in) and pane A drifts from the
        // gesture's leaked deltas. Both land on legal origins, so the quiescence return never moves
        // either; only the hold's enforcement can.
        paneB.clip.setBoundsOrigin(NSPoint(x: 9, y: 0))
        paneA.clip.setBoundsOrigin(NSPoint(x: 9, y: 0))
        try #require(paneA.clip.bounds.origin.x == 9, "fixture failed to strand pane A")
        try #require(paneB.clip.bounds.origin.x == 9, "fixture failed to scroll pane B")

        // Floored for the same reason as its sibling above, and the assertion after it depends on
        // this one having actually waited.
        let heldA = await LayoutPumpWait.poll(upTo: 60) { paneA.clip.bounds.origin.x == 0 }
        #expect(heldA.held,
                "the gesture's own pane was never held — the original leak is back, after \(heldA.passes) passes")
        #expect(paneB.clip.bounds.origin.x == 9,
                "a vertical gesture in pane A reverted pane B's own scroll — B's reveal is defeated again")
    }

    /// The question the pane's reveal asks before it scrolls, `PaneColumnHoldGate.isStackHeld`,
    /// must be the scoped one, per stack, like the revert it exists to avoid.
    ///
    /// Nothing else catches an unscoped version: the mounted reveal test proves the gate defers a
    /// reveal in the gesture's own pane, and would pass if the gate asked the app-wide query. Then
    /// a flick in one pane would stall the other pane's reveal for the whole momentum tail, the
    /// coupling `shouldHoldHorizontalDrift(for:)` exists to remove.
    ///
    /// Pane A answering true keeps pane B's false from being a vacuous absence.
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

        // A vertical drag in pane A, dated ahead of the wall clock so the hold can't lapse mid-test
        // (as in the enforcement tests above).
        beginVerticalDragAhead(lock, window: window,
                               at: paneA.clip.convert(NSPoint(x: 20, y: 20), to: nil))

        #expect(paneA.gate!.isStackHeld,
                "the gesture's own pane did not report held — its reveal will be issued into the hold and reverted")
        #expect(!paneB.gate!.isStackHeld,
                "a gesture in pane A held pane B's gate — B's reveal is stalled by a flick it has nothing to do with")
    }

    /// A gate with no watchdog, or one whose watchdog hasn't resolved a scroll view yet, must read
    /// as not held. There is nothing to revert in that state, so a reveal loses nothing by going
    /// ahead, and a gate that failed closed would defer every reveal made before the ancestor walk
    /// lands.
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

    /// A pane parks at most one deferred reveal, and can drop it.
    ///
    /// Four drivers schedule a reveal (`browsePath`, the preview's rising edge, and each of the two
    /// stored widths growing), and the column width is `@AppStorage`, so its driver fires in both
    /// panes. Each reveal issues two attempts, and every attempt that finds the stack held
    /// re-checks on its own timer, so unparked chains would multiply under one hold. Each chain
    /// strongly retains the pane's captures and the `ScrollViewProxy` for its whole budget, whether
    /// or not the pane still exists, and an `asyncAfter` block can't be cancelled, so the
    /// cancellable lives on the gate.
    ///
    /// Measured as deallocation, not a chain count, because retention is the claim: a count would
    /// pass with the blocks kept alive somewhere else.
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

    /// A reveal that has been superseded can't park, and can't evict the reveal that superseded it.
    ///
    /// A reveal also leaves two attempts behind (a `DispatchQueue.main.async` and an
    /// `.asyncAfter(+revealRetryDelay)`), neither cancellable nor tied to view lifetime. A second
    /// reveal within 0.25s of a first is routine (`browsePath` then `showsPreview`; the
    /// `@AppStorage` column width firing in both panes), and without this check the first reveal's
    /// retry would fire afterwards and replace the newer chain with its own, at a reset budget and
    /// aimed at the stale `treeRoot` it was scheduled with.
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

    /// A teardown cancel is final, not merely current.
    ///
    /// `.onDisappear` empties the box, but an attempt queued within `revealRetryDelay` of the
    /// teardown still runs, and must not park a fresh chain on the gate after the cancel. A
    /// torn-down watchdog resolves no scroller, so the gate would read not-held anyway, but the
    /// bound must come from the cancel, not from the fail-open path.
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

/// Lets the main actor turn for `seconds` without laying anything out.
@MainActor private func idle(seconds: Double) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 8_000_000)
    }
}

/// Waits for the watchdog to move the clip, with a floor on passes rather than on seconds. The
/// pull home arrives on a main-actor turn, and a congested run has fewer turns per second, so a
/// deadline in seconds alone can expire however generous it looks. `LayoutPumpWait.pumpFloor`
/// passes are guaranteed however little of the deadline is left.
///
/// Returns the pass count with the verdict so the caller can report it: a wait that gave up
/// after a handful of passes was starved and says nothing about the code; one that gave up
/// after hundreds disproved the condition.
///
/// `poll`, not `pump`: nothing here waits on a layout pass, and pumping would disarm the
/// runaway-layout guards. See `LayoutPumpWait.poll`.
@MainActor private func waitForOrigin(_ clip: NSClipView, toBecome expected: NSPoint,
                                      timeout: Double = 15) async -> (held: Bool, passes: Int) {
    await LayoutPumpWait.poll(upTo: timeout) { clip.bounds.origin == expected }
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
    let ahead = CFAbsoluteTimeGetCurrent() + 3600
    lock.ingest(phase: .began, momentumPhase: [], dx: 0, dy: 0,
                window: window, locationInWindow: location, at: ahead)
    lock.ingest(phase: .changed, momentumPhase: [], dx: 1, dy: -12,
                window: window, locationInWindow: location, at: ahead + 0.01)
}
