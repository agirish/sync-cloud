import Testing
import Foundation
@testable import Settings

/// SettingsManager persistence: setPath's empty-string clear. Asserted directly against
/// UserDefaults (setPath writes synchronously before its background rediscovery Task), in an
/// injected suite, so nothing touches .standard or races other tests.
@Suite struct SettingsPersistenceTests {

    @MainActor
    @Test func testSetPathEmptyClearsTheOverride() {
        let test = TestDefaults()
        // The root override. `path_override_` is the legacy Location key, which this build reads
        // once at migration and never writes; the maintenance lines still read it as theirs.
        let key = "root_override_Dropbox"

        let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) })

        settings.setPath("/tmp/custom-root", for: "Dropbox")
        #expect(test.defaults.string(forKey: key) == "/tmp/custom-root")

        // Empty string must clear the override (removeObject), not persist "".
        settings.setPath("", for: "Dropbox")
        #expect(test.defaults.string(forKey: key) == nil)
    }

    // The ignoreGoogleDriveNewerDateOnly relaunch is covered by
    // SettingsDiscoveryTests.testIgnoreGoogleDriveFlagRoundTripsThroughInjectedDefaults.
}

/// The stored-tab resolution. The launch read is in `MacApp/ContentView.swift`, outside every SPM
/// package, so ContentView calls `resolvingStored` rather than spelling the fallback itself, and
/// the fallback is tested here.
@Suite struct StoredTabResolutionTests {

    /// Every case survives a round trip. Without this, `resolvingStored` could return `.appearance`
    /// unconditionally and the fallback test below would still pass.
    @Test func everyTabRoundTripsThroughItsStoredValue() {
        for tab in SettingsView.SettingsTab.allCases {
            #expect(SettingsView.SettingsTab.resolvingStored(tab.rawValue) == tab,
                    "\(tab.rawValue) does not survive a round trip through its own raw value")
        }
    }

    /// Nothing stored, nothing readable, and a value no build ever wrote all land on the same tab.
    /// The third matters most: a retired tab leaves its raw value in `settingsSelectedTab` on
    /// every Mac that used it, and the app reads it on launch, a path nobody runs before shipping.
    @Test func theStoredTabFallsBackWhenUnrecognised() {
        #expect(SettingsView.SettingsTab.resolvingStored(nil) == .appearance)
        #expect(SettingsView.SettingsTab.resolvingStored("") == .appearance)
        #expect(SettingsView.SettingsTab.resolvingStored("a-tab-that-was-retired") == .appearance)
        // Case matters: raw values are exact, and a near miss must not resolve.
        #expect(SettingsView.SettingsTab.resolvingStored("General") == .appearance,
                "resolution is case-insensitive, so a near-miss silently lands on a real tab")
    }
}
