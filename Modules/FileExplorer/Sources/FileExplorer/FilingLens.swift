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

/// The confidence tier a Filing suggestion falls into, so the results list reads as "sure, maybe,
/// needs you" rather than a wall of cards. Keyed on the best candidate, matching the card's chip.
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

    /// The section marker's tint, matching the card's confidence chip.
    var color: Color {
        switch self {
        case .high:   return SemanticColor.success
        case .medium: return SemanticColor.warning
        case .low:    return .secondary
        }
    }

    /// How many of the meter's 3 bars this tier fills, so confidence reads as a quantity rather
    /// than a color-word. Never 0: the weakest tier still lights one bar.
    var filledBars: Int {
        switch self {
        case .high:   return 3
        case .medium: return 2
        case .low:    return 1
        }
    }

    /// What raises a suggestion into this tier, so the tiers read as a scale ("what makes this
    /// High?") rather than three arbitrary words.
    var gloss: String {
        switch self {
        case .high:   return "filename match or a rule you taught"
        // Medium mixes softer name/metadata matches with content reads (capped at medium), so
        // the gloss can't claim one source.
        case .medium: return "a likely match by name or contents"
        case .low:    return "weak signal — pick a home"
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
    /// Mirrors `FilingSuggestionCard`'s chip.
    static func of(_ suggestion: FilingSuggestion) -> FilingConfidenceTier {
        of(suggestion.best?.confidence)
    }
}

// MARK: - Confidence meter (G5)

/// A compact 3-bar meter that reads confidence as a quantity (more bars, surer), tinted like the
/// tier's chip. Shared by the card's confidence cluster and the section header.
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

/// One confidence-grouped section of Filing suggestions.
struct FilingSuggestionSection: Identifiable {
    let tier: FilingConfidenceTier
    let suggestions: [FilingSuggestion]
    var id: String { tier.rawValue }
}

enum FilingSuggestionGrouping {
    /// Splits suggestions into High, Medium and Low sections, dropping empty tiers and keeping the
    /// engine's order within each. Pure, for tests.
    static func sections(_ suggestions: [FilingSuggestion]) -> [FilingSuggestionSection] {
        FilingConfidenceTier.allCases.compactMap { tier in
            let matching = suggestions.filter { FilingConfidenceTier.of($0) == tier }
            return matching.isEmpty ? nil : FilingSuggestionSection(tier: tier, suggestions: matching)
        }
    }
}
