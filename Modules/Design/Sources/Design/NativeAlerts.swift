import AppKit
import Foundation

@MainActor
public struct NativeAlerts {
    
    /// Presents a native macOS Finder-style delete confirmation prompt.
    /// - Parameters:
    ///   - itemNames: The list of file or folder names selected for deletion.
    /// - Returns: True if the user confirmed the deletion.
    public static func confirmDelete(for itemNames: [String]) -> Bool {
        guard !itemNames.isEmpty else { return false }

        if itemNames.count == 1, let first = itemNames.first {
            return confirmAction(
                messageText: "Are you sure you want to delete \"\(first)\"?",
                informativeText: "This item will be moved to the Trash.",
                confirmTitle: "Delete"
            )
        }
        return confirmAction(
            messageText: "Are you sure you want to delete \(itemNames.count) items?",
            informativeText: "These items will be moved to the Trash.",
            confirmTitle: "Delete"
        )
    }

    /// A Finder-style destructive confirm/cancel alert whose summary is supplied by the caller.
    /// Used by flows that build their own "what will happen" message (e.g. Tidy). The confirm
    /// button is the destructive Return default, matching `confirmDelete`.
    /// - Returns: True if the user chose the confirm button.
    public static func confirmDestructive(messageText: String, informativeText: String, confirmTitle: String) -> Bool {
        confirmAction(messageText: messageText, informativeText: informativeText, confirmTitle: confirmTitle)
    }

    /// Shared confirm/cancel warning alert behind `confirmDelete` (following
    /// the `promptForName` pattern below): the caller supplies only the strings that differ.
    /// - Returns: True if the user chose the confirm button.
    private static func confirmAction(messageText: String, informativeText: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText

        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        // Make the destructive confirm button the default rightmost
        if let confirmButton = alert.buttons.first {
            confirmButton.hasDestructiveAction = true
            confirmButton.keyEquivalent = "\r"
        }

        return alert.runModal() == .alertFirstButtonReturn
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

    /// Why the entered name can't be used, or nil when it's acceptable — the single gate the
    /// name prompt re-prompts on.
    ///
    /// A blank (or whitespace-only) entry is folded in with every other invalid name rather than
    /// short-circuiting the loop. Confirming an empty field used to `return nil`, and nil is this
    /// API's *Cancel* signal, so every caller read it as "the user backed out": the dialog closed
    /// with no rename, no new folder, and no explanation — while literally any other bad name got
    /// a reason and a second try.
    ///
    /// The empty check stays here even though the app's own validator already rejects empty
    /// names. Because nil is the Cancel channel, an empty string can never be handed back to a
    /// caller no matter what `validate` says, so a validator that happened to accept one would
    /// turn into a phantom cancel again. `validate` runs first so a caller that has its own
    /// wording for this keeps it.
    ///
    /// Internal (not private) so `NativeAlertsNamePromptTests` can pin the rule without a modal.
    static func nameRejectionReason(for trimmedName: String, validate: (String) -> String?) -> String? {
        if let reason = validate(trimmedName) { return reason }
        return trimmedName.isEmpty ? "A name is required." : nil
    }

    /// The name-prompt control flow with the two modal presentations injected: `present` shows one
    /// round of the entry sheet pre-filled with `draft` and returns the raw text the user confirmed
    /// (nil = Cancel); `explain` shows the "can't be used" alert. Loops until the user cancels or
    /// enters a name that clears `nameRejectionReason`, re-presenting pre-filled with the rejected
    /// text so they can fix it rather than retype it.
    ///
    /// Split out from `promptForName` because the interesting half — *which* entries re-prompt and
    /// which end the loop — is otherwise reachable only by driving two nested `runModal()` calls.
    /// A blank entry ending the loop looked identical to a cancel from the outside, which is
    /// precisely how it went unnoticed. Internal so the tests can drive it with scripted entries.
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

                // Select all text in the text field initially natively like Finder
                if selectAllInitially, let editor = alert.window.fieldEditor(true, for: textField) {
                    editor.selectAll(nil)
                }
                // Focus the text field
                alert.window.initialFirstResponder = textField

                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                return textField.stringValue
            },
            explain: { value, reason in
                let error = NSAlert()
                error.alertStyle = .warning
                // A blank entry re-prompts like any other rejection, but not in the same words:
                // «The name "" can't be used. … Please choose a different name.» reads as
                // nonsense when the user typed nothing at all.
                if value.isEmpty {
                    error.messageText = reason
                    error.informativeText = "Type a name, or press Cancel to stop."
                } else {
                    error.messageText = "The name \"\(value)\" can't be used."
                    error.informativeText = "\(reason) Please choose a different name."
                }
                error.addButton(withTitle: "OK")
                error.runModal()
            }
        )
    }

}
