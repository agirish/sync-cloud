import Sync

/// The two panes' name rulesets, for the surfaces that list files from BOTH sides at once.
///
/// A pane row belongs to one provider and asks that provider's rules. A Differences row does not:
/// it exists precisely because the two sides disagree, and the whole reason to flag a hostile name
/// *there* is that the row is about to become a copy. So the question a differences row asks is not
/// "is this name risky" but **"will this name survive this comparison"** — and it will not if
/// EITHER side rejects it. Copying left-to-right must clear the right's rules; the direction is
/// per-row and the user can flip it, so binding the check to one side would leave the badge
/// answering a question about a copy the user has since redirected.
///
/// Over-reporting is the safe direction here for the same reason `PaneActionDelegate`'s unresolved
/// provider falls back to OneDrive, the strictest: a name flagged on a side it would in fact have
/// survived costs a glance, and one flagged on neither breaks a sync.
public struct PaneProviderRules: Equatable, Sendable {
    public let left: CloudProvider.ProviderType
    public let right: CloudProvider.ProviderType

    public init(left: CloudProvider.ProviderType, right: CloudProvider.ProviderType) {
        self.left = left
        self.right = right
    }

    /// OneDrive both sides — the strictest ruleset, for callers with no provider context (previews,
    /// and the tests that assert table layout rather than provider behaviour). Over-reports rather
    /// than letting a name that will break a sync pass unflagged.
    public static let strictest = PaneProviderRules(left: .oneDrive, right: .oneDrive)

    /// Every distinct ruleset in play, so a caller checks each at most once — the two panes are on
    /// the same provider more often than not.
    public var distinct: [CloudProvider.ProviderType] {
        left == right ? [left] : [left, right]
    }
}
