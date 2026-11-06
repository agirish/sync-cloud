import Foundation

/// How the filing artifacts date themselves. `folder-profile.json` and `filing-memory.json` sit
/// side by side and are read by lining up their `generated` headers, so both must spell an instant
/// the same way, and the format lives here once: a second copy could drift with nothing failing.
/// The format is frozen by the offline Python builder, whose output these files must stay
/// interchangeable with: local time, no zone suffix, seconds resolution.
public enum FilingArtifactStamp {

    /// `date` as the artifacts write it: `2026-08-16T09:41:07`. `en_US_POSIX` so a regional
    /// calendar can't reach the digits; `.current` because the builder stamps local time. The
    /// caller injects the instant rather than this reading a clock (`docs/flaky-tests.md`, "Tests
    /// racing a real-time window"). Public so FileExplorer's agreement test can round-trip a stamp
    /// this writer produced.
    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// The stamp read back as an instant, nil for anything not exactly the format above. Lets the
    /// app say "surveyed 3 days ago" from the corpus's `surveyedAt`. Local time both ways: the
    /// files are read on the machine that wrote them.
    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }
}
