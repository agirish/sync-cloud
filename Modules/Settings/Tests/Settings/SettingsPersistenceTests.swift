import Testing
import Foundation
@testable import Settings

/// Coverage for the two SettingsManager persistence branches the audit found untested: setPath's
/// empty-string clear path, and the ignoreGoogleDriveNewerDateOnly flag surviving a relaunch.
///
/// Both assert directly against UserDefaults side effects (setPath is synchronous before its
/// background rediscovery Task). Each test injects its own UserDefaults suite, so nothing here
/// touches .standard or races other tests.
@Suite struct SettingsPersistenceTests {

    @MainActor
    @Test func testSetPathEmptyClearsTheOverride() {
        let test = TestDefaults()
        defer { test.wipe() }
        let key = "path_override_Dropbox"

        let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) })

        settings.setPath("/tmp/custom-root", for: "Dropbox")
        #expect(test.defaults.string(forKey: key) == "/tmp/custom-root")

        // Empty string must clear the override (removeObject), not persist "".
        settings.setPath("", for: "Dropbox")
        #expect(test.defaults.string(forKey: key) == nil)
    }

    // testIgnoreGoogleDriveFlagPersistsAcrossInstances was removed 2026-08-22: a line-for-line
    // duplicate of SettingsDiscoveryTests.testIgnoreGoogleDriveFlagRoundTripsThroughInjectedDefaults.
}

/// The stored-tab resolution, which until now no test could reach.
///
/// The launch read is in `MacApp/ContentView.swift`, outside every SPM package, so its `??` was
/// invisible to the whole suite — a doc comment on `SettingsTab` asserted the fallback and named
/// the wrong tab, which is what a claim nothing checks decays into. `resolvingStored` is the seam
/// that makes it checkable; ContentView now calls it rather than spelling the fallback itself.
@Suite struct StoredTabResolutionTests {

    /// Every case survives a round trip. This is the half that keeps the fallback honest: without
    /// it, `resolvingStored` could return `.appearance` unconditionally and every case below would
    /// still pass.
    @Test func everyTabRoundTripsThroughItsStoredValue() {
        for tab in SettingsView.SettingsTab.allCases {
            #expect(SettingsView.SettingsTab.resolvingStored(tab.rawValue) == tab,
                    "\(tab.rawValue) does not survive a round trip through its own raw value")
        }
    }

    /// Nothing stored, nothing readable, and a value no build ever wrote all land on the same tab.
    ///
    /// The third case is the one with teeth. A tab retired in a future release leaves its raw value
    /// in `settingsSelectedTab` on every Mac that used it, and the app reads that string on launch
    /// — so this is the path a *past* user takes through a *future* build, which is exactly the
    /// path nobody runs before shipping.
    @Test func theStoredTabFallsBackWhenUnrecognised() {
        #expect(SettingsView.SettingsTab.resolvingStored(nil) == .appearance)
        #expect(SettingsView.SettingsTab.resolvingStored("") == .appearance)
        #expect(SettingsView.SettingsTab.resolvingStored("a-tab-that-was-retired") == .appearance)
        // Case matters — raw values are exact, and a near miss must not resolve.
        #expect(SettingsView.SettingsTab.resolvingStored("General") == .appearance,
                "resolution is case-insensitive, so a near-miss silently lands on a real tab")
    }
}
