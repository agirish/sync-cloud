import AppKit
import Foundation

@MainActor
public struct NativeAlerts {
    
    /// The ⌘⌫ / row-menu confirmation. It says "Move to Trash" because that is what happens, the
    /// verb Finder and every other trash confirmation use (the pane bar's button keeps Finder's
    /// short "Delete").
    ///
    /// It promises no ⌘Z: that would be false on a volume with no Trash, which asks again in its
    /// own alert before deleting outright, and in Edit's file list, where ⌘Z may undo typing. The
    /// body says what the title can't: the Trash gives it back.
    /// - Parameters:
    ///   - itemNames: The file or folder names selected for deletion.
    ///   - hiddenByFilter: Items inside the selected folders that the pane's type filter is hiding,
    ///     which go to the Trash with them. Said in the body when above zero.
    /// - Returns: True if the user confirmed the deletion.
    public static func confirmDelete(for itemNames: [String], hiddenByFilter: Int = 0) -> Bool {
        guard let alert = deleteAlert(for: itemNames, hiddenByFilter: hiddenByFilter) else { return false }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The alert `confirmDelete` presents, built but not run, so a test can pin its words and
    /// buttons without a modal session it can't dismiss. `nil` for no items.
    static func deleteAlert(for itemNames: [String], hiddenByFilter: Int = 0) -> NSAlert? {
        guard !itemNames.isEmpty else { return nil }
        let includes = hiddenByFilter > 0
            ? "Includes \(hiddenByFilter == 1 ? "1 item" : "\(hiddenByFilter.formatted()) items") the filter is hiding. "
            : ""
        if itemNames.count == 1, let first = itemNames.first {
            return destructiveAlert(
                messageText: "Move “\(first)” to the Trash?",
                informativeText: includes + "You can put it back from the Trash.",
                confirmTitle: "Move to Trash"
            )
        }
        return destructiveAlert(
            messageText: "Move \(itemNames.count.formatted()) items to the Trash?",
            informativeText: includes + "You can put them back from the Trash.",
            confirmTitle: "Move to Trash"
        )
    }

    /// A Finder-style destructive confirm/cancel alert whose summary the caller supplies, for flows
    /// that build their own "what will happen" message (the Duplicates lens). The confirm button is
    /// the destructive Return default, as in `confirmDelete`.
    /// - Returns: True if the user chose the confirm button.
    public static func confirmDestructive(messageText: String, informativeText: String, confirmTitle: String) -> Bool {
        confirmAction(messageText: messageText, informativeText: informativeText, confirmTitle: confirmTitle)
    }

    /// A confirm/cancel alert for a change that is not destructive: one that rearranges the screen
    /// and is undone by doing it again (⌘K offering to swap the panes so Organize opens on the
    /// named source).
    ///
    /// Not `confirmDestructive`, whose caution icon and `hasDestructiveAction` default are macOS's
    /// "this deletes something" signal. Spent on a reversible view change, the signal stops meaning
    /// anything on the dialogs that do move files to the Trash.
    /// - Returns: True if the user chose the confirm button.
    public static func confirmChange(messageText: String, informativeText: String, confirmTitle: String) -> Bool {
        changeAlert(messageText: messageText, informativeText: informativeText,
                    confirmTitle: confirmTitle).runModal() == .alertFirstButtonReturn
    }

    /// The alert `confirmChange` presents, built but not run, so `NativeAlertsTests` can pin its
    /// style and buttons. A test can't go near `runModal()`: it blocks the test's main thread on a
    /// modal session nothing in the harness can dismiss.
    static func changeAlert(messageText: String, informativeText: String, confirmTitle: String) -> NSAlert {
        let alert = NSAlert()
        // `.informational`, not `.warning`: nothing here is at risk.
        alert.alertStyle = .informational
        alert.messageText = messageText
        alert.informativeText = informativeText

        // Return confirms, Escape cancels — the plain default button, with none of
        // `confirmAction`'s destructive marking.
        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// A confirm/cancel alert for a deletion that can't be undone: a record or secret with no Trash
    /// to come back from, such as the spend totals the budget caps count against, or the API key in
    /// the Keychain.
    ///
    /// Unlike `confirmDestructive`, where Return confirms because the item can come back from the
    /// Trash, Cancel is the default here and the destructive button takes no Return key, as in Sync
    /// History's "Clear History" and Settings' "Reset All Settings…".
    /// - Returns: True if the user chose the confirm button.
    public static func confirmIrreversible(messageText: String, informativeText: String,
                                           confirmTitle: String) -> Bool {
        runModalCancellingOnEscape(irreversibleAlert(messageText: messageText,
                                                     informativeText: informativeText,
                                                     confirmTitle: confirmTitle)) == .alertFirstButtonReturn
    }

    /// Runs `alert` modally, with Escape pressing the button that answers Return (Cancel, in every
    /// alert that needs this).
    ///
    /// **An alert whose Cancel takes Return loses Escape.** NSAlert gives a "Cancel" button the
    /// Escape key, and making it the default replaces that with Return (one key equivalent per
    /// button), so Escape would do nothing. A local monitor runs inside the modal session, so it
    /// can answer Escape without taking Return from Cancel. The button is found by its key, not its
    /// place, so Escape gives whatever Return would.
    public static func runModalCancellingOnEscape(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let button = escapeAnswer(for: event, window: alert.window, buttons: alert.buttons)
            else { return event }
            button.performClick(nil)
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal()
    }

    /// The button Escape presses: the one that answers Return, for a first press of Escape or ⌘.
    /// aimed at the alert's window. Nil for anything else, which the monitor passes on, and nil
    /// when a button already holds Escape. A repeat passes on, so a held key can't press the button
    /// again after the alert has answered.
    ///
    /// Window and buttons are separate parameters because a test can't stage them together:
    /// ordering an alert's window in outside `runModal` clears its buttons' keys.
    static func escapeAnswer(for event: NSEvent, window: NSWindow, buttons: [NSButton]) -> NSButton? {
        guard event.type == .keyDown, !event.isARepeat, event.window === window else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Escape, or ⌘. — macOS's other cancel key, which an alert sends to its Escape button.
        let isEscape = event.keyCode == 53 && modifiers.isEmpty
        let isCommandPeriod = event.charactersIgnoringModifiers == "." && modifiers == .command
        guard isEscape || isCommandPeriod else { return nil }
        // An alert with a button still holding Escape answers it itself, and there the Return
        // button is the confirm: pressing it would turn Escape into yes.
        guard !buttons.contains(where: { $0.keyEquivalent == "\u{1b}" }) else { return nil }
        return buttons.first { $0.keyEquivalent == "\r" }
    }

    /// The alert `confirmIrreversible` presents, built but not run, so a test can pin its default
    /// button without a modal session it can't dismiss.
    static func irreversibleAlert(messageText: String, informativeText: String,
                                  confirmTitle: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText
        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        return alert
    }

    /// Runs the shared destructive confirm/cancel alert behind `confirmDestructive`; the caller
    /// supplies only the strings that differ.
    /// - Returns: True if the user chose the confirm button.
    private static func confirmAction(messageText: String, informativeText: String, confirmTitle: String) -> Bool {
        destructiveAlert(messageText: messageText, informativeText: informativeText,
                         confirmTitle: confirmTitle).runModal() == .alertFirstButtonReturn
    }

    /// The destructive alert `confirmAction` and `deleteAlert` present, built but not run.
    private static func destructiveAlert(messageText: String, informativeText: String,
                                         confirmTitle: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText

        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        // The destructive confirm is the default button, answering Return.
        if let confirmButton = alert.buttons.first {
            confirmButton.hasDestructiveAction = true
            confirmButton.keyEquivalent = "\r"
        }
        return alert
    }

    /// Runs `folderPanel` modally.
    /// - Returns: The folder chosen, or nil when cancelled.
    public static func chooseFolder(prompt: String? = nil, message: String? = nil, startingAt folder: URL? = nil,
                                    canCreateDirectories: Bool? = nil) -> URL? {
        let panel = folderPanel(prompt: prompt, message: message, startingAt: folder,
                                canCreateDirectories: canCreateDirectories)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// The one-folder chooser `chooseFolder` runs, built but not run, so a test can pin it without
    /// a modal session. Each argument is set only when given, so nil leaves the panel's own default.
    static func folderPanel(prompt: String? = nil, message: String? = nil, startingAt folder: URL? = nil,
                            canCreateDirectories: Bool? = nil) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let canCreateDirectories { panel.canCreateDirectories = canCreateDirectories }
        if let prompt { panel.prompt = prompt }
        if let message { panel.message = message }
        if let folder { panel.directoryURL = folder }
        return panel
    }

    /// Presents a native macOS prompt requesting a new name for an existing file/folder.
    /// When `validate` rejects the entered name, explains why and re-presents, like Finder.
    /// - Parameters:
    ///   - currentName: The current name of the file/folder.
    ///   - validate: Returns a human-readable failure reason for an unusable name, nil when acceptable.
    /// - Returns: The new user-provided name, or nil if cancelled.
    public static func promptForRename(currentName: String, validate: (String) -> String?) -> String? {
        promptForName(
            title: "Rename Item",
            prompt: "Enter a new name for this item:",
            buttonTitle: "Rename",
            initialValue: currentName,
            selectAllInitially: false,
            validate: validate
        )
    }

    /// Presents a native macOS prompt requesting a name for a new folder.
    /// When `validate` rejects the entered name, explains why and re-presents, like Finder.
    /// - Parameter validate: Returns a human-readable failure reason for an unusable name, nil when acceptable.
    /// - Returns: The new user-provided folder name, or nil if cancelled.
    public static func promptForNewFolder(validate: (String) -> String?) -> String? {
        promptForName(
            title: "New Folder",
            prompt: "Enter a name for the new folder:",
            buttonTitle: "Create",
            initialValue: "untitled folder",
            selectAllInitially: true,
            validate: validate
        )
    }

    /// Why the entered name can't be used, or nil when it's acceptable: the one gate the name
    /// prompt re-prompts on.
    ///
    /// A blank entry is rejected like any other bad name, never handed back: nil is this API's
    /// Cancel signal, so an empty result would read as "the user backed out" and close the dialog
    /// with no explanation. The empty check stays even though the app's validator rejects empty
    /// names, so a validator that accepted one can't turn it into a phantom cancel. `validate` runs
    /// first, so a caller's own wording wins.
    ///
    /// Internal so `NativeAlertsNamePromptTests` can pin the rule without a modal.
    static func nameRejectionReason(for trimmedName: String, validate: (String) -> String?) -> String? {
        if let reason = validate(trimmedName) { return reason }
        return trimmedName.isEmpty ? "A name is required." : nil
    }

    /// The name-prompt control flow with the two modal presentations injected: `present` shows one
    /// round of the entry sheet pre-filled with `draft` and returns the raw text confirmed (nil =
    /// Cancel); `explain` shows the "can't be used" alert. Loops until the user cancels or enters a
    /// name that clears `nameRejectionReason`, re-presenting the rejected text so they can fix it.
    ///
    /// Split from `promptForName` so tests can drive which entries re-prompt and which end the loop
    /// with scripted entries, instead of two nested `runModal()` calls; a blank entry that ended
    /// the loop would look exactly like a cancel from outside.
    static func runNamePrompt(
        initialValue: String,
        validate: (String) -> String?,
        present: (_ draft: String) -> String?,
        explain: (_ trimmedName: String, _ reason: String) -> Void
    ) -> String? {
        var draft = initialValue
        while true {
            guard let entered = present(draft) else { return nil }
            let value = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let reason = nameRejectionReason(for: value, validate: validate) else { return value }
            explain(value, reason)
            draft = entered
        }
    }

    /// Shared name-entry prompt: runs until the user cancels or enters a name that passes
    /// `validate`; rejected names get an explanatory alert and the prompt returns pre-filled
    /// with the rejected text so the user can fix it. The loop itself lives in `runNamePrompt`;
    /// everything here is the AppKit presentation it drives.
    private static func promptForName(
        title: String,
        prompt: String,
        buttonTitle: String,
        initialValue: String,
        selectAllInitially: Bool,
        validate: (String) -> String?
    ) -> String? {
        runNamePrompt(
            initialValue: initialValue,
            validate: validate,
            present: { draft in
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = prompt

                alert.addButton(withTitle: buttonTitle)
                alert.addButton(withTitle: "Cancel")

                let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
                textField.stringValue = draft
                textField.lineBreakMode = .byTruncatingTail
                alert.accessoryView = textField

                // Select the whole name, as Finder does.
                if selectAllInitially, let editor = alert.window.fieldEditor(true, for: textField) {
                    editor.selectAll(nil)
                }
                alert.window.initialFirstResponder = textField

                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                return textField.stringValue
            },
            explain: { value, reason in
                let error = NSAlert()
                error.alertStyle = .warning
                // A blank entry re-prompts like any other rejection, but in its own words: «The
                // name "" can't be used» reads as nonsense when the user typed nothing.
                if value.isEmpty {
                    error.messageText = reason
                    error.informativeText = "Type a name, or press Cancel to stop."
                } else {
                    error.messageText = "The name “\(value)” can’t be used."
                    error.informativeText = "\(reason) Please choose a different name."
                }
                error.addButton(withTitle: "OK")
                error.runModal()
            }
        )
    }

}
