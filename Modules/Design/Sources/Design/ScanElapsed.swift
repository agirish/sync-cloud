import Foundation

/// How long the running scan has been going, as a line under the busy state's title.
///
/// The sibling of ``ScanFreshness``, kept separate on purpose: freshness is coarse ("29m ago")
/// because it answers "is this fresh?", while this is read during the wait, so it counts seconds
/// and never floors them ("12s", not "0s").
///
/// It is the whole of the Compare scan's progress: `FileDiffEngine.getFilesInDirectory` counts
/// nothing as it walks, and a percentage would need a per-entry callback in the app's hottest loop.
/// Elapsed time costs a timer and can't be wrong.
public enum ScanElapsed {

    /// `"12s"`, `"1m 04s"`, `"11m 09s"`. Never negative, so a clock change mid-scan can't count up
    /// from below zero.
    ///
    /// Past a minute the seconds are zero-padded, so the `monospacedDigit` label keeps one width
    /// for the whole minute; under a minute they aren't, since "05s" reads like a stopwatch not yet
    /// started. No hours: a Compare scan that has run an hour is a fault, and `"73m 20s"` says so
    /// more plainly than `"1h 13m"`.
    public static func text(since start: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(start)))
        guard seconds >= 60 else { return "\(seconds)s" }
        return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }
}
