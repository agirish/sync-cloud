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
    @MainActor
    static func poll(upTo seconds: Double,
                     until condition: () -> Bool) async -> (held: Bool, passes: Int) {
        var passes = 0
        let deadline = Date().addingTimeInterval(seconds)
        while passes < pumpFloor || Date() < deadline {
            passes += 1
            if condition() { return (true, passes) }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return (condition(), passes + 1)
    }
}
