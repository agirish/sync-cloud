import Testing
import Foundation

/// The Compare review's trash confirmation must not promise an undo it can't always deliver.
///
/// On a volume with no Trash (exFAT, most SMB shares) `deleteItems` can't trash the copy and
/// escalates to the permanent-delete confirmation, which destroys it outright; nothing reaches
/// the undo manager. `DuplicateReviewCoordinator`'s log line already branches "Trashed" against
/// "Permanently deleted" for the same reason.
///
/// A scan, because the text lives in a default closure around a blocking `NSAlert`. Both
/// directions are asserted: no unconditional ⌘Z claim, and the text names the second
/// confirmation, which is real (`SyncOperationAlerts.confirmPermanentDelete`, critical style).
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
        #expect(source.contains("On a volume with no Trash you’ll be asked first"),
                "the confirmation no longer says what happens where a trash is impossible")
        #expect(source.contains("a permanent delete can’t be undone"),
                "the confirmation does not say the permanent case is unrecoverable")
    }

    /// The promise it makes has to be true: a second, critical confirmation stands in front of
    /// every permanent delete. Without it the text would be false reassurance of its own.
    @Test func thePermanentDeleteConfirmationItPromisesReallyExists() throws {
        let source = try macAppSources()
        #expect(source.contains("func confirmPermanentDelete(itemPaths: [String]) -> Bool"),
                "nothing implements the confirmation the trash alert now promises")
        #expect(source.contains("manager.permanentDeleteConfirmer = { itemPaths in"),
                "the confirmation exists but nothing wires it to the delete path")
    }
}
