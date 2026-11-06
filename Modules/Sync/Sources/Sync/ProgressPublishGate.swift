import Foundation

/// Decides which per-item progress updates are worth publishing to the UI. Each write to a
/// `FileSyncManager` published property re-renders the whole window, so a per-file report would
/// redraw it once per file.
///
/// The gate passes a report only when the whole percent changes, capping a run at ~101 updates.
/// Percent, not time, so it is deterministic: no clock for a test to race. Small runs still publish
/// every item. The first report and the terminal one (`completed >= total`) always pass, so a run
/// starts at its true position and ends on 100%.
///
/// Workers report in parallel, so a lower `completed` can arrive after a higher one. The gate
/// compares against the percent it last published and lets it through: a brief backwards step.
public struct ProgressPublishGate: Equatable, Sendable {
    /// The percentage most recently allowed through, or nil before the first report.
    public private(set) var lastPublishedPercent: Int?

    public init() {}

    /// Whether this report should be published, updating the gate when it is.
    ///
    /// - Parameters:
    ///   - completed: Items finished so far.
    ///   - total: Items in the run. A non-positive total has no denominator, so every report passes
    ///     rather than being swallowed.
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

/// A `ProgressPublishGate` a `@Sendable` reporting closure can carry into a parallel run. The
/// closure (`reportCompleted`) is shared by every worker. `@unchecked`, as `ProgressRef` is: the
/// closure runs only inside `MainActor.run`, so the main actor serializes the mutation.
public final class ProgressPublishGateBox: @unchecked Sendable {
    private var gate = ProgressPublishGate()

    public init() {}

    /// See `ProgressPublishGate.admits(completed:total:)`. Call only from the main actor.
    public func admits(completed: Int, total: Int) -> Bool {
        gate.admits(completed: completed, total: total)
    }
}
