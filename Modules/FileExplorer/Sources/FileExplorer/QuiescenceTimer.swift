import Foundation

/// Runs an action once a stream of activity has stopped for `quiescence` — without arming a timer
/// per activity report.
///
/// **The problem it replaces.** Both pane scroll watchdogs — the column stack's
/// `PaneColumnsOverscrollReturn` and each column's own `PaneColumnJitterProbe` — work by watching
/// STATE rather than signals: every bounds change re-arms a short timer, and the correction runs
/// only once the list has come to rest. That design is deliberate and stays (a gesture forwarded
/// between nested scroll views loses its phase, so "the gesture ended" is not a signal either of
/// them can trust). What it cost was the re-arming: each one cancelled its pending `DispatchWorkItem`
/// and allocated and scheduled a fresh one on EVERY bounds-change notification. Those arrive at
/// frame cadence, per scroll view — a pane with three columns open runs four of these — so a
/// two-second scroll allocated and scheduled on the order of a thousand work items to answer one
/// question at the end of it.
///
/// **The fix.** Activity is recorded as a timestamp; a timer is armed only when none is pending.
/// When it fires it checks how long the stream has actually been idle, and if something moved while
/// it waited it re-arms for the remainder instead of running early. The action therefore still runs
/// exactly `quiescence` after the LAST report — the same guarantee the cancel-and-reallocate version
/// gave — while arming once per quiescence window rather than once per frame.
///
/// The clock and the scheduler are both injected so the rule can be driven directly in tests. That
/// is not decoration: a test that waits on a real 0.14s window to prove a timer coalesced is a test
/// racing a real-time window, which is the shape of flakiness this codebase has already paid for.
@MainActor
final class QuiescenceTimer {
    /// How long the activity stream must be silent before `action` runs.
    let quiescence: TimeInterval

    /// A hair of slack on the idle test, and the floor on a re-arm's delay.
    ///
    /// The deadline is compared against a real clock in floating point, so "exactly `quiescence`
    /// has elapsed" is not a quantity that reliably compares `>=` — a timer landing precisely on
    /// its deadline reads as a few hundred nanoseconds short, re-arms for that sliver, and runs a
    /// scheduler round-trip later. Harmless, but it is a spurious arm on the one path this type
    /// exists to keep cheap, and it makes the rule impossible to state exactly in a test. A
    /// millisecond is three orders of magnitude below the watchdogs' own 0.14s window.
    private static let slack: TimeInterval = 0.001

    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// Whether a timer is in flight. The whole point: while this is true, further activity costs a
    /// timestamp write and nothing else.
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

    /// Records one unit of activity and (re)arms the check.
    ///
    /// `action` is stored rather than captured once at init because the watchdogs re-resolve what
    /// they are guarding as SwiftUI rebuilds the view tree under them; the most recent caller's
    /// closure is the one that runs.
    func noteActivity(then action: @escaping () -> Void) {
        self.action = action
        lastActivityAt = now()
        guard !isPending else { return }
        arm(after: quiescence)
    }

    /// Cancels any pending run and forgets the action — for a view leaving its window.
    func cancel() {
        action = nil
        // `isPending` stays true until the scheduled block runs; it finds a nil action and stops.
        // Nothing is gained by trying to un-schedule it, and a flag that lied about a live timer
        // would let the next `noteActivity` arm a second one.
    }

    private func arm(after delay: TimeInterval) {
        isPending = true
        schedule(delay) { [weak self] in
            guard let self else { return }
            self.isPending = false
            guard let action = self.action else { return }
            let idle = self.now() - self.lastActivityAt
            guard idle >= self.quiescence - Self.slack else {
                // Something moved while this timer was in flight. Wait out the remainder rather
                // than running early — running early is exactly what the cancel-and-reallocate
                // version existed to prevent, and a watchdog that corrects mid-gesture fights the
                // platform on the paths the platform handles.
                self.arm(after: max(self.quiescence - idle, Self.slack))
                return
            }
            action()
        }
    }
}
