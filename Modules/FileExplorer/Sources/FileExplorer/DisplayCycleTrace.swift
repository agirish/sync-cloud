import AppKit
import Events
import Foundation

/// Counts AppKit's update-constraints passes per display cycle, so the Columns layout runaway can
/// be measured instead of guessed at.
///
/// **Why a counter and not a crash.** `docs/columns-layout-loop.md` records that the crash rate
/// moves by an order of magnitude for reasons nobody understands — 5/5 one evening, 0/12 the next,
/// 22 warm survivals matched by 6/6 with the assert forced back on — so survived/died has almost no
/// power as a verdict on a candidate fix. What the window is actually doing is continuous: it spends
/// some number of update-constraints passes per cycle, and AppKit raises only at the far end of that
/// scale, once the count exceeds the window's view count. Reading the number directly turns a coin
/// flip into a measurement, and it reads the same whether or not the assert is suppressed — which
/// matters, because the shipped app suppresses it.
///
/// **`updateConstraintsIfNeeded` is the seam, and it is public API.** AppKit calls it once per pass.
/// Measured on a deliberate never-settling sibling ping-pong: 4,690 calls across 400 manual
/// `layoutIfNeeded`s, 853 across one second of runloop. No private selector, no `_`-prefixed
/// swizzle, nothing that a future macOS can quietly rename out from under the app — and the swizzle
/// is not installed at all unless the trace is armed.
///
/// **The driver matters more than anything else here, and that is the finding this file exists
/// to carry forward.** AppKit's runaway guards are armed only on the display cycle. Driving the
/// same never-settling ping-pong by hand never reaches them:
///
/// | driver | guard armed | outcome |
/// |---|---|---|
/// | `window.layoutIfNeeded()` x400 | yes | survives — 469,000 `updateConstraints` calls, no raise |
/// | one second of the runloop | yes | raises on the first cycle |
///
/// Every headless fixture written against this bug so far (`PaneTreeSwapLayoutBudgetTests`,
/// `PaneRowHeightStabilityTests`, `ColumnsRepublishLayoutLoopTests`, `PaneColumnsLayoutLoopTests`)
/// drives with `layoutIfNeeded`, so their "settles in 2 rounds" verdicts say nothing about this
/// crash — they were measuring a path that structurally cannot fail. `ColumnsDisplayCycleTests`
/// drives with the runloop and counts through this type instead.
///
/// **Armed by hand, for a diagnostic session:**
///
/// ```sh
/// defaults write com.abhishekgirish.SyncCloud displayCycleTraceEnabled -bool YES
/// ```
///
/// Off by default and gated the same way `PaneScrollTrace` is, and for the same reason: the log is
/// capped at 5 MB and trimmed from the TAIL, so anything emitted per frame evicts the sync runs and
/// errors the log exists to preserve.
@MainActor
public enum DisplayCycleTrace {
    /// `defaults write com.abhishekgirish.SyncCloud displayCycleTraceEnabled -bool YES`.
    public static let defaultsKey = "displayCycleTraceEnabled"

    /// Read once, so the counting hook costs a Bool rather than a `UserDefaults` lookup per pass.
    /// Settable for the tests, which drive the bookkeeping directly rather than through the swizzle.
    public static var isEnabled = UserDefaults.standard.bool(forKey: defaultsKey)

    /// Cycles quieter than this are never worth a line, whatever the window's size. A HEALTHY
    /// two-pane Columns provider switch — both panes drilled, preview up, the tree dropped and
    /// republished — spends **7** passes against 348 views (`ColumnsDisplayCycleTests`,
    /// deterministic across runs), so this sits just above a busy-but-correct cycle.
    ///
    /// An absolute floor is not sufficient on its own, which the fixture also showed: mounting that
    /// same pane costs **14** passes in its first turn against only 136 views. Initial layout is
    /// expensive and perfectly healthy, and a bare floor would report it. Hence `budgetFraction`.
    static let floor = 12

    /// …and a cycle is only worth a line if it also reaches this fraction of AppKit's OWN budget,
    /// which is the window's view count — that is the number AppKit raises at, so it is the only
    /// scale a pass count means anything on. One eighth: far enough below the cliff to catch a loop
    /// long before it is fatal (and while the assert is suppressed, so it never would be), far
    /// enough above ordinary work that mounting a window stays silent.
    ///
    /// A window whose view count cannot be read falls back to the floor alone rather than going
    /// unreported: a missing denominator is a reason to be noisy, not quiet.
    static let budgetFraction = 8

    /// Passes counted for the cycle in progress, keyed by `NSWindow.windowNumber`. Keyed rather
    /// than summed because AppKit's budget is per WINDOW — a Settings sheet churning is a different
    /// finding from the main window churning, and a total would hide which.
    private static var passesThisCycle: [Int: Int] = [:]
    /// The worst cycle each window has had this session, so the summary at the end of a diagnostic
    /// session does not depend on anyone having watched the log while it happened.
    private static var highWater: [Int: Int] = [:]

    private static var observer: CFRunLoopObserver?
    private static var swizzled = false

    /// Installs the counting hook. No-op unless the trace is armed, so an unarmed session runs
    /// exactly the code it ran before this type existed.
    ///
    /// Idempotent: `App.init` can be re-run by SwiftUI, and exchanging the implementations twice
    /// would restore the original and silently stop counting.
    public static func arm() {
        guard isEnabled, !swizzled else { return }
        guard let original = class_getInstanceMethod(
                NSWindow.self, #selector(NSWindow.updateConstraintsIfNeeded)),
              let replacement = class_getInstanceMethod(
                NSWindow.self, #selector(NSWindow.syncCloud_tracedUpdateConstraintsIfNeeded))
        else {
            Logger.shared.debug("[cycle] display-cycle trace could not install — hook absent")
            return
        }
        method_exchangeImplementations(original, replacement)
        swizzled = true
        installObserver()
        // .debug like the [cycle] reports themselves — see the [hitch] armed line for why an
        // announcement must not outrank what it announces.
        Logger.shared.debug(
            "[cycle] display-cycle trace ARMED — logging any window that spends \(floor)+ "
            + "update-constraints passes in one cycle (docs/columns-layout-loop.md)")
    }

    /// One pass, on one window. Separated from the swizzle so the bookkeeping is testable without
    /// installing anything process-wide.
    static func notePass(window: Int) {
        passesThisCycle[window, default: 0] += 1
    }

    /// Ends the cycle: reports anything at or above the floor and starts the next one.
    ///
    /// Returns what it reported, so a test can assert on the decision rather than on the log file.
    @discardableResult
    static func endCycle(describe: (Int) -> String = { "window \($0)" },
                         views: (Int) -> Int? = { viewCount(ofWindowNumber: $0) })
    -> [(window: Int, passes: Int)] {
        defer { passesThisCycle.removeAll(keepingCapacity: true) }
        var reported: [(window: Int, passes: Int)] = []
        for (window, passes) in passesThisCycle where worthReporting(passes: passes,
                                                                    views: views(window)) {
            let previousWorst = highWater[window] ?? 0
            highWater[window] = max(previousWorst, passes)
            reported.append((window, passes))
            Logger.shared.debug(
                "[cycle] \(describe(window)) spent \(passes) update-constraints passes in one "
                + "display cycle (worst this session \(max(previousWorst, passes)))")
        }
        return reported.sorted { $0.passes > $1.passes }
    }

    /// Both gates: above the absolute floor, and at least `1/budgetFraction` of AppKit's own budget.
    /// A `nil` view count means the denominator could not be read, which reports on the floor alone.
    ///
    /// **`views` is an autoclosure, and that is load-bearing rather than tidy.** Reading it means
    /// walking a window's whole view tree; this runs on every window, on every runloop turn, for as
    /// long as the trace is armed. Evaluated eagerly it was a recursive walk of the entire UI at
    /// runloop frequency on the main thread — which is a lot of main-thread work to add to a
    /// diagnostic whose entire subject is main-thread layout timing, i.e. an instrument perturbing
    /// what it measures. Behind the floor it is read only for the rare cycle that might be worth a
    /// line, and a quiet app never pays for it at all.
    static func worthReporting(passes: Int, views: @autoclosure () -> Int?) -> Bool {
        guard passes >= floor else { return false }
        guard let views = views() else { return true }
        return passes * budgetFraction >= views
    }

    /// The worst cycle `window` has had this session — 0 if it has never crossed the floor.
    static func worstSoFar(window: Int) -> Int { highWater[window] ?? 0 }

    /// The raw count for the cycle in progress, for the one test that has to prove the swizzle
    /// landed. `endCycle` deliberately reports only what crossed the floor, so it cannot answer
    /// "did the hook fire at all" — which is exactly the question worth asking of an instrument.
    static func endCycleCountForTesting(window: Int) -> Int { passesThisCycle[window] ?? 0 }

    static func resetForTesting() {
        passesThisCycle.removeAll()
        highWater.removeAll()
    }

    /// A window's view count — AppKit's own budget, and the only thing a pass count means anything
    /// against. `nil` when the window has no content view to walk.
    static func viewCount(of window: NSWindow) -> Int? {
        guard let root = window.contentView else { return nil }
        func walk(_ v: NSView) -> Int { 1 + v.subviews.reduce(0) { $0 + walk($1) } }
        return walk(root)
    }

    /// The same, by window number — `nil` when no such window is open, which is the case for every
    /// synthetic number a test uses.
    static func viewCount(ofWindowNumber number: Int) -> Int? {
        NSApplication.shared.windows
            .first { $0.windowNumber == number }
            .flatMap { viewCount(of: $0) }
    }

    private static func installObserver() {
        // Both edges of the turn. `.beforeWaiting` is the natural end of a display cycle, but a
        // window churning hard enough to matter is precisely one that may not reach it promptly —
        // `.afterWaiting` closes the previous cycle at the start of the next turn, so a storm is
        // still reported rather than accumulating into the following one.
        let activity: CFRunLoopActivity = [.beforeWaiting, .afterWaiting]
        let obs = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activity.rawValue, true, 0
        ) { _, _ in
            MainActor.assumeIsolated { _ = endCycle(describe: describeWindow) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs
    }

    /// Names a window in the log by title and view count. Title alone is not enough — the budget
    /// that decides whether AppKit raises is the view count, so a bare pass count cannot be read.
    private static func describeWindow(_ number: Int) -> String {
        guard let window = NSApplication.shared.windows.first(where: { $0.windowNumber == number })
        else { return "window \(number)" }
        let views = viewCount(of: window).map { "\($0)" } ?? "?"
        let title = window.title.isEmpty ? "untitled" : window.title
        return "\"\(title)\" (\(views) views)"
    }
}

extension NSWindow {
    /// The traced half of the `updateConstraintsIfNeeded` exchange. After
    /// `method_exchangeImplementations` this name carries AppKit's ORIGINAL implementation, which is
    /// why the recursive-looking call below is not recursion.
    ///
    /// **The thread check is not defensive noise.** `MainActor.assumeIsolated` TRAPS when it is
    /// wrong, so an instrument that used it unguarded would convert "AppKit called this from
    /// somewhere unexpected" into a crash — in a diagnostic whose entire purpose is to observe a
    /// crash without causing one. Off the main thread the pass simply goes uncounted, which
    /// understates the metric rather than killing the session.
    @objc dynamic func syncCloud_tracedUpdateConstraintsIfNeeded() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { DisplayCycleTrace.notePass(window: windowNumber) }
        }
        syncCloud_tracedUpdateConstraintsIfNeeded()
    }
}
