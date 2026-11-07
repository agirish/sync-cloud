/// User-facing names for the two sync targets, resolved from the panes' cloud providers.
/// When both panes show the same provider the names are suffixed with the pane side
/// ("iCloud (left)" / "iCloud (right)") so copy/move labels stay unambiguous.
public struct PaneProviderNames: Equatable, Sendable {
    /// The pane's name as a surface showing both panes must say it, with "(left)"/"(right)" when
    /// the panes share a provider.
    public let left: String
    public let right: String

    /// The same names without that suffix, for surfaces that show one source (Organize, Storage),
    /// where a suffix against a pane not on screen is noise. Kept rather than stripped from the
    /// pair, which would mangle a provider really named "Archive (left)".
    public let leftPlain: String
    public let rightPlain: String

    public init(leftName: String?, rightName: String?) {
        let left = leftName ?? "Left"
        let right = rightName ?? "Right"
        self.leftPlain = left
        self.rightPlain = right
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

    /// One pane's name for a surface that shows only that pane — see ``leftPlain``.
    public func plain(isLeft: Bool) -> String {
        isLeft ? leftPlain : rightPlain
    }
}
