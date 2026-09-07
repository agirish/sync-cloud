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
        /// **Not an answer: a detour.** Show the reader what actually arrived, and then ask the
        /// same three questions again at the foot of the diff. **Only offered for `.changed`** —
        /// a file that has moved or been renamed has nothing at its path to read, so there is
        /// nothing to put in the right-hand column.
        ///
        /// Every caller has to LOOP on this rather than fall through: it resolves nothing, and a
        /// `switch` that treats it as a third way of saying "no" would leave the document stopped
        /// with the question silently dropped. See `ContentView+Editor.applyDivergenceAnswer`,
        /// which is the one place that acts on this enum, precisely so there is one loop and not
        /// two.
        case showWhatChanged
        /// Change nothing, and leave autosave stopped.
        case cancel

        /// Whether taking this answer discards something.
        ///
        /// **The two destructive answers discard in OPPOSITE directions** — one throws away what
        /// arrived, the other throws away what you typed — which is why neither may hold Return and
        /// both wear AppKit's destructive styling. Asked of the *answer* rather than of the button
        /// title so the styling and the click are read through the same mapping: a reordered title
        /// list cannot leave the styling on one button and the meaning on another.
        var isDestructive: Bool {
            switch self {
            case .saveAnyway, .reloadFromDisk: return true
            case .showWhatChanged, .cancel: return false
            }
        }
    }

    /// **Four buttons for a file that CHANGED, two for one that is GONE**, and the difference is
    /// not tidiness. "Reload from Disk" answers "keep theirs, drop mine" — a real answer when there
    /// is a their-version to read — and "Show What Changed…" opens that version beside the buffer.
    /// For a file that has been moved or renamed there is nothing at that path to reload OR to
    /// show, so either would be a button that cannot do what it says.
    ///
    /// Both non-cancel *answers* are destructive in opposite directions — one discards what
    /// arrived, the other discards what you typed — so Cancel is the safe landing and neither of
    /// the others keeps Return. "Show What Changed…" discards nothing and writes nothing, so it is
    /// neither; see ``DivergenceAnswer/isDestructive``.
    ///
    /// **Cancel stays last in both lists**, which is what makes "every other response is Cancel"
    /// in ``divergenceAnswer(for:divergence:)`` the safe rule rather than a coincidence.
    nonisolated static func divergenceButtonTitles(
        for divergence: EditorFileStore.Divergence) -> [String] {
        switch divergence {
        case .changed: return ["Save Anyway", "Reload from Disk", "Show What Changed…", "Cancel"]
        case .missing: return ["Save Anyway", "Cancel"]
        }
    }

    /// The response AppKit hands back for the button at `index`.
    ///
    /// **`NSAlert` numbers its buttons upward from `alertFirstButtonReturn`**, and only the first
    /// three have names — a four-button alert's last one is `alertThirdButtonReturn + 1`, which is
    /// exactly the kind of literal that goes wrong when a button is added. Named here so the
    /// styling loop below and the tests both read positions the same way the runtime does.
    nonisolated static func divergenceResponse(atButtonIndex index: Int)
        -> NSApplication.ModalResponse {
        NSApplication.ModalResponse(
            rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }

    /// **The one place a button position becomes an answer**, and it has to be read against the
    /// same divergence the titles were built from: "Reload from Disk" is the second button for a
    /// changed file and does not exist for a missing one, where the second button is Cancel.
    /// Reading the position without the case is how the safe answer becomes the destructive one.
    ///
    /// **Adding "Show What Changed…" moved nothing.** It went in at position three — after both
    /// real answers and before Cancel — so `.saveAnyway` is still the first button and
    /// `.reloadFromDisk` still the second, and Cancel still falls through to the default. That is
    /// deliberate: a new button inserted ahead of an existing one silently redefines every position
    /// after it, and the two answers it would have shifted are the destructive ones.
    nonisolated static func divergenceAnswer(
        for response: NSApplication.ModalResponse,
        divergence: EditorFileStore.Divergence) -> DivergenceAnswer {
        switch (divergence, response) {
        case (_, .alertFirstButtonReturn): return .saveAnyway
        case (.changed, .alertSecondButtonReturn): return .reloadFromDisk
        case (.changed, .alertThirdButtonReturn): return .showWhatChanged
        // Every other response — Cancel, a dismissed sheet, anything AppKit adds later — is the
        // answer that changes nothing.
        default: return .cancel
        }
    }

    nonisolated static func isConfirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    /// **The diff overlay's three verbs ARE these three answers**, coming back from the detour.
    ///
    /// A total mapping, written out rather than left to a shared raw value, so it is impossible for
    /// the overlay to hand back `.showWhatChanged` — which would reopen the overlay from inside
    /// itself and leave the question unanswerable except by quitting. The overlay's type has no such
    /// case; this is the assertion that it never grows one silently.
    nonisolated static func divergenceAnswer(
        for verdict: EditorDivergenceVerdict) -> DivergenceAnswer {
        switch verdict {
        case .saveAnyway: return .saveAnyway
        case .reloadFromDisk: return .reloadFromDisk
        case .cancel: return .cancel
        }
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
        //
        // **Which buttons those are is read from the MAPPING, not from their titles.** This used to
        // strip Return from everything not titled "Cancel", which was the same set right up until a
        // button arrived that is neither destructive nor Cancel: "Show What Changed…" would have
        // been styled as a destructive action for opening a read-only diff. Asking
        // `divergenceAnswer` means the styling can only ever land on the positions the click is
        // actually read as destructive.
        for (index, button) in alert.buttons.enumerated()
        where divergenceAnswer(for: divergenceResponse(atButtonIndex: index),
                               divergence: divergence).isDestructive {
            button.keyEquivalent = ""
            button.hasDestructiveAction = true
        }
        return divergenceAnswer(for: alert.runModal(), divergence: divergence)
    }
}
