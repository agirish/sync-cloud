import Testing
import Foundation
@testable import Settings
import Sync

@Suite struct SettingsManagerTests {

    @Test @MainActor func testDefaultICloudProvider() {
        let test = TestDefaults()
        defer { test.wipe() }
        let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { [] })

        // SettingsManager starts with 1 default iCloud provider, before any discovery
        #expect(settings.availableProviders.count >= 1)
        #expect(settings.availableProviders.first?.id == "iCloud")
    }

    @Test @MainActor func testPathOverrides() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { [] })
        let testPath = "/tmp/test_override"

        settings.setPath(testPath, for: "iCloud")
        await settings.discoverProviders()
        #expect(settings.path(for: "iCloud") == testPath)

        settings.resetPath(for: "iCloud")
        await settings.discoverProviders()
        #expect(settings.path(for: "iCloud") != testPath)
    }

    @Test @MainActor func testPathForMissingProvider() {
        let test = TestDefaults()
        defer { test.wipe() }
        let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { [] })
        #expect(settings.path(for: "NonExistent") == "")
    }
}
