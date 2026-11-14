import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// The merge path's half of `DeleteOutcome`'s promise. `DuplicateRemovalHonestyTests` pins the two
/// reclaim paths; the merge is the third caller, with a worse failure than a misdirected undo.
///
/// A merge copies the redundant copy's unique files into the keeper, registers a
/// `registerCopyUndo` for that fold, then trashes the copy. On a Trash-less volume (exFAT, most SMB
/// shares) the copy is destroyed permanently and registers no restore, but the copy-undo remains,
/// and undoing a copy deletes the copied item. "Press ⌘Z to undo" would then lead to removing the
/// folded files from the keeper with the originals already gone (behind a confirmation, but
/// prompted by the app).
///
/// A real `FileManager` subclass rather than the mock disk: the merge hashes real bytes to plan,
/// and only the `fileManager is FileManager` fast path yields the sizes it plans from.
@Suite struct MergeUndoPromiseTests {

    /// Builds the overlapping pair the merge folds: one shared file (skipped by the plan) and one
    /// unique file in the redundant copy (the fold, and so the copy-undo).
    private func makePair(_ base: URL, redundantName: String) throws -> (keeper: URL, redundant: URL, group: DuplicateGroup) {
        let keeper = base.appendingPathComponent("Keeper")
        let redundant = base.appendingPathComponent(redundantName)
        try writeBytes(keeper.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        try writeBytes(redundant.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        try writeBytes(redundant.appendingPathComponent("unique.txt"), bytes: 4000, fill: 0x55)
        let k = DuplicateCopy.stub(keeper.path, keeper: true, isDirectory: true, size: 4000)
        let r = DuplicateCopy.stub(redundant.path, keeper: false, isDirectory: true, size: 8000, itemCount: 2, unique: 1)
        return (keeper, redundant, .stub([k, r], matchType: .overlapping(sharedFraction: 0.5), reclaimable: 4000))
    }

    /// The copy leaves permanently and the merge still succeeds, but nothing may offer the undo:
    /// taking it would delete the only remaining copy of the folded files. Not the banner, and not
    /// the registration: `undoable: !anyPermanentlyDeleted` hides only the banner's button; if the
    /// registration still ran, Edit ▸ Undo would read "Undo Merge Keeper" and firing it would delete
    /// the folded files out of the keeper while the original is permanently gone. This asserts the
    /// banner and the registration, then fires the undo to prove the folded file survives.
    @MainActor
    @Test func aMergeWhoseCopyWasDestroyedPermanentlyRegistersNoUndoAtAll() async throws {
        let log = LogCapture()
        let base = try makeCanonicalTempRoot(prefix: "MergeUndoRegistration")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Redundant-\(UUID().uuidString)"
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(rName)")
        defer { try? FileManager.default.removeItem(at: trashed) }
        let pair = try makePair(base, redundantName: rName)
        let folded = pair.keeper.appendingPathComponent("unique.txt")

        let manager = FileSyncManager(fileManager: TrashRefusingVolume())
        let undo = UndoManager()
        manager.undoManager = undo
        manager.permanentDeleteConfirmer = { _ in true }   // the user confirms the permanent delete
        manager.duplicateGroups = [pair.group]

        let ok = await manager.mergeDuplicateGroup(pair.group)

        // The premise: this is the permanent-delete path, not a quietly refused merge.
        #expect(ok == true, "the merge did not complete, so nothing here is the unrecoverable case")
        #expect(FileManager.default.fileExists(atPath: pair.redundant.path) == false,
                "the copy is still on disk — the permanent delete never happened")
        #expect(FileManager.default.fileExists(atPath: trashed.path) == false,
                "the copy reached the Trash after all, so nothing here is the unrecoverable case")
        #expect(FileManager.default.fileExists(atPath: folded.path),
                "the unique file was not folded in, so there is no copy-undo to be dangerous")

        // No undo offered on the banner for a merge that can't be taken back…
        #expect(manager.banner?.message.contains("Merged") == true)
        #expect(manager.banner?.message.contains("⌘Z") != true,
                "the merge offered ⌘Z after destroying the copy permanently — taking it deletes the folded files from the keeper, and the originals are gone")
        #expect(manager.banner?.isUndoable != true)

        // The invariant: the Edit menu has nothing to offer for a merge that can't be reversed.
        #expect(undo.canUndo == false,
                "Edit ▸ Undo still offers “\(undo.undoActionName)” for a merge whose original is unrecoverable")
        #expect(undo.undoActionName.contains("Merge") == false,
                "the undo stack still names the merge: “\(undo.undoActionName)”")

        // And pressing it destroys nothing.
        undo.undo()
        await waitUntil("any undo work drains") { manager.activeFileOperationsCount == 0 }
        #expect(FileManager.default.fileExists(atPath: folded.path),
                "Edit ▸ Undo deleted the folded file out of the keeper — its original is permanently gone, so that was the last instance")

        let line = await log.entries.last { $0.message.contains("deleted permanently rather than trashed") }?.message
        #expect(line?.contains("not undoable") != true,
                "the audit log still claims the merge is not undoable rather than saying the undo was withheld: “\(line ?? "nil")”")
        #expect(line?.contains("NOT registered") == true,
                "the audit log does not record what actually happened: “\(line ?? "nil")”")
    }

    /// A declined permanent delete is the user's choice and is named as one. `deleteItems` posts an
    /// accurate banner ("Kept that item — it can't be moved to the Trash, and you chose not to
    /// delete it permanently"), and the merge's tail must not overwrite it with "some copies were
    /// left in place. Review and retry.": everything was folded, and nothing was left by accident.
    @MainActor
    @Test func aDeclinedPermanentDeleteIsNamedRatherThanOverwritten() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeDeclined")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Redundant-\(UUID().uuidString)"
        let pair = try makePair(base, redundantName: rName)

        let manager = FileSyncManager(fileManager: TrashRefusingVolume())
        manager.undoManager = UndoManager()
        manager.permanentDeleteConfirmer = { _ in false }   // the user declines
        manager.duplicateGroups = [pair.group]

        let ok = await manager.mergeDuplicateGroup(pair.group)

        #expect(ok == false, "the merge claimed success over a copy that is still on disk")
        #expect(FileManager.default.fileExists(atPath: pair.redundant.path),
                "the decline destroyed the copy anyway")
        #expect(FileManager.default.fileExists(atPath: pair.keeper.appendingPathComponent("unique.txt").path),
                "the fold did not happen, so this is not the case under test")

        let message = manager.banner?.message ?? ""
        #expect(message.contains("Review and retry") == false,
                "the decline was reported as an accident to review: “\(message)”")
        #expect(message.contains("chose not to delete"),
                "no banner names the decline: “\(message)”")
        #expect(message.contains("folded 1 file"),
                "the banner does not say the fold succeeded: “\(message)”")
    }

    /// A Trash-less volume for one named path only, so a single merge can produce both outcomes.
    private final class TrashlessForOne: FileManager, @unchecked Sendable {
        let refusedPath: String
        let trash: ScratchTrash
        init(refusedPath: String, trash: ScratchTrash) {
            self.refusedPath = refusedPath
            self.trash = trash
            super.init()
        }
        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            if url.path == refusedPath {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
            }
            try trash.trashItem(at: url, resultingItemURL: resultingItemURL)
        }
    }

    /// The mixed case, and why the copy-undo is withheld rather than registering nothing: one copy
    /// reached the Trash and can still be put back in one step. That step is registered (it only
    /// restores) but isn't named after the merge, since "Undo Merge Keeper" would promise to
    /// reverse a merge that can't be reversed.
    @MainActor
    @Test func aMixedMergeKeepsTheRestoreButNotTheMergeNamedUndo() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeUndoMixed")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let aName = "A-\(UUID().uuidString)"
        let bName = "B-\(UUID().uuidString)"
        let a = base.appendingPathComponent(aName)
        let b = base.appendingPathComponent(bName)
        try writeBytes(keeper.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        for (url, fill, unique) in [(a, UInt8(0x61), "a-only.txt"), (b, UInt8(0x62), "b-only.txt")] {
            try writeBytes(url.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
            try writeBytes(url.appendingPathComponent(unique), bytes: 4000, fill: fill)
        }

        let trash = ScratchTrash(in: base)
        let manager = FileSyncManager(fileManager: TrashlessForOne(refusedPath: b.path, trash: trash))
        let undo = UndoManager()
        manager.undoManager = undo
        manager.permanentDeleteConfirmer = { _ in true }
        let group = DuplicateGroup.stub(
            [.stub(keeper.path, keeper: true, isDirectory: true, size: 4000),
             .stub(a.path, keeper: false, isDirectory: true, size: 8000, itemCount: 2, unique: 1),
             .stub(b.path, keeper: false, isDirectory: true, size: 8000, itemCount: 2, unique: 1)],
            matchType: .overlapping(sharedFraction: 0.5), reclaimable: 8000)
        manager.duplicateGroups = [group]

        _ = await manager.mergeDuplicateGroup(group)

        // The premise: A trashed, B destroyed.
        try #require(trash.names == [aName],
                     "A did not reach the Trash — this is not the mixed case: \(trash.names)")
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

    /// Parks the first `attributesOfItem` of one exact path, the folded file's destination in the
    /// keeper, which only the merge's copy-undo identity walk stats. The test can then hold that
    /// walk unresolved while asking whether the merge already claims to be done. Bounded park,
    /// recorded timeout, per the `ParkGate`/`FirstStatGate` contract.
    private final class DestinationStatGate: FileManager, @unchecked Sendable {
        let targetPath: String
        let trash: ScratchTrash
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // In a box rather than stored vars: `FileManager` already conforms to `Sendable`, so the
        // compiler rejects mutable stored properties on a subclass.
        private let state = LockedBox((gated: false, timedOut: false))

        init(targetPath: String, trash: ScratchTrash) {
            self.targetPath = targetPath
            self.trash = trash
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
                    // Turns as well as seconds, as in `FirstStatGate`: the release waits on a
                    // 600 ms grace loop of main-actor sleeps.
                    if !release.wait(until: TurnDeadline(seconds: 10, turns: parkTurnFloor)) {
                        state.withLock { $0.timedOut = true }
                    }
                }
            }
            return try super.attributesOfItem(atPath: path)
        }

        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try trash.trashItem(at: url, resultingItemURL: resultingItemURL)
        }
    }

    /// A merge must await its copy-undo identity walk before reporting done, so "the operation
    /// returned" implies "its undo is fully armed". Discarding the returned task would let a merge
    /// post "Press ⌘Z to undo" before the identities it promises to check exist. The guard holds
    /// either way (the handler suspends in the resolver), but the drift tests rely on tampering the
    /// moment the operation returns.
    ///
    /// The folded file's destination stat is parked, so the walk can't resolve; a merge that
    /// reports done while it is parked fails.
    @MainActor
    @Test(.parksAThread) func aMergeDoesNotReportDoneBeforeItsCopyUndoIdentityIsRecorded() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeUndoArm")
        defer { try? FileManager.default.removeItem(at: base) }
        let rName = "Redundant-\(UUID().uuidString)"
        let pair = try makePair(base, redundantName: rName)

        let gate = DestinationStatGate(targetPath: pair.keeper.appendingPathComponent("unique.txt").path,
                                       trash: ScratchTrash(in: base))
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
        // Give the merge every chance to finish wrongly while its walk is parked. Correct code
        // can't complete here (it awaits the walk), so this is a bounded grace period, not a
        // timing guess about the passing direction.
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
        #expect(manager.banner?.isUndoable == true)
        #expect(gate.trash.names == [rName], "the redundant copy never reached the test's own Trash")
    }
}

/// The other half of the merge's ⌘Z promise: a merge with nothing to register.
///
/// A merge that folds nothing and trashes nothing registers no copy-undo and no restore, so
/// `anyPermanentlyDeleted` is false, yet a ⌘Z offer would point at whatever the user did before the
/// merge. Two real ways to reach it:
/// - Every redundant copy has already left the disk (an external delete, or a retry after a
///   partial merge). `guard fm.fileExists(atPath: redundant.path) else { continue }` skips each,
///   and skipping isn't failing, so the merge succeeds.
/// - The group has no redundant copy. `DuplicateGroup.redundantCopies` excludes the keeper and the
///   fallback keeper, so a one-copy group yields an empty list. `mergeDuplicateGroup` is `public`
///   and `DuplicateGroup`'s initializer validates nothing, so the group's contents belong to the
///   caller (as `applyRecommendedDuplicates` reasons for its empty-batch banner).
@Suite struct MergeEmptyUndoPromiseTests {

    private func copy(_ url: URL, keeper: Bool, unique: Int) -> DuplicateCopy {
        .stub(url.path, keeper: keeper, isDirectory: true, size: 4000, unique: unique)
    }

    /// A previous step the merge must not offer to reverse. Registered directly so the assertion is
    /// about what is on top of the stack: an empty stack would let `canUndo == false` pass and hide
    /// the misdirection.
    @MainActor
    private func registerPriorStep(_ manager: FileSyncManager) -> UndoManager {
        let undo = UndoManager()
        manager.undoManager = undo
        undo.registerUndo(withTarget: manager) { _ in }
        undo.setActionName("Something Else")
        return undo
    }

    @MainActor
    @Test func aMergeWhoseCopiesHaveAllVanishedDoesNotPromiseAnUndoItNeverRegistered() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeVanished")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        try writeBytes(keeper.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        // Listed in the group, never created on disk.
        let vanished = base.appendingPathComponent("Redundant")

        let manager = FileSyncManager()
        let undo = registerPriorStep(manager)
        let group = DuplicateGroup.stub([copy(keeper, keeper: true, unique: 0), copy(vanished, keeper: false, unique: 1)],
                                        matchType: .overlapping(sharedFraction: 0.5))

        let ok = await manager.mergeDuplicateGroup(group)
        #expect(ok, "skipping a copy that is already gone is not a failure")
        let banner = try #require(manager.banner)
        #expect(!banner.isUndoable,
                "the banner offered ⌘Z for a merge that registered nothing: \(banner.message)")
        #expect(!banner.message.contains("⌘Z"),
                "the banner's prose offered ⌘Z for a merge that registered nothing: \(banner.message)")
        #expect(undo.undoActionName == "Something Else",
                "the merge registered nothing, so ⌘Z still points at the step before it")
    }

    @MainActor
    @Test func aMergeOfAGroupWithNoRedundantCopyDoesNotPromiseAnUndo() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeNoRedundant")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        try writeBytes(keeper.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)

        let manager = FileSyncManager()
        let undo = registerPriorStep(manager)
        // One copy, so `redundantCopies` is empty and the fold loop never runs.
        let group = DuplicateGroup.stub([copy(keeper, keeper: true, unique: 0)], matchType: .overlapping(sharedFraction: 1.0))

        _ = await manager.mergeDuplicateGroup(group)
        let banner = try #require(manager.banner)
        #expect(!banner.isUndoable,
                "the banner offered ⌘Z for a merge that registered nothing: \(banner.message)")
        #expect(undo.undoActionName == "Something Else",
                "the merge registered nothing, so ⌘Z still points at the step before it")
    }
}
