import Foundation

/// Pure relative-age text + stale flag for the pane header's "Scanned N ago" pill, kept out of the
/// view so the buckets and the stale threshold are unit-testable.
enum ScanFreshness {
    /// Past this age the pill turns amber — the diff you're looking at may no longer match disk.
    static let staleAfter: TimeInterval = 10 * 60 // 10 minutes

    struct Result: Equatable {
        let text: String
        let isStale: Bool
    }

    static func describe(scanDate: Date, now: Date, staleAfter: TimeInterval = staleAfter) -> Result {
        let elapsed = max(0, now.timeIntervalSince(scanDate))
        return Result(text: "Scanned \(relative(elapsed))", isStale: elapsed >= staleAfter)
    }

    /// Coarse, glanceable buckets — half a minute, minutes, hours, days. Deliberately not
    /// second-precise (the badge answers "is this fresh?", not "exactly how old?"), and the two
    /// sub-minute steps exist only because they cost nothing: the view ticks every 30s anyway.
    ///
    /// Units FLOOR rather than round, so "N <unit> ago" always means at least N of that unit has
    /// elapsed and a label can never contradict the next coarser one. Rounding produced seam
    /// artifacts: "Scanned 60m ago" at 3570–3599s (an hour that isn't "1h"), "24h ago" just shy of
    /// a day, and a "1m → 2m" jump at 89→90s when only 1.5 minutes had passed.
    ///
    /// The old ladder BROKE that invariant at its very first step: "just now" spanned 0–44s and
    /// "1m ago" began at 45s, claiming a minute that had not elapsed. The 0s/30s steps below
    /// replace it, so 1m now starts at a genuine 60s. Everything from 120s up is unchanged —
    /// `s / 60` already covered 1m–59m and `s / 3600` already covered 1h–23h, so the explicit
    /// `..<120` and `..<7200` cases were redundant restatements and are gone.
    static func relative(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        switch s {
        case ..<30: return "0s ago"
        case ..<60: return "30s ago"
        case ..<3600: return "\(s / 60)m ago"           // 1m…59m; never "60m"
        case ..<86_400: return "\(s / 3600)h ago"       // 1h…23h; never "24h"
        default:
            let days = s / 86_400
            return days <= 1 ? "1 day ago" : "\(days) days ago"
        }
    }
}
