import Testing
import Foundation
@testable import Settings
import Sync

/// Enable/disable of discovered providers: filtering, persistence, and the
/// last-enabled-provider guard.
@Suite struct SettingsEnablementTests {

    private func folder(_ name: String) -> URL {
        URL(fileURLWithPath: "/Users/test/Library/CloudStorage/\(name)")
    }

    @Test @MainActor func testProvidersDefaultToEnabled() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([self.folder("Dropbox"), self.folder("OneDrive-Personal")]) })
        await settings.discoverProviders()

        #expect(settings.enabledProviders.map(\.id) == settings.availableProviders.map(\.id))
        #expect(settings.isEnabled("Dropbox"))
        #expect(settings.isEnabled("OneDrive-Personal"))
    }

    @Test @MainActor func testDisableFiltersEnabledProvidersButKeepsAvailable() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([self.folder("Dropbox")]) })
        await settings.discoverProviders()

        settings.setEnabled(false, for: "Dropbox")

        #expect(!settings.isEnabled("Dropbox"))
        #expect(settings.enabledProviders.map(\.id) == ["iCloud"])
        // Settings still lists the disabled provider so it can be re-enabled.
        #expect(settings.availableProviders.map(\.id) == ["iCloud", "Dropbox"])
    }

    @Test @MainActor func testReEnableRestoresProvider() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([self.folder("Dropbox")]) })
        await settings.discoverProviders()

        settings.setEnabled(false, for: "Dropbox")
        settings.setEnabled(true, for: "Dropbox")

        #expect(settings.isEnabled("Dropbox"))
        #expect(settings.enabledProviders.map(\.id) == ["iCloud", "Dropbox"])
    }

    @Test @MainActor func testDisabledStatePersistsAcrossManagerInstances() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let lister: SettingsManager.CloudStorageLister = { .read([
            URL(fileURLWithPath: "/Users/test/Library/CloudStorage/Dropbox")
        ]) }

        let first = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: lister)
        await first.discoverProviders()
        first.setEnabled(false, for: "Dropbox")

        let second = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: lister)
        await second.discoverProviders()

        #expect(!second.isEnabled("Dropbox"))
        #expect(second.enabledProviders.map(\.id) == ["iCloud"])
    }

    @Test @MainActor func testLastEnabledProviderCannotBeDisabled() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([self.folder("Dropbox")]) })
        await settings.discoverProviders()

        settings.setEnabled(false, for: "Dropbox")
        #expect(!settings.canDisable("iCloud"))

        // Refused: disabling iCloud now would leave no provider for the panes.
        settings.setEnabled(false, for: "iCloud")

        #expect(settings.isEnabled("iCloud"))
        #expect(settings.enabledProviders.map(\.id) == ["iCloud"])
    }

    @Test @MainActor func testNewlyDiscoveredProviderDefaultsToEnabledDespiteOtherDisables() async {
        let test = TestDefaults()
        defer { test.wipe() }

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([self.folder("Dropbox"), self.folder("GoogleDrive-me@example.com")]) })
        // Disable Dropbox before it (or Google Drive) is discovered.
        await settings.discoverProviders()
        settings.setEnabled(false, for: "Dropbox")
        await settings.discoverProviders()

        #expect(settings.isEnabled("GoogleDrive-me@example.com"))
        #expect(!settings.isEnabled("Dropbox"))
        #expect(settings.enabledProviders.map(\.id) == ["iCloud", "GoogleDrive-me@example.com"])
    }
}
