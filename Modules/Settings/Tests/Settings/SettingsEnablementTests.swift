import Testing

/// A control that turns something on must never be gated on that thing being on. A single
/// `.disabled(!cloudControlsEnabled)` (`useAI && useCloud`) over Intelligence's Claude section would
/// sweep in the toggle that sets `useCloud`, which defaults to false, so the cloud path could never
/// be switched on. A control's disabled state isn't observable from a unit test, so the two gates
/// are static functions and this suite checks they disagree in the state that matters.
@Suite struct CloudGateTests {

    /// AI on, cloud not yet turned on: the toggle must be live, as the only way out of this state.
    @Test func theCloudToggleIsLiveInTheStateItExistsToLeave() {
        #expect(IntelligenceSettingsTab.cloudToggleEnabled(useAI: true),
                "the cloud toggle is disabled while cloud is off — the paid path cannot be enabled")
        #expect(!IntelligenceSettingsTab.cloudControlsEnabled(useAI: true, useCloud: false),
                "the key and model are live before cloud refining is turned on")
    }

    /// The gates are different functions, not two names for one expression. Folding
    /// `cloudToggleEnabled` into `cloudControlsEnabled` looks tidy and must fail here.
    @Test func theTwoGatesDisagreeSomewhere() {
        let states = [(true, true), (true, false), (false, true), (false, false)]
        let disagreements = states.filter { useAI, useCloud in
            IntelligenceSettingsTab.cloudToggleEnabled(useAI: useAI)
                != IntelligenceSettingsTab.cloudControlsEnabled(useAI: useAI, useCloud: useCloud)
        }

        #expect(!disagreements.isEmpty,
                """
                The cloud toggle and the key/model rows are gated identically in all four states, \
                so the toggle is disabled by its own setting — the defect this suite exists for.
                """)
    }

    /// With on-device AI off there is no cloud path, so nothing in the section is operable. Without
    /// this the suite would pass against a `cloudToggleEnabled` that returned `true`.
    @Test func nothingCloudIsOperableWithoutOnDeviceAI() {
        #expect(!IntelligenceSettingsTab.cloudToggleEnabled(useAI: false))
        #expect(!IntelligenceSettingsTab.cloudControlsEnabled(useAI: false, useCloud: true))
    }
}
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
        let settings = test.manager(
            lister: { .read([self.folder("Dropbox"), self.folder("OneDrive-Personal")]) })
        await settings.discoverProviders()

        #expect(settings.enabledProviders.map(\.id) == settings.availableProviders.map(\.id))
        #expect(settings.isEnabled("Dropbox"))
        #expect(settings.isEnabled("OneDrive-Personal"))
    }

    @Test @MainActor func testDisableFiltersEnabledProvidersButKeepsAvailable() async {
        let test = TestDefaults()
        let settings = test.manager(lister: { .read([self.folder("Dropbox")]) })
        await settings.discoverProviders()

        settings.setEnabled(false, for: "Dropbox")

        #expect(!settings.isEnabled("Dropbox"))
        #expect(settings.enabledProviders.map(\.id) == ["iCloud"])
        // Settings still lists the disabled provider so it can be re-enabled.
        #expect(settings.availableProviders.map(\.id) == ["iCloud", "Dropbox"])
    }

    @Test @MainActor func testReEnableRestoresProvider() async {
        let test = TestDefaults()
        let settings = test.manager(lister: { .read([self.folder("Dropbox")]) })
        await settings.discoverProviders()

        settings.setEnabled(false, for: "Dropbox")
        settings.setEnabled(true, for: "Dropbox")

        #expect(settings.isEnabled("Dropbox"))
        #expect(settings.enabledProviders.map(\.id) == ["iCloud", "Dropbox"])
    }

    @Test @MainActor func testDisabledStatePersistsAcrossManagerInstances() async {
        let test = TestDefaults()
        let lister: SettingsManager.CloudStorageLister = { .read([
            URL(fileURLWithPath: "/Users/test/Library/CloudStorage/Dropbox")
        ]) }

        let first = test.manager(lister: lister)
        await first.discoverProviders()
        first.setEnabled(false, for: "Dropbox")

        let second = test.manager(lister: lister)
        await second.discoverProviders()

        #expect(!second.isEnabled("Dropbox"))
        #expect(second.enabledProviders.map(\.id) == ["iCloud"])
    }

    @Test @MainActor func testLastEnabledProviderCannotBeDisabled() async {
        let test = TestDefaults()
        let settings = test.manager(lister: { .read([self.folder("Dropbox")]) })
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

        let settings = test.manager(
            lister: { .read([self.folder("Dropbox"), self.folder("GoogleDrive-me@example.com")]) })
        // Disable Dropbox before it (or Google Drive) is discovered.
        await settings.discoverProviders()
        settings.setEnabled(false, for: "Dropbox")
        await settings.discoverProviders()

        #expect(settings.isEnabled("GoogleDrive-me@example.com"))
        #expect(!settings.isEnabled("Dropbox"))
        #expect(settings.enabledProviders.map(\.id) == ["iCloud", "GoogleDrive-me@example.com"])
    }
}
