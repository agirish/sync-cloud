import AppKit
import Sync

/// NSAlert-backed prompts for `FileSyncManager`'s collision and permanent-delete seams.
/// These live in the app target (not Design) because they answer with Sync's domain type
/// `CollisionResolution`, and Design must not depend on Sync. The Sync package itself is
/// UI-free: its seam defaults fail safe (skip / don't delete), and `SyncCloudApp` wires
/// these prompts in at construction.
@MainActor
struct SyncOperationAlerts {

    /// Builds the alert's informative text. For a folder collision it adds Finder's
    /// wholesale-replacement warning, since Replace trashes the entire existing folder —
    /// including items that exist only there — not just the same-named file.
    /// Pure (no AppKit) so it can be unit-tested and so file vs. folder wording can't drift.
    nonisolated static func collisionInformativeText(isMove: Bool, isDirectory: Bool) -> String {
        let base = "Do you want to replace it with the one you're \(isMove ? "moving" : "copying")?"
        guard isDirectory else { return base }
        return base + " Replacing a folder replaces its entire contents. "
            + "Items that exist only in the destination folder will be moved to the Trash."
    }

    /// The collision alert shared by both prompts below: identical text, buttons, and
    /// response mapping — the only variation between them is the optional accessory view,
    /// so the two can't drift apart.
    private static func runCollisionAlert(fileName: String, isMove: Bool, isDirectory: Bool, accessoryView: NSView?) -> CollisionResolution {
        let alert = NSAlert()
        alert.messageText = "An item named \"\(fileName)\" already exists in this location."
        alert.informativeText = collisionInformativeText(isMove: isMove, isDirectory: isDirectory)
        alert.accessoryView = accessoryView

        // Buttons added right to left.
        alert.addButton(withTitle: "Keep Both") // First added (Rightmost, Return key default)
        alert.addButton(withTitle: "Skip")      // Second added (Middle)
        alert.addButton(withTitle: "Replace")   // Third added (Leftmost)

        switch alert.runModal() {
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

    /// Presents a native macOS alert to resolve file collisions (Replace, Keep Both, Skip).
    static func promptForCollision(fileName: String, isMove: Bool, isDirectory: Bool) -> CollisionResolution {
        runCollisionAlert(fileName: fileName, isMove: isMove, isDirectory: isDirectory, accessoryView: nil)
    }

    /// Presents a collision resolution alert with an "Apply to all" option for bulk sync.
    /// - Returns: The chosen resolution and whether to apply it to all remaining conflicts in this bulk run.
    static func promptForCollisionWithApplyToAll(fileName: String, isMove: Bool, isDirectory: Bool) -> (resolution: CollisionResolution, applyToAll: Bool) {
        let checkbox = NSButton(checkboxWithTitle: "Apply to all for remaining conflicts", target: nil, action: nil)
        checkbox.state = .off
        checkbox.sizeToFit()
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: max(checkbox.frame.width, 280), height: checkbox.frame.height + 4))
        checkbox.frame.origin = CGPoint(x: 0, y: 0)
        accessory.addSubview(checkbox)

        let resolution = runCollisionAlert(fileName: fileName, isMove: isMove, isDirectory: isDirectory, accessoryView: accessory)
        return (resolution, checkbox.state == .on)
    }

    /// Presents a fallback permanent deletion confirmation if moving to Trash fails (e.g., on network drives).
    /// - Parameter itemNames: The names of the files/folders
    /// - Returns: True if confirmed for immediate permanent deletion.
    static func confirmPermanentDelete(itemNames: [String]) -> Bool {
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

        // This is the app's only unrecoverable action, so Return must NOT confirm it —
        // the user reaches this alert mid-delete-flow, primed to hit Return. Cancel takes
        // the Return default; Delete is click-only (Cancel keeps Escape automatically).
        if let deleteButton = alert.buttons.first {
            deleteButton.hasDestructiveAction = true
            deleteButton.keyEquivalent = ""
        }
        if alert.buttons.count > 1 {
            alert.buttons[1].keyEquivalent = "\r"
        }

        return alert.runModal() == .alertFirstButtonReturn
    }
}
