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

    /// The collision alert's button titles, in `NSAlert.addButton` order (right to left, so the
    /// first is the rightmost / Return-key default). The single source of both what is drawn and
    /// what each response means: `collisionResolution(for:)` maps the Nth button's response to the
    /// Nth entry's meaning, so a reordering here without one there is a test failure rather than a
    /// silent "Skip click replaces the file".
    nonisolated static let collisionButtonTitles = ["Keep Both", "Skip", "Replace"]

    /// The modal response a click on the button at `index` of an `NSAlert`'s button list produces.
    /// `NSAlert` numbers them from `.alertFirstButtonReturn` in add order; spelled out here so the
    /// mapping tests can address a button by title rather than by a magic constant.
    nonisolated static func modalResponse(forButtonAt index: Int) -> NSApplication.ModalResponse {
        NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }

    /// Maps the collision alert's modal response to the resolution it stands for. Extracted from
    /// the `runModal()` call so the button-order → resolution mapping is unit-testable: swapping
    /// two arms here silently turns a "Skip" click into a replace, which destroys the user's file
    /// and is invisible until it does. Any unexpected response (a programmatic dismissal) falls
    /// back to the safe answer, `.skip`.
    nonisolated static func collisionResolution(for response: NSApplication.ModalResponse) -> CollisionResolution {
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

    /// The collision alert shared by both prompts below: identical text, buttons, and
    /// response mapping — the only variation between them is the optional accessory view,
    /// so the two can't drift apart.
    private static func runCollisionAlert(_ collision: FileCollision, accessoryView: NSView?) -> CollisionResolution {
        let alert = NSAlert()
        alert.messageText = "An item named \"\(collision.fileName)\" already exists in this location."
        alert.informativeText = collisionInformativeText(collision)
        alert.accessoryView = accessoryView

        // Buttons added right to left, from the shared title list.
        for title in collisionButtonTitles {
            alert.addButton(withTitle: title)
        }

        return collisionResolution(for: alert.runModal())
    }

    /// Presents a native macOS alert to resolve file collisions (Replace, Keep Both, Skip).
    static func promptForCollision(_ collision: FileCollision) -> CollisionResolution {
        runCollisionAlert(collision, accessoryView: nil)
    }

    /// Presents a collision resolution alert with an "Apply to all" option for bulk sync.
    /// - Returns: The chosen resolution and whether to apply it to all remaining conflicts in this bulk run.
    static func promptForCollisionWithApplyToAll(_ collision: FileCollision) -> (resolution: CollisionResolution, applyToAll: Bool) {
        // Folder collisions never offer "Apply to all": replacing a folder trashes its entire
        // contents, so each one is decided on its own (matching the engine's directory guard).
        guard !collision.isDirectory else {
            return (runCollisionAlert(collision, accessoryView: nil), false)
        }
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

        // Buttons added right to left, from the shared title list.
        for title in invalidNameButtonTitles(prompt) {
            alert.addButton(withTitle: title)
        }

        return invalidNameResolution(for: alert.runModal())
    }

    /// The invalid-name alert's button titles in `NSAlert.addButton` order (rightmost first),
    /// paired with `invalidNameResolution(for:)` the same way the collision pair is.
    nonisolated static func invalidNameButtonTitles(_ prompt: NameViolationPrompt) -> [String] {
        ["Use \"\(prompt.sanitizedName)\"", "Skip", "Keep Invalid Name"]
    }

    /// Maps the invalid-name alert's modal response to the resolution it stands for. Extracted
    /// for the same reason as `collisionResolution(for:)`: a swapped arm here answers "Skip"
    /// with "Keep Invalid Name", writing an item the provider will never upload.
    nonisolated static func invalidNameResolution(for response: NSApplication.ModalResponse) -> InvalidNameResolution {
        switch response {
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

    /// Whether a two-button confirmation's response means "yes, proceed". Every Bool-answering
    /// prompt here puts its affirmative action first (rightmost, Return-key default) and Cancel
    /// second (Escape), so the single rule is "only the first button confirms" — and any other
    /// response (a programmatic dismissal) declines. Shared so no confirmation can drift into
    /// treating Cancel as consent.
    nonisolated static func isConfirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
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
        return isConfirmed(alert.runModal())
    }

    /// Message line of the cloud-spend pre-flight: what's about to be classified and by which model,
    /// e.g. `Classify 12 files with Haiku?`. Over budget it leads with the block so the headline
    /// itself says the call won't run. Pure so the wording is unit-testable.
    nonisolated static func filingSpendMessage(_ p: FilingSpendPreflight) -> String {
        let noun = p.fileCount == 1 ? p.unit : p.unit + "s"
        if p.wouldExceedCap {
            let which = p.wouldExceedTotalCap && !p.wouldExceedMonthlyCap ? "total" : "monthly"
            return "This would exceed your \(which) cloud budget"
        }
        // "Classify" is the filing refine's verb; any other unit is a send, said as one.
        return p.unit == "file"
            ? "Classify \(p.fileCount) \(noun) with \(FilingSpendFormat.model(p.model))?"
            : "Send \(p.fileCount) \(noun) to \(FilingSpendFormat.model(p.model))?"
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
            // The fallback sentence is only true of the filing refine — the mapping refine has
            // no on-device model, so promising "free on-device suggestions" over its blocked
            // dialog would be a fallback the click cannot deliver.
            text += " Running this would exceed the \(which) cap, so it's blocked — "
                + (p.unit == "file"
                   ? "Organize will use its free on-device suggestions instead. "
                   : "this pass only runs in the cloud, so nothing will be sent. ")
                + "Raise or turn off the cap in Settings → Organize."
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
            // Over budget: no proceed path. The button says what actually happens next — the
            // filing refine falls back on-device; the mapping refine simply does not run.
            alert.addButton(withTitle: p.unit == "file" ? "Use On-Device Instead" : "OK")
            _ = alert.runModal()
            return false
        }
        alert.addButton(withTitle: p.unit == "file" ? "Classify" : "Send")   // Return key default
        alert.addButton(withTitle: "Cancel")      // Escape
        return isConfirmed(alert.runModal())
    }

    /// Confirms a whole-tree pass whose probe found the folder too large to analyse quickly.
    ///
    /// **The message says "more than", never a total**, and that is not hedging: the probe stopped,
    /// so it genuinely does not know how much of the tree it did not see. A figure here would be a
    /// number the app invented.
    ///
    /// Return proceeds, Escape cancels. Not `.critical` — nothing is destroyed either way, the
    /// pass is cancellable once started, and a red badge on "this will be slow" is the kind of
    /// alarm that trains people to dismiss alarms.
    static func confirmLargeWalk(_ p: LargeWalkPreflight) -> Bool {
        let alert = NSAlert()
        alert.messageText = largeWalkMessage(p)
        alert.informativeText = largeWalkInformativeText(p)
        alert.addButton(withTitle: "Continue")   // Return key default
        alert.addButton(withTitle: "Cancel")     // Escape
        return isConfirmed(alert.runModal())
    }

    /// Split out, `nonisolated` and pure so the wording can be asserted without running a modal —
    /// an NSAlert in a test suite is a hang, not a test.
    nonisolated static func largeWalkMessage(_ p: LargeWalkPreflight) -> String {
        "“\(p.rootName)” is a very large folder"
    }

    nonisolated static func largeWalkInformativeText(_ p: LargeWalkPreflight) -> String {
        let counted = p.probeLimit.formatted(.number.grouping(.automatic))
        // Asked of the pass rather than tested against one case: `readsFileContents` is the
        // property that decides, and four passes go through here now. `p.pass == .duplicates`
        // silently gave Filing the cheaper sentence when Filing joined.
        let what = p.pass.readsFileContents
            ? "\(p.pass.title) also reads the contents of files it cannot judge by name, so this can take several minutes."
            : "\(p.pass.title) has to walk all of it, which can take several minutes."
        return "It holds more than \(counted) items. \(what) You can cancel once it starts."
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
        return isConfirmed(alert.runModal())
    }

    /// Message line of the permanent-delete confirmation. `itemPaths` are ABSOLUTE paths — see
    /// `permanentDeleteInformativeText`. Pure (no AppKit) so the wording is unit-testable.
    nonisolated static func permanentDeleteMessage(itemPaths: [String]) -> String {
        if itemPaths.count == 1, let first = itemPaths.first {
            return "Are you sure you want to permanently delete \"\((first as NSString).lastPathComponent)\"?"
        }
        return "Are you sure you want to permanently delete these \(itemPaths.count) items?"
    }

    /// Body of the permanent-delete confirmation: **what is about to be destroyed, by path**, then
    /// the warning.
    ///
    /// This is the app's only unrecoverable action and it used to name nothing. The `count > 1`
    /// branch rendered "…permanently delete these N items?" and discarded the list outright, so
    /// after the duplicates batch redesign made ONE dialog cover every group, a 12-group batch
    /// asked about "these 37 items" with no way to see what they were. The `count == 1` branch
    /// named a basename only, which for the duplicates flows is the one thing that cannot
    /// disambiguate: two copies in a group are usually same-named — that is *why* they grouped.
    ///
    /// Paths are home-abbreviated and capped the way `SyncRunUndoPreview.confirmationDetail` caps
    /// its itemization, with the same bullet and "and N more" spellings, because both are alert
    /// bodies listing files the user is about to let the app act on.
    nonisolated static func permanentDeleteInformativeText(itemPaths: [String], maxLines: Int = 8) -> String {
        var lines = itemPaths.prefix(max(0, maxLines)).map { "  •  \(displayPath($0))" }
        if itemPaths.count > maxLines { lines.append("  …  and \(itemPaths.count - maxLines) more") }
        lines.append("")
        lines.append(itemPaths.count == 1
            ? "This item will be deleted immediately because it can't be moved to the Trash. You can't undo this action."
            : "These items will be deleted immediately because they can't be moved to the Trash. You can't undo this action.")
        return lines.joined(separator: "\n")
    }

    /// Presents a fallback permanent deletion confirmation if moving to Trash fails (e.g., on network drives).
    /// - Parameter itemPaths: The ABSOLUTE paths of the files/folders about to be destroyed. Paths,
    ///   not names: the alert has to be able to tell two same-named copies apart, and the callers
    ///   (the duplicates flows above all) routinely ask about exactly that.
    /// - Returns: True if confirmed for immediate permanent deletion.
    static func confirmPermanentDelete(itemPaths: [String]) -> Bool {
        guard !itemPaths.isEmpty else { return false }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = permanentDeleteMessage(itemPaths: itemPaths)
        alert.informativeText = permanentDeleteInformativeText(itemPaths: itemPaths)

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

        return isConfirmed(alert.runModal())
    }
}
