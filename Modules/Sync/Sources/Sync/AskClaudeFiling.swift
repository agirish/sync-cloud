import Foundation

/// Filing help's card in Ask Claude, and what Claude is told. The card is local UI and shows
/// everything; Claude gets the folders and reasons, and the word read from the file only when the
/// file is in a folder shared without asking.
public struct AskClaudeFilingCard: Codable, Equatable, Sendable {

    public enum Kind: Codable, Equatable, Sendable {
        case suggestions
        /// No Filing profile yet: the card offers Setup.
        case noProfile
        /// The place they named is outside the surveyed folder, which is named.
        case outside(surveyed: String)
        /// The profile has no folder that fits.
        case noMatch
    }

    public struct Folder: Codable, Equatable, Sendable {
        /// "iCloud › Documents › Taxes › 2025".
        public let label: String
        /// Absolute, for Go to Folder. Never sent to Claude.
        public let path: String
        /// "High", "Medium" or "Needs your pick", To File's words.
        public let confidence: String
        public let reason: String
        /// The reason names a word read from the file.
        public let fromFile: Bool
        /// Not in the place they named, but kept because the file plainly belongs here:
        /// "Outside Travel".
        public let note: String?
        /// A folder not made yet, named like its siblings (TE327): Make and Move Here makes it.
        /// Optional so a chat saved before it reads.
        public let isNew: Bool?
        /// The name the file takes here, made from inside it (TE328), and where its style came from.
        public var newName: String?
        public var nameBasis: String?
        /// The name copies a file in a folder that doesn't share without asking: held until Share
        /// Names and Folders, though the file's own folder shares (decision NF). Nil when not.
        public var nameHeld: Bool?

        public init(label: String, path: String, confidence: String, reason: String, fromFile: Bool, note: String? = nil,
                    isNew: Bool = false) {
            self.label = label
            self.path = path
            self.confidence = confidence
            self.reason = reason
            self.fromFile = fromFile
            self.note = note
            self.isNew = isNew ? true : nil
        }
    }

    /// The best folder's siblings when they are plain names (TE327, decision JG): Claude may offer
    /// a new one like them. Its label and names; never on the card.
    public struct NamedSiblings: Codable, Equatable, Sendable {
        /// "iCloud › Documents › Travel › Trips".
        public let label: String
        /// Absolute. Never sent to Claude.
        public let path: String
        public let names: [String]

        public init(label: String, path: String, names: [String]) {
            self.label = label
            self.path = path
            self.names = names
        }
    }

    public let fileName: String
    /// Absolute. Never sent to Claude.
    public let filePath: String
    public let kind: Kind
    public let folders: [Folder]
    /// Days since the survey, when it is 21 or more.
    public let staleDays: Int?
    /// Refine with Claude can be offered: the answer isn't High and Organize's Refine is set up.
    public let canRefine: Bool
    /// The place they named, by source and folder ("Dropbox", "iCloud › Documents › Travel").
    public let place: String?
    public let namedSiblings: NamedSiblings?
    /// Why the file keeps its own name though it wanted one (TE328): locked, a picture, …
    public var nameKept: String?
    /// What its first page said, for Move Here's card.
    public var nameFacts: ContentName.Facts?
    /// Whether Claude has the new names; nil when no folder gives one.
    public var names: AskClaudeHeldNames?

    public init(fileName: String, filePath: String, kind: Kind, folders: [Folder] = [], staleDays: Int? = nil,
                canRefine: Bool = false, place: String? = nil, namedSiblings: NamedSiblings? = nil) {
        self.fileName = fileName
        self.filePath = filePath
        self.kind = kind
        self.folders = folders
        self.staleDays = staleDays
        self.canRefine = canRefine
        self.place = place
        self.namedSiblings = namedSiblings
    }
}

public enum AskClaudeFiling {

    /// To File's words for a confidence.
    public static func label(_ confidence: FilingConfidence) -> String {
        switch confidence {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Needs your pick"
        }
    }

    /// The tool's answer to Claude.
    /// - `sharesFreely`: whether the file is in a folder shared without asking: only then is a
    ///   folder picked from its text named to Claude.
    public static func result(_ card: AskClaudeFilingCard, sharesFreely: Bool) -> String {
        let name = AskClaudeScreenCard.escape(card.fileName)
        switch card.kind {
        case .noProfile:
            return "They have no folder survey yet, so there are no conventions of theirs to go by. Say so; their card offers Setup, whose survey learns how they file. Don’t guess a folder."
        case .outside(let surveyed):
            // Say so, and offer the survey's folder instead.
            let survey = AskClaudeScreenCard.escape(surveyed)
            let place = card.place.map(AskClaudeScreenCard.escape) ?? "the place they named"
            return "Their folder survey covers \(survey) only, and \(place) isn’t in it, so there are no conventions of theirs to sort by there. Say so, and offer to sort it into \(survey) by how they file instead, or to move it into one folder of \(place) they name, with propose_changes. Don’t guess a folder."
        case .noMatch:
            return "No folder in their folder survey fits \(name). Say so; don’t guess one."
        case .suggestions:
            let namesGo = sharesFreely || card.names?.shared == true
            // Decision NF: a name copied from a folder that asks first waits for the click.
            func nameGoes(_ folder: AskClaudeFilingCard.Folder) -> Bool { card.names?.shared == true || (namesGo && folder.nameHeld != true) }
            var lines = ["Where \(name) fits, by how they file (their folder survey, read on their Mac, free):"]
            for (i, folder) in card.folders.enumerated() {
                let rank = i == 0 ? "best" : "runner-up"
                // A folder picked by a word read from the file says what the file holds, so unless
                // the file shares freely it stays on their card.
                if folder.fromFile && !sharesFreely {
                    lines.append("\(rank): a folder picked by a word read from the file · \(folder.confidence) · on their card, not sent to you")
                    continue
                }
                let note = folder.note.map { " · \(AskClaudeScreenCard.escape($0)), where it plainly belongs" } ?? ""
                let what = folder.isNew == true ? "a new folder, \(AskClaudeScreenCard.escape(folder.label)), not made yet" : AskClaudeScreenCard.escape(folder.label)
                // TE328 (decision IW): a name made from inside the file goes only where the file shares.
                let renamed = folder.newName.map { nameGoes(folder) ? " · renamed there to \(AskClaudeScreenCard.escape($0))" : "" } ?? ""
                lines.append("\(rank): \(what) · \(folder.confidence) · \(AskClaudeScreenCard.escape(folder.reason))\(note)\(renamed)")
            }
            if card.folders.contains(where: { $0.newName != nil && !nameGoes($0) }) {
                lines.append("Apple Intelligence made a new name for it on their Mac from its first page, in each folder’s style. The name isn’t sent to you: it comes from what the file says. Don’t guess it. Their card has Share Names and Folders.")
            }
            if card.nameKept != nil {
                lines.append("Its name says nothing about it, but it keeps it: Apple Intelligence couldn’t name it. The card says why.")
            }
            // The siblings of a folder picked by a word from the file name it among them, and
            // their parent says what the file holds: they too stay on the card.
            if let named = card.namedSiblings,
               sharesFreely || !card.folders.contains(where: { $0.fromFile && ($0.path as NSString).deletingLastPathComponent == named.path }) {
                lines.append("The folders in \(AskClaudeScreenCard.escape(named.label)) are named \(named.names.map(AskClaudeScreenCard.escape).joined(separator: ", ")). If those are one kind of name (places, people, companies, cars) and the file plainly belongs to a new one of that kind, you may offer a new folder there named the same way, with the move, on one propose_changes card; say the closest folder above is the other choice. Otherwise don’t offer one.")
            }
            if let days = card.staleDays {
                lines.append("Their survey is \(days) days old, so folders made since aren’t known; Update the Survey is in Organize ▸ Restructure.")
            }
            let makes = card.folders.contains { $0.isNew == true } ? ", Make and Move Here for the new folder (one Apply makes it and moves the file)" : ""
            lines.append("They have a card with Go to Folder and Move Here\(makes)\(card.canRefine ? ", and Refine with Claude" : ""). Nothing was \(makes.isEmpty ? "moved" : "moved or made").")
            return lines.joined(separator: "\n")
        }
    }
}
