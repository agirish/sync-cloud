import SwiftUI
import Sync
import Design

// MARK: - Filing glyph vocabulary

/// The Filing lens's own iconography, kept distinct from the duplicate finder's (which uses the
/// `wand.and.stars` / `checkmark.seal.fill` vocabulary). Centralized so Duplicates vs Filing never drift
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
        case .high:   return SemanticColor.success
        case .medium: return SemanticColor.warning
        case .low:    return .secondary
        }
    }

    /// How many of the 3 meter bars are filled for this tier (G5) — a *quantity* readout so
    /// confidence reads as "more bars = surer" without a color-word lookup: High 3 / Medium 2 /
    /// Low 1. Never 0, so even the weakest tier shows a single lit bar rather than an empty meter.
    var filledBars: Int {
        switch self {
        case .high:   return 3
        case .medium: return 2
        case .low:    return 1
        }
    }

    /// A one-line gloss of what *raises* a suggestion into this tier — the confidence key, so the
    /// tiers read as a scale ("what makes this High?") rather than three arbitrary color-words (G5).
    var gloss: String {
        switch self {
        case .high:   return "filename match or a rule you taught"
        // Medium mixes softer name/metadata matches with on-device content reads (content
        // confidence is capped at medium), so the gloss can't claim one source — the engine
        // files many filename-derived rows here too.
        case .medium: return "a likely match by name or contents"
        case .low:    return "weak signal — pick a home"
        }
    }

    /// The tier a raw confidence value falls into (nil ⇒ `.low`, mirroring the card's "Pick a home"
    /// default). The single source of truth both `of(_ suggestion:)` and the card key off.
    static func of(_ confidence: FilingConfidence?) -> FilingConfidenceTier {
        switch confidence {
        case .high?:   return .high
        case .medium?: return .medium
        default:       return .low
        }
    }

    /// The tier a suggestion belongs to, keyed on its best candidate's confidence (nil, i.e. no
    /// candidate / "Pick a home", falls into `.low`). Mirrors `FilingSuggestionCard`'s chip.
    static func of(_ suggestion: FilingSuggestion) -> FilingConfidenceTier {
        of(suggestion.best?.confidence)
    }
}

// MARK: - Confidence meter (G5)

/// A compact 3-bar meter that reads confidence as a *quantity* — more filled bars = surer — so it
/// doesn't depend on knowing which color-word (High/Medium/Low) means what. Tinted to match the
/// tier's chip color. Shared by the per-card confidence cluster and the grouped-list section header.
struct ConfidenceMeter: View {
    let tier: FilingConfidenceTier
    var barWidth: CGFloat = 3
    var barHeight: CGFloat = 11
    var spacing: CGFloat = 2

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i < tier.filledBars ? tier.color : tier.color.opacity(0.18))
                    .frame(width: barWidth, height: barHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Confidence \(tier.filledBars) of 3")
    }
}

// MARK: - Override detection (G2)

/// Whether filing into a chosen folder is an *override* of the suggestion — the correction worth
/// remembering (G2). Pure so it can be unit-tested; keyed only on paths.
enum FilingOverride {
    /// True when `chosenPath` differs from the suggestion's best candidate (path-normalized), i.e.
    /// the user picked a home other than the one suggested. A suggestion with no best candidate (the
    /// user always had to pick) counts as an override too, since the pick still teaches where these
    /// files go. Accepting the suggested home returns false — nothing new to learn.
    static func isOverride(_ suggestion: FilingSuggestion, chosenPath: String) -> Bool {
        guard let best = suggestion.best?.path else { return true }
        return standardized(best) != standardized(chosenPath)
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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
