import Foundation
import Testing
@testable import Sync

/// What the app says when macOS refuses to move a file to the Trash.
///
/// **Reported from the running app on 2026-08-30**: a duplicate under `~/Documents` — a file the
/// user owns, in a folder the user owns, with no flags and no deny ACL — came back as "Some items
/// couldn't be deleted. (“Lease Agreement.pdf” couldn't be moved to the trash because you don't
/// have permission to access it.)". Foundation's sentence names the symptom and stops, the alert
/// carried no path, and nothing at all reached `~/sync-cloud.log`, so diagnosing it meant
/// reproducing it.
///
/// The classification is unchanged — a permission refusal was already treated as retryable rather
/// than escalated to the permanent-delete prompt, and that stays true, because answering a
/// permission problem with an unrecoverable act would be worse. What changed is what the user is
/// told and what the log records.
@Suite struct TrashPermissionRefusalTests {

    private func cocoa(_ code: Int, under underlying: NSError? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: NSCocoaErrorDomain, code: code, userInfo: info)
    }

    private func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    // MARK: Which refusals are permission

    @Test func aWriteNoPermissionErrorIsAPermissionRefusal() {
        #expect(FileSyncManager.isPermissionRefusal(cocoa(NSFileWriteNoPermissionError)))
    }

    /// Foundation routinely reports a Cocoa error WRAPPING the POSIX cause, so the chain is walked
    /// — the same reason `isTransientTrashFailure` walks it.
    @Test func aWrappedPosixDenialIsFoundThroughTheChain() {
        #expect(FileSyncManager.isPermissionRefusal(
            cocoa(NSFileWriteUnknownError, under: posix(EACCES))))
        #expect(FileSyncManager.isPermissionRefusal(
            cocoa(NSFileWriteUnknownError, under: posix(EPERM))))
    }

    /// **A busy file is not a denied one.** `EBUSY` is the case a retry genuinely fixes — a cloud
    /// daemon mid-write — and telling that user to go change a privacy setting would send them to
    /// fix something that is not broken.
    @Test func aBusyItemIsNotAPermissionRefusal() {
        #expect(!FileSyncManager.isPermissionRefusal(posix(EBUSY)))
        #expect(!FileSyncManager.isPermissionRefusal(posix(EAGAIN)))
        #expect(!FileSyncManager.isPermissionRefusal(cocoa(NSFileLockingError)))
    }

    /// **The narrowing must not change what gets escalated.** Both a busy item and a denied one
    /// stay transient, so neither reaches the permanent-delete confirmation — offering to destroy
    /// a file outright because the app was refused the Trash would answer a permission problem
    /// with an unrecoverable act.
    @Test func everyPermissionRefusalIsStillTransient() {
        let refusals = [cocoa(NSFileWriteNoPermissionError),
                        cocoa(NSFileWriteUnknownError, under: posix(EACCES)),
                        posix(EPERM)]
        for error in refusals {
            #expect(FileSyncManager.isPermissionRefusal(error), "\(error)")
            #expect(FileSyncManager.isTransientTrashFailure(error),
                    "a permission refusal became escalatable to a permanent delete: \(error)")
        }
    }

    /// A genuinely Trash-less volume still falls through to the confirmation prompt, which is the
    /// case that machinery exists for.
    @Test func anUnsupportedVolumeIsNeitherTransientNorAPermissionRefusal() {
        let unsupported = cocoa(NSFeatureUnsupportedError)
        #expect(!FileSyncManager.isTransientTrashFailure(unsupported))
        #expect(!FileSyncManager.isPermissionRefusal(unsupported))
    }

    // MARK: The diagnosis line

    /// **The codes, not the sentence.** "you don't have permission to access it" is the same
    /// string for a TCC denial, a deny-delete ACL and a read-only mount; the domains and codes are
    /// what tell the next reader which — and none of them was reaching the log at all.
    @Test func theDiagnosisNamesEveryDomainAndCodeInTheChain() {
        let error = cocoa(NSFileWriteNoPermissionError, under: posix(EPERM))
        let line = FileSyncManager.trashFailureDiagnosis(error)
        #expect(line.contains("NSCocoaErrorDomain 513"))
        #expect(line.contains("NSPOSIXErrorDomain 1"))
        #expect(line.contains("←"), "the chain was flattened to its outermost error")
    }

    /// Bounded, like the walks it sits beside: a cyclic chain must not spin.
    @Test func theDiagnosisTerminates() {
        let inner = NSError(domain: "A", code: 1)
        var chain = inner
        for _ in 0..<12 {
            chain = NSError(domain: "A", code: 1, userInfo: [NSUnderlyingErrorKey: chain])
        }
        let line = FileSyncManager.trashFailureDiagnosis(chain)
        #expect(line.components(separatedBy: "←").count <= 6)
    }

    // MARK: What the user is told

    /// The remedy, and the reason a reader would otherwise not guess it: an app can read every
    /// file in a granted folder and still be refused the move, because a file kept in iCloud Drive
    /// is trashed into iCloud's own Trash, outside those per-folder grants.
    @Test func theRefusalNamesTheFileAndTheRemedy() {
        let error = SyncError.trashNotPermitted(path: "/Users/x/Documents/a.pdf",
                                                reason: "no permission")
        #expect(error.path == "/Users/x/Documents/a.pdf",
                "without a path the alert cannot even offer Reveal in Finder")
        #expect(error.message.contains("Full Disk Access"))
        #expect(error.message.contains("iCloud"))
        #expect(error.message.contains("Nothing was removed."),
                "a refusal must say the file is still there")
        #expect(error.reason == "no permission")
    }

    /// **Not retryable, and that is the point of splitting it out.** Pressing the same button
    /// again cannot change a permission, and a Retry button that cannot work is worse than none.
    @Test func aPermissionRefusalOffersNoRetry() {
        let error = SyncError.trashNotPermitted(path: "/Users/x/a.pdf", reason: "denied")
        #expect(!error.isRetryable)
        #expect(!error.alertActions(hasRetryHandler: true).contains(.retry))
        #expect(error.alertActions(hasRetryHandler: true).contains(.revealInFinder))
    }

    /// The generic delete failure is unchanged for everything that is not a permission refusal.
    @Test func theGenericDeleteFailureStillExists() {
        let error = SyncError.deleteFailed(reason: "busy")
        #expect(error.title == "Delete Failed")
        #expect(error.message == "Some items couldn't be deleted.")
    }

    // MARK: End to end

    /// **The whole path, from a denied `trashItem` to what the user reads.** The unit cases above
    /// pin the classification; this pins that `deleteItems` actually routes a denial into it
    /// rather than flattening it back to Foundation's sentence — which is exactly what the shipped
    /// build did, because the presenter rebuilt the error from `localizedDescription`.
    @MainActor
    @Test func aDeniedTrashReachesTheUserAsTheRefusalAndLeavesTheFile() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/Lease Agreement.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashErrorOnce = NSError(domain: NSCocoaErrorDomain,
                                    code: NSFileWriteNoPermissionError,
                                    userInfo: [NSUnderlyingErrorKey:
                                                NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        // If the refusal were escalated instead, this would be asked — and answering false would
        // make the assertions below pass for the wrong reason. It must never be called.
        var askedToDestroy = false
        manager.permanentDeleteConfirmer = { _ in askedToDestroy = true; return false }

        let outcome = await manager.deleteItems(at: ["/docs/Lease Agreement.pdf"], fileManager: fm)

        #expect(outcome.removed == 0)
        #expect(fm.virtualDisk["/docs/Lease Agreement.pdf"] != nil, "the file was removed anyway")
        #expect(!askedToDestroy,
                "a permission refusal was escalated to the permanent-delete prompt")
        let error = try #require(manager.currentError)
        #expect(error.title == "Not Allowed to Move to the Trash",
                "the refusal was flattened back to the generic sentence: \(error.title)")
        #expect(error.path == "/docs/Lease Agreement.pdf")
        #expect(!error.isRetryable)
        #expect(await loggedLineOnDisk(containing: "refused to move /docs/Lease Agreement.pdf") != nil,
                "the refusal left nothing in the log he audits")
    }
}
