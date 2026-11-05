import Testing
import Foundation
import FileExplorer
import Settings
import Sync
@testable import SyncCloud

/// `PaneActionDelegate`'s half of the row badge: the provider it asks about, the keep it honours,
/// and the pane's equality, which fails silently.
@MainActor
@Suite struct PaneRiskyNameDelegateTests {

    private func delegate(syncManager: FileSyncManager, settings: SettingsManager,
                          keptNames: Set<String> = []) -> PaneActionDelegate {
        PaneActionDelegate(
            handler: nil, syncManager: syncManager, settings: settings, isLeft: true,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: false, ownsOrganizeScope: false, servesEditor: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in }, onOpenInEditor: { _ in },
            ignoreStateToken: [], keptNamesToken: keptNames,
            onFindDuplicatesOf: { _ in }, onOrganizeFolder: { _ in }, onCheckFolderShape: { _ in }, onOrganizeScope: { _ in }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })
    }

    /// The staleness hazard, and why `keptNamesToken` is a stored property. The pane skips
    /// re-rendering when its delegate says nothing it answers has changed, and keeping a name
    /// changes only how rows with that name draw. Left out of `isEquivalent`, the dismissed badge
    /// would stay on screen until something unrelated moved, as `ignoreStateToken` prevents for
    /// ignores.
    ///
    /// A pair: the first case proves the token is compared, the second that the comparison isn't
    /// always false, which would defeat the `Equatable` boundary's optimization.
    @Test func keepingANameMakesTheDelegateCompareUnequal() {
        let manager = FileSyncManager()
        let settings = SettingsManager()

        let before = delegate(syncManager: manager, settings: settings, keptNames: [])
        let after = delegate(syncManager: manager, settings: settings, keptNames: ["Q3: final.pdf"])
        #expect(before.isEquivalent(to: after) == false,
                "the pane would skip the re-render and the badge would go stale")

        let unchanged = delegate(syncManager: manager, settings: settings, keptNames: [])
        #expect(before.isEquivalent(to: unchanged),
                "an unchanged keep set must still let the pane skip the render")
    }

    /// Withdrawing one keep while adding another leaves the count unchanged, which is why the token
    /// is the set and not a number.
    @Test func swappingOneKeepForAnotherIsNoticed() {
        let manager = FileSyncManager()
        let settings = SettingsManager()
        let a = delegate(syncManager: manager, settings: settings, keptNames: ["one "])
        let b = delegate(syncManager: manager, settings: settings, keptNames: ["two "])
        #expect(a.isEquivalent(to: b) == false)
    }

    /// A kept name is silenced, and a name with the same hazard beside it isn't: a keep is about
    /// one name, not the hazard class.
    @Test func aKeptNameIsSilencedAndItsNeighbourIsNot() {
        let defaults = ScratchDefaults("PaneKept")

        let manager = FileSyncManager()
        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("kept name ")
        manager.keptNamesStore = store

        let d = delegate(syncManager: manager, settings: SettingsManager())
        // No provider resolves for "left", so the delegate falls back to OneDrive, the strictest
        // (as `paneProviderType` documents), which is what makes a trailing space risky here.
        #expect(d.riskyNameReason(forName: "kept name ", isDirectory: false) == nil)
        #expect(d.isKeptName("kept name "))
        #expect(d.riskyNameReason(forName: "other name ", isDirectory: false) != nil)
        #expect(d.isKeptName("other name ") == false)
    }

    /// The badge and the menu answer the same rules, so a name that badges is offered "Fix name".
    /// They diverge on one point, asserted here: a kept name loses its badge but keeps its menu
    /// item, in case the user changes their mind.
    @Test func theMenuStillOffersToFixAKeptName() {
        let defaults = ScratchDefaults("PaneKeptMenu")

        let manager = FileSyncManager()
        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("meant it ")
        manager.keptNamesStore = store

        let d = delegate(syncManager: manager, settings: SettingsManager())
        let node = FileNode(id: "/root/meant it ", name: "meant it ", isDirectory: false, children: nil)
        #expect(d.riskyNameReason(forName: node.name, isDirectory: false) == nil, "badge is silenced")
        #expect(d.riskyName(for: node) != nil, "but the raw verdict, and so the menu item, remains")
    }
}
