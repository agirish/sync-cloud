import Foundation
import Testing
@testable import Sync

/// What the app does and says when macOS refuses to move a file to the Trash, even one the user
/// owns in a folder they own. Foundation's sentence names only the symptom, so the alert must carry
/// the path and the log the error codes. A permission refusal stays retryable and never reaches
/// the permanent-delete prompt: answering a permission problem with an unrecoverable act is worse.
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

    /// Foundation often wraps the POSIX cause in a Cocoa error, so the chain is walked, as
    /// `isTransientTrashFailure` walks it.
    @Test func aWrappedPosixDenialIsFoundThroughTheChain() {
        #expect(FileSyncManager.isPermissionRefusal(
            cocoa(NSFileWriteUnknownError, under: posix(EACCES))))
        #expect(FileSyncManager.isPermissionRefusal(
            cocoa(NSFileWriteUnknownError, under: posix(EPERM))))
    }

    /// A busy file is not a denied one. `EBUSY` (a cloud daemon mid-write) is what a retry fixes;
    /// calling it a permission problem would send the user to fix something that isn't broken.
    @Test func aBusyItemIsNotAPermissionRefusal() {
        #expect(!FileSyncManager.isPermissionRefusal(posix(EBUSY)))
        #expect(!FileSyncManager.isPermissionRefusal(posix(EAGAIN)))
        #expect(!FileSyncManager.isPermissionRefusal(cocoa(NSFileLockingError)))
    }

    /// A permission refusal stays transient, like a busy item, so it never reaches the
    /// permanent-delete confirmation: being refused the Trash is no reason to destroy the file.
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

    /// A Trash-less volume still falls through to the confirmation prompt, the case it exists for.
    @Test func anUnsupportedVolumeIsNeitherTransientNorAPermissionRefusal() {
        let unsupported = cocoa(NSFeatureUnsupportedError)
        #expect(!FileSyncManager.isTransientTrashFailure(unsupported))
        #expect(!FileSyncManager.isPermissionRefusal(unsupported))
    }

    // MARK: The diagnosis line

    /// The log gets the codes, not the sentence. "you don't have permission to access it" is the
    /// same for a TCC denial, a deny-delete ACL and a read-only mount; only the domains and codes
    /// of the whole chain tell them apart.
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

    /// The refusal says only what is known: the file is untouched, every route was tried, and the
    /// codes are in the log. It promises no remedy: Full Disk Access is not the cause, since an app
    /// with no grants at all can trash files in the same folder.
    @Test func theRefusalSaysWhatIsKnownAndPromisesNoRemedy() {
        let error = SyncError.trashNotPermitted(path: "/Users/x/Documents/a.pdf",
                                                reason: "no permission")
        #expect(error.path == "/Users/x/Documents/a.pdf",
                "without a path the alert cannot even offer Reveal in Finder")
        #expect(error.message.contains("Nothing was removed"),
                "a refusal must say the file is still there")
        #expect(error.message.contains("system’s own Trash service"),
                "the reader must know the out-of-process fallback was tried too")
        #expect(error.message.contains("re-register"),
                "the reader must know the third attempt was tried too")
        #expect(error.message.contains("sync-cloud.log"),
                "the one place the codes are is not named")
        #expect(!error.message.contains("Full Disk Access"),
                "Full Disk Access is named again, and it is measurably not the cause")
        #expect(error.reason == "no permission")
    }

    /// Not retryable: pressing the same button again can't change a permission, and a Retry button
    /// that can't work is worse than none.
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
        #expect(error.message == "Some items couldn’t be deleted.")
    }

    // MARK: The out-of-process fallback

    /// A refusal gets a second attempt through the system service before it becomes a failure.
    /// `trashItem` moves the item from the app's own process; `NSWorkspace.recycle` asks the system
    /// to, which can succeed where the in-process move is refused.
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

    /// The service keys its answer with its own spelling of each URL (a resolved `/private`
    /// prefix, a trailing slash on a folder), and `URL` hashes on the absolute string, so a plain
    /// `moved[url]` misses a file it just trashed. Each reading gets its own case: the exact key
    /// is what a re-spelling defeats, and the wide one is what a multi-item answer must not reach.
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
        // A single unrelated entry is nil here too. "One entry must be mine" holds only for a
        // one-item request (five asked, one back would be misattributed), so it lives in
        // `recycledSingle`.
        #expect(FileSyncManager.recycled(asked, in: [other: landed]) == nil,
                "the one-item-only reading leaked into the general one")
    }

    /// The wide reading, where it is sound: request and read are one call, so a one-entry answer to
    /// a one-item request is that item in any spelling. No standardising maps `/private/docs` to
    /// `/docs` (the real shape on a symlinked root), so only this rule finds it.
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

    /// End to end: with the service re-spelling its key, the delete still counts the item as
    /// trashed and never offers to destroy outright a file already recoverable in the Trash.
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
            // `/private` + the path, the real symlinked-root re-spelling, which no standardising
            // maps back, so this drives the widest reading.
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

    /// An item both Trash APIs refuse still reaches the Trash. Such a refusal can come from a stale
    /// file-provider record while a plain `rename(2)` still works, and moving the item
    /// re-registers it. The mock refuses until the path is moved into, so removing
    /// `trashAfterReregistering`'s move must make this fail.
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

    /// The item is parked under a hidden sibling name only until it is moved back, so no
    /// `.synccloud-trash-retry-…` may outlive the delete, in the folder or in the Trash.
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

    /// When the park itself is denied there is nothing to re-register: the original refusal stands,
    /// with its own message and path, and the file stays under its own name.
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

    /// Re-registration is only for a permission refusal. A busy item gets the caller's retry and
    /// is never renamed, even for a moment.
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

    /// An ordinary trash never moves the item first: re-registration is a last resort, with a side
    /// effect the other two attempts lack.
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

    /// If the park succeeds and the move back fails, the item is intact under a dotted name in the
    /// same folder, so the user must be told that path, not "the file is untouched". Needs
    /// `failMoveToPathsOnce`: `shouldFailMove` clears on its first throw, so it fails the park.
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

    /// The strand leaves a file somewhere nobody asked for, so it logs a line naming both paths.
    @MainActor
    @Test func aStrandedParkIsLoggedWithBothNames() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        // A name no other test strands: the log is the process's, and the move path's strand
        // (`MoveParkedLeftoverTests`) writes the same sentence about its own file.
        fm.virtualDisk["/docs/stranded-log.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.trashRefusedUntilMovedIn = true
        fm.failMoveToPathsOnce = ["/docs/stranded-log.pdf"]
        manager.trashViaWorkspace = { _ in [:] }

        _ = await manager.deleteItems(at: ["/docs/stranded-log.pdf"], fileManager: fm)

        let line = await loggedLineOnDisk(containing: "/docs/stranded-log.pdf was parked as")
        let logged = try #require(line, "the strand left nothing in the log")
        #expect(logged.contains("could NOT be moved back"), "the log line does not say the item was left parked")
        #expect(logged.contains("synccloud-trash-retry"), "the log line does not name where it is")
    }

    /// A folder is re-registered the same way: duplicate groups are often folders, and "Trash the
    /// other copy" is offered over them.
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

    /// When re-registration runs and the Trash still refuses, the log records the third attempt,
    /// so a reader can tell a retry that failed from one that never ran.
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

    /// A move must not become a permanent delete under this refusal. Cross-volume move and replace
    /// trash the source and fall back to `removeItem`, a move's one unrecoverable branch; the same
    /// refusal blocks that trash, so without the retry the move destroys the original.
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

    /// Pins the call site, not the helper: the helper's own tests stay green if the call in
    /// `FileOperations+Primitives` is deleted, while this and the next drive `safeMoveItem` end to
    /// end. `movedInto` is the assertion that matters: the source leaves `virtualDisk` whether it
    /// was trashed or removed, but only the retry's move back writes to the source path.
    @Test func aCrossVolumeMoveTrashesTheSourceRatherThanDestroyingIt() throws {
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        fm.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        fm.shouldFailMove = true            // EXDEV on the staging rename → cross-volume path
        fm.trashRefusedUntilMovedIn = true  // and the source's trash is refused

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

    /// The retry declines a busy source, which is not a permission refusal, so a move that hits a
    /// transient error runs its ordinary cleanup.
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

    /// An ordinary trash never reaches the system service: the in-process path reports per-item
    /// errors the service can't.
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

    /// Nor does a busy item: the caller's retry serves it better, and the service would trade a
    /// retryable error for a silent one.
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

    /// When the in-process trash, the system service and the re-registered retry are all refused,
    /// the refusal stands with its own message, path and log line, and no parked name survives.
    /// The mock refuses every `trashItem`, not just the first, so all three really are denied.
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

    /// Records the URLs a stubbed `trashViaWorkspace` was asked to trash, so a test can tell
    /// whether the fallback ran.
    private final class Recorder: @unchecked Sendable {
        var urls: [String] = []
    }

    // MARK: The item the delete path must not park — and the move path must

    /// The delete path declines re-registration while a provider is moving the item's bytes. An
    /// item mid-write throws the same `NSFileWriteNoPermissionError`, so only its transfer state
    /// tells them apart, and renaming it mid-sync invites the provider to record a delete and a
    /// create. The park would work on this fixture, and the control runs it with the probe false.
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

    /// The move path parks regardless, because its alternative destroys the file:
    /// `retriedSourceCleanupTrash` returning false sends its callers to `removeItem`. A positive
    /// control, on a fixture whose only way to the Trash is the park.
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

    /// The pin that can fail where the control above can't. As a `nonisolated static`,
    /// `retriedSourceCleanupTrash` can't reach the instance's `isMidCloudTransfer`, but nothing
    /// stops it calling the static probe directly, which would send an uploading source to
    /// `removeItem`. This path has no seam to inject a probe through, so a source scan checks it.
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

    /// The whole path, from a denied `trashItem` to what the user reads: `deleteItems` routes a
    /// denial into the refusal rather than flattening it back to Foundation's sentence.
    @MainActor
    @Test func aDeniedTrashReachesTheUserAsTheRefusalAndLeavesTheFile() async throws {
        let fm = MockFileManager()
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        fm.virtualDisk["/docs/Lease Agreement.pdf"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 100], contents: nil)
        // Refuses every attempt, so nothing can move the file.
        fm.trashErrorAlways = NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError,
                                      userInfo: [NSUnderlyingErrorKey:
                                                  NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        // Must never be called: an escalated refusal answered false here would pass the
        // assertions below for the wrong reason.
        var askedToDestroy = false
        manager.permanentDeleteConfirmer = { _ in askedToDestroy = true; return false }
        // Stubbed to refuse, which also keeps the test away from the real system service.
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
