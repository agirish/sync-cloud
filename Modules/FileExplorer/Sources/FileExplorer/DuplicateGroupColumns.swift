import SwiftUI
import Design

/// The Duplicates header row's invisible columns: verb and digits each sit in a fixed slot, so a
/// stack of group cards reads as a table without drawing one, and the sizes share one digit column
/// whether the row ends in "reclaim" or "shared".
///
/// Slot widths are derived, never hard-coded: each is the measured width of the widest word its
/// vocabulary can produce at the current font scale, via `LabelMetrics`. Callers apply them as
/// `minWidth`, so an outlier string still lays out instead of truncating.
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

