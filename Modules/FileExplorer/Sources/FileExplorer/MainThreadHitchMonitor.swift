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
    /// Turns longer than this are worth a line. 50 ms is three dropped frames at 60 Hz — past the
    /// point where a click stops feeling attached to the pointer, and far enough above routine
    /// layout that the log stays readable.
    static let threshold: CFTimeInterval = 0.050

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

    static func reset() {
        worst = 0
        hitchCount = 0
        totalHitchTime = 0
        turnBegan = nil
    }
}

/// `CACurrentMediaTime()` without importing QuartzCore into this module — a monotonic clock, so it
/// cannot be moved by a system clock adjustment mid-measurement the way a wall clock can.
func CACurrentMediaTimeShim() -> CFTimeInterval {
    CFTimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}
