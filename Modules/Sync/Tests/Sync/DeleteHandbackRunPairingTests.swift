import Testing
import Foundation
import Events
@testable import Sync

/// **`deleteItems(restoreUndoHandback:)` must not arm the "Undo Last Run" pairing.**
///
/// The pairing is a name gate: `recordSyncHistory` snapshots `undoManager.undoActionName` at the
/// moment the run finished registering its undo, and `lastSyncRunUndoPreview` later re-reads that
/// name to confirm the recorded run is still the top of the stack. Every other caller of
/// `deleteItems` has already registered its group by then, so the snapshot names ITS OWN step.
///
/// The handback caller has not. The whole point of the handback is that `deleteItems` stops
/// registering mid-await and lets the caller register the restore — synchronously, after this
/// method returns — so the group that will top the stack does not exist yet and the snapshot names
/// the caller's PREVIOUS action instead. The gate cannot tell two identically named steps apart
/// (`invalidateRunUndoPairing`'s own reason), and the merge names its step after the group it
/// folded, so merging "Photos" twice in a row produces exactly that collision: the second merge
/// pairs its delete-only records with the FIRST merge's still-topmost group, the name gate passes
/// against the second merge's group, and "Undo Last Run" itemizes a handful of deletes while
/// `undo()` reverses a whole merge — including the half that DELETES the folded files out of the
/// keeper.
///
/// Nothing in the repo constructed a handed-back delete before this suite, so the guard in
/// `deleteItems` (`handedBack` → invalidate, never pair) could be deleted outright with the full
/// 2613-test package still green. Both tests below are red without it.
@MainActor
@Suite struct DeleteHandbackRunPairingTests {

    /// A tiny undoable target, so a registered step is a real one.
    private final class Marker { var undone = false }

    private func isolatedManager() -> FileSyncManager {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DeleteHandbackRunPairing-\(UUID().uuidString).jsonl")
        let manager = FileSyncManager()
        manager.syncHistoryStore = SyncHistoryStore(fileURL: url)
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

    /// The shape without the merge around it: a step named "Merge Photos" is on top (the caller's
    /// previous action), and a handed-back delete runs. The pairing must be DEAD afterwards — the
    /// records this delete produced belong to a group nobody has registered yet.
    @Test func aHandedBackDeleteNeverPairsItsRecordsWithTheCallersPreviousStep() async throws {
        let manager = isolatedManager()
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

        // Premises: the delete really went down the handback path, all-trashed — the one case the
        // old condition (`successfullyTrashed.count != items.count`) does not cover.
        try #require(outcome.trashed == 1, "the fixture did not trash: \(outcome)")
        try #require(handedBack?.0.count == 1, "the handback was never called, so nothing below is about it")
        #expect(manager.undoManager?.undoActionName == "Merge Photos",
                "the caller has not registered its group yet — that is the premise of the handback")

        #expect(manager.lastSyncRunUndoPreview == nil,
                "the handed-back delete armed the run pairing against the caller's PREVIOUS step (“\(manager.lastSyncRunUndoPreview?.actionName ?? "nil")”) — “Undo Last Run” would itemize these deletes while undo() reverses that other action")
    }

    /// …and the delete's records still reach the durable store: the fix withholds the PAIRING, not
    /// the history. Without this, dropping the `recordSyncHistory` call entirely would pass above.
    @Test func aHandedBackDeleteStillRecordsItsHistory() async throws {
        let manager = isolatedManager()
        let fm = MockFileManager()
        try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        fm.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)

        _ = await manager.deleteItems(at: ["/src/a.txt"], fileManager: fm,
                                      restoreUndoHandback: { _, _ in })

        let recorded = manager.syncHistoryStore.records
        #expect(recorded.contains { $0.action == .delete && $0.sourcePath == "/src/a.txt" },
                "the handed-back delete recorded no durable history at all: \(recorded)")
    }

    // MARK: the scenario

    /// **Two merges of same-named groups, back to back** — the collision the name gate cannot see.
    ///
    /// Merge 1 leaves "Merge Keeper" on top. Merge 2's `deleteItems` runs while that is still the
    /// top (merge 2 registers its own group afterwards), so an armed pairing snapshots "Merge
    /// Keeper" — and merge 2's group is named "Merge Keeper" too, so the gate passes over the wrong
    /// group with only merge 2's `.delete` records to show for it.
    ///
    /// A real `FileManager`, for the reason `MergeUndoGroupingAndGateTests` documents: the merge
    /// hashes real bytes to plan, and only the `fileManager is FileManager` fast path yields the
    /// sizes it plans from.
    @Test func asecondMergeOfASameNamedGroupDoesNotInheritTheFirstMergesStep() async throws {
        let base = try makeCanonicalTempRoot(prefix: "TwoMerges")
        defer { try? FileManager.default.removeItem(at: base) }
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let names = ["RedOne-\(UUID().uuidString)", "RedTwo-\(UUID().uuidString)"]
        defer { for n in names { try? FileManager.default.removeItem(at: trash.appendingPathComponent(n)) } }

        // Two groups whose keepers share a NAME — "Keeper" — so both merges register a step called
        // "Merge Keeper". Distinct parents, so they are genuinely two groups.
        let one = try makeGroup(base.appendingPathComponent("one"), redundantName: names[0])
        let two = try makeGroup(base.appendingPathComponent("two"), redundantName: names[1])

        let manager = isolatedManager()             // groupsByEvent = false: the steps are the merges'
        manager.duplicateGroups = [one.group, two.group]

        try #require(await manager.mergeDuplicateGroup(one.group) == true, "the first merge failed")
        try #require(manager.undoManager?.undoActionName == "Merge Keeper",
                     "the first merge's step is not named as the second's will be, so the collision below cannot arise")

        try #require(await manager.mergeDuplicateGroup(two.group) == true, "the second merge failed")

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
        let copies = [
            DuplicateCopy(id: keeper.path, name: "Keeper", isDirectory: true, size: 4000, itemCount: 1,
                          modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true),
            DuplicateCopy(id: redundant.path, name: redundantName, isDirectory: true, size: 8000,
                          itemCount: 2, modificationDate: nil, uniqueItemCount: 1, depth: 0,
                          isRecommendedKeeper: false)
        ]
        return (keeper, redundant,
                DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "Keeper",
                               isDirectory: true, copies: copies, reclaimableBytes: 4000))
    }
}
