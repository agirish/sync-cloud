import SwiftUI
import Sync
import Design

/// Maps a banner severity to its visual treatment. Kept out of ContentView so the
/// symbol names can be pinned by tests (a typo'd name renders as a blank icon at runtime).
enum OperationBannerStyle {
    static func iconName(for severity: OperationBanner.Severity) -> String {
        switch severity {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    static func tint(for severity: OperationBanner.Severity) -> Color {
        switch severity {
        case .success: return SemanticColor.success
        case .warning: return SemanticColor.warning
        case .error: return SemanticColor.error
        }
    }
}
