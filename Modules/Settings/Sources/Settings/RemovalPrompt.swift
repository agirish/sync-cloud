import Design
import Foundation

/// What Settings asks before a control throws away something one click cannot bring back (HR).
///
/// **Five controls did it on one click**: a folder source's Remove, the ignored items' and the kept
/// names' Clear All, the saved suggestions' Clear, and choosing "All columns" for column widths.
/// None of them touches the user's files. Four forget choices made by hand, which come back only
/// by making them again; the saved suggestions come back on their own, but the next Refine pays
/// Claude again for every file to get them. Reset Setup, Reset All Settings and Clear Log already
/// asked; these ask the same way.
///
/// The words live here, beside one another, so the five read as one voice; each control's gate is
/// beside the control. Public so a control outside Settings — an Ask Claude card (TE290) — asks
/// in the same words; of the gates, only Column widths' (`ColumnResizeChoice`) is public so far.
public struct RemovalPrompt: Equatable, Sendable {
    public let messageText: String
    public let informativeText: String
    public let confirmTitle: String

    /// The standard alert: Cancel is the default, and the destructive button takes no Return key —
    /// the same alert Reset All Settings… and Clear Log ask with.
    @MainActor public func ask() -> Bool {
        NativeAlerts.confirmIrreversible(messageText: messageText,
                                         informativeText: informativeText,
                                         confirmTitle: confirmTitle)
    }

    /// Ask, and only then act. Taking the confirmer is what makes the decision reachable from a
    /// test — a button's closure is not — and keeps a control from acting by forgetting to ask.
    /// - Returns: Whether `act` ran.
    @discardableResult
    public static func actIfConfirmed(confirm: () -> Bool, act: () -> Void) -> Bool {
        guard confirm() else { return false }
        act()
        return true
    }

    // MARK: The five questions

    /// Sources ▸ a folder source ▸ Remove.
    public static func removeFolderSource(named name: String) -> RemovalPrompt {
        RemovalPrompt(
            messageText: "Remove “\(name)” from your sources?",
            informativeText: "SyncCloud stops showing this folder and forgets any name you gave it, "
                + "where it opens, whether it was switched off, and what you ignored while comparing "
                + "it. Adding the folder again starts it afresh. The folder and its files stay where "
                + "they are.",
            confirmTitle: "Remove")
    }

    /// Sync ▸ Ignored items ▸ Clear All.
    public static func clearIgnoredItems(count: Int) -> RemovalPrompt {
        RemovalPrompt(
            messageText: count == 1 ? "Stop ignoring 1 item?"
                : "Stop ignoring all \(count.formatted()) items?",
            informativeText: "Everything you ignored for the folders you’re comparing comes back in "
                + "Differences, until you ignore it again. Your files aren’t affected.",
            confirmTitle: "Clear All")
    }

    /// Organize ▸ Kept names ▸ Clear All.
    public static func clearKeptNames(count: Int) -> RemovalPrompt {
        RemovalPrompt(
            messageText: count == 1 ? "Stop keeping 1 name?"
                : "Stop keeping all \(count.formatted()) names?",
            informativeText: "SyncCloud flags each of these names again — on its row at once, and in "
                + "Organize from the next scan — until you choose Always Allow This Name for it "
                + "again. No file is renamed.",
            confirmTitle: "Clear All")
    }

    /// Intelligence ▸ Saved suggestions ▸ Clear. Says the cost, because that is the part of this
    /// clear nobody would guess: the next Refine pays Claude again for every file.
    public static func clearSavedSuggestions(count: Int) -> RemovalPrompt {
        RemovalPrompt(
            messageText: count == 1 ? "Clear 1 saved suggestion?"
                : "Clear \(count.formatted()) saved suggestions?",
            informativeText: "The next scan asks the on-device model about every file again, and "
                + "the next Refine sends every file to Claude again — and pays for each one. Your "
                + "files aren’t affected.",
            confirmTitle: "Clear Suggestions")
    }

    /// Readability ▸ Column widths ▸ All columns, when some columns were sized on their own.
    public static func releaseColumnWidths(count: Int) -> RemovalPrompt {
        RemovalPrompt(
            messageText: "Put every column back to one width?",
            informativeText: count == 1
                ? "The column you sized on its own goes back to the width every column shares. "
                    + "Choosing Each column again doesn’t bring its width back."
                : "The \(count.formatted()) columns you sized on their own go back to the width every column "
                    + "shares. Choosing Each column again doesn’t bring their widths back.",
            confirmTitle: "Use All Columns")
    }
}
