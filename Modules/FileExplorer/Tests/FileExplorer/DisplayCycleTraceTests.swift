import Testing
import AppKit
@testable import FileExplorer

/// The display-cycle instrument's own rules. "Did the app survive" is too weak to judge a layout
/// fix by (`docs/columns-layout-loop.md`), so the trace must be right: a cycle below the floor is
/// silent, one at or above it is a line, and the hook it swizzles must exist.
@MainActor
@Suite(.serialized) struct DisplayCycleTraceTests {

    /// AppKit calls `updateConstraintsIfNeeded`, public API, once per pass, so the instrument needs
    /// no private selector. If a macOS removes it, `arm()` declines quietly; this test says so.
    @Test func testTheSwizzledHookAndItsTargetBothExist() {
        #expect(class_getInstanceMethod(NSWindow.self,
                                        #selector(NSWindow.updateConstraintsIfNeeded)) != nil,
                "AppKit's updateConstraintsIfNeeded is gone — the instrument has no seam")
        #expect(class_getInstanceMethod(
            NSWindow.self,
            #selector(NSWindow.syncCloud_tracedUpdateConstraintsIfNeeded)) != nil,
                "the traced half is missing — arm() would exchange nothing")
    }

    /// A busy but healthy cycle stays silent. The floor sits above a measured healthy republish (7
    /// passes); the log is trimmed, so a trace that reports normal work evicts the evidence.
    @Test func testACycleBelowTheFloorReportsNothing() {
        DisplayCycleTrace.resetForTesting()
        for _ in 0..<(DisplayCycleTrace.floor - 1) { DisplayCycleTrace.notePass(window: 7) }
        #expect(DisplayCycleTrace.endCycle().isEmpty)
        #expect(DisplayCycleTrace.worstSoFar(window: 7) == 0,
                "a cycle that was never reported must not move the high-water mark")
    }

    /// The count is per window, as AppKit's budget is: a total would hide which window churned.
    @Test func testWindowsAreCountedSeparatelyAndTheWorstLeads() {
        DisplayCycleTrace.resetForTesting()
        for _ in 0..<DisplayCycleTrace.floor { DisplayCycleTrace.notePass(window: 1) }
        for _ in 0..<(DisplayCycleTrace.floor * 3) { DisplayCycleTrace.notePass(window: 2) }
        let reported = DisplayCycleTrace.endCycle()
        #expect(reported.map(\.window) == [2, 1], "reported \(reported)")
        #expect(DisplayCycleTrace.worstSoFar(window: 2) == DisplayCycleTrace.floor * 3)
        #expect(DisplayCycleTrace.worstSoFar(window: 1) == DisplayCycleTrace.floor)
    }

    /// Ending a cycle starts the next one empty, or one storm would be re-reported every turn.
    @Test func testEndingACycleClearsIt() {
        DisplayCycleTrace.resetForTesting()
        for _ in 0..<(DisplayCycleTrace.floor * 2) { DisplayCycleTrace.notePass(window: 3) }
        #expect(DisplayCycleTrace.endCycle().count == 1)
        #expect(DisplayCycleTrace.endCycle().isEmpty, "the storm was re-reported on the next cycle")
    }

    /// The high-water mark keeps the worst, not the latest: a diagnostic session is read after the
    /// fact, and a quieter cycle must not erase a storm.
    @Test func testTheHighWaterMarkKeepsTheWorst() {
        DisplayCycleTrace.resetForTesting()
        for _ in 0..<(DisplayCycleTrace.floor * 4) { DisplayCycleTrace.notePass(window: 5) }
        DisplayCycleTrace.endCycle()
        for _ in 0..<DisplayCycleTrace.floor { DisplayCycleTrace.notePass(window: 5) }
        DisplayCycleTrace.endCycle()
        #expect(DisplayCycleTrace.worstSoFar(window: 5) == DisplayCycleTrace.floor * 4)
    }

    /// A busy mount stays silent, which the floor alone can't do: mounting the Columns pane costs a
    /// healthy 14 passes against 136 views, over the floor. AppKit's budget is the view count, so
    /// the second gate is a fraction of it, and the mount is well under.
    @Test func testABusyMountIsUnderTheBudgetFractionAndStaysSilent() {
        #expect(DisplayCycleTrace.worthReporting(passes: 14, views: 136) == false,
                "the measured healthy mount would be reported")
        // The same 14 passes in a small window IS most of that window's budget, and is a finding.
        #expect(DisplayCycleTrace.worthReporting(passes: 14, views: 40))
    }

    /// The floor still binds beneath the fraction: a tiny window doing tiny work is not news.
    @Test func testTheFloorBindsBeneathTheFraction() {
        #expect(DisplayCycleTrace.worthReporting(passes: DisplayCycleTrace.floor - 1, views: 2) == false)
    }

    /// A missing denominator reports on the floor alone, so a runaway whose window is gone by flush
    /// time is still recorded.
    @Test func testAnUnreadableViewCountFallsBackToTheFloor() {
        #expect(DisplayCycleTrace.worthReporting(passes: DisplayCycleTrace.floor, views: nil))
        #expect(DisplayCycleTrace.worthReporting(passes: DisplayCycleTrace.floor - 1, views: nil) == false)
    }

    /// A quiet cycle must not cost a view-tree walk. The decision runs for every window on every
    /// runloop turn while armed, so reading the view count eagerly would walk the whole UI on the
    /// main thread, perturbing the layout timing it measures. The floor short-circuits first.
    @Test func testAQuietCycleNeverReadsTheViewCount() {
        var reads = 0
        _ = DisplayCycleTrace.worthReporting(passes: 1, views: { reads += 1; return 300 }())
        #expect(reads == 0, "a quiet cycle walked the view tree \(reads) time(s)")

        // A candidate cycle does read it, or the second gate would never apply.
        _ = DisplayCycleTrace.worthReporting(passes: DisplayCycleTrace.floor,
                                             views: { reads += 1; return 300 }())
        #expect(reads == 1)
    }

    /// The swizzle really counts a real window's passes. The bookkeeping tests above would pass if
    /// `method_exchangeImplementations` did nothing, and a trace that never fires reports a healthy
    /// pane, so this arms the real hook and drives a real constraint pass. `arm()` installs a
    /// process-wide method exchange and runloop observer that outlive this test; both are harmless
    /// (the hook only counts, the observer only writes at or above the floor).
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

        // Each dirty-and-update makes a pass; four stays below the floor.
        for _ in 0..<4 {
            box.needsUpdateConstraints = true
            window.updateConstraintsIfNeeded()
        }
        // `endCycle` returns only what crossed the floor, so read the raw count back instead.
        let counted = DisplayCycleTrace.endCycleCountForTesting(window: window.windowNumber)
        #expect(counted >= 4,
                "the exchange did not land — a real window's passes went uncounted (saw \(counted))")
    }

    /// A pass count means nothing alone: AppKit raises when passes exceed the window's view count,
    /// so the instrument must report that denominator.
    @Test func testViewCountWalksTheWholeContentTree() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentLayoutRect)
        let child = NSView(frame: .zero)
        child.addSubview(NSView(frame: .zero))
        root.addSubview(child)
        window.contentView = root
        // AppKit may wrap our content view, so assert a floor: all three of ours, found recursively.
        let count = DisplayCycleTrace.viewCount(of: window)
        #expect((count ?? 0) >= 3, "walked \(String(describing: count)) views")
    }
}
