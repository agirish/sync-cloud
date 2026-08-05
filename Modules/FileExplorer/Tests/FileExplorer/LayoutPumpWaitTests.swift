import AppKit
import Testing
@testable import FileExplorer

/// Pins `LayoutPumpWait`'s pass floor — the one constant ten mounted-view suites in this target
/// depend on, and until now the only thing in the flake defence with no test of its own.
///
/// The floor exists because a deadline is in seconds while everything these waits wait for arrives
/// on main-actor turns, and under full-suite congestion the two units come apart (see
/// `docs/flaky-tests.md`, mechanism 2). That failure only reproduces under load, which is exactly
/// why it must not be the thing the fix is argued from: a flake fix that can only be shown by
/// re-rolling pass rates is a flake fix nobody can check. The floor's *guarantee* is deterministic
/// even though the bug it prevents is not — it is a property of this loop, provable with a counter
/// and an already-spent deadline, on an idle machine, in under a second.
///
/// Verified by mutation on the real constant, and the results are worth recording exactly because
/// two of them are not what they look like:
///
/// - `pumpFloor = 0` — the premise guard fails, and both floor tests fail on `held` AND on their
///   count (1 pass against the 25 demanded). This is the mutation that matters: with the floor
///   gone, every one of the ten calling suites reverts silently to the wall-clock behaviour that
///   was flaking, and no other suite in the target would have said so.
/// - `pumpFloor = 24`, one short of the demand — **only the premise guard fails.** The floor tests
///   still pass, because the loop evaluates `condition()` once more after the deadline, so 24
///   passes buys a 25th evaluation. The floor's real guarantee is `pumpFloor + 1` evaluations, and
///   that off-by-one is the whole reason the premise guard is a separate test rather than a
///   comment: without it a floor lowered to just under the demand would look healthy here.
/// - `aConditionThatNeverHoldsStillGetsAVerdict` catches neither, because its expectation is
///   written in terms of `pumpFloor` and moves with it. It is pinning the post-deadline re-check
///   and the fact that a never-true condition terminates at all — not the floor's magnitude.
@MainActor
@Suite struct LayoutPumpWaitTests {

    /// A bare view, deliberately: the subject is this loop's own accounting, not AppKit layout.
    /// Anything with real layout cost would make the pass counts below depend on the machine.
    private func host() -> NSView { NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10)) }

    /// How many passes the conditions below demand — a LITERAL, deliberately not derived from
    /// `pumpFloor`. Writing it as `pumpFloor / 2` was the first version and it defeated its own
    /// mutation test: zeroing the floor also zeroed the requirement, so the condition held on the
    /// first pass and the `held` assertion — the load-bearing one — passed vacuously against
    /// exactly the change it exists to catch. The count assertion still failed, so the suite went
    /// red, but for an incidental reason. A demand that moves with the thing under test cannot
    /// measure it.
    private static let passesDemanded = 25

    /// Keeps the literal above meaningful: it must be reachable within the floor, or these tests
    /// would be measuring the deadline instead. Fails loudly rather than drifting if the floor
    /// is ever lowered past it.
    @Test func theDemandUsedByTheseTestsSitsBelowTheFloor() {
        #expect(Self.passesDemanded < LayoutPumpWait.pumpFloor,
                "\(Self.passesDemanded) passes is not reachable within a floor of \(LayoutPumpWait.pumpFloor) — the floor tests below would be measuring the deadline")
    }

    /// The load-bearing property. With the deadline ALREADY spent, a condition that needs turns
    /// still gets them — which is precisely what a congested run has too few of.
    @Test func theFloorOutlivesAnExpiredDeadline() async {
        var passes = 0
        let needed = Self.passesDemanded
        let outcome = await LayoutPumpWait.pump(host(), upTo: 0) {
            passes += 1
            return passes >= needed
        }
        #expect(outcome.held,
                "gave up after \(outcome.pumps) pass(es) with the deadline already spent — the floor is not carrying the wait")
        #expect(outcome.pumps == needed,
                "held after \(outcome.pumps) passes, expected exactly \(needed)")
    }

    /// The floor is a minimum, not a ceiling: a condition that needs more passes than the floor
    /// still gets them while the deadline holds. Without this, "raise the floor" and "the wait
    /// stops early" would look identical from the test above.
    ///
    /// **The deadline is 300s, and that number has a story.** It was 30s, and this test then failed
    /// six full-package runs out of six while passing every time under `--filter` — because sixty
    /// passes cost about 1.1 SECONDS each on a congested main actor against 8ms idle, so the
    /// deadline expired around pass 50 and the loop stopped at the floor. That is precisely
    /// mechanism 2, committed by the test written to document mechanism 2: a demand denominated in
    /// passes, bounded by a budget denominated in seconds.
    ///
    /// A pass-denominated deadline is what this wants and there isn't one, so the deadline is
    /// instead sized so congestion cannot reach it. That is safe here in a way it is NOT safe in
    /// the calling suites, and the difference is worth stating: **the regression this guards
    /// against returns IMMEDIATELY.** If the floor became a ceiling the loop exits at
    /// `pumpFloor` and returns 51 passes in milliseconds, red. Nothing makes this test spend its
    /// deadline except a pump that stops evaluating its condition entirely, which is not a
    /// mutation of the line under test. So the large number costs nothing and buys immunity to the
    /// machine — the opposite trade from a fifteen-second wait on rows that may never come.
    @Test func theDeadlineStillCarriesTheWaitPastTheFloor() async {
        var passes = 0
        let needed = LayoutPumpWait.pumpFloor + 10
        let outcome = await LayoutPumpWait.pump(host(), upTo: 300) {
            passes += 1
            return passes >= needed
        }
        #expect(outcome.held, "gave up after \(outcome.pumps) passes, needing \(needed)")
        #expect(outcome.pumps == needed,
                "held after \(outcome.pumps) passes, expected exactly \(needed) — the floor became a ceiling")
    }

    /// A real regression must still get a verdict, and must get it after a bounded number of
    /// passes rather than by spinning. The `+ 1` is the loop's post-deadline re-check, which is
    /// what lets a condition that became true during the last sleep still be seen.
    @Test func aConditionThatNeverHoldsStillGetsAVerdict() async {
        let outcome = await LayoutPumpWait.pump(host(), upTo: 0) { false }
        #expect(!outcome.held, "a never-true condition reported held")
        #expect(outcome.pumps == LayoutPumpWait.pumpFloor + 1,
                "gave up after \(outcome.pumps) passes, expected the floor's \(LayoutPumpWait.pumpFloor) plus the post-deadline re-check")
    }

    /// The window entry point carries a byte-identical loop, and the two have drifted before —
    /// the note on `LayoutPumpWait` records the copy that kept a bug after the other was fixed.
    @Test func theWindowEntryPointHonoursTheSameFloor() async {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host()
        defer { window.contentView = nil }

        var passes = 0
        let needed = Self.passesDemanded
        let outcome = await LayoutPumpWait.pump(window, upTo: 0) {
            passes += 1
            return passes >= needed
        }
        #expect(outcome.held,
                "the window variant gave up after \(outcome.pumps) pass(es) with the deadline spent")
        #expect(outcome.pumps == needed)
    }
}
