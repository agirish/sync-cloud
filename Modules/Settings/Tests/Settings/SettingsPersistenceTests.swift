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

    @MainActor
    @Test func testIgnoreGoogleDriveFlagPersistsAcrossInstances() {
        let test = TestDefaults()
        defer { test.wipe() }
        func makeManager() -> SettingsManager {
            SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) })
        }

        let a = makeManager()
        a.ignoreGoogleDriveNewerDateOnly = true // didSet persists
        // A fresh instance reads the persisted value in init.
        #expect(makeManager().ignoreGoogleDriveNewerDateOnly == true)

        a.ignoreGoogleDriveNewerDateOnly = false
        #expect(makeManager().ignoreGoogleDriveNewerDateOnly == false)
    }
}
