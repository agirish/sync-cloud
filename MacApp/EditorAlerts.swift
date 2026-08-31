import AppKit
import FileExplorer

/// The editor's two modal questions, shaped like `SyncOperationAlerts`: the wording and the
/// button-to-answer mapping are `nonisolated static` and pure, and the only `@MainActor` part is
/// the four lines that build an `NSAlert` and run it.
///
/// **Both questions are about the same thing — not losing work the user did not choose to lose.**
/// One asks before a buffer is dropped, the other before a buffer overwrites a file that changed
/// underneath it. Neither is a warning that can be dismissed into a default: each has an explicit
/// Cancel, and `answer(for:)` is the single place that says which button means what, so no caller
/// can drift into reading Cancel as consent.
@MainActor
enum EditorAlerts {

    // MARK: - Leaving a document with unsaved changes

    /// What the user can do about a dirty buffer they are about to leave.
    enum UnsavedAnswer: Equatable {
        case save
        case discard
        case cancel
    }

    nonisolated static func unsavedMessage(name: String) -> String {
        "Save your changes to “\(name)” before closing it?"
    }

    nonisolated static let unsavedInformativeText =
        "If you don't save, the changes you made since the last save are lost."

    /// Save first (Return), Cancel second (Escape), Discard last — the platform's own order for
    /// this question, and the one that keeps the destructive answer off both default keys.
    nonisolated static let unsavedButtonTitles = ["Save", "Cancel", "Don't Save"]

    nonisolated static func answer(for response: NSApplication.ModalResponse) -> UnsavedAnswer {
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        // Every other response — the second button, a dismissed sheet, anything AppKit adds later
        // — is the answer that changes nothing.
        default: return .cancel
        }
    }

    static func askAboutUnsavedChanges(name: String) -> UnsavedAnswer {
        let alert = NSAlert()
        alert.messageText = unsavedMessage(name: name)
        alert.informativeText = unsavedInformativeText
        for title in unsavedButtonTitles { alert.addButton(withTitle: title) }
        return answer(for: alert.runModal())
    }

    // MARK: - The file changed under the buffer

    /// The message for a file that changed or vanished since it was opened.
    ///
    /// **Two different sentences, because they are two different situations and one of them has a
    /// likely cause worth naming.** A file that is simply *gone* was very probably filed or renamed
    /// by an Organize run in this same window, and saving would put a second copy back at the old
    /// path — so the prompt says so rather than describing a generic conflict.
    nonisolated static func divergenceMessage(name: String,
                                              divergence: EditorFileStore.Divergence) -> String {
        switch divergence {
        case .changed: return "“\(name)” has changed on disk since you opened it."
        case .missing: return "“\(name)” is no longer where you opened it."
        }
    }

    nonisolated static func divergenceInformativeText(
        _ divergence: EditorFileStore.Divergence) -> String {
        switch divergence {
        case .changed:
            return "Saving replaces what's on disk with what's in the editor, and the other "
                + "changes are lost."
        case .missing:
            return "It may have been moved or renamed — by Organize, or outside SyncCloud. "
                + "Saving writes it again at the old location, leaving the moved copy where it is."
        }
    }

    /// The confirm title is the verb, not "OK": the button says what it will do.
    nonisolated static let divergenceButtonTitles = ["Save Anyway", "Cancel"]

    nonisolated static func isConfirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    /// - Returns: `true` when the user asked to write over it anyway.
    static func confirmSaveOverDivergence(name: String,
                                          divergence: EditorFileStore.Divergence) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = divergenceMessage(name: name, divergence: divergence)
        alert.informativeText = divergenceInformativeText(divergence)
        for title in divergenceButtonTitles { alert.addButton(withTitle: title) }
        // The confirming button loses Return, so the destructive answer is never one blind
        // keystroke away — the same guard `SyncOperationAlerts` puts on a permanent delete.
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.first?.hasDestructiveAction = true
        return isConfirmed(alert.runModal())
    }
}
