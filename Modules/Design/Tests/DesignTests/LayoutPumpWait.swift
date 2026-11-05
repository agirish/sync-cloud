import AppKit

/// The one layout-pumping condition wait for this target's mounted-view suites.
///
/// **A copy of `Modules/Dashboard/Tests/Dashboard/LayoutPumpWait.swift` and of
/// `Modules/FileExplorer/Tests/FileExplorer/LayoutPumpWait.swift` (which also carries a `poll`):
/// keep the loop and its floor the same in all three.** The packages share no test-support module,
/// the same reason `wipeDefaultsSuite` is copied into every test target. Duplication is survivable;
/// divergence is not, because a fix made in one copy leaves the bug in the others.
enum LayoutPumpWait {

    /// The fewest layout passes a wait will make before it may give up, however little of its
    /// deadline is left.
    ///
    /// A deadline counts seconds, but these waits need main-actor turns, and under full-suite
    /// congestion the two come apart. A pass costs 8ms idle, and however long the main actor takes
    /// to come back when many suites are mounting views on it. One wait was measured needing 21
    /// passes idle and 5 loaded, where ten seconds bought only 3.
    ///
    /// The slower the machine, the fewer passes are needed, since any wall-clock delay in the code
    /// under test has elapsed by the second pass. A starved run needs more turns, not more seconds,
    /// so a longer deadline doesn't help. See `docs/flaky-tests.md`, "Fixed pumps and fixed sleeps".
    static let pumpFloor = 50

    /// The same wait against a host view rather than a window, for suites that poll
    /// `layoutSubtreeIfNeeded()` on a view. A view wait bounded only in seconds gives up under a
    /// full-package run and passes in isolation.
    @MainActor
    static func pump(_ view: NSView, upTo seconds: Double,
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

    /// Pumps `window`'s layout until `condition` holds, or until BOTH the deadline has passed and
    /// `pumpFloor` passes have been made.
    ///
    /// Returns whether it held and how many passes that took. Report the pass count on failure: a
    /// wait that gave up after a handful of passes was starved and says nothing about the code,
    /// while one that gave up after a thousand was disproved.
    ///
    /// `now` is injectable so the deadline can be tested at all. Showing that the deadline carries a
    /// wait past the floor on a real clock is a bet that N seconds buy more than `pumpFloor` passes,
    /// which congestion loses. With a frozen clock the deadline never expires, so the condition
    /// decides when the loop ends. Nothing outside the tests passes it.
    ///
    /// **`floor` is for the floor's own tests and nothing else.** They assert the loop's shape,
    /// which doesn't depend on the floor being 50, and a pass can cost seconds on a saturated CI
    /// main actor. Every real wait takes the default; a caller that lowers it reopens "Fixed pumps
    /// and fixed sleeps" by hand, which is why `theFloorIsOnlyLoweredByItsOwnTests` scans for it.
    @MainActor
    static func pump(_ window: NSWindow, upTo seconds: Double,
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
}
