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

    /// Shared confirm/cancel warning alert behind `confirmDelete` (following
    /// the `promptForName` pattern below): the caller supplies only the strings that differ.
    /// (`confirmMove` used to live here too; move confirmation moved into the sync layer's
    /// Settings-gated `transferConfirmer`, which shows From/To details.)
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

    /// Shared name-entry prompt: runs until the user cancels or enters a name that passes
    /// `validate`; rejected names get an explanatory alert and the prompt returns pre-filled
    /// with the rejected text so the user can fix it.
    private static func promptForName(
        title: String,
        prompt: String,
        buttonTitle: String,
        initialValue: String,
        selectAllInitially: Bool,
        validate: (String) -> String?
    ) -> String? {
        var draft = initialValue
        while true {
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

            let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return nil }
            guard let reason = validate(value) else { return value }

            let error = NSAlert()
            error.alertStyle = .warning
            error.messageText = "The name \"\(value)\" can't be used."
            error.informativeText = "\(reason) Please choose a different name."
            error.addButton(withTitle: "OK")
            error.runModal()
            draft = textField.stringValue
        }
    }

}
