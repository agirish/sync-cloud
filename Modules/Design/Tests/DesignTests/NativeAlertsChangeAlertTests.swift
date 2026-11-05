import AppKit
import Testing
@testable import Design

/// `NativeAlerts.confirmChange`, the confirm/cancel alert for a change that rearranges rather than
/// destroys (⌘K offering to swap the panes so Organize can open on the source you named).
///
/// Asked of the alert `changeAlert` builds, never of `confirmChange`, whose `runModal()` would park
/// the test's main thread on a modal session nothing here can dismiss. The assembly is what sets
/// this dialog apart from the destructive one, so the assembly is what is pinned.
@Suite @MainActor struct NativeAlertsChangeAlertTests {

    private func alert() -> NSAlert {
        NativeAlerts.changeAlert(
            messageText: "Organize shows one source at a time.",
            informativeText: "Swapping the panes puts Dropbox on the left.",
            confirmTitle: "Swap Panes")
    }

    /// Informational, and not marked destructive. `hasDestructiveAction` and `.warning` are macOS's
    /// "this cannot be undone" pair (the caution icon and the red default button), and
    /// `confirmDelete` needs them to mean that. Spent on a reversible view change, they stop meaning
    /// anything on the alert that really moves files to the Trash.
    ///
    /// Only this alert can be asked: `confirmDestructive` builds its alert inside a `runModal()`
    /// this suite can't enter, which is why this one has a factory of its own.
    @Test func theChangeAlertIsNotDressedAsADestruction() throws {
        let change = alert()
        #expect(change.alertStyle == .informational,
                "the pane-swap alert paints the caution icon for a reversible change")
        let confirm = try #require(change.buttons.first,
                                   "the alert has no buttons at all — the check below would be vacuous")
        #expect(!confirm.hasDestructiveAction,
                "the confirm button is marked destructive — macOS will render it as a deletion")
    }

    /// Confirm, then Cancel, with Return on the confirm. NSAlert lays buttons out right to left from
    /// the first added, and the first takes Return, so an inverted pair would put Return on Cancel
    /// and Escape on the change. The confirm carries the caller's verb; `changeAlert` must not
    /// substitute an "OK" of its own.
    @Test func theConfirmComesFirstAndAnswersReturn() {
        let change = alert()
        #expect(change.buttons.count == 2,
                "the change alert no longer offers exactly a confirm and a cancel")
        #expect(change.buttons.first?.title == "Swap Panes",
                "the caller's verb is not the first (default) button")
        #expect(change.buttons.last?.title == "Cancel",
                "there is no Cancel — a dialog with no way out is not a confirmation")
        #expect(change.buttons.first?.keyEquivalent == "\r",
                "Return does not confirm")
        #expect(change.buttons.last?.keyEquivalent == "\u{1b}",
                "Escape does not cancel — a dismissed dialog would apply the change")
    }

    /// The caller's strings arrive intact, in the right fields: the caller builds both so the
    /// dialog can name the folder and both sources.
    @Test func bothTextsReachTheAlert() {
        let change = alert()
        #expect(change.messageText == "Organize shows one source at a time.")
        #expect(change.informativeText == "Swapping the panes puts Dropbox on the left.")
    }
}
