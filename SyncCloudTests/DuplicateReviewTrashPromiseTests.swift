import Testing
import Foundation

/// **The Compare review's trash confirmation promised an undo it cannot always deliver.**
///
/// It read "Reversible with ⌘Z", unconditionally. On a volume with no Trash — exFAT, most SMB
/// shares — `deleteItems` cannot trash the copy and escalates to the permanent-delete
/// confirmation, which destroys it outright; nothing reaches the undo manager, because there is no
/// backup to restore from. `DuplicateReviewCoordinator` already draws that distinction thirty
/// lines below the alert, where its log line branches "Trashed" against "Permanently deleted"
/// precisely so a reader is not sent to a Trash that never received the file.
///
/// A scan, because the text lives in a default closure around a blocking `NSAlert` and reading it
/// is the only way to check it without standing up the alert. Both directions are asserted: the
/// unconditional claim is gone, and what replaced it names the second confirmation — which is real
/// (`SyncOperationAlerts.confirmPermanentDelete`, critical style) and is what makes the softened
/// promise honest rather than merely vaguer.
@Suite struct DuplicateReviewTrashPromiseTests {

    @Test func theTrashConfirmationDoesNotPromiseAnUnconditionalUndo() throws {
        let source = try macAppSources()

        // Non-vacuity: the alert this is about still exists and still describes the trash.
        #expect(source.contains("Move the right copy of"),
                "the trash confirmation was renamed — this scan is measuring nothing")

        #expect(!source.contains("The left copy is kept. Reversible with ⌘Z."),
                "the confirmation still promises ⌘Z on a volume where the delete is permanent")
    }

    @Test func itSaysWhatHappensWhenTheVolumeHasNoTrash() throws {
        let source = try macAppSources()
        #expect(source.contains("On a volume with no Trash you'll be asked first"),
                "the confirmation no longer says what happens where a trash is impossible")
        #expect(source.contains("a permanent delete can't be undone"),
                "the confirmation does not say the permanent case is unrecoverable")
    }

    /// The promise it now makes has to be true: a second, critical confirmation really does stand
    /// in front of every permanent delete. Without this the reworded text would be its own kind of
    /// false reassurance.
    @Test func thePermanentDeleteConfirmationItPromisesReallyExists() throws {
        let source = try macAppSources()
        #expect(source.contains("func confirmPermanentDelete(itemPaths: [String]) -> Bool"),
                "nothing implements the confirmation the trash alert now promises")
        #expect(source.contains("manager.permanentDeleteConfirmer = { itemPaths in"),
                "the confirmation exists but nothing wires it to the delete path")
    }
}
