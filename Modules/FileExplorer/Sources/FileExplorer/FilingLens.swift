import SwiftUI
import Sync

// MARK: - Filing glyph vocabulary

/// The Filing lens's own iconography, kept distinct from the duplicate finder's (which uses the
/// `wand.and.stars` / `checkmark.seal.fill` vocabulary). Centralized so Tidy vs Filing never drift
/// into sharing a symbol.
enum FilingGlyph {
    /// The Filing lens's signature symbol — a folder being organized. Used by the intro state and
    /// the "scan the folder you navigated to" action.
    static let lens = "folder.badge.gearshape"
    /// Earned terminal state: the user just filed everything loose this session. A full tray reads
    /// as "everything's put away," and is deliberately not the duplicate finder's seal.
    static let allFiled = "tray.full.fill"
    /// Neutral empty: a scan turned up nothing loose to file. An empty tray, again distinct from the
    /// duplicate finder's seal.
    static let nothingLoose = "tray"
}

// MARK: - Confidence grouping (G3)

/// The confidence tier a Filing suggestion falls into — the grouping the results list is broken into
/// so a wall of cards reads as "these are sure, these are maybes, these need you." Keyed on the
/// suggestion's best candidate, so it lines up exactly with the per-card confidence chip.
enum FilingConfidenceTier: String, CaseIterable, Identifiable {
    case high, medium, low
    var id: String { rawValue }

    /// Section header title.
    var title: String {
        switch self {
        case .high:   return "High confidence"
        case .medium: return "Medium confidence"
        case .low:    return "Needs your pick"
        }
    }

    /// The tint the section marker carries — matches the per-card confidence chip colors
    /// (green / orange / secondary).
    var color: Color {
        switch self {
        case .high:   return .green
        case .medium: return .orange
        case .low:    return .secondary
        }
    }

    /// The tier a suggestion belongs to, keyed on its best candidate's confidence (nil, i.e. no
    /// candidate / "Pick a home", falls into `.low`). Mirrors `FilingSuggestionCard`'s chip.
    static func of(_ suggestion: FilingSuggestion) -> FilingConfidenceTier {
        switch suggestion.best?.confidence {
        case .high?:   return .high
        case .medium?: return .medium
        default:       return .low
        }
    }
}

/// One confidence-grouped section of Filing suggestions.
struct FilingSuggestionSection: Identifiable {
    let tier: FilingConfidenceTier
    let suggestions: [FilingSuggestion]
    var id: String { tier.rawValue }
}

enum FilingSuggestionGrouping {
    /// Splits suggestions into High / Medium / Low sections (in that order), dropping empty tiers and
    /// preserving the engine's within-tier ordering. A pure, view-agnostic transform so it can be
    /// unit-tested.
    static func sections(_ suggestions: [FilingSuggestion]) -> [FilingSuggestionSection] {
        FilingConfidenceTier.allCases.compactMap { tier in
            let matching = suggestions.filter { FilingConfidenceTier.of($0) == tier }
            return matching.isEmpty ? nil : FilingSuggestionSection(tier: tier, suggestions: matching)
        }
    }
}
