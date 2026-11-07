import AppKit
import CoreFoundation
import Events
import Foundation

/// Reports how long the main thread stays busy, by timing the run loop itself.
///
/// A clock hung off an input event measures the user's finger: `NSTableView.mouseDown` runs its
/// own tracking loop, so nothing stamped inside it can run until the button comes up. This one
/// ignores events. Observers fire on waking (`afterWaiting`) and before sleeping (`beforeWaiting`),
/// and the span between is main-thread work; a held button is the run loop waiting, so it can't
/// inflate it. Only turns over `threshold` are reported, so the log isn't buried.
///
/// The turn ends at the last end-of-turn observer, not the first: Core Animation's commit observer
/// (order 2,000,000, same phase) runs the layout and drawing it flushes, which an order-0 end
/// would count as idle. Order 0 marks where the turn's own work stopped; each `[hitch]` line gives
/// both spans. A wedged turn never ends, so wanting a stack is `MainThreadStallWatch`'s job.
@MainActor
public enum MainThreadHitchMonitor {
    /// Turns longer than this get their own line: one frame at 60 Hz. A spike threshold is blind
    /// to sustained load (forty 40 ms turns feel like a 1.6 s stall but trip no 50 ms trigger), so
    /// `busyReportInterval` catches that shape and this names the worst turns within it.
    static let threshold: CFTimeInterval = 0.016

    /// How often the duty-cycle line is emitted while the main thread is doing anything: the
    /// fraction of wall-clock time it spent busy, which shows a sluggish transition that no
    /// single-turn threshold can see.
    static let busyReportInterval: CFTimeInterval = 1.0

    /// Below this duty cycle a second gets no line, so idling and stray timers don't log one line
    /// per second forever.
    static let busyReportFloor: Double = 0.10

    private static var observer: CFRunLoopObserver?
    /// The second observer, at the highest order, that closes the turn after the commit.
    private static var lateObserver: CFRunLoopObserver?

    /// Which end-of-turn observer a `beforeWaiting` or `exit` came from.
    enum Edge {
        /// Order 0: the turn's own work is done, the end-of-turn observers are about to run.
        case early
        /// The highest order: everything has run, Core Animation's commit included.
        case late
    }

    /// When the order-0 observer saw the turn's end — `nil` until it does, and when the turn was
    /// closed without it.
    private static var earlyEnd: CFTimeInterval?
    /// The main thread's CPU time when the turn began. Read on the main thread, so it is the main
    /// thread's own: CPU well under the wall span means the thread was starved, close to it, working.
    private static var cpuBegan: CFTimeInterval?
    /// When the current turn started; `nil` while the run loop sleeps. A held button with nothing
    /// happening is a sleeping run loop, so hold time is never timed.
    private static var turnBegan: CFTimeInterval?

    /// Longest turn seen since the last `reset()`, and the running total — so a session can be
    /// summarized rather than read line by line.
    private(set) static var worst: CFTimeInterval = 0
    private(set) static var hitchCount = 0
    private(set) static var totalHitchTime: CFTimeInterval = 0
    /// The last `[hitch]` line, so a test can read it without capturing the log.
    private(set) static var lastLineForTesting: String?

    /// The open duty-cycle window: when it started, how much of it the main thread has been busy,
    /// how many turns that took, and the worst single one.
    private static var windowBegan: CFTimeInterval?
    private static var windowBusy: CFTimeInterval = 0
    private static var windowTurns = 0
    private static var windowWorst: CFTimeInterval = 0

    /// Arms the monitor when the diagnostic flag is set, and does nothing otherwise. The gate lives
    /// here, not at the call site, so `PaneScrollTrace`, which owns the flag, stays internal.
    public static func startIfEnabled() {
        guard PaneScrollTrace.isEnabled else { return }
        start()
    }

    /// Starts reporting. Idempotent.
    static func start() {
        guard observer == nil else { return }
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting, .exit]
        let obs = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities.rawValue, true, 0
        ) { _, activity in
            MainActor.assumeIsolated { _ = note(activity, edge: .early) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        let ends: CFRunLoopActivity = [.beforeWaiting, .exit]
        let late = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, ends.rawValue, true, CFIndex.max
        ) { _, activity in
            MainActor.assumeIsolated { _ = note(activity, edge: .late) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), late, .commonModes)
        lateObserver = late
        // `.commonModes`, not `.defaultMode`: modal tracking loops such as `NSTableView`'s run in
        // their own mode, and a default-mode observer would go quiet during exactly that work.
        observer = obs
        // .debug like the [hitch] lines: at Info, "armed" followed by level-dropped reports would
        // read as a healthy main thread.
        Logger.shared.debug("[hitch] monitor armed (threshold \(Int(threshold * 1000))ms)")
    }

    static func stop() {
        guard let observer else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        if let lateObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), lateObserver, .commonModes) }
        self.observer = nil
        lateObserver = nil
        turnBegan = nil
    }

    /// The rule, apart from the run loop so tests can feed it a synthetic sequence of activities.
    ///
    /// - Parameter edge: which end-of-turn observer a `beforeWaiting` or `exit` came from. Only
    ///   `.late` closes the turn; `.early` marks where its own work stopped.
    /// - Returns: the hitch duration when this activity ended a turn that exceeded `threshold`.
    @discardableResult
    static func note(_ activity: CFRunLoopActivity, edge: Edge = .late,
                     at now: CFTimeInterval = CACurrentMediaTimeShim(),
                     cpu: CFTimeInterval = callingThreadCPUTime()) -> CFTimeInterval? {
        switch activity {
        case .afterWaiting:
            // Woke up: a turn begins.
            turnBegan = now
            cpuBegan = cpu
            earlyEnd = nil
            return nil
        case .beforeWaiting, .exit:
            guard let began = turnBegan else { return nil }
            guard edge == .late else {
                // The turn's own work is done; the commit's layout and drawing are still to come.
                if earlyEnd == nil { earlyEnd = now }
                return nil
            }
            // About to sleep: the turn is over, and everything since waking was work.
            turnBegan = nil
            let elapsed = now - began
            let ownWork = earlyEnd.map { $0 - began }
            let cpuSpent = cpuBegan.map { cpu - $0 }
            earlyEnd = nil
            cpuBegan = nil
            accumulate(elapsed, at: now)
            guard elapsed >= threshold else { return nil }
            hitchCount += 1
            totalHitchTime += elapsed
            worst = max(worst, elapsed)
            let line = hitchLine(elapsed: elapsed, ownWork: ownWork, cpu: cpuSpent, context: appContext())
            lastLineForTesting = line
            Logger.shared.debug(line)
            return elapsed
        default:
            return nil
        }
    }

    /// Folds one finished turn, sub-threshold ones included, into the duty-cycle window and closes
    /// the window when it is full. The first turn to finish after the interval closes it, not a
    /// timer, so reporting never wakes an idle main thread; a partial window before a quiet spell
    /// carries into the next busy one.
    private static func accumulate(_ elapsed: CFTimeInterval, at now: CFTimeInterval) {
        guard let started = windowBegan else {
            windowBegan = now - elapsed
            windowBusy = elapsed
            windowTurns = 1
            windowWorst = elapsed
            return
        }
        windowBusy += elapsed
        windowTurns += 1
        windowWorst = max(windowWorst, elapsed)

        let span = now - started
        guard span >= busyReportInterval else { return }
        let duty = windowBusy / span
        if duty >= busyReportFloor {
            Logger.shared.debug(String(
                format: "[busy] main thread %.0f%% busy — %.0fms of %.0fms over %d turns, worst %.1fms",
                duty * 100, windowBusy * 1000, span * 1000, windowTurns, windowWorst * 1000))
        }
        windowBegan = nil
        windowBusy = 0
        windowTurns = 0
        windowWorst = 0
    }

    /// One `[hitch]` line: the whole turn, how much of it came before the end-of-turn observers
    /// (the rest is layout, drawing and the commit), the main thread's CPU time over it, and
    /// whether the app was in front and had a window on screen — a turn that runs while the app is
    /// hidden is a different suspect from one under the user's pointer.
    static func hitchLine(elapsed: CFTimeInterval, ownWork: CFTimeInterval?, cpu: CFTimeInterval?,
                          context: String) -> String {
        var line = String(format: "[hitch] main thread busy %.1fms", elapsed * 1000)
        if let ownWork {
            line += String(format: " (%.1fms before the end-of-turn observers)", ownWork * 1000)
        }
        if let cpu { line += String(format: ", CPU %.1fms", cpu * 1000) }
        return line + ", " + context
    }

    /// "app active, window visible" and its negations, read on the main thread. A test process has
    /// no `NSApp`, which reads as inactive with nothing visible.
    static func appContext() -> String {
        let state = appState()
        return "app \(state.active ? "active" : "inactive"), \(state.everyWindowOccluded ? "every window occluded" : "window visible")"
    }

    /// The same facts, for ``StallClassifier``.
    static func appState() -> StallAppState {
        let app = NSApp
        return StallAppState(active: app?.isActive ?? false,
                             everyWindowOccluded: !(app?.windows.contains { $0.occlusionState.contains(.visible) } ?? false))
    }

    static func reset() {
        worst = 0
        hitchCount = 0
        totalHitchTime = 0
        turnBegan = nil
        earlyEnd = nil
        cpuBegan = nil
        windowBegan = nil
        windowBusy = 0
        windowTurns = 0
        windowWorst = 0
    }
}

/// `CACurrentMediaTime()` without importing QuartzCore into this module — a monotonic clock, so it
/// cannot be moved by a system clock adjustment mid-measurement the way a wall clock can.
func CACurrentMediaTimeShim() -> CFTimeInterval {
    CFTimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

/// The CPU time the CALLING thread has used. The monitor's observers run on the main thread, so
/// there it is the main thread's.
func callingThreadCPUTime() -> CFTimeInterval {
    CFTimeInterval(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000
}
