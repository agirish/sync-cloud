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

    /// Coarse, glanceable buckets — "just now", minutes, hours, days. Deliberately not second-precise
    /// (the pill answers "is this fresh?", not "exactly how old?").
    ///
    /// Units FLOOR rather than round, so "N <unit> ago" always means at least N of that unit has
    /// elapsed and a label can never contradict the next coarser one. Rounding produced seam
    /// artifacts: "Scanned 60m ago" at 3570–3599s (an hour that isn't "1h"), "24h ago" just shy of
    /// a day, and a "1m → 2m" jump at 89→90s when only 1.5 minutes had passed.
    static func relative(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        switch s {
        case ..<45: return "just now"
        case ..<120: return "1m ago"
        case ..<3600: return "\(s / 60)m ago"           // 2m…59m; never "60m"
        case ..<7200: return "1h ago"
        case ..<86_400: return "\(s / 3600)h ago"       // 2h…23h; never "24h"
        default:
            let days = s / 86_400
            return days <= 1 ? "1 day ago" : "\(days) days ago"
        }
    }
}
