import Testing
import Foundation
import FileExplorer
import Settings
import Sync
@testable import SyncCloud

/// `PaneActionDelegate`'s half of the `⌂ on this Mac only` badge: which panes ask the question at
/// all, and the pane equality that decides whether an answer can go stale on screen.
///
/// The gating is asserted in BOTH directions. A net over one render path proves nothing about the
/// other: a delegate that answered `true` everywhere would pass a folder-source-only test, and one
/// that answered `false` everywhere would pass a cloud-source-only test.
@MainActor
@Suite struct PaneHomeBadgeDelegateTests {

    private static let iCloud = CloudProvider(
        id: "iCloud", displayName: "iCloud", imageName: "icloud",
        path: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs", type: .iCloud)

    /// The coverage a real settings list would produce, built the production way.
    private static var coverage: FileLocation.Coverage {
        FileLocation.coverage(of: [iCloud], disabledProviderIds: [])
    }

    private func delegate(
        syncManager: FileSyncManager, settings: SettingsManager,
        homeBadgeCoverage: FileLocation.Coverage?
    ) -> PaneActionDelegate {
        PaneActionDelegate(
            handler: nil, syncManager: syncManager, settings: settings, isLeft: true,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in },
            ignoreStateToken: [], keptNamesToken: [],
            homeBadgeCoverage: homeBadgeCoverage, onFindDuplicatesOf: { _ in },
            onOrganizeFolder: { _ in }, onOrganizeScope: { _ in }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })
    }

    // MARK: The gate, both ways

    /// A folder source's pane asks the question, and answers it per row: a file outside every
    /// cloud folder is badged, one inside iCloud on the same pane is not.
    @Test func aFolderSourcePaneBadgesRowsOutsideEveryCloudFolder() {
        let d = delegate(syncManager: FileSyncManager(), settings: SettingsManager(),
                         homeBadgeCoverage: Self.coverage)
        #expect(d.isOnThisMacOnly(forPath: "/Users/u/Projects/notes.md"))
        #expect(d.isOnThisMacOnly(
            forPath: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/a.md") == false)
    }

    /// **The same rows in a cloud source's own pane show nothing.** Inside a provider's folder
    /// every row is covered by definition, so the badge would be a mark on everything — and a mark
    /// on everything says nothing.
    ///
    /// Uses the SAME path as the positive case above, so what changes is the pane and only the
    /// pane. A path-based fixture would leave open the possibility that the two cases simply
    /// disagree about the path.
    @Test func aCloudSourcePaneBadgesNothingAtAll() {
        let d = delegate(syncManager: FileSyncManager(), settings: SettingsManager(),
                         homeBadgeCoverage: nil)
        #expect(d.isOnThisMacOnly(forPath: "/Users/u/Projects/notes.md") == false,
                "the badge appeared inside a cloud source's own pane")
        #expect(d.isOnThisMacOnly(
            forPath: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/a.md") == false)
    }

    /// The default on the protocol answers false, so a conformer with no provider context — every
    /// test stub, every pane that is not a real provider view — renders the row it rendered before
    /// the badge existed.
    ///
    /// Reached through an EXISTENTIAL deliberately: a member declared only in a protocol extension
    /// is dispatched statically, which is how "Fix name…" was unreachable from the moment it was
    /// written. This is the call shape `FileTreeView` actually makes.
    @Test func aDelegateWithNoCoverageAnswersFalseThroughTheExistential() {
        struct Stub: FileActionDelegate {
            func handleRefresh() {}
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
        #expect(existential.isOnThisMacOnly(forPath: "/Users/u/Projects/notes.md") == false)
        #expect(existential.canFindDuplicates == false,
                "a stub with no workspace behind it offered the Duplicates door")
        #expect(existential.canOrganizeFolder == false,
                "a stub with no workspace behind it offered the Organize door")
    }

    /// A real pane DOES offer the Duplicates door — otherwise the test above passes because the
    /// item is gated off everywhere.
    @Test func aRealPaneOffersTheDuplicatesDoor() {
        let d = delegate(syncManager: FileSyncManager(), settings: SettingsManager(),
                         homeBadgeCoverage: nil)
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
        let concrete = delegate(syncManager: FileSyncManager(), settings: SettingsManager(),
                                homeBadgeCoverage: nil)
        let existential: FileActionDelegate = concrete
        #expect(existential.canOrganizeFolder,
                "the real pane's answer did not survive the existential — the member is extension-only and dispatching to the default")
    }

    /// Files only ever reach the badge, never the Organize handoff: "where do the loose files in
    /// here belong" has no meaning aimed at a file, which already has a home. Asserted on the
    /// HANDLER rather than only on the menu that gates it, so the guarantee travels with the
    /// action — and in both directions, or the guard proves nothing.
    @Test func theOrganizeHandoffIgnoresFiles() {
        var asked: [String] = []
        let base = delegate(syncManager: FileSyncManager(), settings: SettingsManager(),
                            homeBadgeCoverage: nil)
        let d = PaneActionDelegate(
            handler: nil, syncManager: base.syncManager, settings: base.settings, isLeft: true,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in },
            ignoreStateToken: [], keptNamesToken: [], homeBadgeCoverage: nil,
            onFindDuplicatesOf: { _ in }, onOrganizeFolder: { asked.append($0.id) }, onOrganizeScope: { _ in }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })

        d.handleOrganizeFolder(FileNode(id: "/Users/u/Projects/a.txt", name: "a.txt",
                                        isDirectory: false, children: nil))
        #expect(asked.isEmpty, "a file reached the Organize handoff")

        d.handleOrganizeFolder(FileNode(id: "/Users/u/Projects", name: "Projects",
                                        isDirectory: true, children: []))
        #expect(asked == ["/Users/u/Projects"],
                "a folder did NOT reach the handoff — the guard above proves nothing")
    }

    /// Folders only ever reach the badge, never the duplicates handoff — a folder overlap group is
    /// a different unit. Asserted on the HANDLER rather than only on the menu that gates it, so
    /// the guarantee travels with the action.
    @Test func theDuplicatesHandoffIgnoresFolders() {
        var asked: [String] = []
        var d = delegate(syncManager: FileSyncManager(), settings: SettingsManager(),
                         homeBadgeCoverage: nil)
        d = PaneActionDelegate(
            handler: nil, syncManager: d.syncManager, settings: d.settings, isLeft: true,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in },
            ignoreStateToken: [], keptNamesToken: [], homeBadgeCoverage: nil,
            onFindDuplicatesOf: { asked.append($0.id) }, onOrganizeFolder: { _ in }, onOrganizeScope: { _ in }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })

        d.handleFindDuplicates(FileNode(id: "/Users/u/Projects", name: "Projects",
                                        isDirectory: true, children: []))
        #expect(asked.isEmpty, "a folder reached the duplicates handoff")

        d.handleFindDuplicates(FileNode(id: "/Users/u/Projects/a.txt", name: "a.txt",
                                        isDirectory: false, children: nil))
        #expect(asked == ["/Users/u/Projects/a.txt"],
                "a file did NOT reach the handoff — the guard above proves nothing")
    }

    // MARK: The staleness hazard

    /// **The reason `homeBadgeCoverage` is a stored, compared property.**
    ///
    /// The pane skips re-rendering — and with it every visible row — when its delegate vouches
    /// that nothing it answers has changed. Adding a folder source or re-pointing a provider
    /// changes what every row draws and NOTHING else the pane compares: same tree, same paths,
    /// same selection. Leave it out of `isEquivalent` and the pane keeps marking rows against a
    /// source list that no longer exists — `4cae0471`'s finding outliving the provider, arriving
    /// through the third eagerly-rendered answer.
    ///
    /// A pair, like its two siblings: the first case proves the value is compared, the second that
    /// the comparison is not simply always-false — which would "pass" the first while destroying
    /// the optimization the whole `Equatable` boundary exists for.
    @Test func aChangedSourceListMakesTheDelegateCompareUnequal() {
        let manager = FileSyncManager()
        let settings = SettingsManager()
        let before = delegate(syncManager: manager, settings: settings,
                              homeBadgeCoverage: Self.coverage)
        let after = delegate(
            syncManager: manager, settings: settings,
            homeBadgeCoverage: FileLocation.coverage(
                of: [Self.iCloud,
                     CloudProvider(id: "OneDrive-A", displayName: "OneDrive (A)",
                                   imageName: "onedrive",
                                   path: "/Users/u/Library/CloudStorage/OneDrive-A/Documents",
                                   type: .oneDrive)],
                disabledProviderIds: []))
        #expect(before.isEquivalent(to: after) == false,
                "the pane would skip the re-render and every ⌂ would go stale")

        let unchanged = delegate(syncManager: manager, settings: settings,
                                 homeBadgeCoverage: Self.coverage)
        #expect(before.isEquivalent(to: unchanged),
                "an unchanged source list must still let the pane skip the render")
    }

    /// Switching a pane from a folder source to a cloud one (which turns every ⌂ off) is the same
    /// hazard through the nil case, which an all-non-nil fixture would miss.
    @Test func gainingOrLosingTheGateIsNoticed() {
        let manager = FileSyncManager()
        let settings = SettingsManager()
        let folderPane = delegate(syncManager: manager, settings: settings,
                                  homeBadgeCoverage: Self.coverage)
        let cloudPane = delegate(syncManager: manager, settings: settings, homeBadgeCoverage: nil)
        #expect(folderPane.isEquivalent(to: cloudPane) == false)
    }
}
