import Testing
import AppKit
@testable import FileExplorer

/// The display-cycle instrument's own rules.
///
/// The trace exists because "did the app survive" is too low-powered to evaluate a fix with (see
/// `docs/columns-layout-loop.md`), so what it reports has to be right: a cycle below the floor is
/// silence, a cycle at or above it is a line, and the hook it swizzles has to actually exist.
@MainActor
@Suite(.serialized) struct DisplayCycleTraceTests {

    /// AppKit calls `updateConstraintsIfNeeded` once per pass and it is PUBLIC API — that is the
    /// whole reason this instrument needs no private selector. If a future macOS removes it,
    /// `arm()` logs and declines rather than exchanging a nil method, but this test is what says so
    /// out loud rather than leaving a silently-dead trace.
    @Test func testTheSwizzledHookAndItsTargetBothExist() {
        #expect(class_getInstanceMethod(NSWindow.self,
                                        #selector(NSWindow.updateConstraintsIfNeeded)) != nil,
                "AppKit's updateConstraintsIfNeeded is gone — the instrument has no seam")
        #expect(class_getInstanceMethod(
            NSWindow.self,
            #selector(NSWindow.syncCloud_tracedUpdateConstraintsIfNeeded)) != nil,
                "the traced half is missing — arm() would exchange nothing")
    }

    /// A busy-but-correct cycle must stay silent. The floor is calibrated against a measured healthy
    /// republish (7 passes), so a cycle at 7 is exactly the case that must not produce a line — the
    /// log is trimmed from the tail, and a trace that reports normal work evicts the evidence.
    @Test func testACycleBelowTheFloorReportsNothing() {
        DisplayCycleTrace.resetForTesting()
        for _ in 0..<(DisplayCycleTrace.floor - 1) { DisplayCycleTrace.notePass(window: 7) }
        #expect(DisplayCycleTrace.endCycle().isEmpty)
        #expect(DisplayCycleTrace.worstSoFar(window: 7) == 0,
                "a cycle that was never reported must not move the high-water mark")
    }

    @Test func testACycleAtTheFloorIsReportedAndRemembered() {
        DisplayCycleTrace.resetForTesting()
        for _ in 0..<DisplayCycleTrace.floor { DisplayCycleTrace.notePass(window: 7) }
        let reported = DisplayCycleTrace.endCycle()
        #expect(reported.count == 1)
        #expect(reported.first?.passes == DisplayCycleTrace.floor)
        #expect(DisplayCycleTrace.worstSoFar(window: 7) == DisplayCycleTrace.floor)
    }

    /// The count is PER WINDOW, because AppKit's budget is: a Settings sheet churning and the main
    /// window churning are different findings, and a total would hide which one is which.
    @Test func testWindowsAreCountedSeparatelyAndTheWorstLeads() {
        DisplayCycleTrace.resetForTesting()
        for _ in 0..<DisplayCycleTrace.floor { DisplayCycleTrace.notePass(window: 1) }
        for _ in 0..<(DisplayCycleTrace.floor * 3) { DisplayCycleTrace.notePass(window: 2) }
        let reported = DisplayCycleTrace.endCycle()
        #expect(reported.map(\.window) == [2, 1], "reported \(reported)")
        #expect(DisplayCycleTrace.worstSoFar(window: 2) == DisplayCycleTrace.floor * 3)
        #expect(DisplayCycleTrace.worstSoFar(window: 1) == DisplayCycleTrace.floor)
    }

    /// Ending a cycle must start the next one empty, or one storm would be re-reported on every
    /// subsequent turn for the rest of the session.
    @Test func testEndingACycleClearsIt() {
        DisplayCycleTrace.resetForTesting()
        for _ in 0..<(DisplayCycleTrace.floor * 2) { DisplayCycleTrace.notePass(window: 3) }
        #expect(DisplayCycleTrace.endCycle().count == 1)
        #expect(DisplayCycleTrace.endCycle().isEmpty, "the storm was re-reported on the next cycle")
    }

    /// The high-water mark keeps the WORST, not the latest — a diagnostic session is read after the
    /// fact, and a quieter cycle following a storm must not erase it.
    @Test func testTheHighWaterMarkKeepsTheWorst() {
        DisplayCycleTrace.resetForTesting()
        for _ in 0..<(DisplayCycleTrace.floor * 4) { DisplayCycleTrace.notePass(window: 5) }
        DisplayCycleTrace.endCycle()
        for _ in 0..<DisplayCycleTrace.floor { DisplayCycleTrace.notePass(window: 5) }
        DisplayCycleTrace.endCycle()
        #expect(DisplayCycleTrace.worstSoFar(window: 5) == DisplayCycleTrace.floor * 4)
    }

    /// **A busy MOUNT must stay silent, and that is why the floor alone is not enough.**
    ///
    /// Measured: mounting the Columns pane costs 14 passes in its first turn against 136 views —
    /// over the absolute floor, and perfectly healthy. AppKit's own budget is the view count, so the
    /// second gate is a fraction of that, and the mount is well under it.
    @Test func testABusyMountIsUnderTheBudgetFractionAndStaysSilent() {
        #expect(DisplayCycleTrace.worthReporting(passes: 14, views: 136) == false,
                "the measured healthy mount would be reported")
        // The same 14 passes in a small window IS most of that window's budget, and is a finding.
        #expect(DisplayCycleTrace.worthReporting(passes: 14, views: 40))
    }

    /// The floor still binds underneath the fraction: a tiny window doing tiny work is not news
    /// however large a share of its handful of views the passes are.
    @Test func testTheFloorBindsBeneathTheFraction() {
        #expect(DisplayCycleTrace.worthReporting(passes: DisplayCycleTrace.floor - 1, views: 2) == false)
    }

    /// A missing denominator reports on the floor alone. Being unable to size the budget is a reason
    /// to be noisy — the alternative is a runaway going unrecorded because its window had already
    /// gone away by flush time.
    @Test func testAnUnreadableViewCountFallsBackToTheFloor() {
        #expect(DisplayCycleTrace.worthReporting(passes: DisplayCycleTrace.floor, views: nil))
        #expect(DisplayCycleTrace.worthReporting(passes: DisplayCycleTrace.floor - 1, views: nil) == false)
    }

    /// **A quiet cycle must not cost a view-tree walk.**
    ///
    /// Reading the denominator means walking a window's whole view tree, and this decision runs for
    /// every window on every runloop turn while the trace is armed. Evaluated eagerly that is a
    /// recursive walk of the entire UI at runloop frequency, on the main thread — inside a
    /// diagnostic whose subject IS main-thread layout timing. An instrument that perturbs what it
    /// measures is worse than none, so the floor has to short-circuit before the walk.
    @Test func testAQuietCycleNeverReadsTheViewCount() {
        var reads = 0
        _ = DisplayCycleTrace.worthReporting(passes: 1, views: { reads += 1; return 300 }())
        #expect(reads == 0, "a quiet cycle walked the view tree \(reads) time(s)")

        // …and a candidate cycle does read it, or the second gate would not be applied at all.
        _ = DisplayCycleTrace.worthReporting(passes: DisplayCycleTrace.floor,
                                             views: { reads += 1; return 300 }())
        #expect(reads == 1)
    }

    /// **The swizzle really counts a real window's real passes.**
    ///
    /// Everything above pins the bookkeeping, which would go on passing if
    /// `method_exchangeImplementations` silently did nothing — and an instrument that never fires
    /// reports a healthy pane, which is the one failure mode this whole file exists to avoid. So
    /// this arms the actual hook and drives an actual window through an actual constraint pass.
    ///
    /// Deliberately last in a `.serialized` suite, and deliberately honest about its cost: `arm()`
    /// installs a PROCESS-WIDE method exchange and a runloop observer that outlive this test. Both
    /// are harmless to everything after it — the hook only increments a counter, and the observer
    /// only writes a line for a cycle at or above the floor, which nothing else in the suite comes
    /// near — but it is a side effect, not a leak-free fixture, and it is the only way to prove the
    /// exchange landed.
    @Test func testArmingActuallyCountsARealWindowsPasses() {
        DisplayCycleTrace.isEnabled = true
        DisplayCycleTrace.arm()
        DisplayCycleTrace.resetForTesting()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let box = NSView(frame: .zero)
        box.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            box.topAnchor.constraint(equalTo: content.topAnchor),
            box.widthAnchor.constraint(equalToConstant: 50),
            box.heightAnchor.constraint(equalToConstant: 50)
        ])
        window.contentView = content

        // Below the floor, so `endCycle` reports nothing — the count is read straight from the
        // bookkeeping instead. Dirtying and updating repeatedly is what produces the passes.
        for _ in 0..<4 {
            box.needsUpdateConstraints = true
            window.updateConstraintsIfNeeded()
        }
        // `endCycle` returns only what crossed the floor; drive it over to read the count back out.
        let counted = DisplayCycleTrace.endCycleCountForTesting(window: window.windowNumber)
        #expect(counted >= 4,
                "the exchange did not land — a real window's passes went uncounted (saw \(counted))")
    }

    /// A pass count means nothing on its own: AppKit raises when passes exceed the window's VIEW
    /// count, so the instrument has to be able to report that denominator.
    @Test func testViewCountWalksTheWholeContentTree() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentLayoutRect)
        let child = NSView(frame: .zero)
        child.addSubview(NSView(frame: .zero))
        root.addSubview(child)
        window.contentView = root
        // The content view AppKit installs may wrap ours, so assert the shape rather than a
        // literal: our three views are in there, and the walk is recursive rather than one level.
        let count = DisplayCycleTrace.viewCount(of: window)
        #expect((count ?? 0) >= 3, "walked \(String(describing: count)) views")
    }
}
