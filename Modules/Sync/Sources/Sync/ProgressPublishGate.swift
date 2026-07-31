import Foundation

/// Decides which per-item progress updates are worth publishing to the UI.
///
/// **Why a gate at all.** The bulk operations report completion once per file, and each report
/// used to write a `@Published` property on `FileSyncManager`. Every write to any of that
/// manager's published properties re-evaluates the body of the window's root view — which builds
/// both file panes, the differences pane and the inspector — so a 500-file copy asked the whole
/// window to re-render five hundred times, for a counter whose displayed value is a fraction and a
/// progress bar a few hundred pixels wide.
///
/// **Percent, not time.** A whole-percent gate caps the traffic at ~101 updates for a run of any
/// size, and it does so *deterministically*: no clock, no timer, nothing for a test to race. That
/// last part is the reason it is not an interval — a gate keyed on elapsed time can only be tested
/// against a clock seam, and a test racing a real-time window is the flakiness this codebase has
/// paid for before. Small runs are unaffected: with twenty items the percent moves five points per
/// file, so every one of them still publishes.
///
/// The gate never suppresses an update the user would notice missing: the first report and the
/// terminal one (`completed >= total`) always pass, so a run always starts at its true position
/// and always lands on 100%.
///
/// Out-of-order reports are tolerated rather than corrected. The workers complete in parallel and
/// hop to the main actor to report, so a lower `completed` can arrive after a higher one; the gate
/// compares against the percent it last *published* and lets such a report through, which is the
/// same brief backwards step the ungated code already showed.
public struct ProgressPublishGate: Equatable, Sendable {
    /// The percentage most recently allowed through, or nil before the first report.
    public private(set) var lastPublishedPercent: Int?

    public init() {}

    /// Whether this report should be published, updating the gate when it is.
    ///
    /// - Parameters:
    ///   - completed: Items finished so far.
    ///   - total: Items in the run. A non-positive total is degenerate — the caller has no
    ///     denominator to render a fraction against — so every report passes rather than being
    ///     silently swallowed by a division the gate cannot do.
    public mutating func admits(completed: Int, total: Int) -> Bool {
        guard total > 0 else { return true }
        guard completed < total else {
            lastPublishedPercent = 100
            return true
        }
        let percent = max(0, completed) * 100 / total
        guard percent != lastPublishedPercent else { return false }
        lastPublishedPercent = percent
        return true
    }
}

/// A `ProgressPublishGate` a `@Sendable` reporting closure can carry into a parallel run.
///
/// The gate itself is a value so its rule can be tested without any of this; the box exists only
/// because the closure that consults it (`reportCompleted`) is `@escaping @Sendable` and shared by
/// every worker. `@unchecked` for the same reason `ProgressRef` is: the closure is invoked
/// exclusively from `MainActor.run`, so the mutation is serialized by the main actor even though
/// the type cannot express that.
public final class ProgressPublishGateBox: @unchecked Sendable {
    private var gate = ProgressPublishGate()

    public init() {}

    /// See `ProgressPublishGate.admits(completed:total:)`. Call only from the main actor.
    public func admits(completed: Int, total: Int) -> Bool {
        gate.admits(completed: completed, total: total)
    }
}
