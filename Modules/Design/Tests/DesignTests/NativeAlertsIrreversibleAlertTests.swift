import AppKit
import Testing
@testable import Design

/// `NativeAlerts.confirmIrreversible` — the confirm/cancel alert for a deletion with no Trash to
/// come back from (the API key, the spend totals the caps count against).
///
/// Asked of the alert `irreversibleAlert` builds, never of `confirmIrreversible`, whose
/// `runModal()` would park this test's main thread on a session nothing here can dismiss.
@Suite @MainActor struct NativeAlertsIrreversibleAlertTests {

    private func alert() -> NSAlert {
        NativeAlerts.irreversibleAlert(messageText: "Remove the API key?",
                                       informativeText: "This deletes it from the Keychain.",
                                       confirmTitle: "Remove Key")
    }

    /// **Return cancels.** The destructive button comes first, is marked destructive, and takes no
    /// key at all; Cancel answers Return — the convention of Sync History's Clear History and
    /// Settings' Reset All Settings…, and the opposite of `confirmDelete`, whose items go to the
    /// Trash and can come back.
    @Test func cancelIsTheDefaultAndTheDestructionTakesNoKey() throws {
        let built = alert()
        #expect(built.alertStyle == .warning)
        #expect(built.buttons.count == 2, "the alert no longer offers exactly a confirm and a cancel")
        let confirm = try #require(built.buttons.first)
        let cancel = try #require(built.buttons.last)
        #expect(confirm.title == "Remove Key")
        #expect(confirm.hasDestructiveAction, "the confirm is not marked destructive")
        #expect(confirm.keyEquivalent == "", "Return or Escape would delete")
        #expect(cancel.title == "Cancel")
        #expect(cancel.keyEquivalent == "\r", "Return does not cancel")
    }

    @Test func theCallersWordsArriveIntact() {
        let built = alert()
        #expect(built.messageText == "Remove the API key?")
        #expect(built.informativeText == "This deletes it from the Keychain.")
    }
}
