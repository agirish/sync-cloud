import AppKit

/// The one layout-pumping condition wait for this target's mounted-view suites.
///
/// **Duplicated verbatim from `Modules/FileExplorer/Tests/FileExplorer/LayoutPumpWait.swift` — keep
/// the copies in step.** The two live in separate SPM packages with no shared test-support module,
/// the same reason `wipeDefaultsSuite` is copied into every test target. Duplication is survivable;
/// DIVERGENCE is not, and has already cost this repo once: three private copies of this loop existed
/// inside one target, the defect below was fixed in one of them on 2026-08-03, and the other two
/// kept the bug against the same congested main actor.
enum LayoutPumpWait {

    /// The fewest layout passes a wait will make before it may give up, however little of its
    /// deadline is left.
    ///
    /// **A deadline is in seconds; everything these waits wait for arrives on main-actor turns, and
    /// under full-suite congestion those two units come apart.** Each pass costs 8ms of sleep on an
    /// idle machine, and however long the main actor takes to come back when a hundred other suites
    /// are mounting views on it. Measured on `main` at `05c7a81c`, one wait needed 21 passes idle
    /// (0.19s) and 5 passes on a loaded machine — where ten seconds bought only 3, and the run failed
    /// with nothing wrong but the queue it was waiting in.
    ///
    /// Note which way the requirement moves: the *slower* the machine, the *fewer* passes are
    /// needed, because any wall-clock delay inside the code under test is long since elapsed by the
    /// second pass. What a starved run needs is not more seconds but more turns — so raising a
    /// deadline would not have fixed it.
    ///
    /// See `docs/flaky-tests.md`, mechanism 2.
    static let pumpFloor = 50

    /// Pumps `window`'s layout until `condition` holds, or until BOTH the deadline has passed and
    /// `pumpFloor` passes have been made.
    ///
    /// Returns whether it held, and how many passes that took. **The pass count is the diagnosis a
    /// caller should report on failure**: a wait that gave up after a handful of passes was starved
    /// and says nothing about the code, while one that gave up after a thousand was genuinely
    /// disproved.
    ///
    /// **`now` is injectable for one reason: it is the only way to test the deadline at all.** The
    /// floor is deterministic, but asserting that the deadline carries a wait *past* the floor
    /// means asserting that N wall seconds buy more than `pumpFloor` passes — a throughput bet
    /// against the very congestion this file exists to survive. These overloads did not have the
    /// seam, so the test of that property was left betting on the machine: written with a
    /// 30-second deadline it failed six full-package runs out of six, and was "fixed" by raising
    /// the deadline to 300 seconds on the reasoning that congestion could not reach it. On
    /// 2026-08-13 congestion reached it — 57 of the 60 passes it needed, in 304 seconds, about
    /// 5.3s per pass against the ~1.1s that reasoning already called congested. A bigger number
    /// was never the answer; the missing unit was.
    ///
    /// With a frozen clock the deadline never expires, so the CONDITION decides when the loop ends
    /// and the assertion is about the loop's shape rather than the machine's speed. Nothing outside
    /// the tests passes this.
    /// The same wait against a host VIEW rather than a window.
    ///
    /// `docs/flaky-tests.md` records four suites that poll `layoutSubtreeIfNeeded()` on a view and
    /// so could not adopt the floor by substitution — they needed this entry point, and the doc says
    /// so. It stopped being theoretical on 2026-08-04: `FoldAllToggleBindingTests` gave up with the
    /// table showing **0 rows** in a full-package run and passed three times out of three in
    /// isolation, which is this mechanism exactly. Its own 15-second deadline bought too few
    /// main-actor turns, and seconds were never the unit that mattered.
    @MainActor
    static func pump(_ view: NSView, upTo seconds: Double,
                     now: () -> Date = Date.init,
                     until condition: () -> Bool) async -> (held: Bool, pumps: Int) {
        var pumps = 0
        let deadline = now().addingTimeInterval(seconds)
        while pumps < pumpFloor || now() < deadline {
            view.layoutSubtreeIfNeeded()
            pumps += 1
            if condition() { return (true, pumps) }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        view.layoutSubtreeIfNeeded()
        return (condition(), pumps + 1)
    }

    @MainActor
    static func pump(_ window: NSWindow, upTo seconds: Double,
                     now: () -> Date = Date.init,
                     until condition: () -> Bool) async -> (held: Bool, pumps: Int) {
        var pumps = 0
        let deadline = now().addingTimeInterval(seconds)
        while pumps < pumpFloor || now() < deadline {
            window.layoutIfNeeded()
            pumps += 1
            if condition() { return (true, pumps) }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
        return (condition(), pumps + 1)
    }
}
