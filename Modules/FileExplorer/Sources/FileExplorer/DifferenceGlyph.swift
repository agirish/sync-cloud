import SwiftUI
import Sync

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
        case .nameConflict: return .yellow
        }
    }

    /// The direction tint (blue → right, purple → left) behind the type colors above;
    /// also used directly by the Differences table's "Copy to" chip so the chip and the
    /// badges can't diverge.
    static func color(toRight: Bool) -> Color {
        toRight ? .blue : .purple
    }
}
