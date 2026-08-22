import Testing
import Foundation
@testable import FileExplorer

/// **Deleting an automation rule is the one destructive control in this lens that nothing takes
/// back**, and it was a single click in the same row as Edit and Preview.
///
/// Everything else here is reversible: a toggle re-toggles, an edit re-edits, and filing registers
/// a move undo so ⌘Z reverts the whole run. `removeAutomationRule` drops the rule, persists the
/// list, and leaves nothing to recover it from — while a rule's conditions, destination template
/// and ordering are hand-built work.
///
/// A scan, and honest about its reach: it proves the Delete button routes through the pending-
/// deletion state and that a confirmation dialog is wired to it. It cannot prove macOS presents
/// that dialog — driving a `confirmationDialog` needs the real presentation machinery, and a test
/// that mounted it would be pinning SwiftUI rather than this decision.
@Suite struct AutomationRuleDeleteConfirmTests {

    private static func lensSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // …/Tests/FileExplorer
            .deletingLastPathComponent()      // …/Tests
            .deletingLastPathComponent()      // …/FileExplorer
            .appendingPathComponent("Sources/FileExplorer/AutomationsLens.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The card's Delete must ASK, not remove. Stated as both halves — what it does do and what it
    /// no longer does — because either alone passes on a rename.
    @Test func theCardsDeleteButtonAsksBeforeRemoving() throws {
        let source = try Self.lensSource()
        #expect(source.contains("onDelete: { rulePendingDeletion = rule }"),
                "the card's Delete no longer routes through the confirmation")
        #expect(!source.contains("onDelete: { syncManager.removeAutomationRule"),
                "the card's Delete removes the rule directly, with nothing to take it back")
    }

    /// And exactly one call site actually removes, reached from the dialog's destructive button.
    @Test func theOnlyRemovalIsTheConfirmedOne() throws {
        let source = try Self.lensSource()
        let calls = source.components(separatedBy: "syncManager.removeAutomationRule").count - 1
        #expect(calls == 1, "expected one removal call site, found \(calls)")

        let dialog = try #require(source.range(of: "confirmationDialog("),
                                  "no confirmation dialog is wired in this lens")
        let after = source[dialog.upperBound...]
        let block = String(after.prefix(1200))
        #expect(block.contains("rulePendingDeletion"), "the dialog is not bound to the pending rule")
        #expect(block.contains("role: .destructive"),
                "the confirm button is not marked destructive, so it does not read as one")
        #expect(block.contains("role: .cancel"), "the dialog offers no way out")
        #expect(block.contains("syncManager.removeAutomationRule"),
                "the dialog's confirm does not actually remove the rule")
    }

    /// The dialog has to say the thing that makes it worth reading: this is not undoable.
    @Test func theDialogSaysItCannotBeUndone() throws {
        let source = try Self.lensSource()
        #expect(source.contains("can't be undone"),
                "the confirmation does not say the deletion is permanent, which is its whole point")
    }
}
