import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// How long a copy stays on the clipboard, and whether a shown ID is kept out of screen sharing.
@Suite struct VaultSharingTests {
    static func scratch() throws -> UserDefaults {
        vaultScratchDefaults("vault-sharing")
    }

    @Test func aCopyStaysAMinuteUnlessAnotherOfTheChoicesIsSaved() throws {
        let defaults = try Self.scratch()
        #expect(VaultSharingSettings.clipboardSeconds(in: defaults) == 60)
        defaults.set(30, forKey: VaultSharingSettings.clipboardSecondsKey)
        #expect(VaultSharingSettings.clipboardSeconds(in: defaults) == 30)
        // A value no choice offers, as `defaults write` could leave: never an hour on the clipboard.
        defaults.set(3600, forKey: VaultSharingSettings.clipboardSecondsKey)
        #expect(VaultSharingSettings.clipboardSeconds(in: defaults) == 60)
        defaults.set(0, forKey: VaultSharingSettings.clipboardSecondsKey)
        #expect(VaultSharingSettings.clipboardSeconds(in: defaults) == 60)
    }

    @Test func eachChoiceIsSaidInWords() {
        #expect(VaultSharingSettings.clipboardChoices.map(VaultSharingSettings.label(seconds:))
                == ["30 seconds", "1 minute", "2 minutes", "5 minutes"])
    }

    @Test func aShownIDIsHiddenFromCaptureUnlessTurnedOff() throws {
        let defaults = try Self.scratch()
        #expect(VaultSharingSettings.hidesFromCapture(in: defaults), "on with nothing saved")
        defaults.set(false, forKey: VaultSharingSettings.hidesFromCaptureKey)
        #expect(!VaultSharingSettings.hidesFromCapture(in: defaults))
        // A damaged value reads as the safe choice.
        defaults.set("nonsense", forKey: VaultSharingSettings.hidesFromCaptureKey)
        #expect(VaultSharingSettings.hidesFromCapture(in: defaults))
    }
}
