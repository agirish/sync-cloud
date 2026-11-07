import Dashboard
import FileExplorer
import Settings
import Sync
@testable import SyncCloud

/// A pane's `PaneActionDelegate`: no handler, a scratch manager and settings unless given, the
/// left pane of a "left"/"right" pair, every flag off and every closure a no-op, except what a
/// test names.
@MainActor
func paneDelegate(syncManager: FileSyncManager? = nil, settings: SettingsManager? = nil,
                  isLeft: Bool = true, isSingleSource: Bool = false, ownsOrganizeScope: Bool = false,
                  servesEditor: Bool = false, keptNamesToken: Set<String> = [],
                  onFindDuplicatesOf: @escaping (FileNode) -> Void = { _ in },
                  onOrganizeFolder: @escaping (FileNode) -> Void = { _ in },
                  onOrganizeScope: @escaping (FileNode) -> Void = { _ in },
                  onOpenInNewTab: @escaping (FileNode) -> Void = { _ in }) -> PaneActionDelegate {
    PaneActionDelegate(
        handler: nil, syncManager: syncManager ?? .scratch(), settings: settings ?? .scratch(), isLeft: isLeft,
        leftProviderId: "left", rightProviderId: "right", isSingleSource: isSingleSource,
        ownsOrganizeScope: ownsOrganizeScope, servesEditor: servesEditor,
        forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
        ignoreStateToken: [], keptNamesToken: keptNamesToken,
        onFindDuplicatesOf: onFindDuplicatesOf, onOrganizeFolder: onOrganizeFolder, onCheckFolderShape: { _ in },
        onOrganizeScope: onOrganizeScope, onOpenInNewTab: onOpenInNewTab, onNewTabHere: { _ in }, onCloseTab: { })
}
