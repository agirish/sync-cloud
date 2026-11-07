import Foundation
import Testing
@testable import Sync

/// `FileSyncManager(defaults:)`, which the app's tests build every manager with: in that host
/// `.standard` is the user's live domain. A store it missed would read and write his settings.
@MainActor
@Suite struct FileSyncManagerDefaultsInitTests {

    @Test func everySettingsStoreIsTheGivenSuite() {
        let defaults = ScratchDefaults("FileSyncManagerDefaultsInit")
        let manager = FileSyncManager(defaults: defaults)
        #expect(manager.duplicateIgnoreDefaults === defaults)
        #expect(manager.filingContentDefaults === defaults)
        #expect(manager.filingRuleDefaults === defaults)
    }

    /// The bare form keeps `.standard`, the app's own store: the init adds a door, it moves nothing.
    @Test func theBareManagerKeepsTheStandardStores() {
        let manager = FileSyncManager()
        #expect(manager.duplicateIgnoreDefaults === UserDefaults.standard)
        #expect(manager.filingContentDefaults === UserDefaults.standard)
        #expect(manager.filingRuleDefaults === UserDefaults.standard)
    }
}
