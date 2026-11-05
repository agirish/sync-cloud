import Testing
import Foundation
@testable import Settings
import Sync

@Suite struct SettingsManagerTests {

    @Test @MainActor func testDefaultICloudProvider() {
        let test = TestDefaults()
        let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) })

        // SettingsManager starts with 1 default iCloud provider, before any discovery
        #expect(settings.availableProviders.count >= 1)
        #expect(settings.availableProviders.first?.id == "iCloud")
    }

    // Path overrides are covered by
    // SettingsDiscoveryTests.testSetPathResetPathRoundTripWithoutGlobalState, and the iCloud case,
    // including the override surviving discovery, by the seed test below.

    /// The init-time seed applies the persisted iCloud path and name overrides, and computes
    /// validity against the effective path, as discovery does; otherwise anything rendered before
    /// discovery flashes the default path, default name and a wrong badge.
    @Test @MainActor func testInitSeedHonorsPersistedICloudOverrides() async {
        let test = TestDefaults()
        let overridePath = "/Volumes/External/iCloudDocs"
        test.defaults.set(overridePath, forKey: "root_override_iCloud")
        test.defaults.set("My iCloud", forKey: "name_override_iCloud")

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([]) },
            // Only the override path exists on "disk", so a valid badge right away shows validity
            // was computed against the effective path, not the default.
            pathValidator: { $0 == overridePath })

        #expect(settings.availableProviders.map(\.id) == ["iCloud"])
        #expect(settings.rootPath(for: "iCloud") == overridePath)
        #expect(settings.availableProviders.first?.displayName == "My iCloud")
        #expect(settings.isPathValid(for: "iCloud") == true)

        // The seed and the first discovery publish agree: discovery changes nothing here.
        let seeded = settings.availableProviders
        await settings.discoverProviders()
        #expect(settings.availableProviders == seeded)
        #expect(settings.isPathValid(for: "iCloud") == true)
    }

    @Test @MainActor func testPathForMissingProvider() {
        let test = TestDefaults()
        let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) })
        #expect(settings.rootPath(for: "NonExistent") == "")
    }
}
