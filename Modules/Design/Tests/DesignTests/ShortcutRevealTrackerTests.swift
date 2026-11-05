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

    /// The fewest polls this wait makes before it may give up, however little of its deadline is
    /// left. Same number and reason as `LayoutPumpWait.pumpFloor` in the Dashboard and FileExplorer
    /// test targets: a deadline is in seconds, what this waits for arrives on main-actor turns, and
    /// under full-suite load a few seconds can buy only a handful of polls
    /// (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps").
    private static let pollFloor = 50

    /// Bounded, and fails on expiry naming the call site, so a regression can't hang the suite. It
    /// gives up only once the deadline has passed and `pollFloor` polls have been made. The poll
    /// count goes in the message: a wait that gave up after 4 was starved, one after 50 disproved.
    ///
    /// Only the floor's own case below overrides `floor`, since it asserts a shape that doesn't
    /// depend on the floor's size and a poll can cost seconds on a saturated CI main actor. Every
    /// real wait here takes the default.
    private func waitUntil(_ what: Comment,
                           timeout: TimeInterval = 5,
                           floor: Int = ShortcutRevealTrackerTests.pollFloor,
                           sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () -> Bool) async {
        var polls = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while polls < floor || ContinuousClock.now < deadline {
            polls += 1
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(condition(), "\(what.rawValue) — still false after \(polls) polls",
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

    /// The timer must not fire on a hold that was already cancelled. A machine-only test can't
    /// reach this, because it is the scheduling that has to be torn down.
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

    // MARK: The floor itself

    /// How many polls the case below demands. A literal, not derived from the floor: a demand that
    /// moved with the floor would shrink with it and let the case pass vacuously.
    private static let pollsDemanded = 3

    /// The floor the case below runs against: five, not the production fifty. A literal, like
    /// ``pollsDemanded``, so it can't move with the floor.
    private static let testFloor = 5

    /// The demand must be reachable within the floor. The only case that catches a floor lowered to
    /// just under the demand: the post-deadline `#expect` evaluates the condition once more, so a
    /// floor of N gives N + 1 evaluations.
    @Test func theDemandUsedByTheFloorCaseSitsBelowTheFloor() {
        #expect(Self.pollsDemanded < Self.testFloor,
                "\(Self.pollsDemanded) polls is not reachable within a floor of \(Self.testFloor) — the floor case below would be measuring the deadline")
    }

    /// Pins the production floor at fifty, which the case below can't see. Fifty is the figure
    /// measured in `docs/flaky-tests.md` ("Fixed pumps and fixed sleeps"), the same as
    /// `LayoutPumpWait.pumpFloor`, because main-actor turns are what starve either way.
    @Test func theProductionPollFloorIsStillFifty() {
        #expect(Self.pollFloor == 50,
                "the floor every real wait here uses is now \(Self.pollFloor) — see docs/flaky-tests.md mechanism 2")
        #expect(Self.testFloor < Self.pollFloor, "the test floor is no longer the cheaper one")
    }

    /// The floor outlives an expired deadline. The failure it prevents shows only under load, but
    /// the guarantee is deterministic, so it is tested with a counter and a spent deadline. Each of
    /// the repo's four floors has a test like this (`LayoutPumpWait.pumpFloor`, both
    /// `waitPollFloor` copies). `waitUntil` records its own failure if it gives up.
    @Test func theFloorOutlivesAnExpiredDeadline() async {
        var polls = 0
        await waitUntil("a condition needing \(Self.pollsDemanded) polls never held",
                        timeout: 0, floor: Self.testFloor) {
            polls += 1
            return polls >= Self.pollsDemanded
        }
        #expect(polls >= Self.pollsDemanded,
                "the condition was evaluated only \(polls) times against a floor of \(Self.testFloor)")
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
