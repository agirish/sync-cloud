import Foundation

/// Runs an action once a stream of activity has stopped for `quiescence`, without arming a timer
/// per activity report.
///
/// The pane scroll watchdogs (`PaneColumnsOverscrollReturn`, `PaneColumnJitterProbe`) watch state,
/// not gesture phases, which nested scroll views lose: each bounds change, at frame cadence per
/// scroll view, restarts the wait. Here activity is only a timestamp, and a timer is armed only
/// when none is pending; when it fires early it re-arms for the remainder. The action still runs
/// exactly `quiescence` after the last report, arming once per window rather than once per frame.
///
/// The clock and scheduler are injected so tests drive the rule directly instead of racing a real
/// 0.14s window.
@MainActor
final class QuiescenceTimer {
    /// How long the activity stream must be silent before `action` runs.
    let quiescence: TimeInterval

    /// A hair of slack on the idle test, and the floor on a re-arm's delay. In floating point a
    /// timer landing exactly on its deadline can read a few hundred nanoseconds short and re-arm
    /// for that sliver. A millisecond is far below the watchdogs' 0.14s window.
    private static let slack: TimeInterval = 0.001

    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// Whether a timer is in flight. While it is, further activity costs only a timestamp write.
    private(set) var isPending = false
    private var lastActivityAt: TimeInterval = 0
    private var action: (() -> Void)?

    init(
        quiescence: TimeInterval,
        now: @escaping () -> TimeInterval = { CFAbsoluteTimeGetCurrent() },
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
        }
    ) {
        self.quiescence = quiescence
        self.now = now
        self.schedule = schedule
    }

    /// Records one unit of activity and arms the check if none is pending. The most recent
    /// caller's `action` is the one that runs, because the watchdogs re-resolve what they guard as
    /// SwiftUI rebuilds the view tree.
    func noteActivity(then action: @escaping () -> Void) {
        self.action = action
        lastActivityAt = now()
        guard !isPending else { return }
        arm(after: quiescence)
    }

    /// Cancels any pending run and forgets the action — for a view leaving its window.
    func cancel() {
        action = nil
        // `isPending` stays true until the scheduled block runs and finds a nil action. Clearing
        // it here would let the next `noteActivity` arm a second timer.
    }

    private func arm(after delay: TimeInterval) {
        isPending = true
        schedule(delay) { [weak self] in
            guard let self else { return }
            self.isPending = false
            guard let action = self.action else { return }
            let idle = self.now() - self.lastActivityAt
            guard idle >= self.quiescence - Self.slack else {
                // Something moved while this timer was in flight: wait out the remainder. A
                // watchdog that corrects mid-gesture fights the platform's own scrolling.
                self.arm(after: max(self.quiescence - idle, Self.slack))
                return
            }
            action()
        }
    }
}
