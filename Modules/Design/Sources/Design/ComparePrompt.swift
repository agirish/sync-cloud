import Foundation

/// The copy on Compare's not-scanned empty state — the card the default workspace opens on.
///
/// Compare was the only workspace that opened cold. Duplicates and Organize re-run their scan on
/// open when it cannot cost money, Storage restores its report, and Compare said *"Nothing scanned
/// yet"* on every launch however many times it had been scanned. It cannot restore its rows — every
/// action it offers against one writes files — but it can stop pretending it has never run.
///
/// Lives beside ``ScanFreshness``, whose buckets it borrows, so the two ways this app says "how old
/// is this?" use one ladder. The summary itself is a `Sync` type; only the sentence is here, which
/// is why these take loose values rather than the struct — `Design` sits under `Sync`, not over it.
public enum ComparePrompt {

    /// No usable summary: either nothing has ever been scanned, or what was scanned was a
    /// different pair of folders than the panes are pointed at now.
    public static let neverScanned =
        "Nothing scanned yet. Scan the two focused folders to see what differs."

    /// `"Last scanned 3 days ago — 412 differences. Scan again to see what has changed since."`
    ///
    /// Past tense throughout, and the button beside it says Scan: nothing here may read as a
    /// statement about the folders *now*. The count is what the last scan found, and the sentence
    /// that follows exists to say the world has moved on since — which is the whole reason the rows
    /// themselves are not restored.
    public static func lastScan(differenceCount: Int, date: Date, now: Date) -> String {
        let age = ScanFreshness.relative(max(0, now.timeIntervalSince(date)))
        let found: String
        switch differenceCount {
        case 0: found = "no differences"
        case 1: found = "1 difference"
        default: found = "\(differenceCount) differences"
        }
        return "Last scanned \(age) — \(found). Scan again to see what has changed since."
    }
}
