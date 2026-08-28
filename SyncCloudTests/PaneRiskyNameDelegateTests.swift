import Testing
import Foundation
import FileExplorer
import Settings
import Sync
@testable import SyncCloud

/// `PaneActionDelegate`'s half of the row badge: the provider it asks about, the keep it honours,
/// and — the one that bites silently — the pane's equality.
@MainActor
@Suite struct PaneRiskyNameDelegateTests {

    private func delegate(syncManager: FileSyncManager, settings: SettingsManager,
                          keptNames: Set<String> = []) -> PaneActionDelegate {
        PaneActionDelegate(
            handler: nil, syncManager: syncManager, settings: settings, isLeft: true,
            leftProviderId: "left", rightProviderId: "right", isSingleSource: false, ownsOrganizeScope: false,
            forceRefreshAction: {}, onGetInfo: { _ in }, onChooseDestination: { _, _ in },
            ignoreStateToken: [], keptNamesToken: keptNames,
            // Required rather than defaulted, deliberately: a pane that forgot to pass its
            // coverage would silently lose every ⌂ badge, and a default here would let it.
            // `PaneHomeBadgeDelegateTests` owns what these two do.
            homeBadgeCoverage: nil, onFindDuplicatesOf: { _ in }, onOrganizeFolder: { _ in }, onCheckFolderShape: { _ in }, onOrganizeScope: { _ in }, onOpenInNewTab: { _ in }, onNewTabHere: { _ in }, onCloseTab: { })
    }

    /// **The staleness hazard, and the reason `keptNamesToken` is a stored property at all.**
    ///
    /// The pane skips re-rendering — and with it every visible row — when its delegate vouches that
    /// nothing it answers has changed. Keeping a name changes what every row showing that name
    /// draws and NOTHING else the pane compares: same tree, same paths, same selection. Leave the
    /// token out of `isEquivalent` and the pane answers "equivalent", skips the render, and the
    /// badge the user just dismissed stays on screen until something unrelated moves. That is the
    /// exact failure `ignoreStateToken` was added for, arriving through the second eagerly-rendered
    /// answer.
    ///
    /// Written as a pair: the first case proves the token is compared, the second proves the
    /// comparison is not simply always-false (which would "pass" the first while destroying the
    /// optimization the whole `Equatable` boundary exists for).
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

    /// Withdrawing one keep while adding another leaves the COUNT where it was — which is why the
    /// token is the set and not a number.
    @Test func swappingOneKeepForAnotherIsNoticed() {
        let manager = FileSyncManager()
        let settings = SettingsManager()
        let a = delegate(syncManager: manager, settings: settings, keptNames: ["one "])
        let b = delegate(syncManager: manager, settings: settings, keptNames: ["two "])
        #expect(a.isEquivalent(to: b) == false)
    }

    /// A kept name is silenced, and a name with the identical hazard beside it is not — a keep is
    /// about one name, not about the hazard class.
    @Test func aKeptNameIsSilencedAndItsNeighbourIsNot() {
        let suite = "PaneKept-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = FileSyncManager()
        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("kept name ")
        manager.keptNamesStore = store

        let d = delegate(syncManager: manager, settings: SettingsManager())
        // No provider resolves for "left", so the delegate falls back to OneDrive — the strictest —
        // which is the behaviour `paneProviderType` documents and what makes a trailing space risky
        // here at all.
        #expect(d.riskyNameReason(forName: "kept name ", isDirectory: false) == nil)
        #expect(d.isKeptName("kept name "))
        #expect(d.riskyNameReason(forName: "other name ", isDirectory: false) != nil)
        #expect(d.isKeptName("other name ") == false)
    }

    /// The badge and the menu answer the same rules, so a name that badges is a name "Fix name…"
    /// is offered for. They diverge on exactly one point — a KEPT name keeps its menu item (you may
    /// have changed your mind) while losing its badge — and that divergence is asserted rather than
    /// left to be discovered.
    @Test func theMenuStillOffersToFixAKeptName() {
        let suite = "PaneKeptMenu-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

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
