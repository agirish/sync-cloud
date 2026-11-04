import Foundation

/// Filing help's card in Ask Claude (TE255), and what Claude is told. The card is local UI and
/// shows everything; Claude gets the folders and reasons, and the word read from the file only
/// with Let Claude read files on.
public struct AskClaudeFilingCard: Codable, Equatable, Sendable {

    public enum Kind: Codable, Equatable, Sendable {
        case suggestions
        /// No Filing profile yet (decision EX): the card offers Setup.
        case noProfile
        /// The place they named is outside the surveyed folder, which is named (TE284).
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
        /// Not in the place they named, which is kept because the file plainly belongs here
        /// (decision FX): "Outside Travel".
        public let note: String?

        public init(label: String, path: String, confidence: String, reason: String, fromFile: Bool, note: String? = nil) {
            self.label = label
            self.path = path
            self.confidence = confidence
            self.reason = reason
            self.fromFile = fromFile
            self.note = note
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

    public init(fileName: String, filePath: String, kind: Kind, folders: [Folder] = [], staleDays: Int? = nil,
                canRefine: Bool = false, place: String? = nil) {
        self.fileName = fileName
        self.filePath = filePath
        self.kind = kind
        self.folders = folders
        self.staleDays = staleDays
        self.canRefine = canRefine
        self.place = place
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
    /// - `readsFiles`: whether the file shares freely (Let Claude read files, or a folder shared
    ///   without asking): only then is a folder picked from its text named to Claude.
    public static func result(_ card: AskClaudeFilingCard, readsFiles: Bool) -> String {
        let name = AskClaudeScreenCard.escape(card.fileName)
        switch card.kind {
        case .noProfile:
            return "They have no folder survey yet, so there are no conventions of theirs to go by. Say so; their card offers Setup, whose survey learns how they file. Don’t guess a folder."
        case .outside(let surveyed):
            // Decision FY: say so, and offer the survey's folder instead.
            let survey = AskClaudeScreenCard.escape(surveyed)
            let place = card.place.map(AskClaudeScreenCard.escape) ?? "the place they named"
            return "Their folder survey covers \(survey) only, and \(place) isn’t in it, so there are no conventions of theirs to sort by there. Say so, and offer to sort it into \(survey) by how they file instead, or to move it into one folder of \(place) they name, with propose_changes. Don’t guess a folder."
        case .noMatch:
            return "No folder in their folder survey fits \(name). Say so; don’t guess one."
        case .suggestions:
            var lines = ["Where \(name) fits, by how they file (their folder survey, read on their Mac, free):"]
            for (i, folder) in card.folders.enumerated() {
                let rank = i == 0 ? "best" : "runner-up"
                // A folder picked by a word read from the file says what the file holds, so unless
                // the file shares freely it stays on their card (review of TE319–TE323).
                if folder.fromFile && !readsFiles {
                    lines.append("\(rank): a folder picked by a word read from the file · \(folder.confidence) · on their card, not sent to you")
                    continue
                }
                let note = folder.note.map { " · \(AskClaudeScreenCard.escape($0)), where it plainly belongs" } ?? ""
                lines.append("\(rank): \(AskClaudeScreenCard.escape(folder.label)) · \(folder.confidence) · \(AskClaudeScreenCard.escape(folder.reason))\(note)")
            }
            if let days = card.staleDays {
                lines.append("Their survey is \(days) days old, so folders made since aren’t known; Update the Survey is in Organize ▸ Restructure.")
            }
            lines.append("They have a card with Go to Folder and Move Here\(card.canRefine ? ", and Refine with Claude" : ""). Nothing was moved.")
            return lines.joined(separator: "\n")
        }
    }
}
