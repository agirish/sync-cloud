/// User-facing names for the two sync targets, resolved from the panes' cloud providers.
/// When both panes show the same provider the names are suffixed with the pane side
/// ("iCloud (left)" / "iCloud (right)") so copy/move labels stay unambiguous.
public struct PaneProviderNames: Equatable, Sendable {
    /// The pane's name as a surface showing BOTH panes must say it — carrying "(left)"/"(right)"
    /// when the two panes are on the same provider and would otherwise be indistinguishable.
    public let left: String
    public let right: String

    /// The same names WITHOUT that suffix.
    ///
    /// **A suffix that disambiguates against a pane you cannot see is noise.** The Organize and
    /// Storage workspaces show ONE source, and every breadcrumb in them was reading
    /// "iCloud (left) › Documents › …" whenever the Compare tab's two panes happened to sit on the
    /// same provider — a distinction drawn against a pane that is not on screen, and that the
    /// reader has no way to interpret. His report, against the Duplicates compare surface, was
    /// exactly this: "left in parenthesis doesn't make sense right? Just iCloud should suffice."
    ///
    /// Kept beside the disambiguated pair rather than recomputed by stripping the suffix: a
    /// provider genuinely called "Archive (left)" would be mangled by a strip, and the raw name is
    /// already in hand here.
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
