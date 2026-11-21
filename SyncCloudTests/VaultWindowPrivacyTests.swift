import AppKit
import Sync
import Testing
@testable import SyncCloud

/// A shown ID is kept out of screen sharing: the window that draws it is left out of what other
/// apps can capture, and only while an ID is drawn in full.
@MainActor
@Suite struct VaultWindowPrivacyTests {
    @Test func theWindowIsHiddenOnlyWhileAnIDIsShownAndTheSettingAllows() {
        let on = TestDefaults()
        #expect(VaultWindowPrivacy.sharing(exposed: true, defaults: on.defaults) == .none)
        #expect(VaultWindowPrivacy.sharing(exposed: false, defaults: on.defaults) == .readOnly)
        let off = TestDefaults()
        off.defaults.set(false, forKey: VaultSharingSettings.hidesFromCaptureKey)
        #expect(VaultWindowPrivacy.sharing(exposed: true, defaults: off.defaults) == .readOnly)
    }

    @Test func itIsSetOnTheWindowAndPutBackWhenNoIDIsShown() {
        let scratch = TestDefaults()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(window.sharingType == .readOnly, "AppKit's own default: a test of 'put back' needs it")
        VaultWindowPrivacy.apply(exposed: true, to: window, defaults: scratch.defaults)
        #expect(window.sharingType == .none)
        VaultWindowPrivacy.apply(exposed: false, to: window, defaults: scratch.defaults)
        #expect(window.sharingType == .readOnly)
        VaultWindowPrivacy.apply(exposed: true, to: nil, defaults: scratch.defaults)   // no window yet: nothing to do
    }

    @Test func aCopyIsClearedAfterTheTimeTheSettingGives() {
        // The app's own domain is the user's live setting here, so this reads it and never writes.
        let seconds = VaultSharingSettings.clipboardSeconds()
        #expect(VaultPasteboard.clearAfter == .seconds(seconds))
        #expect(VaultCard.clipboardClears == "It clears from the clipboard after \(VaultSharingSettings.label(seconds: seconds)).")
    }
}
