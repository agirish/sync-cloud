import Testing
import Foundation
@testable import Sync

/// Pins the structured `SyncError` type: each constructor's fields, the log rendering, and the
/// pure "which alert actions apply" decision that the app's error alert renders.
@Suite struct SyncErrorTests {

    // MARK: - Constructors / statics

    /// A minimal error with no path and no reason, standing in for any deterministic
    /// (non-retryable) failure in the fixture-agnostic tests below.
    private static let bareError = SyncError(title: "Content Differs", message: "The two files are not identical.")

    @Test func testSyncFailedIsRetryableByDefaultAndCarriesPathAndReason() {
        let error = SyncError.syncFailed(item: "Docs/report.pdf", path: "/Left/Docs/report.pdf", reason: "disk full")
        #expect(error.title == "Sync Failed")
        #expect(error.message == "Couldn’t sync “Docs/report.pdf”.")
        #expect(error.path == "/Left/Docs/report.pdf")
        #expect(error.reason == "disk full")
        #expect(error.isRetryable == true)
    }

    @Test func testSyncFailedRetryabilityIsOverridable() {
        // The bulk (syncAll) call site passes isRetryable: false: a partial-batch retry is ambiguous.
        let error = SyncError.syncFailed(item: "a.txt", path: "/x/a.txt", reason: "boom", isRetryable: false)
        #expect(error.isRetryable == false)
    }

    @Test func testCopyAndMoveFailedWording() {
        let copy = SyncError.copyFailed(items: "the selected items", reason: "nope")
        #expect(copy.title == "Copy Failed")
        #expect(copy.message == "Couldn’t copy the selected items.")
        #expect(copy.reason == "nope")
        #expect(copy.isRetryable == false)

        let move = SyncError.moveFailed(items: "the selected items", reason: "nope")
        #expect(move.title == "Move Failed")
        #expect(move.message == "Couldn’t move the selected items.")
    }

    @Test func testRenameCreateDeleteFields() {
        let rename = SyncError.renameFailed(reason: "permission denied", path: "/x/y")
        #expect(rename.title == "Rename Failed")
        #expect(rename.path == "/x/y")
        #expect(rename.isRetryable == false)

        let folder = SyncError.createFolderFailed(reason: "exists", path: "/parent")
        #expect(folder.title == "Couldn’t Create Folder")
        #expect(folder.path == "/parent")

        // Unchanged for everything that is not a permission refusal.
        let del = SyncError.deleteFailed(reason: "busy")
        #expect(del.title == "Delete Failed")
        #expect(del.message == "Some items couldn’t be deleted.")
        #expect(del.reason == "busy")
    }

    // MARK: - Log rendering

    @Test func testLogDescriptionFoldsEveryKnownField() {
        let error = SyncError(title: "Sync Failed", message: "Couldn’t sync “a.txt”.", path: "/x/a.txt", reason: "disk full")
        #expect(error.logDescription == "Sync Failed: Couldn’t sync “a.txt”. (disk full) [/x/a.txt]")
    }

    @Test func testLogDescriptionOmitsAbsentFields() {
        #expect(Self.bareError.logDescription == "Content Differs: The two files are not identical.")
    }

    // MARK: - Which alert actions apply (pure decision)

    /// Every row's exact list ends in Dismiss, so Dismiss is always present.
    @Test(arguments: [
        (SyncError.syncFailed(item: "a", path: "/x/a", reason: "boom"), true, [SyncErrorAction.retry, .revealInFinder, .dismiss]),
        // Retry is hidden with no handler, even when retryable.
        (SyncError.syncFailed(item: "a", path: "/x/a", reason: "boom"), false, [.revealInFinder, .dismiss]),
        // Retry is hidden when not retryable (copyFailed), even with a handler.
        (SyncError.copyFailed(items: "the selected items", path: "/x/a", reason: "boom"), true, [.revealInFinder, .dismiss]),
        (SyncError.copyFailed(items: "a", path: "/x/a", reason: "boom"), false, [.revealInFinder, .dismiss]),
        // No path hides Reveal but must not hide Retry, e.g. a bulk failure that kept no single
        // representative path.
        (SyncError(title: "Sync Failed", message: "boom", isRetryable: true), true, [.retry, .dismiss]),
        (SyncError(title: "Sync Failed", message: "boom", isRetryable: true), false, [.dismiss]),
        // No path, not retryable: only Dismiss.
        (Self.bareError, true, [.dismiss]),
        (Self.bareError, false, [.dismiss]),
    ])
    func testAlertActions(error: SyncError, hasRetryHandler: Bool, expected: [SyncErrorAction]) {
        #expect(error.alertActions(hasRetryHandler: hasRetryHandler) == expected)
    }
}
