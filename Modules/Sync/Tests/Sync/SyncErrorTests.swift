import Testing
import Foundation
@testable import Sync

/// Pins the structured `SyncError` type: each constructor's fields, the log rendering, and the
/// pure "which alert actions apply" decision that the app's error alert renders.
@Suite struct SyncErrorTests {

    // MARK: - Constructors / statics

    @Test func testContentDiffersFields() {
        let error = SyncError.contentDiffers
        #expect(error.title == "Content Differs")
        #expect(error.message == "The two files are not identical.")
        #expect(error.path == nil)
        #expect(error.reason == nil)
        #expect(error.isRetryable == false)
    }

    @Test func testCouldNotVerifyFields() {
        let error = SyncError.couldNotVerify
        #expect(error.title == "Couldn't Verify")
        #expect(error.message.contains("100 MB"))
        #expect(error.path == nil)
        #expect(error.isRetryable == false)
    }

    @Test func testSyncFailedIsRetryableByDefaultAndCarriesPathAndReason() {
        let error = SyncError.syncFailed(item: "Docs/report.pdf", path: "/Left/Docs/report.pdf", reason: "disk full")
        #expect(error.title == "Sync Failed")
        #expect(error.message == "Couldn't sync \"Docs/report.pdf\".")
        #expect(error.path == "/Left/Docs/report.pdf")
        #expect(error.reason == "disk full")
        #expect(error.isRetryable == true)
    }

    @Test func testSyncFailedRetryabilityIsOverridable() {
        // The bulk (syncAll) call site passes isRetryable: false — a partial-batch retry is ambiguous.
        let error = SyncError.syncFailed(item: "a.txt", path: "/x/a.txt", reason: "boom", isRetryable: false)
        #expect(error.isRetryable == false)
    }

    @Test func testCopyAndMoveFailedWording() {
        let copy = SyncError.copyFailed(items: "the selected items", reason: "nope")
        #expect(copy.title == "Copy Failed")
        #expect(copy.message == "Couldn't copy the selected items.")
        #expect(copy.reason == "nope")
        #expect(copy.isRetryable == false)

        let move = SyncError.moveFailed(items: "the selected items", reason: "nope")
        #expect(move.title == "Move Failed")
        #expect(move.message == "Couldn't move the selected items.")
    }

    @Test func testRenameCreateDeleteFields() {
        let rename = SyncError.renameFailed(reason: "permission denied", path: "/x/y")
        #expect(rename.title == "Rename Failed")
        #expect(rename.path == "/x/y")
        #expect(rename.isRetryable == false)

        let folder = SyncError.createFolderFailed(reason: "exists", path: "/parent")
        #expect(folder.title == "Couldn't Create Folder")
        #expect(folder.path == "/parent")

        let del = SyncError.deleteFailed(reason: "busy")
        #expect(del.title == "Delete Failed")
        #expect(del.reason == "busy")
    }

    // MARK: - Log rendering

    @Test func testLogDescriptionFoldsEveryKnownField() {
        let error = SyncError(title: "Sync Failed", message: "Couldn't sync \"a.txt\".", path: "/x/a.txt", reason: "disk full")
        #expect(error.logDescription == "Sync Failed: Couldn't sync \"a.txt\". (disk full) [/x/a.txt]")
    }

    @Test func testLogDescriptionOmitsAbsentFields() {
        #expect(SyncError.contentDiffers.logDescription == "Content Differs: The two files are not identical.")
    }

    // MARK: - Which alert actions apply (pure decision)

    @Test func testActionsWithPathRetryableAndHandler() {
        let error = SyncError.syncFailed(item: "a", path: "/x/a", reason: "boom")
        #expect(error.alertActions(hasRetryHandler: true) == [.revealInFinder, .retry, .dismiss])
    }

    @Test func testRetryHiddenWhenNoHandlerEvenIfRetryable() {
        let error = SyncError.syncFailed(item: "a", path: "/x/a", reason: "boom")
        #expect(error.alertActions(hasRetryHandler: false) == [.revealInFinder, .dismiss])
    }

    @Test func testRetryHiddenWhenNotRetryableEvenWithHandler() {
        let error = SyncError.copyFailed(items: "the selected items", path: "/x/a", reason: "boom") // isRetryable == false
        #expect(error.alertActions(hasRetryHandler: true) == [.revealInFinder, .dismiss])
    }

    @Test func testRevealHiddenWithoutPath() {
        // No path, not retryable → only Dismiss.
        #expect(SyncError.contentDiffers.alertActions(hasRetryHandler: true) == [.dismiss])
    }

    @Test func testDismissAlwaysPresent() {
        for hasHandler in [true, false] {
            #expect(SyncError.contentDiffers.alertActions(hasRetryHandler: hasHandler).contains(.dismiss))
            #expect(SyncError.syncFailed(item: "a", path: "/x/a", reason: "b").alertActions(hasRetryHandler: hasHandler).contains(.dismiss))
        }
    }
}
