import AppKit
import Testing
@testable import Design

/// `NativeAlerts.confirmChange` — the confirm/cancel alert for a change that **rearranges** rather
/// than destroys (⌘K offering to swap the panes so Organize can open on the source you named).
///
/// Asked of the alert `changeAlert` builds, never of `confirmChange` itself: that one ends in
/// `runModal()`, which parks the test's own main thread on a modal session nothing in this harness
/// can dismiss. The assembly is the whole of what distinguishes this dialog from the destructive
/// one, so the assembly is what is pinned.
@Suite @MainActor struct NativeAlertsChangeAlertTests {

    private func alert() -> NSAlert {
        NativeAlerts.changeAlert(
            messageText: "Organize shows one source at a time.",
            informativeText: "Swapping the panes puts Dropbox on the left.",
            confirmTitle: "Swap Panes")
    }

    /// **Informational, and not marked destructive.** `hasDestructiveAction` and `.warning` are
    /// macOS's "this cannot be undone" pair — the caution icon and the red default button — and
    /// `confirmDelete` needs them to mean that. Spending them on a view change that undoes itself
    /// by being done again is how they stop meaning anything on the alert that really does move
    /// files to the Trash.
    ///
    /// Only this alert can be asked: `confirmDestructive`'s assembly is inside a `runModal()` this
    /// suite cannot enter, which is exactly why the non-destructive one was given a factory of its
    /// own rather than a flag on the existing one.
    @Test func theChangeAlertIsNotDressedAsADestruction() throws {
        let change = alert()
        #expect(change.alertStyle == .informational,
                "the pane-swap alert paints the caution icon for a reversible change")
        let confirm = try #require(change.buttons.first,
                                   "the alert has no buttons at all — the check below would be vacuous")
        #expect(!confirm.hasDestructiveAction,
                "the confirm button is marked destructive — macOS will render it as a deletion")
    }

    /// **Confirm, then Cancel — in that order, with Return on the confirm.**
    ///
    /// The order is the button order on screen (NSAlert lays them out right to left from the first
    /// added), so an inverted pair puts Cancel under Return: a route the user meant to decline
    /// would apply on the keypress that meant to refuse it. And the confirm names its verb, which
    /// is the caller's contract — `changeAlert` must not substitute an "OK" of its own.
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

    /// The caller's strings arrive intact. Trivial to satisfy and worth one line: both texts are
    /// built by the caller specifically so the dialog can name the folder and both sources, and a
    /// summary silently dropped into the wrong field is a dialog that explains nothing.
    @Test func bothTextsReachTheAlert() {
        let change = alert()
        #expect(change.messageText == "Organize shows one source at a time.")
        #expect(change.informativeText == "Swapping the panes puts Dropbox on the left.")
    }
}
