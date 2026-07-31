import CoreFoundation
import Testing
@testable import FileExplorer

/// Pins `MainThreadHitchMonitor`'s timing rule — which is the only thing that makes it worth more
/// than the two metrics it replaces.
///
/// Both predecessors measured the user's finger while looking like they measured the app. `[click]`
/// stamped from mouse-down inside `NSTableView`'s tracking loop; `[render]` moved the stamp to the
/// tap gesture's `onEnded` and claimed to start "after the button is already up", and across twenty
/// real clicks the two agreed to within 0.2ms. Neither had a test, and neither could have had one
/// while its clock hung off an input event.
///
/// So the rule here is driven directly, with an injected clock — no run loop, no events, nothing to
/// race. The claim under test is precise: **time is counted only between waking and going back to
/// sleep.** A held button with nothing happening is the run loop asleep, so it cannot be counted,
/// and that is exactly the property the old metrics lacked.
@MainActor
@Suite struct MainThreadHitchMonitorTests {

    private func fresh() { MainThreadHitchMonitor.reset() }

    // MARK: The property both predecessors lacked

    /// **The regression test for the whole idea.** A long wait — a button held down, a user reading
    /// the screen — must contribute nothing, however long it lasts.
    @Test("Time spent asleep is never counted, however long the wait")
    func sleepIsNotWork() {
        fresh()
        // Wake, do 1ms of work, sleep.
        MainThreadHitchMonitor.note(.afterWaiting, at: 100.000)
        let hitch = MainThreadHitchMonitor.note(.beforeWaiting, at: 100.001)
        #expect(hitch == nil)
        // ...and stay asleep for five seconds. Nothing here is a turn.
        let duringSleep = MainThreadHitchMonitor.note(.beforeWaiting, at: 105.000)
        #expect(duringSleep == nil)
        #expect(MainThreadHitchMonitor.hitchCount == 0)
        #expect(MainThreadHitchMonitor.worst == 0)
    }

    /// The converse, and the mutation check for the test above: a genuinely busy turn IS counted.
    /// Without this, a monitor that reported nothing at all would pass `sleepIsNotWork`.
    @Test("A turn longer than the threshold is reported with its true duration")
    func busyTurnIsReported() {
        fresh()
        MainThreadHitchMonitor.note(.afterWaiting, at: 200.0)
        let hitch = MainThreadHitchMonitor.note(.beforeWaiting, at: 200.6)
        #expect(hitch != nil)
        #expect(abs((hitch ?? 0) - 0.6) < 0.001)
        #expect(MainThreadHitchMonitor.hitchCount == 1)
        #expect(abs(MainThreadHitchMonitor.worst - 0.6) < 0.001)
    }

    // MARK: The threshold

    @Test("A turn under the threshold is not reported")
    func shortTurnIsQuiet() {
        fresh()
        MainThreadHitchMonitor.note(.afterWaiting, at: 300.0)
        let hitch = MainThreadHitchMonitor.note(.beforeWaiting, at: 300.0 + MainThreadHitchMonitor.threshold - 0.001)
        #expect(hitch == nil)
        #expect(MainThreadHitchMonitor.hitchCount == 0)
    }

    @Test("A turn exactly at the threshold is reported")
    func thresholdIsInclusive() {
        fresh()
        MainThreadHitchMonitor.note(.afterWaiting, at: 400.0)
        let hitch = MainThreadHitchMonitor.note(.beforeWaiting, at: 400.0 + MainThreadHitchMonitor.threshold)
        #expect(hitch != nil)
    }

    // MARK: Bookkeeping across a session

    @Test("Worst and total accumulate across turns, and short turns don't pollute them")
    func accumulatesAcrossTurns() {
        fresh()
        // The third turn is deliberately under `threshold`; expressed relative to the constant so
        // that retuning the threshold cannot silently turn this into a four-hitch expectation.
        let short = MainThreadHitchMonitor.threshold / 2
        for (start, end) in [(500.0, 500.2), (501.0, 501.9), (502.0, 502.0 + short), (503.0, 503.3)] {
            MainThreadHitchMonitor.note(.afterWaiting, at: start)
            MainThreadHitchMonitor.note(.beforeWaiting, at: end)
        }
        // 0.2, 0.9 and 0.3 clear the threshold; the deliberately short one does not.
        #expect(MainThreadHitchMonitor.hitchCount == 3)
        #expect(abs(MainThreadHitchMonitor.worst - 0.9) < 0.001)
        #expect(abs(MainThreadHitchMonitor.totalHitchTime - 1.4) < 0.001)
    }

    /// `.exit` ends a turn too — a nested tracking loop (the very thing `.commonModes` is registered
    /// for) exits without a `beforeWaiting`, and dropping that turn would hide the work done inside
    /// the loop this monitor exists to see through.
    @Test("Exiting a nested run loop closes the turn as well")
    func exitClosesTheTurn() {
        fresh()
        MainThreadHitchMonitor.note(.afterWaiting, at: 600.0)
        let hitch = MainThreadHitchMonitor.note(.exit, at: 600.4)
        #expect(hitch != nil)
        #expect(MainThreadHitchMonitor.hitchCount == 1)
    }

    /// A second `beforeWaiting` with no intervening wake must not re-report the same turn — the run
    /// loop emits observers per mode, so duplicates are ordinary rather than exceptional.
    @Test("A turn is reported once, not once per observer callback")
    func turnIsReportedOnce() {
        fresh()
        MainThreadHitchMonitor.note(.afterWaiting, at: 700.0)
        MainThreadHitchMonitor.note(.beforeWaiting, at: 700.5)
        let second = MainThreadHitchMonitor.note(.beforeWaiting, at: 700.9)
        #expect(second == nil)
        #expect(MainThreadHitchMonitor.hitchCount == 1)
    }

    // MARK: The clock

    /// Monotonic, so a system clock adjustment mid-measurement cannot produce a negative or absurd
    /// hitch. Asserted rather than assumed because the shim is hand-rolled to avoid pulling
    /// QuartzCore into this module.
    @Test("The clock advances monotonically")
    func clockIsMonotonic() {
        let a = CACurrentMediaTimeShim()
        let b = CACurrentMediaTimeShim()
        #expect(b >= a)
        #expect(a > 0)
    }
}
