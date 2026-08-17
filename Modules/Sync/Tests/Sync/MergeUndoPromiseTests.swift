import Testing
import Foundation
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
}
