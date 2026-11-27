import AppKit
import Quartz
import SwiftUI
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


    /// VT73 (b): Quick Look's shared panel is out of capture while the Vault previews a document,
    /// set by asking for it (which creates it on a first preview), and shares again after.
    @Test func quickLooksPanelIsOutOfCaptureWhileItShowsAVaultDocument() throws {
        let scratch = TestDefaults()
        VaultWindowPrivacy.quickLook(showsVaultDocument: true, defaults: scratch.defaults)
        #expect(QLPreviewPanel.sharedPreviewPanelExists(), "asking for it made it")
        let panel = try #require(QLPreviewPanel.shared())
        defer { panel.sharingType = .readOnly }
        #expect(panel.sharingType == NSWindow.SharingType.none)
        VaultWindowPrivacy.quickLook(showsVaultDocument: false, defaults: scratch.defaults)
        #expect(panel.sharingType == .readOnly)
    }

    /// A sheet or popover is a window of its own, which the Vault's window's setting does not reach:
    /// one that draws a number keeps itself out of capture (the 2026-11-23 review).
    @Test func aSheetThatDrawsANumberIsKeptFromCapture() {
        let scratch = TestDefaults()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(window.sharingType == .readOnly)
        window.contentView = NSHostingView(rootView: Color.clear.keptFromCapture(defaults: scratch.defaults))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(window.sharingType == .none)
    }

    /// A document's name masks any number in it unless its ID may be shown, as People's sources
    /// list draws it (the 2026-11-23 review).
    @Test func aDocumentsNameIsMaskedUnlessItsIDMayBeShown() {
        let path = "/Docs/Passport A38291647.pdf"
        #expect(VaultCard.documentName(path, shown: true) == "Passport A38291647.pdf")
        #expect(VaultCard.documentName(path, shown: false) == VaultMask.fileName(path))
        #expect(VaultCard.documentName(path, shown: false)?.contains("38291647") == false)
    }

    /// A date of birth People draws in full counts as an ID drawn in full (VT73): the window is
    /// kept out of sharing while it shows, though the chosen row may be another person's.
    @Test func aDateOfBirthShownInFullCountsAsAnIDShown() async throws {
        let (model, _, cleanUp) = try await VaultPeopleViewPanelTests.twoDates(); defer { cleanUp() }
        let section = try #require(model.peopleSections.first { !$0.births.isEmpty })
        try #require(model.canShowBirth(in: section), "the rig's Vault is open: its dates are drawn in full")
        model.selection = nil
        #expect(model.drawsAnIDInFull(layout: .people, editing: false))
        #expect(!model.drawsAnIDInFull(layout: .cards, editing: false), "no date is drawn on the cards")
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

    /// A setting of its own, not the Mac's (VT95): what it says is what is used and what is shown.
    @Test func aCopyIsClearedAfterTheTimeTheSettingGives() {
        for (seconds, said) in [(30, "30 seconds"), (120, "2 minutes")] {
            let scratch = TestDefaults()
            scratch.defaults.set(seconds, forKey: VaultSharingSettings.clipboardSecondsKey)
            #expect(VaultPasteboard.clearAfter(in: scratch.defaults) == .seconds(seconds))
            #expect(VaultCard.clipboardClears(in: scratch.defaults) == "It clears from the clipboard after \(said).")
        }
    }

    /// ⌘C and ⌘X in the editor's number field copy the selection concealed and cleared, as the
    /// Vault's Copy does; anywhere else a text view copies as it always has (the second review).
    @Test func copyInTheEditorsNumberFieldIsConcealed() {
        let pasteboard = NSPasteboard(name: .init("vault-editor-copy-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally(); VaultPasteboard.editingNumber = false }
        let editor = NSTextView()
        editor.string = "Z0000009"
        editor.setSelectedRange(NSRange(location: 0, length: 8))
        VaultPasteboard.editingNumber = false
        #expect(!VaultPasteboard.copyOrCut(editor, cut: false, on: pasteboard), "not the number field: the view's own copy")
        VaultPasteboard.editingNumber = true
        #expect(VaultPasteboard.copyOrCut(editor, cut: false, on: pasteboard))
        #expect(pasteboard.string(forType: .string) == "Z0000009")
        #expect(pasteboard.types?.contains(.init("org.nspasteboard.ConcealedType")) == true)
        #expect(VaultPasteboard.copyOrCut(editor, cut: true, on: pasteboard))
        #expect(editor.string.isEmpty, "cut")
        VaultPasteboard.clearPending()
        #expect(pasteboard.string(forType: .string) == nil, "cleared as the Vault's copies are")
    }

    /// A Vault copy a crash left on the clipboard is cleared at the next launch; anything else is
    /// left alone (the third review).
    @Test func aVaultCopyLeftOverIsClearedAtLaunch() {
        let pasteboard = NSPasteboard(name: .init("vault-left-over-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("someone else's", forType: .string)
        VaultPasteboard.clearLeftOver(on: pasteboard)
        #expect(pasteboard.string(forType: .string) == "someone else's")
        // As a copy from a run that crashed leaves it: marked, with no clear to come in this run
        // (copyConcealed here would take the one pending clear from a suite running beside it).
        pasteboard.clearContents()
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: VaultPasteboard.vaultCopyType)
        pasteboard.setString("Z0000009", forType: .string)
        VaultPasteboard.clearLeftOver(on: pasteboard)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    /// The number field's own editor: a right-click menu of editing alone, no Services, no drag
    /// (the third review).
    @Test func theNumberFieldsEditorLetsNothingOutButTheVaultsCopy() throws {
        let editor = VaultNumberFieldEditor()
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let titles = editor.menu(for: event)?.items.map(\.title)
        #expect(titles == ["Cut", "Copy", "Paste", "", "Select All"])
        #expect(editor.validRequestor(forSendType: .string, returnType: nil) == nil, "Services would take the selection")
        #expect(!editor.dragSelection(with: event, offset: .zero, slideBack: false))
        #expect(VaultNumberFieldCell(textCell: "").fieldEditor(for: NSView()) is VaultNumberFieldEditor)
        // Monospaced, at Settings ▸ Text size, as the SwiftUI field it replaced.
        #expect(VaultNumberField.font(scale: 1.25).pointSize > VaultNumberField.font(scale: 1).pointSize)
        #expect(VaultNumberField.font(scale: 1).isFixedPitch)
    }
}
