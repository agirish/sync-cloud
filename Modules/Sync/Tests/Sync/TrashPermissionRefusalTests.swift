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

    // MARK: Reading the system service's answer

    /// **The service answers with ITS spelling of the URL, not yours.** `NSWorkspace.recycle`
    /// documents the keys as the URLs it was given and hands back its own standardisation of them
    /// — a resolved `/private` prefix, a trailing slash on a directory. `URL` hashes on the
    /// absolute string, so `moved[url]` is nil over a file the service had just trashed.
    ///
    /// Three readings, each with its own case, because the narrow one is what a re-spelling
    /// defeats and the wide one is what a multi-item answer must not fall through to.
    @Test func aRecycledItemIsFoundEvenWhenTheServiceRespellsTheKey() {
        let asked = URL(fileURLWithPath: "/docs/a.pdf")
        let landed = URL(fileURLWithPath: "/Trash/a.pdf")

        #expect(FileSyncManager.recycled(asked, in: [asked: landed]) == landed,
                "the ordinary exact-key answer stopped working")
        // A key naming the same file in a different spelling.
        let respelt = URL(fileURLWithPath: "/docs/./a.pdf")
        #expect(FileSyncManager.recycled(asked, in: [respelt: landed]) == landed,
                "a re-spelt key made a recycled file look untouched")
        // Nothing moved: the service reports only what it moved, so an empty answer is a refusal.
        #expect(FileSyncManager.recycled(asked, in: [:]) == nil)
        // More than one entry and no key that matches: no guessing which one was ours.
        let other = URL(fileURLWithPath: "/docs/b.pdf")
        #expect(FileSyncManager.recycled(asked, in: [other: landed,
                                                     URL(fileURLWithPath: "/docs/c.pdf"): landed])
                    == nil,
                "a file was reported as trashed on the strength of somebody else's entry")
        // **And a SINGLE unrelated entry is nil here too**, which is the boundary between the two
        // functions: read as a rule over a dictionary alone, "one entry must be mine" is false —
        // a caller asking about five items and getting one back would misattribute it. That
        // reading is sound only for a one-item request, so it lives in `recycledSingle` below.
        #expect(FileSyncManager.recycled(asked, in: [other: landed]) == nil,
                "the one-item-only reading leaked into the general one")
    }

    /// The wide reading, where it IS sound: the request and the read are one call, so a one-entry
    /// answer to a one-item request is that item whatever spelling came back. `/private/docs` is a
    /// key no amount of standardising maps to `/docs`, so only this rule can find it — which is
    /// what the real `/private` prefix on a symlinked root looks like.
    @Test func aOneItemRequestReadsAOneEntryAnswerAsItsOwn() async {
        let asked = URL(fileURLWithPath: "/docs/a.pdf")
        let landed = URL(fileURLWithPath: "/Trash/a.pdf")

        let found = await FileSyncManager.recycledSingle(asked) { _ in
            [URL(fileURLWithPath: "/private/docs/a.pdf"): landed]
        }
        #expect(found == landed, "a key no standardisation reaches made a trashed file look untouched")

        // And a refusal is still a refusal.
        let refused = await FileSyncManager.recycledSingle(asked) { _ in [:] }
        #expect(refused == nil)
    }

    /// The same thing end to end: with the service re-spelling its key, the delete must still
    /// count the item as trashed and must never reach the permanent-delete prompt — which, before
    /// this, it did, offering to destroy outright a file already sitting recoverable in the Trash.
    @MainActor
    @Test func aRespeltRecycleKeyDoesNotEscalateToAPermanentDelete() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/a.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        // Refuses in-process every time, so the answer below is the only way out.
        fm.trashErrorAlways = NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError, userInfo: nil)
        manager.trashViaWorkspace = { urls in
            // `/private` + the path, the real shape of a symlinked-root re-spelling — and one
            // no standardisation maps back, so this drives the widest of the three readings.
            Dictionary(uniqueKeysWithValues: urls.map { url -> (URL, URL) in
                (URL(fileURLWithPath: "/private\(url.path)"),
                 URL(fileURLWithPath: "/Trash/\(url.lastPathComponent)"))
            })
        }
        manager.permanentDeleteConfirmer = { _ in
            Issue.record("a file the system service had already trashed reached the permanent-delete prompt")
            return false
        }

        let outcome = await manager.deleteItems(at: ["/docs/a.pdf"], fileManager: fm)

        #expect(outcome.trashed == 1, "the recycled item was not counted as trashed")
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

    /// **The strand branch: parked, and the user is told where.** If the park succeeds and the
    /// move BACK fails, the item is intact — but under a dotted name in the same folder, which is
    /// exactly the state the ordinary refusal's "nothing was removed and the file is untouched"
    /// would misdescribe. Someone reading that goes looking at a path that now holds nothing.
    ///
    /// Needs `failMoveToPathsOnce`, not `shouldFailMove`: the latter clears on its first throw, so
    /// it always fails the PARK and never reaches this branch.
    @MainActor
    @Test func aParkedItemThatCannotBeRestoredIsReportedAtItsNewPath() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/a.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashRefusedUntilMovedIn = true
        fm.failMoveToPathsOnce = ["/docs/a.pdf"]        // the park lands; the move back does not
        manager.trashViaWorkspace = { _ in [:] }
        manager.permanentDeleteConfirmer = { _ in
            Issue.record("a parked item reached the permanent-delete prompt")
            return false
        }

        let outcome = await manager.deleteItems(at: ["/docs/a.pdf"], fileManager: fm)

        #expect(outcome.removed == 0, "nothing was deleted, so nothing may be counted as removed")
        let parked = fm.virtualDisk.keys.filter { $0.contains("synccloud-trash-retry") }
        #expect(parked.count == 1, "the item should be parked exactly once: \(parked)")
        #expect(fm.virtualDisk["/docs/a.pdf"] == nil, "the fixture no longer models a strand")

        let error = try #require(manager.currentError)
        #expect(error.title == "Renamed, Not Deleted",
                "the strand was reported as an ordinary refusal: \(error.title)")
        #expect(error.path == parked.first,
                "Reveal in Finder would open a path that no longer holds the item")
        #expect(!error.message.contains("untouched"),
                "the message claims the file is untouched, and it is not where it was")
        #expect(error.message.contains("a.pdf"), "the message must name the original name to restore")
    }

    /// The strand is the one branch that leaves a file somewhere nobody asked for, so it owes the
    /// log he audits a line — with both names in it.
    @MainActor
    @Test func aStrandedParkIsLoggedWithBothNames() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/a.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashRefusedUntilMovedIn = true
        fm.failMoveToPathsOnce = ["/docs/a.pdf"]
        manager.trashViaWorkspace = { _ in [:] }

        _ = await manager.deleteItems(at: ["/docs/a.pdf"], fileManager: fm)

        let line = await loggedLineOnDisk(containing: "could NOT be moved back")
        let logged = try #require(line, "the strand left nothing in the log")
        #expect(logged.contains("/docs/a.pdf"), "the log line does not name the item")
        #expect(logged.contains("synccloud-trash-retry"), "the log line does not name where it is")
    }

    /// **A folder is re-registered the same way.** Duplicate groups are routinely folders, and the
    /// whole surface this fix serves offers "Trash the other copy" over them, so the retry may not
    /// be file-only.
    @MainActor
    @Test func aDirectoryIsReregisteredTheSameWay() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/folder"] = MockFileManager.FileStub(
            isDirectory: true, attributes: [.size: 0], contents: nil)
        fm.trashRefusedUntilMovedIn = true
        manager.trashViaWorkspace = { _ in [:] }

        let outcome = await manager.deleteItems(at: ["/docs/folder"], fileManager: fm)

        #expect(outcome.trashed == 1, "a folder was not re-registered")
        #expect(fm.virtualDisk["/docs/folder"] == nil)
    }

    /// **The retry that changes nothing says so.** When the re-registration runs and the Trash
    /// still refuses, the log must record that the third attempt happened — otherwise the only
    /// trace is the first refusal, and a reader cannot tell the retry from a retry that never ran.
    @MainActor
    @Test func aRetryThatStillFailsLeavesItsOwnLineInTheLog() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/b.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashErrorAlways = NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError, userInfo: nil)
        manager.trashViaWorkspace = { _ in [:] }

        _ = await manager.deleteItems(at: ["/docs/b.pdf"], fileManager: fm)

        #expect(await loggedLineOnDisk(containing: "STILL refused it") != nil,
                "the third attempt ran and left no trace of having run")
        #expect(fm.virtualDisk["/docs/b.pdf"] != nil, "the item must be back at its own path")
    }

    // MARK: The move primitives' unrecoverable fallback

    /// **A move must not turn into a permanent deletion under this refusal.** The cross-volume
    /// move and replace both clean up the source with `trashItem` and fall back to `removeItem`,
    /// which is the one unrecoverable branch of a move. The same refusal that blocks a delete
    /// blocks that trash, so without the retry a move silently destroys the original.
    @Test func theSourceCleanupRetryStopsShortOfTheUnrecoverableFallback() {
        let fm = MockFileManager()
        fm.virtualDisk["/src/a.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashRefusedUntilMovedIn = true

        let handled = FileSyncManager.retriedSourceCleanupTrash(
            URL(fileURLWithPath: "/src/a.pdf"),
            after: NSError(domain: NSCocoaErrorDomain,
                           code: NSFileWriteNoPermissionError, userInfo: nil),
            fileManager: fm, context: "Cross-volume move")

        #expect(handled, "the caller would have fallen through to removeItem and destroyed it")
        #expect(fm.virtualDisk["/src/a.pdf"] == nil, "the source should have reached the Trash")
    }

    /// **The CALL SITE, not the helper.** The two tests above pin `retriedSourceCleanupTrash`
    /// itself, and would stay green if the call in `FileOperations+Primitives` were deleted. These
    /// two drive `safeMoveItem` end to end, so they fail if the primitives stop asking.
    ///
    /// `movedInto` is the assertion that matters. Without the retry the source still leaves
    /// `virtualDisk` — permanently removed rather than trashed — so checking only that it is gone
    /// would pass either way, and the mock's `trashedPaths` records the trash DESTINATION, which
    /// both outcomes can produce. Nothing in a cross-volume move writes to the source path, so the
    /// source appearing as a move destination means one thing: the retry put it back.
    @Test func aCrossVolumeMoveTrashesTheSourceRatherThanDestroyingIt() throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        fm.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.shouldFailMove = true            // EXDEV on the staging rename → cross-volume path
        fm.trashRefusedUntilMovedIn = true  // and the source's trash is refused, as measured

        _ = try FileSyncManager.safeMoveItem(at: URL(fileURLWithPath: "/src/data.bin"),
                                             to: URL(fileURLWithPath: "/dst/data.bin"),
                                             fileManager: fm)

        #expect(fm.movedInto.contains("/src/data.bin"),
                "the source was destroyed by the unrecoverable fallback instead of re-registered")
        #expect(fm.virtualDisk["/src/data.bin"] == nil, "the source should have reached the Trash")
        #expect(fm.virtualDisk["/dst/data.bin"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect(fm.virtualDisk.keys.contains { $0.contains("synccloud-trash-retry") } == false,
                "the park was left behind in the source folder")
    }

    /// The same call site in the REPLACE arm, which has its own copy of the fallback.
    @Test func aCrossVolumeReplaceTrashesTheSourceRatherThanDestroyingIt() throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        fm.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.virtualDisk["/dst/data.bin"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 5], contents: nil)
        fm.shouldFailMove = true
        fm.trashRefusedUntilMovedIn = true

        _ = try FileSyncManager.safeMoveItem(at: URL(fileURLWithPath: "/src/data.bin"),
                                             to: URL(fileURLWithPath: "/dst/data.bin"),
                                             fileManager: fm)

        #expect(fm.movedInto.contains("/src/data.bin"),
                "the replace arm destroyed the source instead of re-registering it")
        #expect(fm.virtualDisk["/src/data.bin"] == nil, "the source should have reached the Trash")
        #expect(fm.virtualDisk["/dst/data.bin"]?.attributes?[FileAttributeKey.size] as? Int == 100)
    }

    /// **And it stays a fallback.** A busy source is not a permission refusal, so the retry must
    /// decline it and let the existing cleanup run exactly as before — otherwise this change would
    /// alter the behaviour of every move that hits a transient error.
    @Test func theSourceCleanupRetryDeclinesAnythingButAPermissionRefusal() {
        let fm = MockFileManager()
        fm.virtualDisk["/src/a.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)

        let handled = FileSyncManager.retriedSourceCleanupTrash(
            URL(fileURLWithPath: "/src/a.pdf"),
            after: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)),
            fileManager: fm, context: "Cross-volume move")

        #expect(!handled, "a busy source was taken over by the permission retry")
        #expect(fm.movedInto.isEmpty, "a busy source was moved about")
        #expect(fm.virtualDisk["/src/a.pdf"] != nil)
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

    // MARK: The item the delete path must not park — and the move path must

    /// **The re-registration retry is declined while a provider is still moving the item's
    /// bytes.** The refusal it answers — `NSFileWriteNoPermissionError` on a file-provider item —
    /// is the same error an item its daemon is mid-write on throws, so the error cannot tell the
    /// two apart and the item's transfer state has to. Renaming a file out from under a sync that
    /// is halfway through it invites the provider to record a delete-and-create where there was
    /// neither.
    ///
    /// The fixture is one where the park WOULD have worked (`trashRefusedUntilMovedIn`), so the
    /// refusal is the only thing that can produce this result — and the control below is the same
    /// fixture with the probe answering false.
    @MainActor
    @Test func theDeletePathDeclinesToParkAnItemMidTransfer() async throws {
        func attempt(midTransfer: Bool) async -> (DeleteOutcome, stillThere: Bool, MockFileManager) {
            let fm = MockFileManager()
            let manager = FileSyncManager(fileManager: fm)
            manager.undoManager = UndoManager()
            fm.virtualDisk["/docs/a.pdf"] = MockFileManager.FileStub(
                isDirectory: false, attributes: [.size: 100], contents: nil)
            fm.trashRefusedUntilMovedIn = true
            manager.trashViaWorkspace = { _ in [:] }
            manager.isMidCloudTransfer = { _ in midTransfer }
            manager.permanentDeleteConfirmer = { _ in
                Issue.record("a permission refusal reached the permanent-delete prompt")
                return false
            }
            let outcome = await manager.deleteItems(at: ["/docs/a.pdf"], fileManager: fm)
            return (outcome, fm.virtualDisk["/docs/a.pdf"] != nil, fm)
        }

        let (declined, stillThere, fm) = await attempt(midTransfer: true)
        #expect(declined.trashed == 0, "an item mid-transfer was parked and trashed anyway")
        #expect(stillThere, "an item mid-transfer left its own path")
        #expect(fm.movedInto.isEmpty, "the item was physically moved despite the refusal")

        // The control: the identical fixture with nothing transferring parks, restores and trashes.
        let (parked, gone, _) = await attempt(midTransfer: false)
        #expect(parked.trashed == 1, "the fixture cannot park at all, so the refusal proves nothing")
        #expect(!gone, "the control never reached the Trash")
    }

    /// **And the MOVE path must park regardless, because there the alternative destroys the file.**
    ///
    /// `retriedSourceCleanupTrash` returning false sends its two callers to `removeItem` — the one
    /// unrecoverable branch of a cross-volume move. Declining to park there would trade a source
    /// that reaches the Trash for one deleted outright, which is strictly worse for exactly the
    /// item the delete path's refusal exists to protect. It is a `nonisolated static` and the
    /// policy is a property on the manager, so it cannot pick the refusal up by accident — this
    /// pins that, by parking on a fixture whose only way to the Trash is the park.
    @Test func theMoveSourceCleanupParksEvenSoBecauseItsAlternativeIsPermanent() throws {
        let fm = MockFileManager()
        fm.virtualDisk["/docs/a.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashRefusedUntilMovedIn = true
        let refusal = NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteNoPermissionError, userInfo: nil)

        let handled = FileSyncManager.retriedSourceCleanupTrash(
            URL(fileURLWithPath: "/docs/a.pdf"), after: refusal, fileManager: fm,
            context: "Cross-volume move")

        #expect(handled, """
                the move's source cleanup did not reach the Trash, so its caller falls through to                 removeItem and destroys the original outright
                """)
        #expect(fm.virtualDisk["/docs/a.pdf"] == nil, "the source never left its path")
    }

    /// **The test above is a positive control and cannot fail on the regression it describes**, so
    /// this is the pin that can.
    ///
    /// `retriedSourceCleanupTrash` is a `nonisolated static` and the policy is an instance
    /// property, so it cannot reach `manager.isMidCloudTransfer` — the compiler enforces that half.
    /// The half the compiler does NOT enforce is somebody calling the static probe directly, which
    /// is a two-word edit and would reintroduce exactly the data loss: a source that would have
    /// reached the Trash goes to `removeItem` instead. Injecting a probe to test it is not
    /// available — a `nonisolated static` with a seam is a seam production has to pass through,
    /// and the point is that this path has none — so the scan states the rule and says so.
    @Test func theMoveSourceCleanupDoesNotConsultTheMidTransferProbe() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync/FileOperations.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read FileOperations.swift — this check is vacuous")
        let start = try #require(source.range(of: "static func retriedSourceCleanupTrash("),
                                 "`retriedSourceCleanupTrash` is gone or renamed — re-aim this scan")
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex),
                               "cannot find the end of `retriedSourceCleanupTrash` — re-aim this scan")
        let body = String(source[start.upperBound..<end.lowerBound])
        // The positive control: the body really is the one being read.
        #expect(body.contains("trashAfterReregistering("),
                "the scan is reading the wrong function — it does not park at all")
        #expect(!body.contains("midCloudTransfer"), """
                the move's source cleanup consults the mid-transfer probe, so an uploading file                 that would have reached the Trash is sent to removeItem and destroyed instead
                """)
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
