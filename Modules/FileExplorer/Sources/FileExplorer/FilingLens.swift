import SwiftUI
import Sync
import Design

// MARK: - Filing glyph vocabulary

/// The Filing lens's own iconography, kept apart from the duplicate finder's (`wand.and.stars`,
/// `checkmark.seal.fill`) so the two never share a symbol.
enum FilingGlyph {
    /// The Filing lens's signature symbol — a folder being organized. Used by the intro state and
    /// the "scan the folder you navigated to" action.
    static let lens = "folder.badge.gearshape"
    /// The user filed everything loose this session. A full tray reads as "everything's put away",
    /// and isn't the duplicate finder's seal.
    static let allFiled = "tray.full.fill"
    /// A scan found nothing loose to file. An empty tray, again not the duplicate finder's seal.
    static let nothingLoose = "tray"
}

// MARK: - Confidence grouping (G3)

/// The confidence tier a Filing suggestion falls into, keyed on the best candidate as the card's
/// pill is: what a search's `confidence:` chip matches.
enum FilingConfidenceTier: String, CaseIterable, Identifiable {
    case high, medium, low
    var id: String { rawValue }

    /// The search chip's words.
    var title: String {
        switch self {
        case .high:   return "High confidence"
        case .medium: return "Medium confidence"
        case .low:    return "Needs your pick"
        }
    }

    /// The tier a raw confidence value falls into (nil is `.low`, the card's "Pick a home"). The one
    /// rule both `of(_ suggestion:)` and the card use.
    static func of(_ confidence: FilingConfidence?) -> FilingConfidenceTier {
        switch confidence {
        case .high?:   return .high
        case .medium?: return .medium
        default:       return .low
        }
    }

    /// The tier a suggestion belongs to, by its best candidate's confidence (none is `.low`).
    /// Mirrors the card's pill.
    static func of(_ suggestion: FilingSuggestion) -> FilingConfidenceTier {
        of(suggestion.best?.confidence)
    }
}

// MARK: - Override detection (G2)

/// Whether filing into a chosen folder overrides the suggestion, the correction worth remembering.
/// Pure, keyed only on paths.
enum FilingOverride {
    /// True when `chosenPath` differs from the best candidate (path-normalized). No best candidate
    /// counts too, since the pick still teaches where these files go; accepting the suggested home
    /// teaches nothing.
    static func isOverride(_ suggestion: FilingSuggestion, chosenPath: String) -> Bool {
        guard let best = suggestion.best?.path else { return true }
        return standardized(best) != standardized(chosenPath)
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

// MARK: - Sections by what you have to do (cards mockup v6)

/// To File's three sections, by what the card asks of you rather than by a raw confidence: file it
/// (Matched, the File All sheet's cards), look first (Check first), or choose (Needs your pick).
enum FilingSectionKind: String, CaseIterable, Identifiable {
    case matched, checkFirst, needsPick
    var id: String { rawValue }

    var title: String {
        switch self {
        case .matched: return "Matched"
        case .checkFirst: return "Check first"
        case .needsPick: return "Needs your pick"
        }
    }

    /// What puts a card here, once per screen. Needs your pick says only its count.
    var gloss: String? {
        switch self {
        case .matched: return "High: the account number on page 1, or the file’s name"
        case .checkFirst: return "a new account, or a likely match to look over"
        case .needsPick: return nil
        }
    }

    var color: Color {
        switch self {
        case .matched: return SemanticColor.success
        case .checkFirst: return SemanticColor.warning
        case .needsPick: return .secondary
        }
    }

    /// The section a file's card sits in: Matched for what File All may file
    /// (``FilingSuggestion/isMatched``), Check first for any other confident home, else Needs your
    /// pick.
    static func of(_ s: FilingSuggestion) -> FilingSectionKind {
        s.isMatched ? .matched : s.hasConfidentHome ? .checkFirst : .needsPick
    }
}

/// One section of To File's cards.
struct FilingCardSection: Identifiable {
    let kind: FilingSectionKind
    let items: [FilingCardItem]
    var id: String { kind.rawValue }
    /// How many files its cards would move.
    var fileCount: Int { items.reduce(0) { $0 + $1.toFile.count } }
    /// How many files its cards show.
    var shownCount: Int { items.reduce(0) { $0 + $1.suggestions.count } }
}

enum FilingCardSections {
    /// Splits suggestions into Matched, Check first and Needs your pick, dropping empty ones, and
    /// groups each section's statements by account folder, keeping the engine's order. Pure, for
    /// tests.
    static func sections(_ suggestions: [FilingSuggestion], pulledOut: Set<String> = []) -> [FilingCardSection] {
        FilingSectionKind.allCases.compactMap { kind in
            let matching = suggestions.filter { FilingSectionKind.of($0) == kind }
            return matching.isEmpty ? nil
                : FilingCardSection(kind: kind, items: FilingCardGrouping.items(matching, pulledOut: pulledOut))
        }
    }

    /// "210 matched, in 21 accounts": the readout's first run, over the Matched files that move.
    /// Accounts when every one has an account; folders otherwise.
    static func matchedPlaces(_ suggestions: [FilingSuggestion]) -> (files: Int, places: Int, accounts: Bool) {
        let matched = suggestions.filter { $0.isMatched && !$0.isAlreadyFiled && $0.duplicateOf == nil }
        let accounts = matched.allSatisfy { $0.best?.account != nil }
        let places = Set(matched.compactMap { $0.best?.account?.root ?? $0.best?.path }).count
        return (matched.count, places, accounts)
    }
}
