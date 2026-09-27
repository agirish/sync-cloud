import Testing
import Foundation
import FileExplorer
import Settings
import Sync
@testable import SyncCloud

/// `PaneActionDelegate`'s two doors out of a row — Find Duplicates and Organize — asserted on the
/// real delegate, through the existential every caller uses, and on the handlers themselves.
///
/// This suite used to open with the `⌂ on this Mac only` badge's gate; the badge was removed on
/// 2026-09-27 and its tests went with it. The door tests were always here too, and stay.
@MainActor
@Suite struct PaneDoorDelegateTests {

    private func delegate(syncManager: FileSyncManager, settings: SettingsManager) -> PaneActionDelegate {
        PaneActionDelegate(
            handler: nil, syncManager: syncManager, settings: settings, isLeft: true,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: false, ownsOrganizeScope: false, servesEditor: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
            ignoreStateToken: [], keptNamesToken: [], onFindDuplicatesOf: { _ in },
            onOrganizeFolder: { _ in }, onCheckFolderShape: { _ in }, onOrganizeScope: { _ in }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })
    }

    /// The protocol's defaults offer no door, so a conformer with no workspace behind it — every
    /// test stub, every pane that is not a real provider view — draws neither menu item.
    ///
    /// Reached through an EXISTENTIAL deliberately: a member declared only in a protocol extension
    /// is dispatched statically, which is how "Fix name…" was unreachable from the moment it was
    /// written. This is the call shape `FileTreeView` actually makes.
    @Test func aDelegateWithNoWorkspaceOffersNoDoorThroughTheExistential() {
        struct Stub: FileActionDelegate {
            func handleRefresh() {}
            func handleOpenInEditor(_ path: String) {}
            func handleFocus(_ node: FileNode) {}
            func handleCopy(_ nodes: [FileNode]) {}
            func handleMove(_ nodes: [FileNode]) {}
            func handleDelete(_ nodes: [FileNode]) {}
            func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
            func handlePaste(_ targetDir: FileNode) {}
            func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
            func handlePasteToPath(_ path: String) {}
            func handleRename(_ node: FileNode) {}
            func handleCreateFolder(at path: String) {}
            func handleGetInfo(for path: String) {}
            func handleSort(_ option: SortOption) {}
            func handleIgnore(_ nodes: [FileNode]) {}
            func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
        }
        let existential: FileActionDelegate = Stub()
        #expect(existential.canFindDuplicates == false,
                "a stub with no workspace behind it offered the Duplicates door")
        #expect(existential.canOrganizeFolder == false,
                "a stub with no workspace behind it offered the Organize door")
    }

    /// A real pane DOES offer the Duplicates door — otherwise the test above passes because the
    /// item is gated off everywhere.
    @Test func aRealPaneOffersTheDuplicatesDoor() {
        let d = delegate(syncManager: FileSyncManager(), settings: SettingsManager())
        #expect(d.canFindDuplicates)
        #expect(d.canOrganizeFolder)
    }

    /// **The dispatch trap, asserted through an existential.** Both members are protocol
    /// requirements rather than extension-only additions, and this is the test that keeps them
    /// that way: every caller reaches the delegate through `FileActionDelegate`, so a member
    /// declared only in the extension dispatches statically to the default and the conformer's
    /// override is never reached. That shipped once here and made "Fix name…" unreachable from
    /// the day it was written — silently, because the menu simply never drew the item.
    @Test func theOrganizeDoorSurvivesTheExistential() {
        let concrete = delegate(syncManager: FileSyncManager(), settings: SettingsManager())
        let existential: FileActionDelegate = concrete
        #expect(existential.canOrganizeFolder,
                "the real pane's answer did not survive the existential — the member is extension-only and dispatching to the default")
    }

    /// Files never reach the Organize handoff: "where do the loose files in
    /// here belong" has no meaning aimed at a file, which already has a home. Asserted on the
    /// HANDLER rather than only on the menu that gates it, so the guarantee travels with the
    /// action — and in both directions, or the guard proves nothing.
    @Test func theOrganizeHandoffIgnoresFiles() {
        var asked: [String] = []
        let base = delegate(syncManager: FileSyncManager(), settings: SettingsManager())
        let d = PaneActionDelegate(
            handler: nil, syncManager: base.syncManager, settings: base.settings, isLeft: true,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: false, ownsOrganizeScope: false, servesEditor: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
            ignoreStateToken: [], keptNamesToken: [],
            onFindDuplicatesOf: { _ in }, onOrganizeFolder: { asked.append($0.id) }, onCheckFolderShape: { _ in }, onOrganizeScope: { _ in }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })

        d.handleOrganizeFolder(FileNode(id: "/Users/u/Projects/a.txt", name: "a.txt",
                                        isDirectory: false, children: nil))
        #expect(asked.isEmpty, "a file reached the Organize handoff")

        d.handleOrganizeFolder(FileNode(id: "/Users/u/Projects", name: "Projects",
                                        isDirectory: true, children: []))
        #expect(asked == ["/Users/u/Projects"],
                "a folder did NOT reach the handoff — the guard above proves nothing")
    }

    /// Folders never reach the duplicates handoff — a folder overlap group is
    /// a different unit. Asserted on the HANDLER rather than only on the menu that gates it, so
    /// the guarantee travels with the action.
    @Test func theDuplicatesHandoffIgnoresFolders() {
        var asked: [String] = []
        var d = delegate(syncManager: FileSyncManager(), settings: SettingsManager())
        d = PaneActionDelegate(
            handler: nil, syncManager: d.syncManager, settings: d.settings, isLeft: true,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: false, ownsOrganizeScope: false, servesEditor: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
            ignoreStateToken: [], keptNamesToken: [],
            onFindDuplicatesOf: { asked.append($0.id) }, onOrganizeFolder: { _ in }, onCheckFolderShape: { _ in }, onOrganizeScope: { _ in }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })

        d.handleFindDuplicates(FileNode(id: "/Users/u/Projects", name: "Projects",
                                        isDirectory: true, children: []))
        #expect(asked.isEmpty, "a folder reached the duplicates handoff")

        d.handleFindDuplicates(FileNode(id: "/Users/u/Projects/a.txt", name: "a.txt",
                                        isDirectory: false, children: nil))
        #expect(asked == ["/Users/u/Projects/a.txt"],
                "a file did NOT reach the handoff — the guard above proves nothing")
    }
}
