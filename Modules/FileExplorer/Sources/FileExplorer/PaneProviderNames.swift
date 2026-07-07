/// User-facing names for the two sync targets, resolved from the panes' cloud providers.
/// When both panes show the same provider the names are suffixed with the pane side
/// ("iCloud (left)" / "iCloud (right)") so copy/move labels stay unambiguous.
public struct PaneProviderNames: Equatable, Sendable {
    public let left: String
    public let right: String

    public init(leftName: String?, rightName: String?) {
        let left = leftName ?? "Left"
        let right = rightName ?? "Right"
        if left == right {
            self.left = "\(left) (left)"
            self.right = "\(right) (right)"
        } else {
            self.left = left
            self.right = right
        }
    }

    /// Spatial fallback, for callers that have no provider context.
    public static let leftRight = PaneProviderNames(leftName: nil, rightName: nil)

    /// The name of the pane opposite the given one.
    public func other(isLeft: Bool) -> String {
        isLeft ? right : left
    }
}
