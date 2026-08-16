import Foundation

/// How the filing artifacts date themselves.
///
/// `folder-profile.json` and `filing-memory.json` are companions: they land in the same profile
/// directory, they get opened side by side when a suggestion looks wrong, and the first thing a
/// reader does with two of them is line up their `generated` headers. That only works while both
/// spell an instant the same way, so the format lives in one place instead of two.
///
/// It was two — ``FilingProfileStore`` and ``FilingSurveyStore`` each carried a private copy, and
/// the argument for that was that six lines of frozen format string are cheaper to duplicate than
/// to share. The cost is not the six lines, it is that nothing fails when one copy changes: adding
/// fractional seconds or moving to `ISO8601DateFormatter` on one side leaves the two artifacts
/// dated in different formats, with no test comparing them and no reader expecting it.
///
/// The format itself is frozen by the offline Python builder, whose output these files have to stay
/// interchangeable with: local time, no zone suffix, seconds resolution.
enum FilingArtifactStamp {

    /// `date` as the artifacts write it — `2026-08-16T09:41:07`.
    ///
    /// `en_US_POSIX` so a user's regional calendar cannot reach the digits, and `.current` because
    /// the offline builder stamps local time and these files are read by the person whose machine
    /// made them. The caller injects the instant rather than this reading a clock —
    /// `docs/flaky-tests.md` mechanism 5.
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
}
