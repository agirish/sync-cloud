import AppKit

/// The one layout-pumping condition wait for every test target's mounted-view suites, and the one
/// place its floor is set, so the floor is a single decision rather than one per suite.
public enum LayoutPumpWait {

    /// The fewest layout passes a wait will make before it may give up, however little of its
    /// deadline is left.
    ///
    /// A deadline is in seconds, but everything these waits wait for arrives on main-actor turns,
    /// and under full-suite congestion the two come apart: a pass costs 8ms idle and seconds when
    /// other suites crowd the main actor. A starved run needs more turns, not more seconds, so
    /// neither a longer deadline nor a shorter delay under test fixes it. The slower the machine,
    /// the fewer passes a condition needs (about 5 starved, about 21 idle).
    ///
    /// Fifty clears both, so the floor carries a wait on its own. It costs nothing on a healthy
    /// machine, where the deadline outlasts it, and it cannot spin: a real regression still gets a
    /// verdict after this many passes.
    ///
    /// See `docs/flaky-tests.md`, "Fixed pumps and fixed sleeps".
    public static let pumpFloor = 50

    /// Pumps `view`'s layout until `condition` holds, or until both the deadline has passed and
    /// `floor` passes have been made. The entry point for suites that poll
    /// `layoutSubtreeIfNeeded()` on a host view rather than a window.
    ///
    /// Returns whether it held and how many passes that took. Report the pass count on failure: a
    /// wait that gave up after a handful of passes was starved and says nothing about the code,
    /// while one that gave up after a thousand was disproved. Elapsed time can't tell them apart.
    ///
    /// `now` is injectable only so the deadline can be tested: with a frozen clock the deadline
    /// never expires, so the condition decides when the loop ends, and the test asserts the loop's
    /// shape rather than the machine's speed. Without it, the test would bet that N wall seconds
    /// buy more than `floor` passes, against the very congestion this file exists to survive.
    ///
    /// `floor` is for the floor's own tests only, which run a small one because the shape they
    /// assert doesn't depend on its value. Every real wait takes the default; a caller that lowers
    /// it reopens the starvation by hand, which is why `theFloorIsOnlyLoweredByItsOwnTests` scans
    /// for it.
    @MainActor
    public static func pump(_ view: NSView, upTo seconds: Double,
                     floor: Int = pumpFloor,
                     now: () -> Date = Date.init,
                     until condition: () -> Bool) async -> (held: Bool, pumps: Int) {
        var pumps = 0
        let deadline = now().addingTimeInterval(seconds)
        while pumps < floor || now() < deadline {
            view.layoutSubtreeIfNeeded()
            pumps += 1
            if condition() { return (true, pumps) }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        view.layoutSubtreeIfNeeded()
        return (condition(), pumps + 1)
    }

    /// The same wait for a window; see the view overload.
    @MainActor
    public static func pump(_ window: NSWindow, upTo seconds: Double,
                     floor: Int = pumpFloor,
                     now: () -> Date = Date.init,
                     until condition: () -> Bool) async -> (held: Bool, pumps: Int) {
        var pumps = 0
        let deadline = now().addingTimeInterval(seconds)
        while pumps < floor || now() < deadline {
            window.layoutIfNeeded()
            pumps += 1
            if condition() { return (true, pumps) }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
        return (condition(), pumps + 1)
    }

    /// The same floor, for a condition that must not be pumped.
    ///
    /// `pump` drives layout on every turn, which is right when waiting for a layout result and
    /// wrong when waiting for an animation the code under test runs, such as
    /// `PaneColumnsOverscrollReturn`'s pull home:
    ///
    /// - The clip's origin is moved by the watchdog, not by a layout pass, so pumping buys nothing.
    /// - `layoutIfNeeded` is not a neutral observer. It disarms AppKit's runaway-layout guards, so
    ///   a wait that pumps can mask the recursive-layout defect a sibling suite exists to catch.
    ///
    /// So only the floor is shared, not the pumping. `pumpFloor` is the same number because the
    /// unit that starves is main-actor turns, whether or not a turn also runs layout. `now` and
    /// `floor` are for this loop's own tests, as on `pump`.
    ///
    /// See `docs/flaky-tests.md`, "Fixed pumps and fixed sleeps".
    @MainActor
    public static func poll(upTo seconds: Double,
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
