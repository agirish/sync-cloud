import SwiftUI
import Design

/// The Duplicates header row's invisible columns (v4.0 polish P2): verb and digits each sit in a
/// fixed slot, so a stack of group cards reads as a table without drawing one — the sizes share
/// one digit column whether the row ends in "reclaim" or "shared".
///
/// **Slot widths are derived, never hard-coded**: each is the measured width of the widest
/// member its vocabulary can produce, at the current font scale, via `LabelMetrics` — a
/// required constant that drifts with the data is a broken model (the rail-width lesson).
/// Callers apply them as `minWidth`, so an outlier string still lays out instead of truncating;
/// alignment holds everywhere the vocabulary does.
///
/// **There was a third slot, for the match-type badge, and it went when the badge did.** Once the
/// list was sectioned by match type, a badge reading "Versions" under a heading reading *Versions*
/// was the heading restated once per card; the card keeps the severity stripe and wash, which
/// carry the same distinction without a word. The slot's whole job was to make every name start at
/// one x despite badges of different widths — with no badge there is nothing before the icon to
/// vary, so the alignment survives its own mechanism.
@MainActor
enum DuplicateGroupColumns {

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

