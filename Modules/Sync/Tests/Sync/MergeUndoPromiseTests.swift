import Testing
import Foundation
import Events
@testable import Sync

/// The merge path's half of `DeleteOutcome`'s promise, which the type's own suite does not reach.
///
/// `DuplicateRemovalHonestyTests` pins the two *reclaim* paths — `resolveDuplicateGroup` and the
/// bulk one — where an unfulfillable "press ⌘Z to undo" sends the shortcut at whatever was
/// previously on top of the stack. The merge is the third caller and it was missed, with a worse
/// consequence than a misdirected undo.
///
/// A merge copies the redundant copy's unique files into the keeper, registers a `registerCopyUndo`
/// for that fold, and then trashes the copy. On a Trash-less volume — exFAT, most SMB shares — the
/// copy is destroyed permanently and registers no restore, but the fold's copy-undo is still in the
/// group, and **undoing a copy deletes the copied item**. So the success banner's "Press ⌘Z to
/// undo" led from a merge that cannot be taken back to a prompt that removes the folded files from
/// the keeper, with the originals already gone. The undo's own delete asks for confirmation, so
/// this is not silent — but the app was the thing telling the user to start.
///
/// A real `FileManager` subclass rather than the mock disk, for the reason `MergeCancelMidCopyTests`
/// documents: the merge hashes real bytes to plan, and only the `fileManager is FileManager` fast
/// path yields the sizes it plans from.
@Suite struct MergeUndoPromiseTests {

    /// A real `FileManager` whose Trash always refuses — the Trash-less volume, without needing one.
    /// `deleteItems` then asks `permanentDeleteConfirmer` and, on a yes, removes the item outright.
    private final class TrashlessVolume: FileManager, @unchecked Sendable {
        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        }
    }

    private func write(_ url: URL, bytes: Int, fill: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    /// Builds the overlapping pair the merge folds: one shared file (skipped by the plan) and one
    /// unique file in the redundant copy (the fold, and so the copy-undo).
    private func makePair(_ base: URL, redundantName: String) throws -> (keeper: URL, redundant: URL, group: DuplicateGroup) {
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent(redundantName)
        try write(keeper.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        try write(redundant.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        try write(redundant.appendingPathComponent("unique.txt"), bytes: 4000, fill: 0x55)
        let k = DuplicateCopy(id: keeper.path, name: "Keeper", isDirectory: true, size: 4000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: redundant.path, name: redundantName, isDirectory: true, size: 8000, itemCount: 2,
                              modificationDate: nil, uniqueItemCount: 1, depth: 0, isRecommendedKeeper: false)
        return (keeper, redundant, DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "Keeper",
                                                  isDirectory: true, copies: [k, r], reclaimableBytes: 4000))
    }

    /// **The headline.** The copy leaves permanently, the merge still succeeds — and the banner must
    /// stop offering the undo, because taking it would delete the only remaining copy of the folded
    /// files.
    @MainActor
    @Test func aMergeWhoseCopyWasDestroyedPermanentlyDoesNotPromiseUndo() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeUndoPromise")
        defer { try? FileManager.default.removeItem(at: base) }
        // Unique name so the Trash assertion below cannot be answered by someone else's folder.
        let rName = "Redundant-\(UUID().uuidString)"
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(rName)")
        defer { try? FileManager.default.removeItem(at: trashed) }
        let pair = try makePair(base, redundantName: rName)

        let manager = FileSyncManager(fileManager: TrashlessVolume())
        manager.undoManager = UndoManager()
        manager.permanentDeleteConfirmer = { _ in true }   // the user confirms the permanent delete
        manager.duplicateGroups = [pair.group]

        let ok = await manager.mergeDuplicateGroup(pair.group)

        // The premise: this really is the permanent-delete path, not a quietly-refused merge.
        #expect(ok == true, "the merge did not complete, so the banner below is not the success one")
        #expect(FileManager.default.fileExists(atPath: pair.redundant.path) == false,
                "the redundant copy is still on disk — the permanent delete never happened")
        #expect(FileManager.default.fileExists(atPath: trashed.path) == false,
                "the copy reached the Trash after all, so nothing here is the unrecoverable case")
        #expect(FileManager.default.fileExists(atPath: pair.keeper.appendingPathComponent("unique.txt").path),
                "the unique file was not folded in, so there is no copy-undo to be dangerous")

        // THE INVARIANT: no undo offered for a merge that cannot be taken back.
        #expect(manager.banner?.message.contains("Merged") == true)
        #expect(manager.banner?.message.contains("⌘Z") != true,
                "the merge offered ⌘Z after destroying the copy permanently — taking it deletes the folded files from the keeper, and the originals are gone")
        #expect(manager.banner?.isUndoable != true)
    }

    /// **The banner is not the only surface that offers ⌘Z.** `undoable: !anyPermanentlyDeleted`
    /// suppresses the banner's button and nothing else; the registration a few lines above it ran
    /// unconditionally, so `undoManager.canUndo` was true and Edit ▸ Undo read "Undo Merge Keeper".
    /// Firing it deletes the folded files back out of the keeper while the original is
    /// permanently gone — the one duplicates path whose reversal DESTROYS data. Measured
    /// identically at dc865114 and 6fe2c8c7: `isUndoable=false`, `canUndo=true`,
    /// `undoActionName="Merge Keeper"`.
    ///
    /// Nothing in the suite observed the Edit-menu path, which is why the banner assertion above
    /// could pass with the hazard fully live. This asserts the registration itself, and then fires
    /// the undo to prove the folded file survives it.
    @MainActor
    @Test func aMergeWhoseCopyWasDestroyedPermanentlyRegistersNoUndoAtAll() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeUndoRegistration")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Redundant-\(UUID().uuidString)"
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(rName)")
        defer { try? FileManager.default.removeItem(at: trashed) }
        let pair = try makePair(base, redundantName: rName)
        let folded = pair.keeper.appendingPathComponent("unique.txt")

        let manager = FileSyncManager(fileManager: TrashlessVolume())
        let undo = UndoManager()
        manager.undoManager = undo
        manager.permanentDeleteConfirmer = { _ in true }
        manager.duplicateGroups = [pair.group]

        let ok = await manager.mergeDuplicateGroup(pair.group)

        #expect(ok == true, "the merge did not complete, so nothing here is the unrecoverable case")
        #expect(FileManager.default.fileExists(atPath: pair.redundant.path) == false,
                "the copy is still on disk — the permanent delete never happened")
        #expect(FileManager.default.fileExists(atPath: folded.path),
                "the unique file was not folded in, so there is no copy-undo to be dangerous")

        // THE INVARIANT: the Edit menu has nothing to offer for a merge that cannot be reversed.
        #expect(undo.canUndo == false,
                "Edit ▸ Undo still offers “\(undo.undoActionName)” for a merge whose original is unrecoverable")
        #expect(undo.undoActionName.contains("Merge") == false,
                "the undo stack still names the merge: “\(undo.undoActionName)”")

        // And pressing it destroys nothing.
        undo.undo()
        await waitUntil("any undo work drains") { manager.activeFileOperationsCount == 0 }
        #expect(FileManager.default.fileExists(atPath: folded.path),
                "Edit ▸ Undo deleted the folded file out of the keeper — its original is permanently gone, so that was the last instance")

        await Logger.shared.debug("merge-undo flush marker").value
        let line = Logger.shared.entries.last { $0.message.contains("deleted permanently rather than trashed") }?.message
        #expect(line?.contains("not undoable") != true,
                "the audit log still claims the merge is not undoable rather than saying the undo was withheld: “\(line ?? "nil")”")
        #expect(line?.contains("NOT registered") == true,
                "the audit log does not record what actually happened: “\(line ?? "nil")”")
    }

    /// A Trash-less volume for ONE named path only, so a single merge can produce both outcomes.
    private final class TrashlessForOne: FileManager, @unchecked Sendable {
        let refusedPath: String
        init(refusedPath: String) { self.refusedPath = refusedPath; super.init() }
        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            if url.path == refusedPath {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
            }
            try super.trashItem(at: url, resultingItemURL: resultingItemURL)
        }
    }

    /// The mixed case, and the reason the fix withholds the copy-undo rather than registering
    /// nothing: one copy reached the Trash and can still be put back in one step. That step is
    /// registered — it only restores — but it is NOT named after the merge, because an Edit menu
    /// reading "Undo Merge Keeper" would promise to reverse a merge that cannot be reversed.
    @MainActor
    @Test func aMixedMergeKeepsTheRestoreButNotTheMergeNamedUndo() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeUndoMixed")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let aName = "A-\(UUID().uuidString)"
        let bName = "B-\(UUID().uuidString)"
        let a = base.appendingPathComponent(aName)
        let b = base.appendingPathComponent(bName)
        let trashedA = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(aName)")
        defer { try? FileManager.default.removeItem(at: trashedA) }

        try write(keeper.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        for (url, fill, unique) in [(a, UInt8(0x61), "a-only.txt"), (b, UInt8(0x62), "b-only.txt")] {
            try write(url.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
            try write(url.appendingPathComponent(unique), bytes: 4000, fill: fill)
        }

        let manager = FileSyncManager(fileManager: TrashlessForOne(refusedPath: b.path))
        let undo = UndoManager()
        manager.undoManager = undo
        manager.permanentDeleteConfirmer = { _ in true }
        let k = DuplicateCopy(id: keeper.path, name: "Keeper", isDirectory: true, size: 4000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let ca = DuplicateCopy(id: a.path, name: aName, isDirectory: true, size: 8000, itemCount: 2,
                               modificationDate: nil, uniqueItemCount: 1, depth: 0, isRecommendedKeeper: false)
        let cb = DuplicateCopy(id: b.path, name: bName, isDirectory: true, size: 8000, itemCount: 2,
                               modificationDate: nil, uniqueItemCount: 1, depth: 0, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "Keeper",
                                   isDirectory: true, copies: [k, ca, cb], reclaimableBytes: 8000)
        manager.duplicateGroups = [group]

        _ = await manager.mergeDuplicateGroup(group)

        // The premise: A trashed, B destroyed.
        try #require(FileManager.default.fileExists(atPath: trashedA.path),
                     "A did not reach the Trash — this is not the mixed case")
        try #require(FileManager.default.fileExists(atPath: b.path) == false,
                     "B was not permanently deleted — this is not the mixed case")

        #expect(undo.canUndo == true, "the restore of the copy that DID reach the Trash was dropped")
        #expect(undo.undoActionName.contains("Merge") == false,
                "the undo step is still named after a merge that cannot be reversed: “\(undo.undoActionName)”")

        undo.undo()
        await waitUntil("the restore puts A back") { FileManager.default.fileExists(atPath: a.path) }
        await waitUntil("the undo drains") { manager.activeFileOperationsCount == 0 }
        for name in ["a-only.txt", "b-only.txt"] {
            #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent(name).path),
                    "the undo removed \(name) from the keeper — B's original is permanently gone")
        }
    }

    /// The other direction, and the reason it is here: without it, deleting the offer outright
    /// would pass. A merge that really did trash its copy still says so.
    @MainActor
    @Test func aMergeWhoseCopyReachedTheTrashStillPromisesUndo() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeUndoPromiseTrash")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Redundant-\(UUID().uuidString)"
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(rName)")
        defer { try? FileManager.default.removeItem(at: trashed) }
        let pair = try makePair(base, redundantName: rName)

        let manager = FileSyncManager(fileManager: FileManager.default)
        manager.undoManager = UndoManager()
        manager.duplicateGroups = [pair.group]

        let ok = await manager.mergeDuplicateGroup(pair.group)

        #expect(ok == true)
        #expect(FileManager.default.fileExists(atPath: pair.redundant.path) == false)
        #expect(manager.banner?.message.contains("⌘Z") == true,
                "a genuinely reversible merge stopped offering its undo")
        #expect(manager.banner?.isUndoable == true)
    }

    /// Parks the FIRST `attributesOfItem` of one exact path — the folded file's destination in
    /// the keeper, which nothing in the merge stats except its copy-undo identity walk — so the
    /// test can hold that walk provably unresolved while asking whether the merge already claims
    /// to be done. Bounded park, recorded timeout, per the `ParkGate`/`FirstStatGate` contract.
    private final class DestinationStatGate: FileManager, @unchecked Sendable {
        let targetPath: String
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // In a box rather than as stored vars: `FileManager` already conforms to `Sendable`, so
        // the compiler rejects mutable stored properties on a subclass outright.
        private let state = LockedBox((gated: false, timedOut: false))

        init(targetPath: String) {
            self.targetPath = targetPath
            super.init()
        }

        var releasedByTimeout: Bool { state.withLock { $0.timedOut } }

        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            if path == targetPath {
                let first = state.withLock { value -> Bool in
                    if value.gated { return false }
                    value.gated = true
                    return true
                }
                if first {
                    entered.signal()
                    if release.wait(timeout: .now() + 10) == .timedOut {
                        state.withLock { $0.timedOut = true }
                    }
                }
            }
            return try super.attributesOfItem(atPath: path)
        }
    }

    /// The dc865114 ordering claim — "the copy/sync call sites await [the identity walk], which
    /// keeps 'the operation returned' implying 'its undo is fully armed'" — was FALSE for the
    /// merge, its fourth caller: it discarded the returned task, so a merge could post
    /// "Press ⌘Z to undo" before the identities it promises to check existed. The guard itself
    /// held either way (the handler suspends in the resolver), but the determinism the drift
    /// tests are written against — tamper the moment the operation returns, then ⌘Z — did not.
    ///
    /// Held deterministically: the folded file's destination stat is parked, so the walk cannot
    /// resolve; a merge that reports done while it is parked is the defect.
    @MainActor
    @Test func aMergeDoesNotReportDoneBeforeItsCopyUndoIdentityIsRecorded() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeUndoArm")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Redundant-\(UUID().uuidString)"
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(rName)")
        defer { try? FileManager.default.removeItem(at: trashed) }
        let pair = try makePair(base, redundantName: rName)

        let gate = DestinationStatGate(targetPath: pair.keeper.appendingPathComponent("unique.txt").path)
        let manager = FileSyncManager(fileManager: gate)
        manager.undoManager = UndoManager()
        manager.duplicateGroups = [pair.group]

        let done = LockedBox(false)
        let mergeTask = Task { @MainActor () -> Bool in
            let ok = await manager.mergeDuplicateGroup(pair.group)
            done.withLock { $0 = true }
            return ok
        }

        await awaitSignal(gate.entered,
                          "the merge's identity walk never statted the folded file — the gate cannot have held it")
        // Give the merge every chance to (wrongly) finish while its walk is parked. On the fixed
        // code completion here is impossible — the merge awaits the walk — so this is a bounded
        // grace period, not a timing guess about the passing direction.
        var polls = 0
        while polls < 60, !done.withLock({ $0 }) {
            polls += 1
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(done.withLock { $0 } == false,
                "the merge reported done — and posted its ⌘Z banner — while an identity walk it registered was still unresolved")

        gate.release.signal()
        let ok = await mergeTask.value
        try #require(!gate.releasedByTimeout,
                     "the walk resumed by timeout, not by this test — the park was never actually held")
        #expect(ok == true, "once the walk resolves, the merge completes normally")
        #expect(manager.banner?.message.contains("⌘Z") == true)
    }
}
