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
}
