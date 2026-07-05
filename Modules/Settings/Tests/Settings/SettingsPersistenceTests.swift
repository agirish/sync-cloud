import Testing
import Foundation
@testable import Settings

/// Coverage for the two SettingsManager persistence branches the audit found untested: setPath's
/// empty-string clear path, and the ignoreGoogleDriveNewerDateOnly flag surviving a relaunch.
///
/// Both assert directly against UserDefaults side effects (setPath is synchronous before its
/// background rediscovery Task). setPath uses a provider id no other test touches so it can't race
/// the shared "iCloud" override key; the flag test uses a unique key and restores the original.
@Suite struct SettingsPersistenceTests {

    @MainActor
    @Test func testSetPathEmptyClearsTheOverride() {
        // Unique id -> unique override key, isolated from testPathOverrides / testResetPath.
        let id = "UnitTest-SettingsPersistence-\(UUID().uuidString)"
        let key = "path_override_\(id)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let settings = SettingsManager(autoDiscover: false)

        settings.setPath("/tmp/custom-root", for: id)
        #expect(UserDefaults.standard.string(forKey: key) == "/tmp/custom-root")

        // Empty string must clear the override (removeObject), not persist "".
        settings.setPath("", for: id)
        #expect(UserDefaults.standard.string(forKey: key) == nil)
    }

    @MainActor
    @Test func testIgnoreGoogleDriveFlagPersistsAcrossInstances() {
        let key = "ignoreGoogleDriveNewerDateOnly"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let a = SettingsManager(autoDiscover: false)
        a.ignoreGoogleDriveNewerDateOnly = true // didSet persists
        // A fresh instance reads the persisted value in init.
        #expect(SettingsManager(autoDiscover: false).ignoreGoogleDriveNewerDateOnly == true)

        a.ignoreGoogleDriveNewerDateOnly = false
        #expect(SettingsManager(autoDiscover: false).ignoreGoogleDriveNewerDateOnly == false)
    }
}
