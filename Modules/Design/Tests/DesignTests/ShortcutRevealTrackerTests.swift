import AppKit
import Testing
@testable import Design

/// The driver: events in, one published `Bool` out.
///
/// `ShortcutRevealMachineTests` proves the hold rule itself; nothing proved that the tracker
/// wires it to anything. Everything between them — scheduling the deadline, cancelling a stale
/// one, writing `isActive`, resign-active — had no coverage at all, and a break anywhere in it
/// means the badges simply never appear while every machine test stays green.
///
/// Driven through the `note…` seam rather than real `NSEvent`s: a `swift test` process has no app
/// event loop to post events into, and `addLocalMonitorForEvents` only ever fires from one.
@MainActor
@Suite(.serialized) struct ShortcutRevealTrackerTests {

    /// A clock the test moves by hand. The tracker's real timer still runs — only its *reading*
    /// of the time is under test control, which is what lets the deadline be reached deliberately
    /// instead of by sleeping for the real hold.
    @MainActor
    private final class TestClock {
        var now = Date(timeIntervalSinceReferenceDate: 780_000_000)
        func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
    }

    private func makeTracker() -> (ShortcutRevealTracker, TestClock) {
        let clock = TestClock()
        return (ShortcutRevealTracker(now: { clock.now }), clock)
    }

    /// Bounded, and it FAILS on expiry naming the call site — an unbounded spin here would turn a
    /// regression into a hung suite.
    private func waitUntil(_ what: Comment,
                           timeout: TimeInterval = 5,
                           sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(condition(), what, sourceLocation: sourceLocation)
    }

    /// End to end: ⌥ alone, the deadline arrives, the published flag flips.
    @Test func holdingOptionAlonePublishesTheReveal() async {
        let (tracker, clock) = makeTracker()
        #expect(!tracker.isActive)

        tracker.noteModifiersChanged(to: .option)
        #expect(!tracker.isActive, "revealed before the hold elapsed")

        clock.advance(by: ShortcutRevealMachine.holdDuration)
        await waitUntil("the tracker publishes the reveal") { tracker.isActive }
    }

    /// The timer must not fire on a hold that was already cancelled — the case a machine-only
    /// test cannot reach, because it is the *scheduling* that has to be torn down.
    @Test func releasingOptionBeforeTheDeadlineNeverPublishes() async {
        let (tracker, clock) = makeTracker()
        tracker.noteModifiersChanged(to: .option)
        tracker.noteModifiersChanged(to: [])

        clock.advance(by: ShortcutRevealMachine.holdDuration * 3)
        // Long enough that an unscheduled-but-still-pending timer would have fired by now.
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(!tracker.isActive, "a cancelled hold still published a reveal")
    }

    @Test func aKeyDownDuringTheHoldNeverPublishes() async {
        let (tracker, clock) = makeTracker()
        tracker.noteModifiersChanged(to: .option)
        tracker.noteKeyDown()

        clock.advance(by: ShortcutRevealMachine.holdDuration * 3)
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(!tracker.isActive, "⌥-typing published a reveal")
    }

    @Test func aMouseDownDuringTheHoldNeverPublishes() async {
        let (tracker, clock) = makeTracker()
        tracker.noteModifiersChanged(to: .option)
        tracker.noteMouseDown()

        clock.advance(by: ShortcutRevealMachine.holdDuration * 3)
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(!tracker.isActive, "⌥-click published a reveal")
    }

    /// Releasing ⌥ takes the badges down again — the other half of the published flag, and the
    /// one a user notices immediately if it breaks.
    @Test func releasingOptionAfterTheRevealPublishesFalse() async {
        let (tracker, clock) = makeTracker()
        tracker.noteModifiersChanged(to: .option)
        clock.advance(by: ShortcutRevealMachine.holdDuration)
        await waitUntil("revealed") { tracker.isActive }

        tracker.noteModifiersChanged(to: [])
        #expect(!tracker.isActive, "the badges stayed up after ⌥ came back up")
    }

    /// ⌥⇥ away mid-look. A *local* monitor never sees the ⌥-up that lands in the other app, so
    /// without this the badges would stay lit over a window that is no longer frontmost.
    @Test func resigningActiveTakesTheRevealDown() async {
        let (tracker, clock) = makeTracker()
        tracker.noteModifiersChanged(to: .option)
        clock.advance(by: ShortcutRevealMachine.holdDuration)
        await waitUntil("revealed") { tracker.isActive }

        tracker.noteResignedActive()
        #expect(!tracker.isActive, "the reveal survived the app resigning active")
    }

    /// A held ⌥ produces a *stream* of `flagsChanged`, and each one reschedules. Each reschedule
    /// must wait only the time REMAINING to the original deadline; if it restarted the full hold
    /// the reveal would be pushed permanently out of reach on a real keyboard.
    ///
    /// Asserted on the scheduled interval, not on `isActive`. The first version of this test
    /// advanced the clock past the deadline and waited for `isActive`, and a mutation that
    /// restarted the clock on every event passed it — the reveal still arrives eventually, just
    /// late, and "eventually" is all `waitUntil` can see. The interval is the only place the bug
    /// is visible.
    @Test func aRepeatOptionEventShortensTheWaitRatherThanRestartingIt() async throws {
        let hold = ShortcutRevealMachine.holdDuration
        let (tracker, clock) = makeTracker()

        tracker.noteModifiersChanged(to: .option)
        // Tolerance, not equality: the interval is a difference of two `Date`s, and a `Date` holds
        // its value as seconds-since-reference in a Double, so `(t0 + 0.2) - t0` comes back as
        // 0.20000004768371582 rather than 0.2. The distinction this test draws — half a hold
        // versus a whole one — is four orders of magnitude wider than that.
        let first = try #require(tracker.lastScheduledInterval)
        #expect(abs(first - hold) < 0.0001, "the first arm scheduled \(first)s, not \(hold)s")

        // Half-way through the hold, another ⌥-alone event.
        clock.advance(by: hold / 2)
        tracker.noteModifiersChanged(to: .option)
        let scheduled = try #require(tracker.lastScheduledInterval)
        #expect(abs(scheduled - hold / 2) < 0.0001,
                "a repeat event rescheduled \(scheduled)s instead of the \(hold / 2)s remaining")

        // ...and it still actually arrives.
        clock.advance(by: hold / 2)
        await waitUntil("the reveal lands on the original deadline") { tracker.isActive }
    }

    /// Nothing armed, nothing scheduled — the timer is torn down rather than left to fire into a
    /// machine that will ignore it.
    @Test func nothingIsScheduledWhileNoHoldIsArmed() {
        let (tracker, _) = makeTracker()
        #expect(tracker.lastScheduledInterval == nil)

        tracker.noteModifiersChanged(to: .option)
        #expect(tracker.lastScheduledInterval != nil)

        tracker.noteModifiersChanged(to: [])
        #expect(tracker.lastScheduledInterval == nil, "a timer stayed scheduled after ⌥ came up")
    }
}
