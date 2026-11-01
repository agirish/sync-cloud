import Foundation
import Sync

/// Which placeholder a pane with no rows should show. A genuinely empty folder is fine;
/// a missing root or disabled provider is a problem the user must fix in Settings, so the
/// two must never share the old ambiguous "empty or invalid" message.
public enum PaneEmptyState: Equatable, Sendable {
    /// The tree has rows; no placeholder.
    case none
    /// The tree is empty because a scan is still in flight. Draws nothing in the centre: the
    /// pane's one busy indicator is its corner chip (`PaneBusyIndicator`). The case still matters,
    /// because it keeps "Folder is empty" off a pane that has not been read yet.
    case loading
    /// The pane's provider is disabled in Settings (transient: pane selection re-resolves
    /// away from disabled providers, but the tree can render before that lands).
    case providerDisabled
    /// The provider's root path is missing or not a directory.
    case invalidRoot
    /// The directory exists but has no visible entries. `hasOnlyHiddenEntries` is true when
    /// entries exist but the hidden-files filter removed all of them.
    case emptyFolder(hasOnlyHiddenEntries: Bool)
    /// The folder has visible entries, but the pane's type filter shows none of them (RD70 TE274).
    case filteredOut(PaneTypeFilter)

    /// "No PDFs in Downloads" for one whole kind, "No matching files in Downloads" for anything
    /// broader, and "Nothing is ticked" for a filter with nothing in it.
    public static func filteredOutTitle(_ filter: PaneTypeFilter, folder: String) -> String {
        if filter.isEmpty { return "Nothing is ticked" }
        if filter.extensions.isEmpty, filter.families.count == 1, let family = filter.families.first {
            return "No \(family.title) in \(folder)"
        }
        return "No matching files in \(folder)"
    }

    /// Classifies the pane's placeholder from cheaply available state — no disk I/O.
    /// `rootIsValid` is SettingsManager's last validity check of the provider ROOT; a
    /// focused subfolder that vanished still classifies as an empty folder.
    /// Order matters: loading always wins (nothing may call a pane empty while it is being read),
    /// and a disabled provider outranks its (possibly also invalid) root path because
    /// re-enabling is the actionable fix.
    public static func classify(
        treeIsEmpty: Bool,
        isLoading: Bool,
        providerIsEnabled: Bool,
        rootIsValid: Bool,
        hasOnlyHiddenEntries: Bool,
        typeFilterEmptied: PaneTypeFilter? = nil
    ) -> PaneEmptyState {
        guard treeIsEmpty else { return .none }
        if isLoading { return .loading }
        if !providerIsEnabled { return .providerDisabled }
        if !rootIsValid { return .invalidRoot }
        if let typeFilterEmptied { return .filteredOut(typeFilterEmptied) }
        return .emptyFolder(hasOnlyHiddenEntries: hasOnlyHiddenEntries)
    }
}
