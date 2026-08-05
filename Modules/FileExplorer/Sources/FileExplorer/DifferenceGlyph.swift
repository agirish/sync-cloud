import SwiftUI
import Sync
import Design

/// Single source of truth for how a difference type is drawn, shared by the
/// tree-pane badges (FileRowView) and the Differences table (DifferencesView)
/// so the two surfaces can't drift. Shape encodes direction/kind so status is
/// readable without color.
enum DifferenceGlyph {
    /// `filled` selects the .fill circle variants used by the large card icons;
    /// the tree badges use the outline variants.
    static func symbol(for type: FileDifference.DifferenceType, filled: Bool) -> String {
        switch type {
        case .missingOnRight: return filled ? "arrow.right.circle.fill" : "arrow.right.circle"
        case .missingOnLeft: return filled ? "arrow.left.circle.fill" : "arrow.left.circle"
        case .differentDates: return "arrow.triangle.2.circlepath"
        case .nameConflict: return filled ? "exclamationmark.triangle.fill" : "exclamationmark.triangle"
        }
    }

    static func color(for type: FileDifference.DifferenceType) -> Color {
        switch type {
        case .missingOnRight: return color(toRight: true)
        case .missingOnLeft: return color(toRight: false)
        case .differentDates: return .orange
        // Caution, not warning: a name conflict needs the user's judgment (which spelling wins?),
        // nothing was skipped or lost. Value-identical to the old raw .yellow.
        case .nameConflict: return SemanticColor.caution
        }
    }

    /// The direction tint (blue → right, purple → left) behind the type colors above.
    /// (It once also fed the table's "Copy to" direction chip; the chip is gone — the
    /// Change column names the destination — and the type badges are the remaining reader.)
    static func color(toRight: Bool) -> Color {
        toRight ? .blue : .purple
    }
}
