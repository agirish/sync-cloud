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

    /// **Said the same way wherever the question comes from** (TE148) — closing, opening another
    /// file, ⌘N — so not "before closing it", which was wrong for all but one of them.
    nonisolated static func unsavedMessage(name: String) -> String {
        "Save your changes to “\(name)”?"
    }

    /// Said only when no cause applies — which a document Edit asks about always has.
    nonisolated static let unsavedInformativeText =
        "If you don’t save, the changes you made since the last save are lost."

    /// **Why this document is being asked about at all** (TE148) — autosave writes everything else
    /// without a word. One line, the first that applies, in this order.
    enum LeaveCause: Equatable {
        /// The file is gone from its path: the text on screen may be the only copy.
        case gone
        /// The file changed on disk while there was typing that is not on it.
        case changed
        /// The last save failed — the reason, reader-facing.
        case failed(String)
        /// The last save landed but couldn't be checked — the stop's own sentence.
        case unchecked(String)
        /// The user switched autosave off for this file.
        case autosaveOff
    }

    nonisolated static func leaveCause(isGone: Bool, stop: EditorAutosaveStop?, autosaveOff: Bool) -> LeaveCause? {
        if isGone || stop == .diverged(.missing) { return .gone }
        switch stop {
        case .diverged(.changed)?: return .changed
        case .failed(let message)?: return .failed(message)
        case .unchecked?: return .unchecked(stop?.detail ?? "")
        default: return autosaveOff ? .autosaveOff : nil
        }
    }

    nonisolated static let onlyCopyLine = "It’s no longer on disk — this text may be the only copy."

    nonisolated static func causeLine(_ cause: LeaveCause) -> String {
        switch cause {
        case .gone: return onlyCopyLine
        case .changed: return "It changed on disk while you were typing."
        case .failed(let message): return "Its last save failed — \(message)"
        case .unchecked(let detail): return detail
        case .autosaveOff: return "Autosave is off for this file."
        }
    }

    /// Save first (Return), Cancel second (Escape), Discard last — the platform's own order for
    /// this question, and the one that keeps the destructive answer off both default keys.
    nonisolated static let unsavedButtonTitles = ["Save", "Cancel", "Don’t Save"]

    nonisolated static func answer(for response: NSApplication.ModalResponse) -> UnsavedAnswer {
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        // Every other response — the second button, a dismissed sheet, anything AppKit adds later
        // — is the answer that changes nothing.
        default: return .cancel
        }
    }

    static func askAboutUnsavedChanges(name: String, cause: LeaveCause?) -> UnsavedAnswer {
        askWithSaveButtons(message: unsavedMessage(name: name),
                           informative: cause.map(causeLine) ?? unsavedInformativeText)
    }

    // MARK: - Leaving a file that is gone (TE146)

    /// **A file deleted with nothing typed** — clean, so autosave had nothing to say, but the text
    /// on screen may be the only copy left. Asked with the close question's buttons; Save is Save
    /// Again.
    nonisolated static func onlyCopyMessage(name: String) -> String { "Save “\(name)” again?" }

    static func askAboutTheOnlyCopy(name: String) -> UnsavedAnswer {
        askWithSaveButtons(message: onlyCopyMessage(name: name), informative: onlyCopyLine)
    }

    /// The same file open read-only, which can't be written back — leaving or quitting can only
    /// lose it, so the question is that and Cancel.
    nonisolated static func goneMessage(name: String) -> String { "“\(name)” is no longer on disk" }

    nonisolated static let readOnlyGoneInformativeText = "Leaving now loses this text — it may be the only copy."

    /// **Don't Save first with Return taken off it, Cancel second** (decision BS): Esc cancels, and
    /// Return does nothing — the destructive answer is never one keystroke away. On screen it reads
    /// Cancel · Don't Save, a two-button alert's first button sitting on the right.
    nonisolated static let readOnlyGoneButtonTitles = ["Don’t Save", "Cancel"]

    /// The first button discards; everything else — Cancel, a dismissed alert — keeps the document.
    nonisolated static func readOnlyGoneAnswer(for response: NSApplication.ModalResponse) -> UnsavedAnswer {
        response == .alertFirstButtonReturn ? .discard : .cancel
    }

    static func askAboutLeavingAGoneReadOnlyFile(name: String) -> UnsavedAnswer {
        readOnlyGoneAnswer(for: readOnlyGoneAlert(name: name).runModal())
    }

    static func readOnlyGoneAlert(name: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = goneMessage(name: name)
        alert.informativeText = readOnlyGoneInformativeText
        for title in readOnlyGoneButtonTitles { alert.addButton(withTitle: title) }
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[0].hasDestructiveAction = true
        return alert
    }

    private static func askWithSaveButtons(message: String, informative: String) -> UnsavedAnswer {
        answer(for: saveButtonsAlert(message: message, informative: informative).runModal())
    }

    /// The close question's three buttons. **Don't Save is marked destructive** (TE176), as Quit
    /// Anyway, Discard Changes and Keep Mine… are, and keeps the ⌘D AppKit gives it — so its key
    /// equivalent is left alone — while Return stays on Save.
    static func saveButtonsAlert(message: String, informative: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        for title in unsavedButtonTitles { alert.addButton(withTitle: title) }
        alert.buttons[2].hasDestructiveAction = true
        return alert
    }

    // MARK: - Keep Mine (TE59, TE97)

    /// Keep Mine… writes the buffer over a version that arrived from elsewhere, so it asks first:
    /// what is lost, in words, and the destructive answer off Return. **Wherever it is pressed** —
    /// the banner, the ⌘S alert, the comparison sheet's foot (TE97): the sheet's used to write
    /// without asking what the banner's asked. See ``keepMineAsks(for:)``.
    nonisolated static func keepMineMessage(name: String) -> String {
        "Replace the version of “\(name)” on disk with yours?"
    }

    nonisolated static let keepMineInformativeText =
        "It was changed somewhere else while you were typing. Keeping your version writes over "
        + "that one, and the other changes are lost."

    /// Keep Mine first, Cancel second — Cancel holds Return and Escape. No ellipsis here: this is
    /// the question the ellipsis on Keep Mine… promised, and its answer writes.
    nonisolated static let keepMineButtonTitles = ["Keep Mine", "Cancel"]

    /// **Whether writing the buffer asks "Replace the version on disk with yours?" first** — for a
    /// file that CHANGED, where there is another version to lose. A file that is no longer there has
    /// nothing at its path to replace; its Save Again writes it back where it was, and the alert
    /// that offered it already said so.
    nonisolated static func keepMineAsks(for divergence: EditorFileStore.Divergence) -> Bool {
        divergence == .changed
    }

    static func confirmKeepMine(name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = keepMineMessage(name: name)
        alert.informativeText = keepMineInformativeText
        for title in keepMineButtonTitles { alert.addButton(withTitle: title) }
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[0].hasDestructiveAction = true
        return isConfirmed(alert.runModal())
    }

    // MARK: - The file changed under the buffer

    /// The message for a file that changed or vanished since it was opened.
    ///
    /// **Two different sentences, because they are two different situations.** A changed file is
    /// said in the banner's words (TE150) — "since you opened it" was wrong once autosave had run. A
    /// gone one is said as gone: a move is followed (TE59), so what is left was deleted, or went with
    /// its folder.
    nonisolated static func divergenceMessage(name: String,
                                              divergence: EditorFileStore.Divergence) -> String {
        switch divergence {
        case .changed: return "“\(name)” changed on disk while you were typing."
        case .missing: return "“\(name)” is no longer where you opened it."
        }
    }

    nonisolated static func divergenceInformativeText(
        _ divergence: EditorFileStore.Divergence) -> String {
        switch divergence {
        case .changed:
            return "Keeping your version replaces the one on disk, and the other changes are lost."
        // What Save Again does (TE151): the banner's write, which looks first and puts back a folder
        // that went too.
        case .missing:
            return "It writes it back where it was, making its folder again if that went too."
        }
    }

    /// What the user can do about a file that moved under the buffer.
    enum DivergenceAnswer: Equatable {
        /// Overwrite what is on disk with the buffer — Keep Mine… for a file that changed, which
        /// asks first (``keepMineAsks(for:)``), and Save Again for one that is gone, which is the
        /// banner's Save Again: it looks first, and makes the folder again (TE151).
        case saveAnyway
        /// Throw the buffer away and take the file — Use Disk Version. **Only offered for
        /// `.changed`** — see ``divergenceButtonTitles(for:)``.
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
        ///
        /// **Save Again discards nothing** (TE151): the file is gone, and it writes only while
        /// nothing is at the path. It is not destructive on the banner, so not here either.
        func isDestructive(for divergence: EditorFileStore.Divergence) -> Bool {
            switch self {
            case .saveAnyway: return divergence == .changed
            case .reloadFromDisk: return true
            case .showWhatChanged, .cancel: return false
            }
        }
    }

    /// **Four buttons for a file that CHANGED, two for one that is GONE**, and the difference is
    /// not tidiness. "Use Disk Version" answers "keep theirs, drop mine" — a real answer when there
    /// is a their-version to read — and "Compare…" opens that version beside the buffer.
    ///
    /// **The changed file's words are the banner's** (TE97, `EditorDiskVerbs`), so the question
    /// reads the same wherever it is asked — and in the banner's order (TE178). The gone file's
    /// Save Again is the banner's too (TE151): there is no "mine" against a "theirs" there, only a
    /// file to write back.
    /// For a file that has been moved or renamed there is nothing at that path to reload OR to
    /// show, so either would be a button that cannot do what it says.
    ///
    /// Both non-cancel *answers* are destructive in opposite directions — one discards what
    /// arrived, the other discards what you typed — so neither keeps Return. "Compare…" discards
    /// nothing and writes nothing, so it comes first and takes Return; see
    /// ``DivergenceAnswer/isDestructive(for:)``.
    ///
    /// **Cancel stays last in both lists**, which is what makes "every other response is Cancel"
    /// in ``divergenceAnswer(for:divergence:)`` the safe rule rather than a coincidence.
    nonisolated static func divergenceButtonTitles(
        for divergence: EditorFileStore.Divergence) -> [String] {
        switch divergence {
        case .changed: return [EditorDiskVerbs.compare, EditorDiskVerbs.useDiskVersion,
                               EditorDiskVerbs.keepMine, "Cancel"]
        case .missing: return [EditorDiskVerbs.saveAgain, "Cancel"]
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
    /// same divergence the titles were built from: the first button is Compare… for a changed file
    /// and Save Again for a missing one, where the second button is Cancel. Reading the position
    /// without the case is how the safe answer becomes the destructive one.
    ///
    /// **The banner's order** (TE178): Compare…, Use Disk Version, Keep Mine…, Cancel. Compare… is
    /// first and so takes Return, which is safe — it writes nothing — and Cancel, last, still falls
    /// through to the default.
    nonisolated static func divergenceAnswer(
        for response: NSApplication.ModalResponse,
        divergence: EditorFileStore.Divergence) -> DivergenceAnswer {
        switch (divergence, response) {
        case (.changed, .alertFirstButtonReturn): return .showWhatChanged
        case (.changed, .alertSecondButtonReturn): return .reloadFromDisk
        case (.changed, .alertThirdButtonReturn): return .saveAnyway
        case (.missing, .alertFirstButtonReturn): return .saveAnyway
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
        // directions. A blind Return opens Compare… or, for a gone file, Save Again.
        //
        // **Which buttons those are is read from the MAPPING, not from their titles.** This used to
        // strip Return from everything not titled "Cancel", which was the same set right up until a
        // button arrived that is neither destructive nor Cancel: "Compare…" would have
        // been styled as a destructive action for opening a read-only diff. Asking
        // `divergenceAnswer` means the styling can only ever land on the positions the click is
        // actually read as destructive.
        for (index, button) in alert.buttons.enumerated()
        where divergenceAnswer(for: divergenceResponse(atButtonIndex: index),
                               divergence: divergence).isDestructive(for: divergence) {
            button.keyEquivalent = ""
            button.hasDestructiveAction = true
        }
        return divergenceAnswer(for: alert.runModal(), divergence: divergence)
    }
}
