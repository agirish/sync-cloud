import Foundation

/// Which placeholder a pane with no rows should show. A genuinely empty folder is fine;
/// a missing root or disabled provider is a problem the user must fix in Settings, so the
/// two must never share the old ambiguous "empty or invalid" message.
public enum PaneEmptyState: Equatable, Sendable {
    /// The tree has rows; no placeholder.
    case none
    /// The tree is empty because a scan is still in flight; show the scanning spinner.
    case loading
    /// The pane's provider is disabled in Settings (transient: pane selection re-resolves
    /// away from disabled providers, but the tree can render before that lands).
    case providerDisabled
    /// The provider's root path is missing or not a directory.
    case invalidRoot
    /// The directory exists but has no visible entries. `hasOnlyHiddenEntries` is true when
    /// entries exist but the hidden-files filter removed all of them.
    case emptyFolder(hasOnlyHiddenEntries: Bool)

    /// Classifies the pane's placeholder from cheaply available state — no disk I/O.
    /// `rootIsValid` is SettingsManager's last validity check of the provider ROOT; a
    /// focused subfolder that vanished still classifies as an empty folder.
    /// Order matters: loading always wins (the spinner must behave exactly as before),
    /// and a disabled provider outranks its (possibly also invalid) root path because
    /// re-enabling is the actionable fix.
    public static func classify(
        treeIsEmpty: Bool,
        isLoading: Bool,
        providerIsEnabled: Bool,
        rootIsValid: Bool,
        hasOnlyHiddenEntries: Bool
    ) -> PaneEmptyState {
        guard treeIsEmpty else { return .none }
        if isLoading { return .loading }
        if !providerIsEnabled { return .providerDisabled }
        if !rootIsValid { return .invalidRoot }
        return .emptyFolder(hasOnlyHiddenEntries: hasOnlyHiddenEntries)
    }
}
