import AppKit
import Testing
@testable import Design

/// The driver: events in, one published `Bool` out.
///
/// `ShortcutRevealMachineTests` proves the hold rule; this proves the tracker wires it up:
/// scheduling the deadline, cancelling a stale one, writing `isActive`, resign-active. A break
/// there means the badges never appear while every machine test stays green.
///
/// Driven through the `note…` seam rather than real `NSEvent`s: a `swift test` process has no app
/// event loop to post events into, and `addLocalMonitorForEvents` only ever fires from one.
@MainActor
@Suite(.serialized) struct ShortcutRevealTrackerTests {

    /// A clock the test moves by hand. The tracker's real timer still runs; only its reading of the
    /// time is controlled, so the deadline is reached deliberately instead of by sleeping the hold.
    @MainActor
    private final class TestClock {
        var now = Date(timeIntervalSinceReferenceDate: 780_000_000)
        func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
    }

    private func makeTracker() -> (ShortcutRevealTracker, TestClock) {
        let clock = TestClock()
        return (ShortcutRevealTracker(now: { clock.now }), clock)
    }

    /// Bounded by `LayoutPumpWait.poll` and its floor; fails naming the call site, with the poll
    /// count: a wait that gave up after 4 was starved, one after 50 disproved.
    private func waitUntil(_ what: Comment,
                           sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () -> Bool) async {
        let wait = await LayoutPumpWait.poll(upTo: 5, until: condition)
        #expect(wait.held, "\(what.rawValue) — still false after \(wait.passes) polls",
                sourceLocation: sourceLocation)
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

    /// What cancels a hold before its deadline.
    enum Interruption: String, CaseIterable { case release, keyDown, mouseDown }

    /// The timer must not fire on a hold that was already cancelled. A machine-only test can't
    /// reach this, because it is the scheduling that has to be torn down.
    @Test(arguments: Interruption.allCases)
    func anInterruptedHoldNeverPublishes(_ interruption: Interruption) async {
        let (tracker, clock) = makeTracker()
        tracker.noteModifiersChanged(to: .option)
        switch interruption {
        case .release: tracker.noteModifiersChanged(to: [])
        case .keyDown: tracker.noteKeyDown()
        case .mouseDown: tracker.noteMouseDown()
        }

        clock.advance(by: ShortcutRevealMachine.holdDuration * 3)
        // Long enough that an unscheduled-but-still-pending timer would have fired by now.
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(!tracker.isActive, "a hold cancelled by \(interruption) still published a reveal")
    }

    /// Releasing ⌥ takes the badges down again: the other half of the published flag, and the one
    /// a user notices at once if it breaks.
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

    /// A held ⌥ produces a stream of `flagsChanged`, and each reschedules. Each must wait only the
    /// time remaining to the original deadline; restarting the full hold would push the reveal out
    /// of reach on a real keyboard. Asserted on the scheduled interval, not `isActive`: a restarted
    /// clock still reveals eventually, which is all `waitUntil` can see.
    @Test func aRepeatOptionEventShortensTheWaitRatherThanRestartingIt() async throws {
        let hold = ShortcutRevealMachine.holdDuration
        let (tracker, clock) = makeTracker()

        tracker.noteModifiersChanged(to: .option)
        // Tolerance, not equality: a `Date` holds seconds-since-reference in a Double, so
        // `(t0 + 0.2) - t0` isn't exactly 0.2. Half a hold versus a whole one is far wider.
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

    /// Nothing armed, nothing scheduled: the timer is torn down rather than left to fire into a
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
