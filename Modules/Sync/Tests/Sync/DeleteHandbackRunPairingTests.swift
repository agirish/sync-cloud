import Testing
import Foundation
import Events
@testable import Sync

/// `deleteItems(restoreUndoHandback:)` must not arm the "Undo Last Run" pairing.
///
/// The pairing is a name gate: `recordSyncHistory` snapshots `undoManager.undoActionName` once the
/// run has registered its undo, and `lastSyncRunUndoPreview` re-reads it to confirm the run is
/// still on top. A handback caller registers its group only after `deleteItems` returns, so the
/// snapshot would name the caller's previous step. The gate can't tell same-named steps apart, and
/// a merge names its step after the group, so a second merge of "Photos" would pair its deletes
/// with the first merge's step: "Undo Last Run" would list a few deletes while `undo()` reverses a
/// whole merge, including deleting the folded files out of the keeper.
///
/// Removing the `handedBack` guard in `deleteItems` (invalidate, never pair) must fail the unit and the
/// scenario below.
@MainActor
@Suite struct DeleteHandbackRunPairingTests {

    /// A tiny undoable target, so a registered step is a real one.
    private final class Marker { var undone = false }

    private func isolatedManager(fileManager: FileManaging = FileManager.default) -> FileSyncManager {
        let manager = FileSyncManager(fileManager: fileManager)
        manager.syncHistoryStore = makeTempHistoryStore(prefix: "DeleteHandbackRunPairing")
        let um = UndoManager()
        um.groupsByEvent = false            // deterministic manual grouping
        manager.undoManager = um
        return manager
    }

    private func registerStep(_ manager: FileSyncManager, name: String, marker: Marker) {
        let um = manager.undoManager!
        um.beginUndoGrouping()
        um.setActionName(name)
        um.registerUndo(withTarget: marker) { $0.undone = true }
        um.endUndoGrouping()
    }

    // MARK: the unit

    /// Without the merge: a step named "Merge Photos" is on top (the caller's previous action) and a
    /// handed-back delete runs. The pairing must be dead afterwards, since this delete's records
    /// belong to a group not yet registered.
    @Test func aHandedBackDeleteNeverPairsItsRecordsWithTheCallersPreviousStep() async throws {
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let previous = Marker()
        registerStep(manager, name: "Merge Photos", marker: previous)

        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        fm.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)

        var handedBack: ([URL], [URL?])?
        let outcome = await manager.deleteItems(at: ["/src/a.txt"], fileManager: fm,
                                                restoreUndoHandback: { urls, backups in
            handedBack = (urls, backups)
        })

        // Premises: the delete went down the handback path with everything trashed, the case a
        // `successfullyTrashed.count != items.count` check would miss.
        try #require(outcome.trashed == 1, "the fixture did not trash: \(outcome)")
        try #require(handedBack?.0.count == 1, "the handback was never called, so nothing below is about it")
        #expect(manager.undoManager?.undoActionName == "Merge Photos",
                "the caller has not registered its group yet — that is the premise of the handback")

        #expect(manager.lastSyncRunUndoPreview == nil,
                "the handed-back delete armed the run pairing against the caller's PREVIOUS step (“\(manager.lastSyncRunUndoPreview?.actionName ?? "nil")”) — “Undo Last Run” would itemize these deletes while undo() reverses that other action")

        // …and the delete's records still reach the durable store: the guard withholds the pairing,
        // not the history. Dropping the `recordSyncHistory` call would pass the check above.
        let recorded = manager.syncHistoryStore.records
        #expect(recorded.contains { $0.action == .delete && $0.sourcePath == "/src/a.txt" },
                "the handed-back delete recorded no durable history at all: \(recorded)")
    }

    // MARK: the scenario

    /// Two merges of same-named groups back to back, the collision the name gate can't see. Merge
    /// 1 leaves "Merge Keeper" on top; merge 2's `deleteItems` runs before merge 2 registers its
    /// own, also "Merge Keeper", so an armed pairing would pass the gate over the wrong group.
    ///
    /// A real `FileManager`, as `MergeUndoGroupingAndGateTests` explains: the merge hashes real
    /// bytes to plan, and only the `fileManager is FileManager` path yields the sizes it plans from.
    @Test func asecondMergeOfASameNamedGroupDoesNotInheritTheFirstMergesStep() async throws {
        let base = try makeCanonicalTempRoot(prefix: "TwoMerges")
        defer { try? FileManager.default.removeItem(at: base) }
        let trash = ScratchTrash(in: base)
        let names = ["RedOne-\(UUID().uuidString)", "RedTwo-\(UUID().uuidString)"]

        // Two groups whose keepers are both named "Keeper", so both merges register "Merge Keeper".
        // Distinct parents, so they are two groups.
        let one = try makeGroup(base.appendingPathComponent("one"), redundantName: names[0])
        let two = try makeGroup(base.appendingPathComponent("two"), redundantName: names[1])

        let manager = isolatedManager(fileManager: trash)   // groupsByEvent = false: the steps are the merges'

        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        manager.duplicateGroups = [one.group, two.group]

        try #require(await manager.mergeDuplicateGroup(one.group) == true, "the first merge failed")
        try #require(manager.undoManager?.undoActionName == "Merge Keeper",
                     "the first merge's step is not named as the second's will be, so the collision below cannot arise")

        try #require(await manager.mergeDuplicateGroup(two.group) == true, "the second merge failed")
        #expect(trash.names == names, "the merges' redundant copies never reached the test's own Trash")

        #expect(manager.lastSyncRunUndoPreview == nil,
                "the second merge's deletes paired with the FIRST merge's step, and the name gate passed over the second merge's identically named group: “Undo Last Run” would offer \(manager.lastSyncRunUndoPreview?.operationCount ?? 0) delete(s) while undo() reverses a whole merge — restoring the copies AND deleting the folded files back out of the keeper")
    }

    /// The overlapping group the merge folds: a keeper holding one shared file, and one redundant
    /// copy holding that same file plus one of its own.
    private func makeGroup(_ base: URL, redundantName: String)
    throws -> (keeper: URL, redundant: URL, group: DuplicateGroup) {
        func write(_ url: URL, bytes: Int, fill: UInt8) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(repeating: fill, count: bytes).write(to: url)
        }
        let keeper = base.appendingPathComponent("Keeper")
        try write(keeper.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        let redundant = base.appendingPathComponent(redundantName)
        try write(redundant.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        try write(redundant.appendingPathComponent("unique.txt"), bytes: 4000, fill: 0x61)
        let copies: [DuplicateCopy] = [
            .stub(keeper.path, keeper: true, isDirectory: true, size: 4000),
            .stub(redundant.path, keeper: false, isDirectory: true, size: 8000, itemCount: 2, unique: 1),
        ]
        return (keeper, redundant, .stub(copies, matchType: .overlapping(sharedFraction: 0.5), reclaimable: 4000))
    }
}
