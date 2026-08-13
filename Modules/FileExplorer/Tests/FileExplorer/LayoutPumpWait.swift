import AppKit

/// The one layout-pumping condition wait for this target's mounted-view suites, and the one place
/// its floor is set.
///
/// Three suites had grown a byte-identical private copy of this loop. That was survivable while it
/// was only duplication; it stopped being survivable when the loop turned out to have a defect —
/// the fix landed in one copy on 2026-08-03 and the other two kept the bug, in the same target,
/// against the same congested main actor. A shared seam is what makes the floor below a single
/// decision rather than three.
enum LayoutPumpWait {

    /// The fewest layout passes a wait will make before it may give up, however little of its
    /// deadline is left.
    ///
    /// **A deadline is in seconds; everything these waits wait for arrives on main-actor turns, and
    /// under full-suite congestion those two units come apart.** Each pass costs 8ms of sleep on an
    /// idle machine, and however long the main actor takes to come back when a hundred other suites
    /// are mounting views on it. Measured on `main` at `05c7a81c`, 2026-08-03, on
    /// `ColumnPreviewProbeLifecycleTests`' first wait:
    ///
    /// | Machine | Passes it needed | Wall clock they cost |
    /// |---|---|---|
    /// | idle, `--filter` | 21 | 0.19s |
    /// | full package, 8 spinners | 5 | 7.9s / 12.2s / 21.1s |
    ///
    /// Its ten seconds bought **3** passes where the condition needed 5, and the run failed with
    /// nothing wrong but the queue it was waiting in. Note which way the requirement moves: the
    /// *slower* the machine, the *fewer* passes are needed, because any wall-clock delay inside the
    /// code under test is long since elapsed by the second pass. What a starved run needs is not
    /// more seconds but more turns — so raising a deadline would not have fixed it, and neither
    /// would shortening the delay being waited out. Neither buys a turn.
    ///
    /// Ten times the starved requirement, which also clears the 21 an idle machine wants, so the
    /// floor carries a wait on its own. It costs nothing when the machine is healthy — the deadline
    /// is reached long after the floor — and it cannot spin: a genuine regression still gets a
    /// verdict, after this many passes rather than after this many seconds.
    ///
    /// See `docs/flaky-tests.md`, mechanism 2.
    static let pumpFloor = 50

    /// Pumps `window`'s layout until `condition` holds, or until BOTH the deadline has passed and
    /// `pumpFloor` passes have been made.
    ///
    /// Returns whether it held, and how many passes that took. **The pass count is the diagnosis a
    /// caller should report on failure**: a wait that gave up after a handful of passes was starved
    /// and says nothing about the code, while one that gave up after a thousand was genuinely
    /// disproved. Elapsed time cannot tell those apart — both spend the whole deadline.
    @MainActor
    static func pump(_ window: NSWindow, upTo seconds: Double,
                     until condition: () -> Bool) async -> (held: Bool, pumps: Int) {
        var pumps = 0
        let deadline = Date().addingTimeInterval(seconds)
        while pumps < pumpFloor || Date() < deadline {
            window.layoutIfNeeded()
            pumps += 1
            if condition() { return (true, pumps) }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
        return (condition(), pumps + 1)
    }

    /// The same floor, for a condition that must NOT be pumped.
    ///
    /// `pump` drives layout on every turn, which is right when the thing being waited for is a
    /// layout result. It is wrong when the thing being waited for is an ANIMATION the code under
    /// test is running — `PaneColumnsOverscrollReturn`'s pull home, in particular. Two reasons,
    /// and the second is the one that bites:
    ///
    /// - The clip's origin is moved by the watchdog, not by a layout pass, so pumping buys nothing.
    /// - `layoutIfNeeded` is not a neutral observer. It disarms AppKit's runaway-layout guards, so
    ///   a wait that pumps can mask exactly the recursive-layout defect a sibling suite exists to
    ///   catch. Substituting `pump` into these waits would have been the tidy-looking migration and
    ///   would have quietly widened what they tolerate.
    ///
    /// So what is shared here is the FLOOR, which is the part that was wrong — not the pumping.
    /// `pumpFloor` is deliberately the same number: the unit that starves is main-actor turns, and
    /// that is the same unit whether or not a turn also runs layout.
    ///
    /// See `docs/flaky-tests.md`, mechanism 2.
    /// `now` is injectable for ONE reason: it is the only way to test the deadline at all.
    ///
    /// The floor is deterministic — spend the deadline, count the passes — but the deadline itself
    /// is not, because asserting it does anything means asserting that N wall seconds buy more than
    /// `pumpFloor` passes, and that is a throughput bet against the very congestion this file
    /// exists to survive. **Measured, on the same 50 passes: ~5 seconds in the `v2.x` FileExplorer
    /// run and over 60 in `main`'s larger one — a 12× spread between two runs of the same kind of
    /// suite.** A test written against either number is a flake against the other; that is not a
    /// tuning problem, it is the absence of a fixed unit.
    ///
    /// With a frozen clock the deadline never expires, so the CONDITION decides when the loop ends
    /// and the assertion is about the loop's shape rather than the machine's speed. Nothing outside
    /// the tests passes this.
    @MainActor
    /// **`floor` is for the floor's OWN tests and nothing else.**
    ///
    /// The tests of this loop assert a SHAPE — a demand under the floor is served once the deadline
    /// is spent, a demand over it is served while the deadline holds, a condition that never holds
    /// still gets a verdict — and none of that depends on the floor being 50. It cost a great deal
    /// that it did: a pass costs SECONDS on a saturated CI main actor against 8ms idle, so three
    /// tests of this mechanism were among the most expensive in the run. A floor of five asserts
    /// the same shapes for a tenth of the passes; `pumpFloor`'s VALUE is pinned separately by a
    /// constant assertion that costs nothing, and `theFloorIsOnlyLoweredByItsOwnTests` keeps every
    /// real wait on the default.
    static func poll(upTo seconds: Double,
                     floor: Int = pumpFloor,
                     now: () -> Date = Date.init,
                     until condition: () -> Bool) async -> (held: Bool, passes: Int) {
        var passes = 0
        let deadline = now().addingTimeInterval(seconds)
        while passes < floor || now() < deadline {
            passes += 1
            if condition() { return (true, passes) }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return (condition(), passes + 1)
    }
}
