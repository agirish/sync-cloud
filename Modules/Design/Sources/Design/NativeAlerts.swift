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
        
        let alert = NSAlert()
        alert.alertStyle = .warning
        
        if itemNames.count == 1, let first = itemNames.first {
            alert.messageText = "Are you sure you want to delete \"\(first)\"?"
            alert.informativeText = "This item will be moved to the Trash."
        } else {
            alert.messageText = "Are you sure you want to delete \(itemNames.count) items?"
            alert.informativeText = "These items will be moved to the Trash."
        }
        
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        // Make the destructive "Delete" button the default rightmost
        if let deleteButton = alert.buttons.first {
            deleteButton.hasDestructiveAction = true
            deleteButton.keyEquivalent = "\r"
        }
        
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Presents a native macOS confirmation prompt before moving items (i.e., cut + paste).
    /// - Parameters:
    ///   - itemNames: The list of file or folder names selected for moving.
    ///   - destinationLabel: A short label for where the items will be moved (e.g. "Destination", "Source").
    /// - Returns: True if the user confirmed the move.
    public static func confirmMove(for itemNames: [String], destinationLabel: String) -> Bool {
        guard !itemNames.isEmpty else { return false }

        let alert = NSAlert()
        alert.alertStyle = .warning

        if itemNames.count == 1, let first = itemNames.first {
            alert.messageText = "Move \"\(first)\" to \(destinationLabel)?"
            alert.informativeText = "This will remove the item from its current location."
        } else {
            alert.messageText = "Move \(itemNames.count) items to \(destinationLabel)?"
            alert.informativeText = "This will remove the items from their current location."
        }

        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")

        if let moveButton = alert.buttons.first {
            moveButton.hasDestructiveAction = true
            moveButton.keyEquivalent = "\r"
        }

        return alert.runModal() == .alertFirstButtonReturn
    }
    
    /// Presents a native macOS prompt requesting a new name for an existing file/folder.
    /// - Parameters:
    ///   - currentName: The current name of the file/folder.
    /// - Returns: The new user-provided name, or nil if cancelled.
    public static func promptForRename(currentName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename Item"
        alert.informativeText = "Enter a new name for this item:"
        
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = currentName
        textField.lineBreakMode = .byTruncatingTail
        alert.accessoryView = textField
        
        // Focus the text field
        alert.window.initialFirstResponder = textField
        
        if alert.runModal() == .alertFirstButtonReturn {
            let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
    
    /// Presents a native macOS prompt requesting a name for a new folder.
    /// - Returns: The new user-provided folder name, or nil if cancelled.
    public static func promptForNewFolder() -> String? {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Enter a name for the new folder:"
        
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = "untitled folder"
        textField.lineBreakMode = .byTruncatingTail
        alert.accessoryView = textField
        
        // Select all text in the text field initially natively like Finder
        if let editor = alert.window.fieldEditor(true, for: textField) {
            editor.selectAll(nil)
        }
        alert.window.initialFirstResponder = textField
        
        if alert.runModal() == .alertFirstButtonReturn {
            let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
    
}
