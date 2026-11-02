import Foundation

/// The Save a Rule card in Ask Claude (TE286): a correction he made in chat, offered as a free rule
/// on his Mac. Nothing is saved until he clicks (decision GX); the card shows the words, the folder
/// and where the file it was taught on goes.
public struct AskClaudeRuleCard: Codable, Equatable, Sendable {

    public enum Kind: Codable, Equatable, Sendable {
        case new
        /// Words join his rule `rule.name`.
        case addWords(added: [String])
        /// A rule beside the one named, for another folder (decision HH).
        case sibling(of: UUID, ruleName: String)
    }

    public enum State: Codable, Equatable, Sendable {
        case offered
        case saved
        case declined
    }

    public let fileName: String
    public let kind: Kind
    /// The rule as it would be saved.
    public let rule: AutomationRule
    /// Where the file it was taught on goes, relative: "Travel/Trips/IN-US/2026/Sep".
    public let example: String
    /// The year and month were checked against page 1.
    public let checkedDate: Bool
    public var state: State = .offered

    public init(fileName: String, correction: AutomationRuleProposer.Correction) {
        self.fileName = fileName
        switch correction.kind {
        case .new: kind = .new
        case .addWords(let added): kind = .addWords(added: added)
        case .sibling(let of, let name): kind = .sibling(of: of, ruleName: name)
        }
        rule = correction.rule
        example = correction.example
        checkedDate = correction.checkedDate
    }

    /// What Save stores.
    public var correction: AutomationRuleProposer.Correction {
        let k: AutomationRuleProposer.Correction.Kind
        switch kind {
        case .new: k = .new
        case .addWords(let added): k = .addWords(added: added)
        case .sibling(let of, let name): k = .sibling(of: of, ruleName: name)
        }
        return AutomationRuleProposer.Correction(kind: k, rule: rule, example: example, checkedDate: checkedDate)
    }

    /// The card's title.
    public var title: String {
        switch kind {
        case .new: return "Save a rule? \(rule.name)"
        case .addWords: return "Add to your rule “\(rule.name)”?"
        case .sibling(_, let ruleName): return "Like “\(ruleName)”, for another folder?"
        }
    }

    /// The rule's any-of words, as written in it.
    public var words: [String] { AutomationRuleProposer.anyWords(of: rule) ?? [] }

    /// Words that must be there too.
    public var also: [String] {
        for case .mentionsAll(let tokens) in rule.conditions { return tokens }
        return []
    }

    /// The words just added, shown marked.
    public var added: [String] {
        if case .addWords(let added) = kind { return added }
        return []
    }

    /// "Travel › Trips › IN-US › year of travel › month of travel".
    public var destination: String {
        Self.readable(rule.destinationTemplate)
    }

    public static func readable(_ template: String) -> String {
        template.split(separator: "/").map { segment -> String in
            switch String(segment) {
            case AutomationTravelDate.yearToken: return "year of travel"
            case AutomationTravelDate.monthToken: return "month of travel"
            case "{year}": return "year"
            case "{month}": return "month"
            case "{person}": return "person"
            default: return String(segment)
            }
        }.joined(separator: " › ")
    }

    /// What Claude is told. The words and folders are its own and his; no text from the file.
    public static func result(_ card: AskClaudeRuleCard) -> String {
        let words = card.words.map { "“\(AskClaudeScreenCard.escape($0))”" }.joined(separator: ", ")
        var lines: [String]
        switch card.kind {
        case .new:
            lines = ["Offered them a card to save a rule, “\(AskClaudeScreenCard.escape(card.rule.name))”: files mentioning any of \(words) go to \(AskClaudeScreenCard.escape(card.destination))."]
        case .addWords(let added):
            lines = ["Their rule “\(AskClaudeScreenCard.escape(card.rule.name))” already files this folder; offered them a card to add \(added.map { "“\(AskClaudeScreenCard.escape($0))”" }.joined(separator: ", ")) to it."]
        case .sibling(_, let name):
            lines = ["Their rule “\(AskClaudeScreenCard.escape(name))” files these words elsewhere; offered them a card for a rule beside it, “\(AskClaudeScreenCard.escape(card.rule.name))”, to \(AskClaudeScreenCard.escape(card.destination)), for files that also mention \(card.also.map { "“\(AskClaudeScreenCard.escape($0))”" }.joined(separator: " and "))."]
        }
        lines.append("This file would go to \(AskClaudeScreenCard.escape(card.example))." + (card.checkedDate ? "" : " Page 1 couldn’t be read, so the year and month weren’t checked against it."))
        lines.append("Nothing is saved until they click. Say in one line what you offered, and stop.")
        return lines.joined(separator: "\n")
    }

    /// Why no card was offered, for Claude.
    public static func refusal(_ refusal: AutomationRuleProposer.CorrectionRefusal) -> String {
        switch refusal {
        case .noWords:
            return "None of those words can be matched on (too short or too common). Give words of the kind: names, and words such files carry."
        case .notInFile:
            return "None of those words is in the file’s name or page 1, so the rule wouldn’t file the very file it’s taught on. Include at least one word it has."
        case .unusableFolder:
            return "That folder can’t be a rule’s destination. Offer no rule."
        case .covered(let name):
            return "Their rule “\(AskClaudeScreenCard.escape(name))” already files this file there; no new rule is needed. Say so in a line."
        case .needsAlso(let name, let folder):
            return "Their rule “\(AskClaudeScreenCard.escape(name))” files these words into \(AskClaudeScreenCard.escape(readable(folder))). For a rule beside it, give also: words in this file that tell it apart (a destination, an airport code)."
        }
    }
}
