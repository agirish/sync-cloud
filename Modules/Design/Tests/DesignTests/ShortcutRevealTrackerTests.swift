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

    /// The fewest polls this wait will make before it may give up, however little of its deadline
    /// is left. Same number, and the same reason, as `LayoutPumpWait.pumpFloor` in the Dashboard
    /// and FileExplorer test targets.
    ///
    /// **A deadline is in seconds; what this waits for arrives on main-actor turns, and under
    /// full-suite load those two units come apart.** Measured here on 2026-08-08, waiting for the
    /// same reveal: **34 polls in 0.207s** under `--filter`, and **4 polls in 4.44s** in a full
    /// Design run. Five wall-clock seconds bought four evaluations of the condition — the 0.2s
    /// hold had long since elapsed, and what the wait was short of was turns to notice.
    private static let pollFloor = 50

    /// Bounded, and it FAILS on expiry naming the call site — an unbounded spin here would turn a
    /// regression into a hung suite.
    ///
    /// Bounded by **polls as well as by seconds**: it may give up only once both the deadline has
    /// passed and `pollFloor` polls have been made. **The poll count is the diagnosis, so it goes
    /// in the message** — a wait that gave up after 4 of them was starved and says nothing about
    /// the tracker, while one that gave up after 50 was genuinely disproved.
    ///
    /// `floor` is overridden **only by the floor's own case below**, which asserts a shape — a
    /// demand under the floor is served once the deadline is spent — that does not depend on the
    /// floor being fifty. Depending on it was expensive: a poll costs seconds on a saturated CI
    /// main actor, so that one test was spending ~184s of a 665s CI step. Every real wait here
    /// takes the default.
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

    // MARK: The floor itself

    /// How many polls the case below demands — a LITERAL, deliberately not derived from
    /// `pollFloor`. Deriving it defeats its own mutation test: zeroing the floor would also zero
    /// the requirement, and the condition would hold on the first poll against exactly the change
    /// the test exists to catch.
    private static let pollsDemanded = 3

    /// The floor the case below runs against — five, not the production fifty. A literal for the
    /// same reason `pollsDemanded` is one: derived from `pollFloor` it would move with the thing
    /// under test.
    private static let testFloor = 5

    /// Keeps that literal meaningful — and it is the only case that catches a floor lowered to just
    /// *under* the demand, since the loop's post-deadline `#expect` re-evaluates the condition once
    /// more and so buys a 25th poll from a floor of 24. The real guarantee is `pollFloor + 1`.
    @Test func theDemandUsedByTheFloorCaseSitsBelowTheFloor() {
        #expect(Self.pollsDemanded < Self.testFloor,
                "\(Self.pollsDemanded) polls is not reachable within a floor of \(Self.testFloor) — the floor case below would be measuring the deadline")
    }

    /// **The production floor's VALUE**, pinned here because the case below no longer exercises
    /// it. Fifty is the measured figure from `docs/flaky-tests.md` mechanism 2 — the same number
    /// `LayoutPumpWait.pumpFloor` carries, deliberately, because the unit that starves is
    /// main-actor turns either way.
    @Test func theProductionPollFloorIsStillFifty() {
        #expect(Self.pollFloor == 50,
                "the floor every real wait here uses is now \(Self.pollFloor) — see docs/flaky-tests.md mechanism 2")
        #expect(Self.testFloor < Self.pollFloor, "the test floor is no longer the cheaper one")
    }

    /// **The floor outlives an expired deadline** — the property the flake fix rests on, pinned
    /// rather than argued from pass rates.
    ///
    /// This is the suite whose wait actually failed CI, and until now its floor was the only one of
    /// the repo's four with no test: `LayoutPumpWait.pumpFloor` and both `waitPollFloor` copies have
    /// theirs. The bug the floor prevents reproduces only under congestion, but the floor's
    /// *guarantee* is deterministic — a property of the loop, provable with a counter and a spent
    /// deadline on an idle machine.
    ///
    /// `waitUntil` records its own labeled failure if it gives up, so a floor that stopped working
    /// turns this red without any assertion of mine; the count then says by how much.
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
