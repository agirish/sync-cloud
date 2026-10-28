import AppKit
import CoreFoundation
import Events
import Foundation

/// Reports how long the main thread stays busy, by timing the run loop itself.
///
/// **Why the pane needed a third attempt at this.** Two earlier click metrics both measured the
/// user's finger rather than the app's work, and each looked convincing:
///
/// - `[click]` stamps from the selection commit, which happens on mouse-DOWN inside
///   `NSTableView`'s tracking loop, so it spans however long the button was held. `dfa74e4`
///   caught that.
/// - `[render]` was added to fix it, moving the stamp to the tap gesture's `onEnded` and reading it
///   back on the next main-queue turn — "this stamp starts after the button is already up, so
///   whatever it measures is work". That is false, and measurably so: across twenty clicks the two
///   numbers agreed to within **0.2 ms**. `NSTableView.mouseDown` runs its own event-tracking loop,
///   so a block enqueued from inside it cannot run until that loop exits — which is when the button
///   comes up. Where the stamp is taken makes no difference; the interval is bounded below by the
///   hold.
///
/// The common flaw is that both hang their clock off an INPUT EVENT. This one does not know
/// events exist. A run-loop observer fires on the way into the wait (`beforeWaiting`) and on the
/// way out of it (`afterWaiting`); the span between waking and going back to sleep is, by
/// definition, main-thread work. Nothing a finger does can inflate it, because a held button is the
/// run loop *waiting*.
///
/// Only turns over `threshold` are reported — a hitch is what the user feels, and logging every
/// turn would bury the log the way the scroll trace nearly did.
///
/// **The turn ends at the LAST end-of-turn observer, not the first.** Core Animation's commit
/// observer sits at order 2,000,000 in the same `beforeWaiting`/`exit` phase, and the layout and
/// drawing a commit flushes run inside it. An order-0 end closed the turn before any of that, so
/// it counted as idle. Both edges are observed: order 0 marks where the turn's own work stopped,
/// the highest order closes it, and each `[hitch]` line gives both spans.
///
/// A stall long enough to want a stack is `MainThreadStallWatch`'s job, not this type's: this
/// reports only after a turn ends, which a wedged turn never does.
@MainActor
public enum MainThreadHitchMonitor {
    /// Turns longer than this earn their own line. One frame at 60 Hz.
    ///
    /// It started at 50ms — three dropped frames — on the reasoning that a hitch is what the user
    /// feels. That reasoning was wrong in a way worth recording: a spike threshold is **blind to
    /// sustained load**. Switching tabs, opening the customize sheet and opening Settings were all
    /// reported as slow while this logged *nothing at all*, because forty consecutive 40ms turns
    /// look exactly like an idle app to a 50ms trigger, and feel exactly like a 1.6s stall to a
    /// person. `busyReportInterval` below is what actually catches that shape; this now only names
    /// the individual offenders within it.
    static let threshold: CFTimeInterval = 0.016

    /// How often the duty-cycle line is emitted while the main thread is doing anything.
    ///
    /// This is the measurement that matters for "everything is mostly slow": not how long the
    /// worst turn was, but what FRACTION of wall-clock time the main thread spent busy. An idle app
    /// reports nothing; a responsive one a few percent; an app that feels sluggish will sit high
    /// for the whole length of a transition, which is precisely the signature no single-turn
    /// threshold can see.
    static let busyReportInterval: CFTimeInterval = 1.0

    /// Below this duty cycle the second is not worth a line — normal idling and the odd stray
    /// timer, which would otherwise emit one line per second forever.
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
    /// When the current turn started. `nil` while the run loop is asleep, which is the state that
    /// makes this immune to hold time: a pressed button with nothing happening is a sleeping run
    /// loop, and a sleeping run loop is not timed.
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

    /// Arms the monitor when the diagnostic flag is set, and does nothing otherwise.
    ///
    /// The public entry point, and the gate lives HERE rather than at the call site so that
    /// `PaneScrollTrace` — which owns the flag and the reasons it is off by default — stays
    /// internal to this module. The app only has to say "if you are meant to be watching, watch".
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
        // `.commonModes`, not `.defaultMode`: the modal tracking loops this exists to see through —
        // `NSTableView`'s mouse tracking above all — run in their own mode, and an observer
        // registered only for the default mode would go quiet during exactly the work being hunted.
        observer = obs
        // .debug like every [hitch] line it announces: at Info level "armed" followed by silence
        // read as a healthy main thread while the hitch reports were being level-dropped.
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

    /// The rule, separated from the run loop so it can be driven directly in tests — the whole
    /// point of this type is that its timing is honest, and a suite that could not feed it a
    /// synthetic sequence of activities would be taking that on faith.
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

    /// Folds one finished turn into the duty-cycle window, and closes the window when it is full.
    ///
    /// EVERY turn is counted here, including the sub-threshold ones — they are the whole point.
    /// The window is closed on the first turn to finish after the interval elapses rather than on a
    /// timer, so the reporting itself never wakes an idle main thread: an app doing nothing emits
    /// nothing, and the last partial window before a quiet spell is simply carried into the next
    /// busy one.
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
        let app = NSApp
        let active = app?.isActive ?? false
        let visible = app?.windows.contains { $0.occlusionState.contains(.visible) } ?? false
        return "app \(active ? "active" : "inactive"), \(visible ? "window visible" : "every window occluded")"
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
