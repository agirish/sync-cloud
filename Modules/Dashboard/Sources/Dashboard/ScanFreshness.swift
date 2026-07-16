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
    static func relative(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        switch s {
        case ..<45: return "just now"
        case ..<90: return "1m ago"
        case ..<3600: return "\(Int((seconds / 60).rounded()))m ago"
        case ..<5400: return "1h ago"
        case ..<86_400: return "\(Int((seconds / 3600).rounded()))h ago"
        default:
            let days = Int((seconds / 86_400).rounded())
            return days <= 1 ? "1 day ago" : "\(days) days ago"
        }
    }
}
