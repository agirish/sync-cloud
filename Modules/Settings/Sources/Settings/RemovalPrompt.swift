import Design
import Foundation

/// What Settings asks before a control throws away something one click can't bring back: a folder
/// source's Remove, the ignored items' and kept names' Clear All, the saved suggestions' Clear,
/// "All columns" for column widths, Hidden from Claude's Remove, Show Again for the groups kept
/// separate, and sharing a hidden folder without asking. None touches the user's
/// files. Most forget choices made by hand; saved suggestions return, but the next Refine pays
/// Claude again; Hidden from Claude's Remove widens what Claude may see. They ask as Reset Setup,
/// Reset All Settings and Clear Log do.
///
/// The words live here together so they read as one voice; each gate sits beside its control.
/// Public so a control outside Settings, such as an Ask Claude card, asks in the same words; of
/// the gates, only Column widths' (`ColumnResizeChoice`) is public so far.
public struct RemovalPrompt: Equatable, Sendable {
    public let messageText: String
    public let informativeText: String
    public let confirmTitle: String

    /// The standard alert: Cancel is the default, and the destructive button takes no Return key,
    /// as in Reset All Settings… and Clear Log.
    @MainActor public func ask() -> Bool {
        NativeAlerts.confirmIrreversible(messageText: messageText,
                                         informativeText: informativeText,
                                         confirmTitle: confirmTitle)
    }

    /// Ask, and only then act. Taking the confirmer lets a test reach the decision, and keeps a
    /// control from acting by forgetting to ask.
    /// - Returns: Whether `act` ran.
    @discardableResult
    public static func actIfConfirmed(confirm: () -> Bool, act: () -> Void) -> Bool {
        guard confirm() else { return false }
        act()
        return true
    }

    // MARK: The questions

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

    /// Intelligence ▸ Saved suggestions ▸ Clear. Says the cost nobody would guess: the next Refine
    /// pays Claude again for every file.
    public static func clearSavedSuggestions(count: Int) -> RemovalPrompt {
        RemovalPrompt(
            messageText: count == 1 ? "Clear 1 saved suggestion?"
                : "Clear \(count.formatted()) saved suggestions?",
            informativeText: "The next scan asks the on-device model about every file again, and "
                + "the next Refine sends every file to Claude again — and pays for each one. Your "
                + "files aren’t affected.",
            confirmTitle: "Clear Suggestions")
    }

    /// Intelligence ▸ Hidden from Claude ▸ Remove. Says what Claude sees again, because that is
    /// what a yes gives away, and how to take it back.
    public static func showToClaude(named name: String, isFolder: Bool) -> RemovalPrompt {
        RemovalPrompt(
            messageText: "Show “\(name)” to Claude again?",
            informativeText: (isFolder
                ? "Claude can see this folder again when you ask about it: its name, and the names, "
                    + "kinds, sizes and dates of what’s inside it. It can also ask this Mac to read "
                    + "its files. "
                : "Claude can see this file again when you ask about it: its name, kind, size and "
                    + "date. It can also ask this Mac to read it. ")
                + "To hide it again, use Add… here, or Hide from Claude on its right-click menu.",
            confirmTitle: "Show to Claude")
    }

    /// Organize ▸ Duplicates ▸ Groups kept separate ▸ Show Again….
    public static func showKeptSeparateAgain(count: Int) -> RemovalPrompt {
        RemovalPrompt(
            messageText: count == 1 ? "Show 1 group kept separate again?"
                : "Show all \(count.formatted()) groups kept separate again?",
            informativeText: "SyncCloud forgets that you kept them separate, in every folder, so the "
                + "next duplicate scan flags each one that is still a duplicate. Your files aren’t "
                + "affected.",
            confirmTitle: "Show Again")
    }

    /// Ask Claude ▸ Privacy ▸ Shared without asking ▸ Add…, for a folder that is hidden now.
    /// Hidden wins over shared, so sharing it takes the entries that hide it off Hidden from
    /// Claude; this says which, because a folder above it uncovers more than what was picked.
    /// - Parameters:
    ///   - name: The folder picked.
    ///   - above: The hidden folders above it that hide it, by name; empty when only its own entry
    ///     does.
    public static func shareHidden(named name: String, above: [String]) -> RemovalPrompt {
        RemovalPrompt(
            messageText: "Share “\(name)” without asking?",
            informativeText: (above.isEmpty
                ? "It’s hidden from Claude now, and hidden wins over shared, so sharing it takes it "
                    + "off Hidden from Claude. "
                : "It’s inside “\(above.joined(separator: "”, “"))”, hidden from Claude now, and "
                    + "hidden wins over shared, so sharing it takes "
                    + (above.count == 1 ? "that folder" : "those folders")
                    + " off Hidden from Claude, with everything in "
                    + (above.count == 1 ? "it. " : "them. "))
                + "Claude then gets answers, page text, search names and lookups from it without "
                + "asking. Whole documents still ask.",
            confirmTitle: "Share")
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
