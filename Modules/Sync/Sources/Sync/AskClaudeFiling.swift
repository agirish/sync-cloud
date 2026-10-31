import Foundation

/// Filing help's card in Ask Claude (TE255), and what Claude is told. The card is local UI and
/// shows everything; Claude gets the folders and reasons, and the word read from the file only
/// with Let Claude read files on.
public struct AskClaudeFilingCard: Codable, Equatable, Sendable {

    public enum Kind: Codable, Equatable, Sendable {
        case suggestions
        /// No Filing profile yet (decision EX): the card offers Setup.
        case noProfile
        /// The file is outside the surveyed folder, which is named.
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

        public init(label: String, path: String, confidence: String, reason: String, fromFile: Bool) {
            self.label = label
            self.path = path
            self.confidence = confidence
            self.reason = reason
            self.fromFile = fromFile
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

    public init(fileName: String, filePath: String, kind: Kind, folders: [Folder] = [], staleDays: Int? = nil,
                canRefine: Bool = false) {
        self.fileName = fileName
        self.filePath = filePath
        self.kind = kind
        self.folders = folders
        self.staleDays = staleDays
        self.canRefine = canRefine
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
    public static func result(_ card: AskClaudeFilingCard, readsFiles: Bool) -> String {
        let name = AskClaudeScreenCard.escape(card.fileName)
        switch card.kind {
        case .noProfile:
            return "They have no folder survey yet, so there are no conventions of theirs to go by. Say so; their card offers Setup, whose survey learns how they file. Don’t guess a folder."
        case .outside(let surveyed):
            return "Their folder survey covers \(AskClaudeScreenCard.escape(surveyed)) only, and \(name) is somewhere else, so there are no conventions for it. Say so; don’t guess a folder."
        case .noMatch:
            return "No folder in their folder survey fits \(name). Say so; don’t guess one."
        case .suggestions:
            var lines = ["Where \(name) fits, by how they file (their folder survey, read on their Mac, free):"]
            for (i, folder) in card.folders.enumerated() {
                let reason = folder.fromFile && !readsFiles
                    ? "Matched a word read from the file that this folder’s documents use" : folder.reason
                lines.append("\(i == 0 ? "best" : "runner-up"): \(AskClaudeScreenCard.escape(folder.label)) · \(folder.confidence) · \(AskClaudeScreenCard.escape(reason))")
            }
            if let days = card.staleDays {
                lines.append("Their survey is \(days) days old, so folders made since aren’t known; Update the Survey is in Organize ▸ Restructure.")
            }
            lines.append("They have a card with Go to Folder\(card.canRefine ? " and Refine with Claude" : ""). Nothing was moved.")
            return lines.joined(separator: "\n")
        }
    }
}
