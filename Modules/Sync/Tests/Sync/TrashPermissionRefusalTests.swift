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

    /// **What the refusal is allowed to claim.** An earlier version told the reader to grant Full
    /// Disk Access as though that were the fix; it was granted and the refusal stood, and an
    /// ad-hoc app bundle holding no grants at all was later measured trashing files in the same
    /// folder. So the message may not send anyone to System Settings at all — it must say what IS
    /// known: the file is untouched, every route was tried, and the codes are in the log.
    @Test func theRefusalSaysWhatIsKnownAndPromisesNoRemedy() {
        let error = SyncError.trashNotPermitted(path: "/Users/x/Documents/a.pdf",
                                                reason: "no permission")
        #expect(error.path == "/Users/x/Documents/a.pdf",
                "without a path the alert cannot even offer Reveal in Finder")
        #expect(error.message.contains("Nothing was removed"),
                "a refusal must say the file is still there")
        #expect(error.message.contains("system's own Trash service"),
                "the reader must know the out-of-process fallback was tried too")
        #expect(error.message.contains("re-register"),
                "the reader must know the third attempt was tried too")
        #expect(error.message.contains("sync-cloud.log"),
                "the one place the codes are is not named")
        #expect(!error.message.contains("Full Disk Access"),
                "Full Disk Access is named again, and it is measurably not the cause")
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

    // MARK: The out-of-process fallback

    /// **A refusal gets a second attempt through the system service before it becomes a failure.**
    /// `trashItem` moves the item from the app's own process; `NSWorkspace.recycle` asks the system
    /// to do it. On the reported file the item, its parent and its attributes were all fine — a
    /// byte-identical `ditto` copy in the same folder trashed without complaint from another
    /// process — and Full Disk Access did not change the answer, so which process performs the move
    /// is the remaining difference.
    @MainActor
    @Test func aRefusedTrashIsRetriedThroughTheSystemService() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/a.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashErrorOnce = NSError(domain: NSCocoaErrorDomain,
                                    code: NSFileWriteNoPermissionError, userInfo: nil)
        let asked = Recorder()
        manager.trashViaWorkspace = { urls in
            asked.urls = urls.map(\.path)
            return Dictionary(uniqueKeysWithValues: urls.map {
                ($0, URL(fileURLWithPath: "/Trash/\($0.lastPathComponent)"))
            })
        }
        manager.permanentDeleteConfirmer = { _ in
            Issue.record("a refusal reached the permanent-delete prompt")
            return false
        }

        let outcome = await manager.deleteItems(at: ["/docs/a.pdf"], fileManager: fm)

        #expect(asked.urls == ["/docs/a.pdf"], "the fallback was never asked")
        #expect(outcome.trashed == 1, "the recovered item was not counted as trashed")
        #expect(outcome.isUndoable, "a recovered trash must still offer ⌘Z")
        #expect(manager.currentError == nil, "a recovered trash still reported a failure")
    }

    // MARK: The third attempt — re-registering the item with a move in place

    /// **An item both Trash APIs refuse still reaches the Trash.** Measured on the reported tree,
    /// 2026-08-30: twelve of twelve long-standing files under `~/Documents` were refused by
    /// `trashItem` AND by `NSWorkspace.recycle`, while a plain `rename(2)` into the same Trash
    /// directory succeeded — so the refusal is the Trash layer's, over a stale file-provider
    /// record, and moving the item re-registers it.
    ///
    /// The mock refuses until the path has been moved into, which is what makes this test able to
    /// fail: delete `trashAfterReregistering`'s move and no second attempt can ever succeed.
    @MainActor
    @Test func anItemBothTrashApisRefuseIsTrashedAfterBeingReregistered() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/a.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashRefusedUntilMovedIn = true
        manager.trashViaWorkspace = { _ in [:] }        // the system service refuses too
        manager.permanentDeleteConfirmer = { _ in
            Issue.record("a refusal reached the permanent-delete prompt")
            return false
        }

        let outcome = await manager.deleteItems(at: ["/docs/a.pdf"], fileManager: fm)

        #expect(outcome.trashed == 1, "the re-registered item was not counted as trashed")
        #expect(outcome.isUndoable, "a re-registered trash must still offer ⌘Z")
        #expect(manager.currentError == nil, "a recovered trash still reported a failure")
        #expect(fm.virtualDisk["/docs/a.pdf"] == nil, "the item is still on disk")
    }

    /// **It leaves nothing behind.** The item is parked under a hidden sibling name only for as
    /// long as it takes to move it back, so no `.synccloud-trash-retry-…` may outlive the delete —
    /// in the folder or in the Trash. A litter file here would be one the user never named, in a
    /// folder they are actively tidying.
    @MainActor
    @Test func theReregistrationLeavesNoParkedNameBehind() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/a.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashRefusedUntilMovedIn = true
        manager.trashViaWorkspace = { _ in [:] }

        _ = await manager.deleteItems(at: ["/docs/a.pdf"], fileManager: fm)

        let parked = fm.virtualDisk.keys.filter { $0.contains("synccloud-trash-retry") }
        #expect(parked.isEmpty, "a parked name survived the delete: \(parked)")
        #expect(fm.trashedPaths.allSatisfy { !$0.contains("synccloud-trash-retry") },
                "an item reached the Trash under the parked name rather than its own")
    }

    /// **A refusal it cannot fix leaves the item exactly where it was.** When the move itself is
    /// denied there is nothing to re-register, so the original refusal must stand — with its own
    /// message and its path — and the file must still be on disk under its own name.
    @MainActor
    @Test func aReregistrationThatCannotMoveLeavesTheItemUntouched() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/b.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashRefusedUntilMovedIn = true
        fm.shouldFailMove = true                        // the park cannot happen
        manager.trashViaWorkspace = { _ in [:] }
        manager.permanentDeleteConfirmer = { _ in
            Issue.record("a refusal reached the permanent-delete prompt")
            return false
        }

        let outcome = await manager.deleteItems(at: ["/docs/b.pdf"], fileManager: fm)

        #expect(outcome.removed == 0)
        #expect(fm.virtualDisk["/docs/b.pdf"] != nil, "the item was lost by a failed retry")
        let error = try #require(manager.currentError)
        #expect(error.title == "Not Allowed to Move to the Trash")
    }

    /// **Still last, and still only for permission.** A busy item must not be moved about — the
    /// retry the caller already gets is the right answer — so the re-registration may not fire for
    /// it, and the item must not be renamed even momentarily.
    @MainActor
    @Test func aBusyItemIsNeverReregistered() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/c.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashErrorOnce = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        manager.trashViaWorkspace = { _ in [:] }

        _ = await manager.deleteItems(at: ["/docs/c.pdf"], fileManager: fm)

        #expect(fm.virtualDisk["/docs/c.pdf"] != nil)
        #expect(fm.movedInto.isEmpty, "a busy item was moved in an attempt to re-register it")
    }

    /// **An ordinary trash never moves the item first.** The re-registration is a last resort with
    /// a side effect the other two attempts do not have, so a delete that succeeds normally must
    /// not touch it.
    @MainActor
    @Test func anOrdinaryTrashIsNeverReregistered() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/d.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)

        let outcome = await manager.deleteItems(at: ["/docs/d.pdf"], fileManager: fm)

        #expect(outcome.trashed == 1)
        #expect(fm.movedInto.isEmpty, "a trash that succeeded still moved the item")
    }

    /// **The fallback is a fallback.** An ordinary trash must not go anywhere near it — the
    /// in-process path reports per-item errors the service cannot, and it is the path every
    /// successful delete in this app has always taken.
    @MainActor
    @Test func anOrdinaryTrashNeverReachesTheSystemService() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/a.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        let asked = Recorder()
        manager.trashViaWorkspace = { urls in asked.urls = urls.map(\.path); return [:] }

        let outcome = await manager.deleteItems(at: ["/docs/a.pdf"], fileManager: fm)

        #expect(outcome.trashed == 1)
        #expect(asked.urls.isEmpty, "the system service was used for a trash that succeeded")
    }

    /// **A busy item is not sent to the service either.** It is better served by the retry the
    /// caller already gets, and routing it out of process would trade a retryable error for a
    /// silent one.
    @MainActor
    @Test func aBusyItemIsNotSentToTheSystemService() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/a.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashErrorOnce = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        let asked = Recorder()
        manager.trashViaWorkspace = { urls in asked.urls = urls.map(\.path); return [:] }

        _ = await manager.deleteItems(at: ["/docs/a.pdf"], fileManager: fm)

        #expect(asked.urls.isEmpty, "a busy item was routed to the system service")
        #expect(fm.virtualDisk["/docs/a.pdf"] != nil)
    }

    /// When NOTHING can move it — the in-process trash, the system service and the retry after
    /// re-registering it are all refused — the refusal stands, with its own message, its path and
    /// its log line, exactly as before any fallback existed.
    ///
    /// The mock refuses every `trashItem` rather than only the first, which is what makes this
    /// about "all three denied" and not about running out of injected errors.
    @MainActor
    @Test func aServiceThatAlsoRefusesLeavesTheOriginalRefusalStanding() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/b.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashErrorAlways = NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError, userInfo: nil)
        manager.trashViaWorkspace = { _ in [:] }
        manager.permanentDeleteConfirmer = { _ in
            Issue.record("a refusal reached the permanent-delete prompt")
            return false
        }

        let outcome = await manager.deleteItems(at: ["/docs/b.pdf"], fileManager: fm)

        #expect(outcome.removed == 0)
        #expect(fm.virtualDisk["/docs/b.pdf"] != nil,
                "the item was lost by the re-registration it could not benefit from")
        let parked = fm.virtualDisk.keys.filter { $0.contains("synccloud-trash-retry") }
        #expect(parked.isEmpty, "a parked name survived a delete that failed: \(parked)")
        let error = try #require(manager.currentError)
        #expect(error.title == "Not Allowed to Move to the Trash")
    }

    /// The seam exists so a test can never reach the real service. If the default were ever swapped
    /// for something a test could drive, this is what would notice.
    private final class Recorder: @unchecked Sendable {
        var urls: [String] = []
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
        // Refuses EVERY attempt, not just the first: the in-process trash, the system service
        // and the retry after re-registering must all be denied for this to be about what the
        // user is told when nothing can move the file.
        fm.trashErrorAlways = NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError,
                                      userInfo: [NSUnderlyingErrorKey:
                                                  NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        // If the refusal were escalated instead, this would be asked — and answering false would
        // make the assertions below pass for the wrong reason. It must never be called.
        var askedToDestroy = false
        manager.permanentDeleteConfirmer = { _ in askedToDestroy = true; return false }
        // Stubbed to refuse, so this case is about what the user is TOLD when nothing can move the
        // file — and so the test cannot reach the real system service, which is the whole reason
        // `trashViaWorkspace` is a seam.
        manager.trashViaWorkspace = { _ in [:] }

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
