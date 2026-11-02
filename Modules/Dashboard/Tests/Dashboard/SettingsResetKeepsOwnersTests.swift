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
                    SidebarFavoritePlaces.migrationKey, PaneViewMode.columnWidthFloorLiftKey] {
            #expect(SettingsResetKeeps.keeps(key), "\(key)")
        }
    }
}
