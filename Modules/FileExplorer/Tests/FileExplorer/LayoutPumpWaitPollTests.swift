import AppKit
import Testing
@testable import FileExplorer

/// Pins `LayoutPumpWait.poll`'s pass floor — the non-pumping wait `PaneColumnsScrollTests` uses to
/// watch for the overscroll pull home.
///
/// `poll` exists because those waits must not drive layout: the clip's origin is moved by the
/// watchdog rather than by a layout pass, and `layoutIfNeeded` disarms AppKit's runaway-layout
/// guards, so substituting `pump` would have quietly widened what a sibling suite tolerates. What
/// is shared is the FLOOR, which is the part that was actually wrong.
///
/// The bug it prevents only reproduces under load — `PaneColumnsScrollTests.testARestTheGrown\
/// ViewportMadeIllegalIsPulledBack` went red on CI on 2026-08-09 after 49.6s, on a machine that was
/// also building another checkout — and that is exactly why the fix is not argued from pass rates.
/// The floor's *guarantee* is deterministic even though the flake is not: it is a property of this
/// loop, provable with a counter and an already-spent deadline, on an idle machine, in well under
/// a second.
///
/// **There is deliberately no test that `poll` avoids pumping layout.** It takes no view and no
/// window, so it has nothing to pump — the property is carried by the signature, and a test
/// asserting it could only restate that. The thing worth guarding is someone "simplifying" `poll`
/// into a call to `pump`, and what stops that is the paragraph on `LayoutPumpWait.poll`, not an
/// assertion.
///
/// Verified by mutation on the real constant, and one result is not what it looks like:
///
/// - `pumpFloor = 0` — the premise guard fails, and `theFloorOutlivesAnExpiredDeadline` fails on
///   `held` AND on its count (1 pass against the 25 demanded). This is the mutation that matters:
///   with the floor gone, `waitForOrigin` reverts to the wall-clock behaviour that was flaking.
/// - `pumpFloor = 24`, one short of the demand — **only the premise guard fails.** The floor test
///   still passes, because the loop evaluates `condition()` once more after the deadline, so 24
///   passes buys a 25th evaluation. The real guarantee is `pumpFloor + 1` evaluations, which is
///   why the premise guard is a separate test rather than a comment: without it, a floor lowered
///   to just under the demand would look healthy here.
@MainActor
@Suite struct LayoutPumpWaitPollTests {

    /// How many passes the conditions below demand — a LITERAL, deliberately not derived from
    /// `pumpFloor`. Writing it as `pumpFloor / 2` defeats its own mutation test: zeroing the floor
    /// would also zero the requirement, the condition would hold on the first pass, and the
    /// load-bearing `held` assertion would pass vacuously against exactly the change it exists to
    /// catch. A demand that moves with the thing under test cannot measure it.
    private static let passesDemanded = 25

    /// Keeps the literal above meaningful: it must be reachable within the floor, or the test
    /// below would be measuring the deadline instead.
    @Test func theDemandUsedByTheseTestsSitsBelowTheFloor() {
        #expect(Self.passesDemanded < LayoutPumpWait.pumpFloor,
                """
                \(Self.passesDemanded) passes is not reachable within a floor of \
                \(LayoutPumpWait.pumpFloor) — the floor test below would be measuring the deadline.
                """)
    }

    /// The load-bearing property. With the deadline ALREADY spent, a condition that needs turns
    /// still gets them — which is precisely what a congested run has too few of.
    @Test func theFloorOutlivesAnExpiredDeadline() async {
        var passes = 0
        let needed = Self.passesDemanded

        let outcome = await LayoutPumpWait.poll(upTo: 0) {
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

    /// A condition that never holds still terminates, and reports the floor it spent. Without this
    /// the floor could be raised to something absurd — or made unbounded — and nothing would say
    /// so until a suite hung.
    ///
    /// Written in terms of `pumpFloor` on purpose, unlike the demand above: this one is pinning the
    /// post-deadline re-check and the fact that a never-true condition stops at all, not the
    /// floor's magnitude. It catches neither mutation listed on the suite, and that is correct.
    @Test func aConditionThatNeverHoldsStillGetsAVerdict() async {
        let outcome = await LayoutPumpWait.poll(upTo: 0) { false }

        #expect(!outcome.held, "a condition that is never true was reported as held")
        #expect(outcome.passes == LayoutPumpWait.pumpFloor + 1,
                """
                A never-true condition spent \(outcome.passes) passes against a floor of \
                \(LayoutPumpWait.pumpFloor) — the loop's post-deadline re-check has changed shape.
                """)
    }

    /// The deadline is not decorative: while it is live, the wait continues PAST the floor.
    /// Without this, deleting `|| now() < deadline` would cap every wait at exactly `pumpFloor`
    /// passes and nothing here would say so.
    ///
    /// **Driven by a frozen clock, and that is what makes it a test rather than a bet.** Two
    /// earlier versions asserted this through real time and both went red on a loaded machine
    /// while passing under `--filter`: `pumpFloor + 20` inside 5 seconds got 51 passes where it
    /// wanted 70, and `pumpFloor + 2` inside *sixty* seconds still got only 51, because 50 passes
    /// cost over a minute in `main`'s FileExplorer run against ~5 seconds in `v2.x`'s. There is no
    /// deadline generous enough to be safe, because seconds do not convert to passes at any fixed
    /// rate — which is mechanism 2 in one sentence.
    ///
    /// A clock that never advances makes the deadline permanently live, so the CONDITION decides
    /// when the loop ends. The demand is `pumpFloor + 2`: a floor-only loop still reaches
    /// `pumpFloor + 1` via the post-deadline re-check, so two past the floor is the smallest demand
    /// it cannot meet. Verified by mutation — deleting the deadline clause fails this and nothing
    /// else.
    @Test func aLiveDeadlineCarriesTheWaitPastTheFloor() async {
        var passes = 0
        let needed = LayoutPumpWait.pumpFloor + 2
        // Frozen: every read is the same instant, so `now() < deadline` is true forever.
        let frozen = Date(timeIntervalSince1970: 1_770_000_000)

        let outcome = await LayoutPumpWait.poll(upTo: 60, now: { frozen }) {
            passes += 1
            return passes >= needed
        }

        #expect(outcome.held,
                """
                A condition needing \(needed) passes — two past the \(LayoutPumpWait.pumpFloor) \
                floor — was cut off at \(outcome.passes) with the deadline still live. The \
                deadline is not carrying the wait beyond the floor.
                """)
        #expect(outcome.passes == needed,
                "the wait reported \(outcome.passes) passes for a condition that held at \(needed)")
    }
}
