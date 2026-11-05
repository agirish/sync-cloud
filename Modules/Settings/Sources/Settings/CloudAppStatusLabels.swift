import SwiftUI

/// Whose cloud app isn't syncing, for Settings ▸ Sources: provider id → the words beside its amber
/// dot ("not running"). Settings can't see the app's status monitor, which lives above it, so the
/// window hands the answer down. Empty, so nothing is drawn, wherever it isn't set.
private struct CloudAppStatusLabelsKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    public var cloudAppStatusLabels: [String: String] {
        get { self[CloudAppStatusLabelsKey.self] }
        set { self[CloudAppStatusLabelsKey.self] = newValue }
    }
}
