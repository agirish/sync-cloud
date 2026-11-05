import AppKit
import FileExplorer

/// The editor's modal questions, shaped like `SyncOperationAlerts`: the wording and the
/// button-to-answer mapping are `nonisolated static` and pure, and only the lines that build and
/// run an `NSAlert` are `@MainActor`.
///
/// Each guards against losing work the user didn't choose to lose: before a buffer is dropped, or
/// before it overwrites a file that changed underneath it. Each has an explicit Cancel, and one
/// mapping per question says which button means what, so no caller can read Cancel as consent.
@MainActor
enum EditorAlerts {

    // MARK: - Leaving a document with unsaved changes

    /// What the user can do about a dirty buffer they are about to leave.
    enum UnsavedAnswer: Equatable {
        case save
        case discard
        case cancel
    }

    /// The same words wherever the question comes from (closing, opening another file, ⌘N), so it
    /// doesn't say "before closing it".
    nonisolated static func unsavedMessage(name: String) -> String {
        "Save your changes to “\(name)”?"
    }

    /// Said only when no cause applies — which a document Edit asks about always has.
    nonisolated static let unsavedInformativeText =
        "If you don’t save, the changes you made since the last save are lost."

    /// Why this document is being asked about at all, since autosave writes everything else
    /// silently. One line: the first case that applies, in this order.
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
        // Every other response (the second button, a dismissed sheet, anything AppKit adds later)
        // changes nothing.
        default: return .cancel
        }
    }

    static func askAboutUnsavedChanges(name: String, cause: LeaveCause?) -> UnsavedAnswer {
        askWithSaveButtons(message: unsavedMessage(name: name),
                           informative: cause.map(causeLine) ?? unsavedInformativeText)
    }

    // MARK: - Leaving a file that is gone (TE146)

    /// A file deleted with nothing typed: clean, so autosave had nothing to say, but the text on
    /// screen may be the only copy left. Asked with the close question's buttons; Save is Save
    /// Again.
    nonisolated static func onlyCopyMessage(name: String) -> String { "Save “\(name)” again?" }

    static func askAboutTheOnlyCopy(name: String) -> UnsavedAnswer {
        askWithSaveButtons(message: onlyCopyMessage(name: name), informative: onlyCopyLine)
    }

    /// The same file open read-only, which can't be written back — leaving or quitting can only
    /// lose it, so the question is that and Cancel.
    nonisolated static func goneMessage(name: String) -> String { "“\(name)” is no longer on disk" }

    nonisolated static let readOnlyGoneInformativeText = "Leaving now loses this text — it may be the only copy."

    /// Don't Save first with Return taken off it, Cancel second: Esc cancels and Return does
    /// nothing, so the destructive answer is never one keystroke away. On screen it reads
    /// Cancel · Don't Save, since a two-button alert's first button sits on the right.
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

    /// The close question's three buttons. Don't Save is marked destructive, like Quit Anyway,
    /// Discard Changes and Keep Mine…, and keeps the ⌘D AppKit gives it; Return stays on Save.
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
    /// what is lost, in words, with the destructive answer off Return. It asks wherever it is
    /// pressed: the banner, the ⌘S alert, the comparison sheet's foot. See ``keepMineAsks(for:)``.
    nonisolated static func keepMineMessage(name: String) -> String {
        "Replace the version of “\(name)” on disk with yours?"
    }

    nonisolated static let keepMineInformativeText =
        "It was changed somewhere else while you were typing. Keeping your version writes over "
        + "that one, and the other changes are lost."

    /// Keep Mine first, Cancel second; Cancel holds Return and Escape. No ellipsis: this is the
    /// question the ellipsis on Keep Mine… promised, and its answer writes.
    nonisolated static let keepMineButtonTitles = ["Keep Mine", "Cancel"]

    /// Whether writing the buffer asks "Replace the version on disk with yours?" first: only for a
    /// file that changed, where there is another version to lose. A gone file has nothing at its
    /// path to replace; its Save Again writes it back, and the alert that offered it said so.
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

    /// The message for a file that changed or vanished since it was opened, in the banner's words.
    /// "While you were typing", not "since you opened it", because autosave may have run since. A
    /// move is followed, so a missing file was deleted or went with its folder, and is said as gone.
    nonisolated static func divergenceMessage(name: String,
                                              divergence: EditorFileStore.Divergence) -> String {
        switch divergence {
        case .changed: return "“\(name)” changed on disk while you were typing."
        case .missing: return goneMessage(name: name) + "."
        }
    }

    nonisolated static func divergenceInformativeText(
        _ divergence: EditorFileStore.Divergence) -> String {
        switch divergence {
        case .changed:
            return "Keeping your version replaces the one on disk, and the other changes are lost."
        // What Save Again does: the banner's write, which looks first and puts back a folder that
        // went too.
        case .missing:
            return "Save Again writes it back where it was, making its folder again if that went too."
        }
    }

    /// What the user can do about a file that moved under the buffer.
    enum DivergenceAnswer: Equatable {
        /// Overwrite what is on disk with the buffer: Keep Mine… for a changed file, which asks
        /// first (``keepMineAsks(for:)``), and the banner's Save Again for a gone one, which looks
        /// first and makes the folder again.
        case saveAnyway
        /// Throw the buffer away and take the file: Use Disk Version. Only offered for `.changed`;
        /// see ``divergenceButtonTitles(for:)``.
        case reloadFromDisk
        /// Not an answer but a detour: show what arrived, then ask the same three questions at the
        /// foot of the diff. Only offered for `.changed`, since a gone file has nothing to show.
        ///
        /// **Callers must loop on this**, not fall through: it resolves nothing, and treating it as
        /// "no" would leave the document stopped with the question dropped.
        /// `ContentView+Editor.applyDivergenceAnswer` is the one place that acts on this enum, so
        /// there is one loop.
        case showWhatChanged
        /// Change nothing, and leave autosave stopped.
        case cancel

        /// Whether taking this answer discards something. The two destructive answers discard in
        /// opposite directions (what arrived, or what you typed), so neither holds Return and both
        /// get AppKit's destructive styling. Asked of the answer, not the title, so styling and
        /// click read the same mapping. Save Again discards nothing: it writes only while nothing
        /// is at the path.
        func isDestructive(for divergence: EditorFileStore.Divergence) -> Bool {
            switch self {
            case .saveAnyway: return divergence == .changed
            case .reloadFromDisk: return true
            case .showWhatChanged, .cancel: return false
            }
        }
    }

    /// Four buttons for a changed file, two for a gone one, in the banner's words and order
    /// (`EditorDiskVerbs`). A gone file has no other version to reload or compare, so it gets only
    /// Save Again.
    ///
    /// Compare… writes nothing, so it comes first and takes Return; the destructive answers don't
    /// (``DivergenceAnswer/isDestructive(for:)``). Cancel stays last in both lists, which is what
    /// makes "every other response is Cancel" in ``divergenceAnswer(for:divergence:)`` safe.
    nonisolated static func divergenceButtonTitles(
        for divergence: EditorFileStore.Divergence) -> [String] {
        switch divergence {
        case .changed: return [EditorDiskVerbs.compare, EditorDiskVerbs.useDiskVersion,
                               EditorDiskVerbs.keepMine, "Cancel"]
        case .missing: return [EditorDiskVerbs.saveAgain, "Cancel"]
        }
    }

    /// The response AppKit hands back for the button at `index`. `NSAlert` numbers buttons upward
    /// from `alertFirstButtonReturn` and names only three, so a fourth is `alertThirdButtonReturn +
    /// 1`; the styling loop and the tests read positions through this, as the runtime does.
    nonisolated static func divergenceResponse(atButtonIndex index: Int)
        -> NSApplication.ModalResponse {
        NSApplication.ModalResponse(
            rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }

    /// The one place a button position becomes an answer, read against the divergence the titles
    /// were built from: a position read without the case could turn a safe answer destructive. For
    /// a changed file the order is Compare…, Use Disk Version, Keep Mine…, Cancel; for a missing
    /// one, Save Again, Cancel. Cancel falls through to the default.
    nonisolated static func divergenceAnswer(
        for response: NSApplication.ModalResponse,
        divergence: EditorFileStore.Divergence) -> DivergenceAnswer {
        switch (divergence, response) {
        case (.changed, .alertFirstButtonReturn): return .showWhatChanged
        case (.changed, .alertSecondButtonReturn): return .reloadFromDisk
        case (.changed, .alertThirdButtonReturn): return .saveAnyway
        case (.missing, .alertFirstButtonReturn): return .saveAnyway
        // Every other response (Cancel, a dismissed sheet, anything AppKit adds later) changes
        // nothing.
        default: return .cancel
        }
    }

    nonisolated static func isConfirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    /// The diff overlay's three verbs are these three answers, coming back from the detour. Written
    /// out, not a shared raw value, so the overlay can never hand back `.showWhatChanged`, which
    /// would reopen the overlay from inside itself and leave the question unanswerable.
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
        // Neither destructive answer keeps Return, the guard `SyncOperationAlerts` puts on a
        // permanent delete; a blind Return opens Compare… or, for a gone file, Save Again. Which
        // buttons are destructive is read from the mapping, not the titles, so the styling lands
        // only where the click is read as destructive.
        for (index, button) in alert.buttons.enumerated()
        where divergenceAnswer(for: divergenceResponse(atButtonIndex: index),
                               divergence: divergence).isDestructive(for: divergence) {
            button.keyEquivalent = ""
            button.hasDestructiveAction = true
        }
        return divergenceAnswer(for: alert.runModal(), divergence: divergence)
    }
}
