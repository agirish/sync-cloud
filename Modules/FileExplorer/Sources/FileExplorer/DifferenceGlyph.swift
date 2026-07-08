import SwiftUI
import Sync

/// Single source of truth for how a difference type is drawn, shared by the
/// tree-pane badges (FileRowView) and the Differences-pane cards (DifferenceRow)
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
        }
    }

    static func color(for type: FileDifference.DifferenceType) -> Color {
        switch type {
        case .missingOnRight: return .blue
        case .missingOnLeft: return .purple
        case .differentDates: return .orange
        }
    }
}
