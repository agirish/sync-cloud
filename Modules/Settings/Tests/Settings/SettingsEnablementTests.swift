import Testing

/// The rule a whole feature went missing behind: **a control that turns something on must never
/// be gated on that thing being on.**
///
/// Intelligence's Claude section shipped for exactly one build with a single
/// `.disabled(!cloudControlsEnabled)` over the section, where `cloudControlsEnabled` is
/// `useAI && useCloud`. That swept in the toggle that sets `useCloud`, and `useCloud` defaults to
/// false — so the cloud path could not be switched on at all, by anyone, ever. It was invisible
/// to all 215 tests in this package, because a SwiftUI control's disabled state is not observable
/// from a unit test; it took rendering the tab to a PNG and looking at it.
///
/// So the two gates are static functions rather than one inline expression, and this is what
/// holds them apart. It cannot see the `.disabled` modifiers themselves — nothing here can — but
/// it can see the two rules disagree in the one state that matters, which is what the bug was.
@Suite struct CloudGateTests {

    /// The state the defect lived in: AI on, cloud not yet turned on. The toggle MUST be live —
    /// it is the only way out of this state.
    @Test func theCloudToggleIsLiveInTheStateItExistsToLeave() {
        #expect(IntelligenceSettingsTab.cloudToggleEnabled(useAI: true),
                "the cloud toggle is disabled while cloud is off — the paid path cannot be enabled")
        #expect(!IntelligenceSettingsTab.cloudControlsEnabled(useAI: true, useCloud: false),
                "the key and model are live before cloud refining is turned on")
    }

    /// The gates are genuinely different functions, not two names for one expression. Without
    /// this, someone folding `cloudToggleEnabled` back into `cloudControlsEnabled` — which is a
    /// tidy-looking simplification — reintroduces the defect exactly.
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

    /// The other half: with on-device AI off there is no cloud path at all, so nothing in the
    /// section is operable. Without this the suite would pass against a `cloudToggleEnabled` that
    /// simply returned `true`.
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
        defer { test.wipe() }
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { [self.folder("Dropbox"), self.folder("OneDrive-Personal")] })
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
            cloudStorageLister: { [self.folder("Dropbox")] })
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
            cloudStorageLister: { [self.folder("Dropbox")] })
        await settings.discoverProviders()

        settings.setEnabled(false, for: "Dropbox")
        settings.setEnabled(true, for: "Dropbox")

        #expect(settings.isEnabled("Dropbox"))
        #expect(settings.enabledProviders.map(\.id) == ["iCloud", "Dropbox"])
    }

    @Test @MainActor func testDisabledStatePersistsAcrossManagerInstances() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let lister: SettingsManager.CloudStorageLister = { [
            URL(fileURLWithPath: "/Users/test/Library/CloudStorage/Dropbox")
        ] }

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
            cloudStorageLister: { [self.folder("Dropbox")] })
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
            cloudStorageLister: { [self.folder("Dropbox"), self.folder("GoogleDrive-me@example.com")] })
        // Disable Dropbox before it (or Google Drive) is discovered.
        await settings.discoverProviders()
        settings.setEnabled(false, for: "Dropbox")
        await settings.discoverProviders()

        #expect(settings.isEnabled("GoogleDrive-me@example.com"))
        #expect(!settings.isEnabled("Dropbox"))
        #expect(settings.enabledProviders.map(\.id) == ["iCloud", "GoogleDrive-me@example.com"])
    }
}
