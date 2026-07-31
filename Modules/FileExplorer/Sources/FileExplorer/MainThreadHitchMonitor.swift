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
    /// When the current turn started. `nil` while the run loop is asleep, which is the state that
    /// makes this immune to hold time: a pressed button with nothing happening is a sleeping run
    /// loop, and a sleeping run loop is not timed.
    private static var turnBegan: CFTimeInterval?

    /// Longest turn seen since the last `reset()`, and the running total — so a session can be
    /// summarized rather than read line by line.
    private(set) static var worst: CFTimeInterval = 0
    private(set) static var hitchCount = 0
    private(set) static var totalHitchTime: CFTimeInterval = 0

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
            MainActor.assumeIsolated { _ = note(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        // `.commonModes`, not `.defaultMode`: the modal tracking loops this exists to see through —
        // `NSTableView`'s mouse tracking above all — run in their own mode, and an observer
        // registered only for the default mode would go quiet during exactly the work being hunted.
        observer = obs
        Logger.shared.info("[hitch] monitor armed (threshold \(Int(threshold * 1000))ms)")
    }

    static func stop() {
        guard let observer else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = nil
        turnBegan = nil
    }

    /// The rule, separated from the run loop so it can be driven directly in tests — the whole
    /// point of this type is that its timing is honest, and a suite that could not feed it a
    /// synthetic sequence of activities would be taking that on faith.
    ///
    /// - Returns: the hitch duration when this activity ended a turn that exceeded `threshold`.
    @discardableResult
    static func note(_ activity: CFRunLoopActivity, at now: CFTimeInterval = CACurrentMediaTimeShim()) -> CFTimeInterval? {
        switch activity {
        case .afterWaiting:
            // Woke up: a turn begins.
            turnBegan = now
            return nil
        case .beforeWaiting, .exit:
            // About to sleep: the turn is over, and everything since waking was work.
            guard let began = turnBegan else { return nil }
            turnBegan = nil
            let elapsed = now - began
            accumulate(elapsed, at: now)
            guard elapsed >= threshold else { return nil }
            hitchCount += 1
            totalHitchTime += elapsed
            worst = max(worst, elapsed)
            Logger.shared.debug(String(format: "[hitch] main thread busy %.1fms", elapsed * 1000))
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

    static func reset() {
        worst = 0
        hitchCount = 0
        totalHitchTime = 0
        turnBegan = nil
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
