import AppKit
import Sync

/// NSAlert-backed prompts for `FileSyncManager`'s collision and permanent-delete seams.
/// These live in the app target (not Design) because they answer with Sync's domain type
/// `CollisionResolution`, and Design must not depend on Sync. The Sync package itself is
/// UI-free: its seam defaults fail safe (skip / don't delete), and `SyncCloudApp` wires
/// these prompts in at construction.
@MainActor
struct SyncOperationAlerts {

    /// Home-abbreviated (`~/…`) display form of an absolute path, so the alert's From/To
    /// lines stay readable for the deep `~/Library/CloudStorage/…` provider roots.
    nonisolated static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Builds the alert's informative text. Names both locations — the item being copied and
    /// the item it would replace — because the message line's "this location" is otherwise
    /// ambiguous in a two-pane app. For a folder collision it adds Finder's
    /// wholesale-replacement warning, since Replace trashes the entire existing folder —
    /// including items that exist only there — not just the same-named file.
    /// Pure (no AppKit) so it can be unit-tested and so file vs. folder wording can't drift.
    nonisolated static func collisionInformativeText(_ collision: FileCollision) -> String {
        var text = "Do you want to replace it with the one you're \(collision.isMove ? "moving" : "copying")?"
        if collision.isDirectory {
            text += " Replacing a folder replaces its entire contents. "
                + "Items that exist only in the destination folder will be moved to the Trash."
        }
        text += "\n\n\(collision.isMove ? "Moving" : "Copying"): \(displayPath(collision.sourcePath))"
        text += "\nReplacing: \(displayPath(collision.destinationPath))"
        return text
    }

    /// The collision alert shared by both prompts below: identical text, buttons, and
    /// response mapping — the only variation between them is the optional accessory view,
    /// so the two can't drift apart.
    private static func runCollisionAlert(_ collision: FileCollision, accessoryView: NSView?) -> CollisionResolution {
        let alert = NSAlert()
        alert.messageText = "An item named \"\(collision.fileName)\" already exists in this location."
        alert.informativeText = collisionInformativeText(collision)
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
    static func promptForCollision(_ collision: FileCollision) -> CollisionResolution {
        runCollisionAlert(collision, accessoryView: nil)
    }

    /// Presents a collision resolution alert with an "Apply to all" option for bulk sync.
    /// - Returns: The chosen resolution and whether to apply it to all remaining conflicts in this bulk run.
    static func promptForCollisionWithApplyToAll(_ collision: FileCollision) -> (resolution: CollisionResolution, applyToAll: Bool) {
        let checkbox = NSButton(checkboxWithTitle: "Apply to all for remaining conflicts", target: nil, action: nil)
        checkbox.state = .off
        checkbox.sizeToFit()
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: max(checkbox.frame.width, 280), height: checkbox.frame.height + 4))
        checkbox.frame.origin = CGPoint(x: 0, y: 0)
        accessory.addSubview(checkbox)

        let resolution = runCollisionAlert(collision, accessoryView: accessory)
        return (resolution, checkbox.state == .on)
    }

    /// Message line of the invalid-destination-name alert.
    /// Pure (no AppKit) so the wording is unit-testable.
    nonisolated static func invalidNameMessage(_ prompt: NameViolationPrompt) -> String {
        "\"\(prompt.itemName)\" can't be \(prompt.isMove ? "moved" : "copied") to \(prompt.providerName) under this name."
    }

    /// Body of the invalid-destination-name alert: the provider rule, what writing anyway
    /// would do (a local-only item that looks identical to its sanitized sibling), and the
    /// target location.
    nonisolated static func invalidNameInformativeText(_ prompt: NameViolationPrompt) -> String {
        "\(prompt.reason) Writing it anyway would create an item \(prompt.providerName) never uploads — "
            + "it would exist only on this Mac and look identical to \"\(prompt.sanitizedName)\".\n\n"
            + "Destination: \(displayPath(prompt.destinationPath))"
    }

    /// Asks how to handle a destination name the provider forbids: use the sanitized name
    /// (Return key default — if an item already exists there, the normal collision prompt
    /// follows), skip the item (Escape via "Cancel" semantics is deliberately absent; Skip is
    /// an explicit button), or insist on the original name.
    static func promptForInvalidName(_ prompt: NameViolationPrompt) -> InvalidNameResolution {
        let alert = NSAlert()
        alert.messageText = invalidNameMessage(prompt)
        alert.informativeText = invalidNameInformativeText(prompt)

        // Buttons added right to left.
        alert.addButton(withTitle: "Use \"\(prompt.sanitizedName)\"") // Rightmost, Return key default
        alert.addButton(withTitle: "Skip")                            // Middle
        alert.addButton(withTitle: "Keep Invalid Name")               // Leftmost

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .useSanitizedName
        case .alertSecondButtonReturn:
            return .skip
        case .alertThirdButtonReturn:
            return .keepOriginalName
        default:
            return .skip
        }
    }

    /// Message line of the transfer confirmation: verb + what + where, e.g.
    /// `Copy "Resume.docx" to "Documents"?` or `Move 3 items to "Documents"?`.
    /// Pure so the single/plural and copy/move wording is unit-testable.
    nonisolated static func transferConfirmationMessage(_ summary: TransferSummary) -> String {
        let verb = summary.isMove ? "Move" : "Copy"
        let what = summary.itemCount == 1 ? "\"\(summary.firstItemName)\"" : "\(summary.itemCount) items"
        let destinationName = (summary.destinationDirectory as NSString).lastPathComponent
        return "\(verb) \(what) to \"\(destinationName)\"?"
    }

    /// Full From/To body of the transfer confirmation, naming both folders in
    /// home-abbreviated (`~/…`) form — the message line only carries the destination's
    /// last component, so this is where the full locations live. A move also states its
    /// destructive half: copy and move dialogs otherwise differ by a single verb, and a
    /// drag-move is one modifier-key slip away from a copy.
    nonisolated static func transferConfirmationInformativeText(_ summary: TransferSummary) -> String {
        let body = "From: \(displayPath(summary.sourceDirectory))\nTo: \(displayPath(summary.destinationDirectory))"
        guard summary.isMove else { return body }
        return body + "\n\nThe \(summary.itemCount == 1 ? "item" : "items") will be removed from the original location."
    }

    /// Asks the user to confirm a copy/move before it starts. Return confirms (the operation
    /// is recoverable — replaces prompt separately and everything is undoable); Escape cancels.
    /// - Returns: True to proceed with the transfer.
    static func confirmTransfer(_ summary: TransferSummary) -> Bool {
        let alert = NSAlert()
        alert.messageText = transferConfirmationMessage(summary)
        alert.informativeText = transferConfirmationInformativeText(summary)
        alert.addButton(withTitle: summary.isMove ? "Move" : "Copy") // Return key default
        alert.addButton(withTitle: "Cancel")                         // Escape
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Message line of the cloud-spend pre-flight: what's about to be classified and by which model,
    /// e.g. `Classify 12 files with Haiku?`. Over budget it leads with the block so the headline
    /// itself says the call won't run. Pure so the wording is unit-testable.
    nonisolated static func filingSpendMessage(_ p: FilingSpendPreflight) -> String {
        let noun = p.fileCount == 1 ? "file" : "files"
        if p.wouldExceedCap {
            let which = p.wouldExceedTotalCap && !p.wouldExceedMonthlyCap ? "total" : "monthly"
            return "This would exceed your \(which) cloud budget"
        }
        return "Classify \(p.fileCount) \(noun) with \(FilingSpendFormat.model(p.model))?"
    }

    /// Body of the cloud-spend pre-flight: the estimated cost of this call, plus — when a monthly cap
    /// is set — this month's spend against the cap and whether this call would push past it. Pure (no
    /// AppKit) so it's unit-testable and the estimate wording can't drift.
    nonisolated static func filingSpendInformativeText(_ p: FilingSpendPreflight) -> String {
        var text = "Estimated cost: \(FilingSpendFormat.cost(p.estCostUSD)) "
            + "(\(FilingSpendFormat.tokens(p.estInputTokens)) in / \(FilingSpendFormat.tokens(p.estOutputTokens)) out). "
            + "The exact cost is billed to your Anthropic API key and known only after the call."
        if p.monthlyCapUSD > 0 {
            text += "\n\nThis month: \(FilingSpendFormat.cost(p.monthlySpentUSD)) of \(FilingSpendFormat.cost(p.monthlyCapUSD)) monthly cap."
        }
        if p.totalCapUSD > 0 {
            text += "\(p.monthlyCapUSD > 0 ? "\n" : "\n\n")Lifetime: \(FilingSpendFormat.cost(p.totalSpentUSD)) of \(FilingSpendFormat.cost(p.totalCapUSD)) total cap."
        }
        if p.wouldExceedCap {
            let which = p.wouldExceedTotalCap && !p.wouldExceedMonthlyCap ? "total" : "monthly"
            text += " Running this would exceed the \(which) cap, so it's blocked — Filing will use its "
                + "free on-device suggestions instead. Raise or turn off the cap in Settings → Tidy."
        }
        return text
    }

    /// Asks the user to confirm a cloud (Claude) Filing classify, showing the pre-flight cost
    /// estimate and (if set) the monthly budget. When the call would exceed the cap the proceed
    /// button is withheld — the only choice is to fall back on-device — so the cap is honored from the
    /// dialog too. Otherwise "Classify" proceeds and "Cancel" (Escape) falls back on-device.
    /// - Returns: True only when the user chose to proceed with the cloud call.
    static func promptForFilingSpend(_ p: FilingSpendPreflight) -> Bool {
        let alert = NSAlert()
        alert.messageText = filingSpendMessage(p)
        alert.informativeText = filingSpendInformativeText(p)
        if p.wouldExceedCap {
            // Over budget: no proceed path. Inform the user, then fall back on-device regardless.
            alert.addButton(withTitle: "Use On-Device Instead")
            _ = alert.runModal()
            return false
        }
        alert.addButton(withTitle: "Classify")   // Return key default
        alert.addButton(withTitle: "Cancel")      // Escape
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Confirms reversing the most recent sync run before it touches any files, itemizing exactly
    /// what will be undone (from `preview`, which the manager only produces when that run is still
    /// the top of the undo stack). Reversal reuses the app's existing undo stack (safeMove-back,
    /// Trash-restore) — recoverable, and itself redoable — so Return proceeds and Escape cancels.
    /// - Returns: True to reverse the last run.
    static func confirmUndoLastSyncRun(_ preview: SyncRunUndoPreview) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Undo the last sync run?"
        alert.informativeText = preview.confirmationDetail()
        alert.addButton(withTitle: "Undo Last Run") // Return key default
        alert.addButton(withTitle: "Cancel")         // Escape
        return alert.runModal() == .alertFirstButtonReturn
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

        // This is the app's only unrecoverable action, so no keypress may confirm it — the user
        // reaches this alert mid-delete-flow, primed to hit Return. Clearing Delete's key
        // equivalent leaves Return unbound (it does nothing; the user must click Delete
        // deliberately). Cancel is left untouched so it keeps the Escape key NSAlert assigns it
        // automatically — do NOT set Cancel's keyEquivalent to Return, which would displace Escape.
        if let deleteButton = alert.buttons.first {
            deleteButton.hasDestructiveAction = true
            deleteButton.keyEquivalent = ""
        }

        return alert.runModal() == .alertFirstButtonReturn
    }
}
