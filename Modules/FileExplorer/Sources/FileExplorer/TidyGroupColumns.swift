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
enum TidyGroupColumns {

    /// Every badge the vocabulary can produce, overlap pinned to its widest rendering (100%).
    static let badgeVocabulary: [DuplicateMatchType] =
        [.identical, .sameText, .overlapping(sharedFraction: 1.0), .nameOnly, .versions]

    /// The badge fonts, matching `TidyGroupCard.typeBadge` exactly — a slot measured in any
    /// other font is a slot measured for some other view.
    private static let badgeFont = ScaledFont.system(size: 11, weight: .bold)

    /// Width of the widest type badge: symbol + 6pt gap + label + the mini pill's padding.
    static func badgeSlotWidth(scale: CGFloat) -> CGFloat {
        badgeVocabulary.map { type in
            LabelMetrics.symbolWidth(TidyMatchStyle.symbol(type), font: badgeFont, scale: scale)
                + 6
                + LabelMetrics.width(of: TidyMatchStyle.label(type), font: badgeFont, scale: scale)
                + 2 * PillVariant.mini.horizontalPadding
        }.max() ?? 0
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
