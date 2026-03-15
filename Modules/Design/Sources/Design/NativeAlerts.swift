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
    
    /// Presents a fallback permanent deletion confirmation if moving to Trash fails (e.g., on network drives).
    /// - Parameter itemNames: The names of the files/folders
    /// - Returns: True if confirmed for immediate permanent deletion.
    public static func confirmPermanentDelete(itemNames: [String]) -> Bool {
        guard !itemNames.isEmpty else { return false }
        
        let alert = NSAlert()
        alert.alertStyle = .critical
        
        if itemNames.count == 1, let first = itemNames.first {
            alert.messageText = "Are you sure you want to permanently delete \"\(first)\"?"
        } else {
            alert.messageText = "Are you sure you want to permanently delete these \(itemNames.count) items?"
        }
        
        alert.informativeText = "These items will be deleted immediately because they cannot be moved to the Trash. You can't undo this action."
        
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if let deleteButton = alert.buttons.first {
            deleteButton.hasDestructiveAction = true
            deleteButton.keyEquivalent = "\r"
        }
        
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Presents a native macOS alert to resolve file collisions (Replace, Keep Both, Skip).
    public static func promptForCollision(fileName: String, isMove: Bool) -> CollisionResolution {
        let alert = NSAlert()
        alert.messageText = "An item named \"\(fileName)\" already exists in this location."
        alert.informativeText = "Do you want to replace it with the one you're \(isMove ? "moving" : "copying")?"
        
        // Buttons added right to left.
        alert.addButton(withTitle: "Keep Both") // First added (Rightmost, Return key default)
        alert.addButton(withTitle: "Skip")      // Second added (Middle)
        alert.addButton(withTitle: "Replace")   // Third added (Leftmost)
        
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .keepBoth
        case .alertSecondButtonReturn:
            return .skip
        case .alertThirdButtonReturn:
            return .replace
        default:
            return .skip
        }
    }

    /// Presents a collision resolution alert with an "Apply to all" option for bulk sync.
    /// - Returns: The chosen resolution and whether to apply it to all remaining conflicts in this bulk run.
    public static func promptForCollisionWithApplyToAll(fileName: String, isMove: Bool) -> (resolution: CollisionResolution, applyToAll: Bool) {
        let alert = NSAlert()
        alert.messageText = "An item named \"\(fileName)\" already exists in this location."
        alert.informativeText = "Do you want to replace it with the one you're \(isMove ? "moving" : "copying")?"
        
        let checkbox = NSButton(checkboxWithTitle: "Apply to all for remaining conflicts", target: nil, action: nil)
        checkbox.state = .off
        checkbox.sizeToFit()
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: max(checkbox.frame.width, 280), height: checkbox.frame.height + 4))
        checkbox.frame.origin = CGPoint(x: 0, y: 0)
        accessory.addSubview(checkbox)
        alert.accessoryView = accessory
        
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Replace")
        
        let response = alert.runModal()
        let applyToAll = checkbox.state == .on
        switch response {
        case .alertFirstButtonReturn:
            return (.keepBoth, applyToAll)
        case .alertSecondButtonReturn:
            return (.skip, applyToAll)
        case .alertThirdButtonReturn:
            return (.replace, applyToAll)
        default:
            return (.skip, applyToAll)
        }
    }
}

/// Options for resolving file naming collisions during transfers.
public enum CollisionResolution: Sendable {
    case replace
    case keepBoth
    case skip
}
