import Testing
import Foundation
@testable import Settings
import Sync

@Suite struct SettingsManagerTests {

    @Test @MainActor func testDefaultICloudProvider() {
        let test = TestDefaults()
        defer { test.wipe() }
        let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) })

        // SettingsManager starts with 1 default iCloud provider, before any discovery
        #expect(settings.availableProviders.count >= 1)
        #expect(settings.availableProviders.first?.id == "iCloud")
    }

    // testPathOverrides was removed 2026-08-22: a strict subset of
    // SettingsDiscoveryTests.testSetPathResetPathRoundTripWithoutGlobalState (which also asserts
    // the defaults key), with the iCloud-specific angle covered by the seed test below, including
    // the override surviving a subsequent discovery.

    /// The init-time seed must consult the persisted iCloud path/name overrides (and compute
    /// validity against the effective path), exactly like discovery does — otherwise anything
    /// rendered pre-discovery flashes the default path, default name, and a wrong badge.
    @Test @MainActor func testInitSeedHonorsPersistedICloudOverrides() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let overridePath = "/Volumes/External/iCloudDocs"
        test.defaults.set(overridePath, forKey: "root_override_iCloud")
        test.defaults.set("My iCloud", forKey: "name_override_iCloud")

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([]) },
            // Only the override path exists on "disk": the badge must be valid immediately,
            // proving validity was computed against the effective path, not the default.
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
        defer { test.wipe() }
        let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) })
        #expect(settings.rootPath(for: "NonExistent") == "")
    }
}
