import SwiftUI
import Sync
import Design

/// The Duplicates header row's invisible columns (v4.0 polish P2): badge, verb and digits each
/// sit in a fixed slot, so a stack of group cards reads as a table without drawing one — every
/// name starts at one x whatever its badge says, and the sizes share one digit column whether
/// the row ends in "reclaim" or "shared".
///
/// **Slot widths are derived, never hard-coded**: each is the measured width of the widest
/// member its vocabulary can produce, at the current font scale, via `LabelMetrics` — a
/// required constant that drifts with the data is a broken model (the rail-width lesson).
/// Callers apply them as `minWidth`, so an outlier string still lays out instead of truncating;
/// alignment holds everywhere the vocabulary does.
@MainActor
enum DuplicateGroupColumns {

    /// The badge's own metrics, spelled out once so ``badgeSlotWidth(scale:)`` and the view that
    /// draws the badge cannot disagree about what a badge is made of.
    ///
    /// The gap between them was the point of `everyBadgeFitsItsSlot` being called tautological:
    /// slot and assertion were the same expression, so an error in the *ingredients* — a wrong gap,
    /// a wrong padding, a `LabelMetrics` that under-measures — moved both together and every badge
    /// overflowed with the suite green. Naming them here does not close that on its own;
    /// `aDrawnBadgeStaysInsideItsSlot` does, by reading the painted badge back. This just leaves
    /// one place to be wrong instead of two.
    static let badgeGlyphGap: CGFloat = 6
    static var badgePadding: CGFloat { PillVariant.mini.horizontalPadding }

    /// Every badge the vocabulary can produce — the EXCEPTIONS only: `identical` wears no badge
    /// (ROADMAP.md, the Identical-badge item), so the slot is sized for the rows that have one
    /// and the majority row spends the space on its own name.
    static let badgeVocabulary: [DuplicateMatchType] =
        [.sameText, .overlapping(sharedFraction: 1.0), .nameOnly, .versions]

    /// The badge fonts, matching `DuplicateGroupCard.typeBadge` exactly — a slot measured in any
    /// other font is a slot measured for some other view.
    private static let badgeFont = ScaledFont.system(size: 11, weight: .bold)

    /// Width of the widest type badge: symbol + the glyph gap + label + the mini pill's padding.
    static func badgeSlotWidth(scale: CGFloat) -> CGFloat {
        badgeVocabulary.map { badgeWidth($0, scale: scale) }.max() ?? 0
    }

    /// One badge's modelled width — the same arithmetic ``badgeSlotWidth(scale:)`` maximises over.
    /// Measured over `badgeLabel`, the string the badge actually draws — a slot measured over the
    /// category labels would be a slot for some other view.
    static func badgeWidth(_ type: DuplicateMatchType, scale: CGFloat) -> CGFloat {
        LabelMetrics.symbolWidth(DuplicateMatchStyle.symbol(type), font: badgeFont, scale: scale)
            + badgeGlyphGap
            + LabelMetrics.width(of: DuplicateMatchStyle.badgeLabel(type)
                                     ?? DuplicateMatchStyle.label(type),
                                 font: badgeFont, scale: scale)
            + 2 * badgePadding
    }

    /// The verbs a group can end in. "nothing to reclaim" spans both slots and is not a verb.
    static let verbVocabulary = ["reclaim", "shared"]

    static func verbSlotWidth(scale: CGFloat) -> CGFloat {
        verbVocabulary.map {
            LabelMetrics.width(of: $0, font: .system(size: 11), scale: scale)
        }.max() ?? 0
    }

    /// The digits column: wide enough for the widest realistic size run, "~" included (the
    /// overlap figure is an estimate and says so).
    static func digitsSlotWidth(scale: CGFloat) -> CGFloat {
        LabelMetrics.width(of: "~888.8 MB",
                           font: .system(size: 12, weight: .semibold, design: .monospaced),
                           scale: scale)
    }
}

/// The duplicate group's type badge: the match type's glyph and label in a mini pill.
///
/// **Its own view so it can be drawn on its own.** It was a private computed property of
/// `DuplicateGroupCard`, which meant the only way to check that a badge fits the slot the card gives it
/// was to re-measure the model — the tautology `everyBadgeFitsItsSlot` documented in its own note.
/// A test can render this and read the paint back (`aDrawnBadgeStaysInsideItsSlot`), and it renders
/// the badge the card draws rather than a reconstruction of it, which is the only version of that
/// test worth having.
///
/// The colour is the match type's, asked for here rather than passed in: `DuplicateGroupCard.accent` is
/// `DuplicateMatchStyle.color(group.matchType)` and nothing else, so a parameter would only be an
/// opportunity for a caller to draw a badge in some other type's colour.
struct DuplicateTypeBadge: View {
    let matchType: DuplicateMatchType

    private var accent: Color { DuplicateMatchStyle.color(matchType) }

    var body: some View {
        HStack(spacing: DuplicateGroupColumns.badgeGlyphGap) {
            Image(systemName: DuplicateMatchStyle.symbol(matchType))
                .scaledFont(.system(size: 11, weight: .bold))
                .symbolRenderingMode(.hierarchical)
            // The want, not the category — and the category-label fallback is defensive only:
            // the card constructs this badge exclusively for types whose `badgeLabel` is non-nil.
            Text(DuplicateMatchStyle.badgeLabel(matchType) ?? DuplicateMatchStyle.label(matchType))
                .scaledFont(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(accent)
        .pillSurface(.mini, tint: accent)
        .fixedSize()
    }
}
