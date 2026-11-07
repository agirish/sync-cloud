import AppKit
import Testing
@testable import FileExplorer

/// Pins `LayoutPumpWait.poll`'s pass floor, the non-pumping wait `PaneColumnsScrollTests` uses to
/// watch for the overscroll pull home.
///
/// The flake the floor prevents shows only under load, but the floor's guarantee is deterministic:
/// a property of this loop, provable with a counter and an already-spent deadline in well under a
/// second.
///
/// There is deliberately no test that `poll` avoids pumping layout: it takes no view and no window,
/// so the signature carries that. What stops someone folding `poll` into `pump` is the doc comment
/// on `LayoutPumpWait.poll`.
///
/// The loop evaluates `condition()` once more after the deadline, so the real guarantee is
/// `floor + 1` evaluations. Dropping `passes < floor` from the loop must fail
/// `theFloorOutlivesAnExpiredDeadline`.
@MainActor
@Suite struct LayoutPumpWaitPollTests {

    /// How many passes the conditions below demand. A literal, not derived from the floor: a demand
    /// that moved with the floor would hold on the first pass when the floor is zeroed, and the
    /// `held` assertion would pass against the very change it exists to catch.
    private static let passesDemanded = 3

    /// The floor these tests run against: five, not the production fifty, as in
    /// ``LayoutPumpWaitTests/testFloor``. The shapes asserted here don't depend on the magnitude,
    /// and each pass can cost seconds on a saturated CI main actor.
    private static let testFloor = 5

    /// Keeps the literal above meaningful: it must be reachable within the floor, or the test
    /// below would be measuring the deadline instead.
    @Test func theDemandUsedByTheseTestsSitsBelowTheFloor() {
        #expect(Self.passesDemanded < Self.testFloor,
                """
                \(Self.passesDemanded) passes is not reachable within a floor of \
                \(Self.testFloor) — the floor test below would be measuring the deadline.
                """)
    }

    /// With the deadline already spent, a condition that needs turns still gets them, which is
    /// exactly what a congested run has too few of.
    @Test func theFloorOutlivesAnExpiredDeadline() async {
        var passes = 0
        let needed = Self.passesDemanded

        let outcome = await LayoutPumpWait.poll(upTo: 0, floor: Self.testFloor) {
            passes += 1
            return passes >= needed
        }

        #expect(outcome.held,
                """
                A condition needing \(needed) passes was not given them with the deadline spent — \
                it saw \(passes). The floor is not outliving the deadline.
                """)
        #expect(outcome.passes >= needed,
                "the wait reported \(outcome.passes) passes for a condition that needed \(needed)")
    }

    /// A condition that never holds still terminates, after the floor plus the post-deadline
    /// re-check. Without this, the floor could be raised to something absurd or made unbounded, and
    /// nothing would say so until a suite hung.
    @Test func aConditionThatNeverHoldsStillGetsAVerdict() async {
        let outcome = await LayoutPumpWait.poll(upTo: 0, floor: Self.testFloor) { false }

        #expect(!outcome.held, "a condition that is never true was reported as held")
        #expect(outcome.passes == Self.testFloor + 1,
                """
                A never-true condition spent \(outcome.passes) passes against a floor of \
                \(Self.testFloor) — the loop's post-deadline re-check has changed shape.
                """)
    }

    /// While the deadline is live, the wait continues past the floor. Deleting
    /// `|| now() < deadline` would cap every wait at the floor, and must fail this test.
    ///
    /// Driven by a frozen clock, which makes it a test rather than a bet: through real time no
    /// deadline is safe, because seconds don't convert to passes at any fixed rate under load
    /// (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps"). The demand is `floor + 2`: a
    /// floor-only loop reaches `floor + 1` through the post-deadline re-check, so two past is the
    /// smallest demand it can't meet.
    @Test func aLiveDeadlineCarriesTheWaitPastTheFloor() async {
        var passes = 0
        let needed = Self.testFloor + 2
        // Frozen: every read is the same instant, so `now() < deadline` is true forever.
        let frozen = Date(timeIntervalSince1970: 1_770_000_000)

        let outcome = await LayoutPumpWait.poll(upTo: 60, floor: Self.testFloor, now: { frozen }) {
            passes += 1
            return passes >= needed
        }

        #expect(outcome.held,
                """
                A condition needing \(needed) passes — two past the \(Self.testFloor) \
                floor — was cut off at \(outcome.passes) with the deadline still live. The \
                deadline is not carrying the wait beyond the floor.
                """)
        #expect(outcome.passes == needed,
                "the wait reported \(outcome.passes) passes for a condition that held at \(needed)")
    }
}
