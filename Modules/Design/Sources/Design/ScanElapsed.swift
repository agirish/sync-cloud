import Foundation

/// How long the running scan has been going, as a line under the busy state's title.
///
/// The sibling of ``ScanFreshness``, which answers the same question about a scan that has already
/// *finished* — and deliberately not the same function. Freshness is glanceable and coarse ("29m
/// ago") because it answers "is this fresh?"; this reads while the user is waiting, so it counts
/// seconds and never floors them away. A scan that ran for 12 seconds must say 12, not "0s".
///
/// This is the whole of the Compare scan's progress reporting, and the reason is worth keeping
/// beside it: there is no fraction to report. `FileDiffEngine.getFilesInDirectory` counts nothing
/// as it walks, so a percentage would need a per-entry callback in the app's hottest loop plus a
/// main-actor hop to publish from — in a function whose own comments record two rounds of
/// performance work. Elapsed time costs a timer and cannot be wrong.
public enum ScanElapsed {

    /// `"12s"`, `"1m 04s"`, `"11m 09s"`. Never negative — a clock change mid-scan would otherwise
    /// produce a count-up that starts below zero.
    ///
    /// Minutes carry **zero-padded** seconds so the string's width stops changing every second;
    /// the label is `monospacedDigit`, so with padding it is the one width for a whole minute
    /// rather than nudging its neighbours twice a second. Under a minute there is no padding,
    /// because "05s" for the first ten seconds of every scan reads like a stopwatch that has not
    /// started.
    ///
    /// Hours are deliberately absent. A Compare scan that has run for an hour is a fault, not a
    /// long job, and `"73m 20s"` says that more plainly than `"1h 13m"` — which reads like a
    /// progress bar that expects to finish.
    public static func text(since start: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(start)))
        guard seconds >= 60 else { return "\(seconds)s" }
        return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }
}
