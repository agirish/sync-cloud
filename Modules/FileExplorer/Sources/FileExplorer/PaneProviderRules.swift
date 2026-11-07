import Sync

/// The two panes' name rulesets, for surfaces that list files from both sides at once.
///
/// A Differences row is about to become a copy, so it asks whether a name survives this comparison:
/// it doesn't if either side rejects it. The copy direction is per row and the user can flip it, so
/// the check can't bind to one side. Over-reporting is the safe direction, as with
/// `PaneActionDelegate`'s OneDrive fallback: a needless flag costs a glance, a missed one breaks a
/// sync.
public struct PaneProviderRules: Equatable, Sendable {
    public let left: CloudProvider.ProviderType
    public let right: CloudProvider.ProviderType

    public init(left: CloudProvider.ProviderType, right: CloudProvider.ProviderType) {
        self.left = left
        self.right = right
    }

    /// OneDrive both sides, the strictest ruleset, for callers with no provider context (previews,
    /// layout tests). Over-reports rather than letting a sync-breaking name pass.
    public static let strictest = PaneProviderRules(left: .oneDrive, right: .oneDrive)

    /// Every distinct ruleset in play, so a caller checks each at most once; the panes usually
    /// share a provider.
    public var distinct: [CloudProvider.ProviderType] {
        left == right ? [left] : [left, right]
    }
}
