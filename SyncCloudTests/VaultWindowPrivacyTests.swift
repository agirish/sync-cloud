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

    /// A date of birth People draws in full counts as an ID drawn in full (VT73): the window is
    /// kept out of sharing while it shows, though the chosen row may be another person's.
    @Test func aDateOfBirthShownInFullCountsAsAnIDShown() async throws {
        let (model, _, cleanUp) = try await VaultPeopleViewPanelTests.twoDates(); defer { cleanUp() }
        let section = try #require(model.peopleSections.first { !$0.births.isEmpty })
        try #require(model.canShowBirth(in: section), "the rig's Vault is open: its dates are drawn in full")
        model.selection = nil
        #expect(VaultCard.drawsAnIDInFull(model, layout: .people, editing: false))
        #expect(!VaultCard.drawsAnIDInFull(model, layout: .cards, editing: false), "no date is drawn on the cards")
    }

    /// A window that arrives after the panel first decided is set as it arrives (VT73).
    /// A window that arrives after the panel first decided is set as it arrives, and one the
    /// panel leaves shares again (VT73).
    @Test func aWindowThatArrivesLateIsSetAsItArrivesAndOneLeftSharesAgain() {
        let scratch = TestDefaults()   // "Hide from screen sharing" on, whatever the Mac's own is
        let watch = VaultActivityWatch()
        watch.defaults = scratch.defaults
        watch.exposed = true
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        let first = window(), second = window()
        watch.window = first
        #expect(first.sharingType == .none, "the window arrived after the panel decided, and was not set")
        watch.window = second
        #expect(second.sharingType == .none)
        #expect(first.sharingType == .readOnly, "the window the panel left does not share again")
    }

    @Test func aCopyIsClearedAfterTheTimeTheSettingGives() {
        // The app's own domain is the user's live setting here, so this reads it and never writes.
        let seconds = VaultSharingSettings.clipboardSeconds()
        #expect(VaultPasteboard.clearAfter == .seconds(seconds))
        #expect(VaultCard.clipboardClears == "It clears from the clipboard after \(VaultSharingSettings.label(seconds: seconds)).")
    }
}
