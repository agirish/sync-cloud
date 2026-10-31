import SwiftUI

/// **Whose cloud app isn't syncing, for Settings ▸ Sources** (RD68, DN): provider id → the words
/// beside its amber dot ("not running"). Settings cannot see the app's status monitor, which lives
/// above it, so the window hands the answer down. Empty — nothing drawn — anywhere it is not set.
private struct CloudAppStatusLabelsKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    public var cloudAppStatusLabels: [String: String] {
        get { self[CloudAppStatusLabelsKey.self] }
        set { self[CloudAppStatusLabelsKey.self] = newValue }
    }
}
