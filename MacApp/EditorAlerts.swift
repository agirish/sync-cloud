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

    /// What the user can do about a file that moved under the buffer.
    enum DivergenceAnswer: Equatable {
        /// Overwrite what is on disk with the buffer.
        case saveAnyway
        /// Throw the buffer away and re-read the file. **Only offered for `.changed`** — see
        /// ``divergenceButtonTitles(for:)``.
        case reloadFromDisk
        /// Change nothing, and leave autosave stopped.
        case cancel
    }

    /// **Three buttons for a file that CHANGED, two for one that is GONE**, and the difference is
    /// not tidiness. "Reload from Disk" answers "keep theirs, drop mine" — a real answer when there
    /// is a their-version to read. For a file that has been moved or renamed there is nothing at
    /// that path to reload, so offering it would be a button that cannot do what it says.
    ///
    /// Both non-cancel answers are destructive in opposite directions — one discards what arrived,
    /// the other discards what you typed — so Cancel is the safe default and neither of the others
    /// keeps Return.
    nonisolated static func divergenceButtonTitles(
        for divergence: EditorFileStore.Divergence) -> [String] {
        switch divergence {
        case .changed: return ["Save Anyway", "Reload from Disk", "Cancel"]
        case .missing: return ["Save Anyway", "Cancel"]
        }
    }

    /// **The one place a button position becomes an answer**, and it has to be read against the
    /// same divergence the titles were built from: "Reload from Disk" is the second button for a
    /// changed file and does not exist for a missing one, where the second button is Cancel.
    /// Reading the position without the case is how the safe answer becomes the destructive one.
    nonisolated static func divergenceAnswer(
        for response: NSApplication.ModalResponse,
        divergence: EditorFileStore.Divergence) -> DivergenceAnswer {
        switch (divergence, response) {
        case (_, .alertFirstButtonReturn): return .saveAnyway
        case (.changed, .alertSecondButtonReturn): return .reloadFromDisk
        // Every other response — Cancel, a dismissed sheet, anything AppKit adds later — is the
        // answer that changes nothing.
        default: return .cancel
        }
    }

    nonisolated static func isConfirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    /// Asks which version wins.
    static func askAboutDivergence(name: String,
                                   divergence: EditorFileStore.Divergence) -> DivergenceAnswer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = divergenceMessage(name: name, divergence: divergence)
        alert.informativeText = divergenceInformativeText(divergence)
        let titles = divergenceButtonTitles(for: divergence)
        for title in titles { alert.addButton(withTitle: title) }
        // **Neither destructive answer keeps Return**, which is the same guard `SyncOperationAlerts`
        // puts on a permanent delete — and there are two of them here, discarding in opposite
        // directions. Cancel is what a blind Return does.
        for (index, button) in alert.buttons.enumerated() where titles[index] != "Cancel" {
            button.keyEquivalent = ""
            button.hasDestructiveAction = true
        }
        return divergenceAnswer(for: alert.runModal(), divergence: divergence)
    }
}
