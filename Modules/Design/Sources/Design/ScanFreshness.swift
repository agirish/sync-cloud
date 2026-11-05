import Foundation

/// Relative-age text and a stale flag for the "Scanned N ago" readout on the differences count
/// pill, kept out of the view so the buckets and the stale threshold are unit-testable.
///
/// It lives in Design because the readout is composed in FileExplorer, which can't see Dashboard,
/// and Design also holds the `.attention` family that colours a stale scan.
public enum ScanFreshness {
    /// Past this age the pill's age run turns terracotta: the diff on screen may no longer match
    /// disk. The capsule around it doesn't change; see `DifferencesView.countPillDressing`.
    ///
    /// One hour: the app is left open for hours, so a shorter threshold would keep the warning on
    /// almost all the time, and a warning that is always on is furniture. An hour clears an
    /// ordinary working session yet still flags a diff from before lunch.
    ///
    /// Independent of `relative()`'s display buckets: `describe` takes the age from the buckets and
    /// the flag from this constant, so changing this never touches them.
    public static let staleAfter: TimeInterval = 60 * 60 // 1 hour

    public struct Result: Equatable, Sendable {
        /// The full sentence, "Scanned 29m ago": what the tooltip and the all-in-sync empty state
        /// say, where there is room for a subject.
        public let text: String
        /// The bare age, "29m ago", for inside the count pill, whose own label ("576 Differences")
        /// is already the subject.
        public let age: String
        /// The age in words, "29 minutes ago", for VoiceOver, which can read "29m" as metres. Same
        /// buckets as `age`, so the eye and the ear never disagree.
        public let spokenAge: String
        /// Past `staleAfter`, or changed on disk since the scan: either way the listing may no
        /// longer match the disk, and the readout says so in the same terracotta.
        public let isStale: Bool
        /// The folder watcher saw a change after this scan began. The age alone can't say so (a
        /// two-minute-old scan of a folder that changed a minute ago reads "2m ago"), so it has its
        /// own words in `text` and `spoken`.
        public var changedOnDisk: Bool = false

        /// What VoiceOver hears in the age run's place, and the one place staleness is put into
        /// words.
        ///
        /// The age reads the same fresh or stale, and every other channel for the state is visual
        /// or silent: the terracotta is colour, and `.help` isn't announced. Colour must not be a
        /// warning's only carrier, so the spoken form says it outright. Derived here, not at the
        /// call site, so the fresh and stale phrasings can't drift apart.
        public var spoken: String {
            if changedOnDisk { return "scanned \(spokenAge), changed on disk since" }
            return isStale ? "scanned \(spokenAge), may be out of date" : "scanned \(spokenAge)"
        }
    }

    /// - Parameter changedOnDisk: the folder watcher saw a change since the scan began. It only
    ///   ever adds: it can make a fresh scan stale, never an old one fresh, because a watcher that
    ///   misses a change (an idle Mac's iCloud, a Dropbox app that isn't running) must leave the
    ///   clock's warning standing.
    public static func describe(scanDate: Date, now: Date, staleAfter: TimeInterval = staleAfter,
                                changedOnDisk: Bool = false) -> Result {
        let elapsed = max(0, now.timeIntervalSince(scanDate))
        let age = relative(elapsed)
        return Result(text: changedOnDisk ? "Scanned \(age), changed since" : "Scanned \(age)",
                      age: age, spokenAge: spokenRelative(elapsed),
                      isStale: elapsed >= staleAfter || changedOnDisk, changedOnDisk: changedOnDisk)
    }

    /// The tooltip's timestamp: the time alone while the scan is from today, with the date once it
    /// isn't. It takes `now` rather than reading the clock, so `ScanFreshnessSchedule` can promise
    /// the stamp changes only at the midnight it ticks on.
    public static func stamp(scanDate: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(scanDate, inSameDayAs: now)
            ? scanDate.formatted(date: .omitted, time: .standard)
            : scanDate.formatted(date: .abbreviated, time: .standard)
    }

    /// Coarse, glanceable buckets: half a minute, minutes, hours, days. Not second-precise, since
    /// the badge answers "is this fresh?", and the two sub-minute steps cost one tick each: the
    /// view ticks only where a label changes (`ScanFreshnessSchedule`).
    ///
    /// Units floor rather than round, so "N <unit> ago" always means at least N of that unit has
    /// passed and a label never contradicts the next coarser one; rounding would show "60m ago"
    /// just short of an hour. "just now" covers only 0–29s, claiming no amount of time, then "30s
    /// ago", so "1m" starts at a genuine 60s. Days are compact too: "1d ago" follows "23h ago".
    public static func relative(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        switch s {
        case ..<30: return "just now"
        case ..<60: return "30s ago"
        case ..<3600: return "\(s / 60)m ago"           // 1m…59m; never "60m"
        case ..<86_400: return "\(s / 3600)h ago"       // 1h…23h; never "24h"
        default: return "\(s / 86_400)d ago"
        }
    }

    /// `relative`'s buckets in words, for VoiceOver: "just now", "30 seconds ago", "1 minute ago",
    /// "29 minutes ago", "2 hours ago", "3 days ago".
    ///
    /// Also the form for prose: inside a sentence (Compare's "Last scanned …", the divergence
    /// overlay's "written …") the compact "3d ago" reads as a fragment and VoiceOver says "3 d".
    public static func spokenRelative(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        func ago(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        switch s {
        case ..<30: return "just now"
        case ..<60: return ago(30, "second")
        case ..<3600: return ago(s / 60, "minute")
        case ..<86_400: return ago(s / 3600, "hour")
        default: return ago(s / 86_400, "day")
        }
    }
}
