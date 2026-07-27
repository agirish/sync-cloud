import Foundation

/// Pure relative-age text + stale flag for the "Scanned N ago" readout on the differences
/// count pill, kept out of the view so the buckets and the stale threshold are unit-testable.
///
/// Lives in Design rather than beside its one caller: it used to sit in Dashboard next to the
/// pane-header badge it fed, and the readout it feeds now is composed in FileExplorer, which
/// cannot see Dashboard. Design is what both can see, and it is where the `.attention` family
/// that colours a stale scan already lives.
public enum ScanFreshness {
    /// Past this age the pill's AGE RUN turns terracotta — the diff you're looking at may no longer
    /// match disk. The capsule around it does not change; see `DifferencesView.countPillDressing`.
    ///
    /// One hour, up from ten minutes. Ten was tuned when freshness was a small badge in a pane
    /// header, and it did not survive the move onto the differences bar's most prominent control:
    /// this app gets left open for hours, so "older than ten minutes" was the state the pill was in
    /// almost all the time. A warning that is on almost always is furniture, not a warning. An hour
    /// is long enough that an ordinary working session never trips it and short enough that coming
    /// back to a diff from before lunch still says so.
    ///
    /// Independent of `relative()`'s display buckets: `describe` derives the age from the buckets
    /// and the flag from this constant separately, so moving this line never requires touching them.
    public static let staleAfter: TimeInterval = 60 * 60 // 1 hour

    public struct Result: Equatable, Sendable {
        /// The full sentence — "Scanned 29m ago". What the tooltip and the all-in-sync empty
        /// state say, where there is room for a subject.
        public let text: String
        /// The bare age — "29m ago". What rides inside the count pill, where the pill's own
        /// label ("576 Differences") is already the subject and repeating "Scanned" would make
        /// the capsule a sentence fragment about two different things.
        public let age: String
        public let isStale: Bool

        /// What VoiceOver is told in the age run's place — and the ONE place staleness is put
        /// into words.
        ///
        /// The age alone reads identically fresh or stale ("scanned 2h ago" is not a warning),
        /// and every other channel carrying the state is visual or silent: the run's terracotta
        /// capsule is colour, and `.help` is not announced. Colour as the sole carrier of a
        /// warning is exactly what the contrast work around this pill exists to avoid, so the
        /// spoken form says it outright.
        ///
        /// Derived here rather than composed at the call site so the fresh and stale phrasings
        /// cannot drift — they differ by one clause, which is the easiest kind of pair to let rot.
        public var spoken: String {
            isStale ? "scanned \(age), may be out of date" : "scanned \(age)"
        }
    }

    public static func describe(scanDate: Date, now: Date, staleAfter: TimeInterval = staleAfter) -> Result {
        let elapsed = max(0, now.timeIntervalSince(scanDate))
        let age = relative(elapsed)
        return Result(text: "Scanned \(age)", age: age, isStale: elapsed >= staleAfter)
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
    public static func relative(_ seconds: TimeInterval) -> String {
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
