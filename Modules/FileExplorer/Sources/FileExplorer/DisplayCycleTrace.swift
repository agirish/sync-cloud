import AppKit
import Events
import Foundation

/// Counts AppKit's update-constraints passes per display cycle, so the Columns layout runaway
/// (`docs/columns-layout-loop.md`) is measured, not guessed at. The crash itself comes and goes too
/// erratically to judge a fix by, and the shipped app suppresses the assert; the pass count is
/// continuous and reads the same either way. AppKit raises once it exceeds the window's view count.
///
/// The seam is public `updateConstraintsIfNeeded`, called once per pass, swizzled only when armed.
/// AppKit's runaway guards run only on the display cycle: a never-settling loop survives 400
/// `layoutIfNeeded()` calls but raises within one second of runloop. So a fixture that drives
/// layout by hand can't see this crash; `ColumnsDisplayCycleTests` drives the runloop and counts
/// through this type.
///
/// Arm it by hand for a diagnostic session:
///
/// ```sh
/// defaults write com.abhishekgirish.SyncCloud displayCycleTraceEnabled -bool YES
/// ```
///
/// Off by default, like `PaneScrollTrace`: the log is capped at 5 MB and trimmed from the tail, so
/// per-frame lines would evict the sync runs and errors it exists to keep.
@MainActor
public enum DisplayCycleTrace {
    /// `defaults write com.abhishekgirish.SyncCloud displayCycleTraceEnabled -bool YES`.
    public static let defaultsKey = "displayCycleTraceEnabled"

    /// Read once, so the hook costs a Bool, not a `UserDefaults` lookup, per pass. Settable for
    /// tests, which drive the bookkeeping directly.
    public static var isEnabled = UserDefaults.standard.bool(forKey: defaultsKey)

    /// Cycles quieter than this are never logged. A healthy two-pane Columns provider switch spends
    /// 7 passes (`ColumnsDisplayCycleTests`), so this sits just above busy-but-correct. A floor
    /// alone isn't enough: first mount costs 14 passes and is healthy. Hence `budgetFraction`.
    static let floor = 12

    /// A logged cycle must also reach 1/8 of AppKit's own budget, the window's view count: low
    /// enough to catch a loop long before it is fatal, high enough that mounting a window stays
    /// silent. A window whose view count can't be read is judged on the floor alone.
    static let budgetFraction = 8

    /// Passes in the cycle in progress, by `NSWindow.windowNumber`: AppKit's budget is per window,
    /// and a total would hide which one churns.
    private static var passesThisCycle: [Int: Int] = [:]
    /// The worst cycle each window has had this session, for the end-of-session summary.
    private static var highWater: [Int: Int] = [:]

    private static var swizzled = false

    /// Installs the counting hook; a no-op unless the trace is armed. Idempotent: SwiftUI can
    /// re-run `App.init`, and a second exchange would restore the original and stop counting.
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
        // .debug like the [cycle] reports: an announcement must not outrank what it announces.
        Logger.shared.debug(
            "[cycle] display-cycle trace ARMED — logging any window that spends \(floor)+ "
            + "update-constraints passes in one cycle (docs/columns-layout-loop.md)")
    }

    /// One pass on one window. Apart from the swizzle so tests needn't install anything.
    static func notePass(window: Int) {
        passesThisCycle[window, default: 0] += 1
    }

    /// Ends the cycle: reports anything worth a line and starts the next. Returns what it
    /// reported, so a test can assert on the decision rather than the log.
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

    /// Both gates: at or above the floor, and at least `1/budgetFraction` of AppKit's budget. A
    /// `nil` view count reports on the floor alone.
    ///
    /// `views` must stay an autoclosure: it walks the window's whole view tree, and read eagerly on
    /// every turn it would add main-thread work to a trace that measures main-thread layout. Behind
    /// the floor it is read only for a cycle that might be logged.
    static func worthReporting(passes: Int, views: @autoclosure () -> Int?) -> Bool {
        guard passes >= floor else { return false }
        guard let views = views() else { return true }
        return passes * budgetFraction >= views
    }

    /// The worst cycle `window` has had this session — 0 if it has never crossed the floor.
    static func worstSoFar(window: Int) -> Int { highWater[window] ?? 0 }

    /// The raw count for the cycle in progress, so a test can prove the hook fires at all, which
    /// `endCycle` can't say. Not `#if DEBUG`-gated, so `swift test -c release` can assert on it
    /// (see `RiskyNameBadgeCache`).
    static func endCycleCountForTesting(window: Int) -> Int { passesThisCycle[window] ?? 0 }

    /// Not `#if DEBUG`-gated, for the same reason as `endCycleCountForTesting`.
    static func resetForTesting() {
        passesThisCycle.removeAll()
        highWater.removeAll()
    }

    /// A window's view count, AppKit's own budget. `nil` when it has no content view.
    static func viewCount(of window: NSWindow) -> Int? {
        guard let root = window.contentView else { return nil }
        func walk(_ v: NSView) -> Int { 1 + v.subviews.reduce(0) { $0 + walk($1) } }
        return walk(root)
    }

    /// The same, by window number; `nil` when no such window is open, as for a test's numbers.
    static func viewCount(ofWindowNumber number: Int) -> Int? {
        NSApplication.shared.windows
            .first { $0.windowNumber == number }
            .flatMap { viewCount(of: $0) }
    }

    private static func installObserver() {
        // Both edges of the turn: a churning window may not reach `.beforeWaiting` promptly, so
        // `.afterWaiting` closes the previous cycle and a storm isn't folded into the next one.
        //
        // The highest order, not 0: Core Animation's commit observer runs at 2,000,000 in the same
        // phase, and the layout it flushes makes passes of its own. At order 0 the cycle would close
        // before them and they would count toward the next cycle.
        let activity: CFRunLoopActivity = [.beforeWaiting, .afterWaiting]
        let obs = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activity.rawValue, true, CFIndex.max
        ) { _, _ in
            MainActor.assumeIsolated { _ = endCycle(describe: describeWindow) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    }

    /// Names a window in the log by title and view count, since the view count is the budget a
    /// pass count is read against.
    private static func describeWindow(_ number: Int) -> String {
        guard let window = NSApplication.shared.windows.first(where: { $0.windowNumber == number })
        else { return "window \(number)" }
        let views = viewCount(of: window).map { "\($0)" } ?? "?"
        let title = window.title.isEmpty ? "untitled" : window.title
        return "\"\(title)\" (\(views) views)"
    }
}

extension NSWindow {
    /// The traced half of the `updateConstraintsIfNeeded` exchange. After the exchange this name
    /// carries AppKit's original implementation, so the call below is not recursion.
    ///
    /// Keep the thread check: `MainActor.assumeIsolated` traps off the main thread, which would turn
    /// an unexpected caller into a crash. Off the main thread the pass just goes uncounted.
    @objc dynamic func syncCloud_tracedUpdateConstraintsIfNeeded() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { DisplayCycleTrace.notePass(window: windowNumber) }
        }
        syncCloud_tracedUpdateConstraintsIfNeeded()
    }
}
