import Foundation

/// The copy on Compare's not-scanned empty state, the card the workspace opens on. Compare can't
/// restore its rows (every action on one writes files), but it can say when it last scanned
/// instead of claiming it never has.
///
/// Uses ``ScanFreshness``'s buckets in their words form (``ScanFreshness/spokenRelative(_:)``):
/// in a sentence, "3d ago" reads as shorthand and as "3 d" to VoiceOver. Takes loose values, not
/// the `Sync` summary type, because `Design` sits under `Sync`.
public enum ComparePrompt {

    /// No usable summary: nothing was ever scanned, or the last scan was of a different pair of
    /// folders than the panes show now.
    public static let neverScanned =
        "Nothing scanned yet. Scan the two focused folders to see what differs."

    /// `"Last scanned 3 days ago — 412 differences. Scan again to see what has changed since."`
    ///
    /// Past tense throughout, beside a Scan button: nothing here may read as a statement about the
    /// folders now. The count is what the last scan found; the second sentence says things may
    /// have changed since.
    public static func lastScan(differenceCount: Int, date: Date, now: Date) -> String {
        let age = ScanFreshness.spokenRelative(max(0, now.timeIntervalSince(date)))
        let found: String
        switch differenceCount {
        case 0: found = "no differences"
        case 1: found = "1 difference"
        default: found = "\(differenceCount.formatted()) differences"
        }
        return "Last scanned \(age) — \(found). Scan again to see what has changed since."
    }
}
