import Testing
import Foundation
@testable import FileExplorer

/// Deleting an automation rule asks first, because it is the one control in this lens nothing
/// takes back: `removeAutomationRule` drops the rule and persists the list, while its conditions,
/// template and order are hand-built work. Toggles, edits and filing are all undoable.
///
/// A source scan: it proves Delete routes through the pending-deletion state and a confirmation
/// dialog is wired to it, not that macOS presents the dialog, which would pin SwiftUI instead.
@Suite struct AutomationRuleDeleteConfirmTests {

    private static func lensSource() throws -> String { try SourceText.fileExplorer("AutomationsLens.swift") }

    /// The card's Delete must ask, not remove. Both halves are asserted, because either alone
    /// passes on a rename.
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
        let calls = SourceText.codeOnly(source).components(separatedBy: "syncManager.removeAutomationRule").count - 1
        #expect(calls == 1, "expected one removal call site, found \(calls)")

        // From the dialog to the end of the member that attaches it, not a fixed window.
        let block = try SourceText.body(of: "confirmationDialog(", in: source)
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
        #expect(source.contains("can’t be undone"),
                "the confirmation does not say the deletion is permanent, which is its whole point")
    }
}
