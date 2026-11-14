import CoreFoundation
import Testing
@testable import FileExplorer

/// Pins `MainThreadHitchMonitor`'s timing rule: time is counted only between waking and going back
/// to sleep. A held button with nothing happening is the run loop asleep, so it can't be counted; a
/// clock stamped from an input event (mouse-down, a gesture's end) would measure the user's finger
/// instead of the app.
///
/// The rule is driven directly with an injected clock: no run loop, no events, nothing to race.
@MainActor
@Suite struct MainThreadHitchMonitorTests {

    private func fresh() { MainThreadHitchMonitor.reset() }

    // MARK: The property both predecessors lacked

    /// A long wait, such as a button held down or a user reading the screen, must contribute
    /// nothing, however long it lasts.
    @Test("Time spent asleep is never counted, however long the wait")
    func sleepIsNotWork() {
        fresh()
        MainThreadHitchMonitor.note(.afterWaiting, at: 100.000)
        let hitch = MainThreadHitchMonitor.note(.beforeWaiting, at: 100.001)
        #expect(hitch == nil)
        // Five seconds asleep: nothing here is a turn.
        let duringSleep = MainThreadHitchMonitor.note(.beforeWaiting, at: 105.000)
        #expect(duringSleep == nil)
        #expect(MainThreadHitchMonitor.hitchCount == 0)
        #expect(MainThreadHitchMonitor.worst == 0)
    }

    /// The converse: a busy turn is counted. Without this, a monitor that reported nothing at all
    /// would pass `sleepIsNotWork`.
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
        // The third turn is set relative to `threshold`, so retuning it can't make this a
        // four-hitch expectation.
        let short = MainThreadHitchMonitor.threshold / 2
        for (start, end) in [(500.0, 500.2), (501.0, 501.9), (502.0, 502.0 + short), (503.0, 503.3)] {
            MainThreadHitchMonitor.note(.afterWaiting, at: start)
            MainThreadHitchMonitor.note(.beforeWaiting, at: end)
        }
        #expect(MainThreadHitchMonitor.hitchCount == 3)
        #expect(abs(MainThreadHitchMonitor.worst - 0.9) < 0.001)
        #expect(abs(MainThreadHitchMonitor.totalHitchTime - 1.4) < 0.001)
    }

    /// `.exit` ends a turn too: a nested tracking loop (what `.commonModes` is registered for)
    /// exits without a `beforeWaiting`, and dropping that turn would hide the work done inside it.
    @Test("Exiting a nested run loop closes the turn as well")
    func exitClosesTheTurn() {
        fresh()
        MainThreadHitchMonitor.note(.afterWaiting, at: 600.0)
        let hitch = MainThreadHitchMonitor.note(.exit, at: 600.4)
        #expect(hitch != nil)
        #expect(MainThreadHitchMonitor.hitchCount == 1)
    }

    /// A second `beforeWaiting` with no wake between must not re-report the same turn: the run loop
    /// calls observers per mode, so duplicates are ordinary.
    @Test("A turn is reported once, not once per observer callback")
    func turnIsReportedOnce() {
        fresh()
        MainThreadHitchMonitor.note(.afterWaiting, at: 700.0)
        MainThreadHitchMonitor.note(.beforeWaiting, at: 700.5)
        let second = MainThreadHitchMonitor.note(.beforeWaiting, at: 700.9)
        #expect(second == nil)
        #expect(MainThreadHitchMonitor.hitchCount == 1)
    }

    // MARK: The end of the turn

    /// The turn ends at the last end-of-turn observer. Core Animation commits at order 2,000,000,
    /// after an order-0 observer has seen `beforeWaiting`, and the layout and drawing in that
    /// commit are the turn's work too. Here the order-0 edge comes 5 ms in and the commit runs to
    /// 400 ms; closed at the early edge, the turn would be a 5 ms non-event.
    @Test("Layout and drawing after the order-0 observer count as the turn's work")
    func theCommitCountsAsWork() {
        fresh()
        MainThreadHitchMonitor.note(.afterWaiting, at: 800.000)
        let early = MainThreadHitchMonitor.note(.beforeWaiting, edge: .early, at: 800.005)
        #expect(early == nil)
        let hitch = MainThreadHitchMonitor.note(.beforeWaiting, edge: .late, at: 800.400)
        #expect(abs((hitch ?? 0) - 0.4) < 0.001)
        #expect(MainThreadHitchMonitor.hitchCount == 1)
    }

    /// The early edge alone closes nothing, and a later turn is timed from its own wake.
    @Test("The order-0 edge marks the turn without closing it")
    func theEarlyEdgeClosesNothing() {
        fresh()
        MainThreadHitchMonitor.note(.afterWaiting, at: 900.0)
        MainThreadHitchMonitor.note(.exit, edge: .early, at: 900.5)
        #expect(MainThreadHitchMonitor.hitchCount == 0)
        let hitch = MainThreadHitchMonitor.note(.exit, edge: .late, at: 900.6)
        #expect(abs((hitch ?? 0) - 0.6) < 0.001)
    }

    /// Both spans, the CPU time and the app's state, in one line. The CPU figure tells a starved
    /// main thread (CPU well under the span) from a working one.
    @Test("A hitch line gives both spans, CPU time and the app's state")
    func theHitchLineSaysEverything() {
        let line = MainThreadHitchMonitor.hitchLine(elapsed: 0.8123, ownWork: 0.1204, cpu: 0.05,
                                                    context: "app inactive, every window occluded")
        #expect(line == "[hitch] main thread busy 812.3ms (120.4ms before the end-of-turn observers), "
                + "CPU 50.0ms, app inactive, every window occluded")
        #expect(MainThreadHitchMonitor.hitchLine(elapsed: 0.02, ownWork: nil, cpu: nil, context: "x")
                == "[hitch] main thread busy 20.0ms, x")
    }

    /// The CPU span is the main thread's own between wake and close, from the injected readings.
    @Test("The turn's CPU time is read at wake and at close")
    func theCPUSpanIsTheTurns() {
        fresh()
        MainThreadHitchMonitor.note(.afterWaiting, at: 1000.0, cpu: 7.0)
        MainThreadHitchMonitor.note(.beforeWaiting, edge: .early, at: 1000.1, cpu: 7.05)
        let hitch = MainThreadHitchMonitor.note(.beforeWaiting, edge: .late, at: 1000.3, cpu: 7.25)
        #expect(hitch != nil)
        #expect(MainThreadHitchMonitor.lastLineForTesting
                == "[hitch] main thread busy 300.0ms (100.0ms before the end-of-turn observers), CPU 250.0ms, "
                + MainThreadHitchMonitor.appContext())
    }

    // MARK: The clock

    /// Monotonic, so a system clock adjustment mid-measurement can't produce a negative or absurd
    /// hitch. Asserted because the shim is hand-rolled to keep QuartzCore out of this module.
    @Test("The clock advances monotonically")
    func clockIsMonotonic() {
        let a = CACurrentMediaTimeShim()
        let b = CACurrentMediaTimeShim()
        #expect(b >= a)
        #expect(a > 0)
    }
}
