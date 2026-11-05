import Foundation
import Testing
import Design
import FileExplorer
import Settings
import Sync
@testable import Dashboard

/// `SettingsResetKeeps` lives in Sync and names some keys by their strings, because their owners
/// are in packages Sync cannot see. This package sees them all: a renamed key goes red here
/// instead of being reset by Reset All Settings.
@Suite struct SettingsResetKeepsOwnersTests {

    @MainActor
    @Test func everyKeyNamedByItsStringIsStillItsOwnersKey() {
        for key in [EditorPDFSignatureStore.key, RootsMigration.stampKey, RootsMigration.handledProviderIdsKey,
                    RootsMigration.iCloudRootMoveStampKey, PaneBar.migrationKey,
                    SidebarFavoritePlaces.migrationKey, PaneViewMode.columnWidthFloorLiftKey,
                    SidebarFavoritePlaces.storageKey, SidebarFavoritePlaces.salvageKey,
                    FolderJumpStore.pinnedKey, FolderJumpStore.salvageKey(for: FolderJumpStore.pinnedKey),
                    FolderJumpStore.favoriteOrderKey] {
            #expect(SettingsResetKeeps.keeps(key), "\(key)")
        }
        // What he only passed through resets.
        for key in [FolderJumpStore.recentsKey, FolderJumpStore.staysKey, EditorRecentFiles.key] {
            #expect(!SettingsResetKeeps.keeps(key), "\(key)")
        }
    }

    /// Reset All Settings removes Jump's recents and stays while the app runs, and keeps its pins.
    /// The store must not keep the removed recents in memory and write them back on the next visit.
    @MainActor
    @Test func removedRecentsAreNotWrittenBackAndPinsStay() throws {
        let defaults = ScratchDefaults("SettingsResetJumpStore")
        let store = FolderJumpStore(defaults: defaults)
        let root = "/Users/u/Library/Mobile Documents/com~apple~CloudDocs"
        store.recordVisit(root: root, relativePath: "Old", name: "Old")
        store.togglePin(root: root, relativePath: "Taxes", name: "Taxes")
        try #require(store.recents(forRoot: root).count == 1)
        // What the reset removes of this store's keys.
        defaults.removeObject(forKey: FolderJumpStore.recentsKey)
        defaults.removeObject(forKey: FolderJumpStore.staysKey)
        #expect(store.recents(forRoot: root).isEmpty, "the removed recents are still offered")
        store.recordVisit(root: root, relativePath: "New", name: "New")
        let written = FolderJumpStore.storedMap(FolderJumpStore.recentsKey, from: defaults)
        #expect(written.values.flatMap { $0 }.map(\.relativePath) == ["New"], "the removed recents were written back")
        #expect(store.pinned(forRoot: root).map(\.relativePath) == ["Taxes"])
    }
}
