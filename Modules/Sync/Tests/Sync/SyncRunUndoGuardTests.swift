import Testing
import Foundation
import Events
@testable import Sync

/// Coverage for the X2 "Undo Last Run" scoping fix: the reversal must fire ONLY when the last
/// recorded sync run is still the top of the shared undo stack, must refuse (and name what's there)
/// when a non-sync action is on top, and must itemize what it will reverse. Uses a synchronous
/// `UndoManager` with marker targets so the gate is tested without depending on the async reversal.
@MainActor
@Suite struct SyncRunUndoGuardTests {

    /// A tiny undoable target: flips `undone` when its registered undo runs.
    private final class Marker { var undone = false }

    private func isolatedManager() -> FileSyncManager {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncRunUndoGuardTest-\(UUID().uuidString).jsonl")
        let manager = FileSyncManager()
        manager.syncHistoryStore = SyncHistoryStore(fileURL: url)
        let um = UndoManager()
        um.groupsByEvent = false            // deterministic manual grouping + synchronous undo()
        manager.undoManager = um
        return manager
    }

    private func record(_ action: SyncAction = .move, run: UUID) -> SyncHistoryRecord {
        SyncHistoryRecord(runId: run, action: action, sourcePath: "/a/x.txt", destPath: "/b/x.txt")
    }

    /// Registers one named, grouped undo (mirroring how the op sites register a run) that flips the
    /// marker when reversed.
    private func registerRun(_ manager: FileSyncManager, name: String, marker: Marker) {
        let um = manager.undoManager!
        um.beginUndoGrouping()
        um.setActionName(name)
        um.registerUndo(withTarget: marker) { $0.undone = true }
        um.endUndoGrouping()
    }

    // MARK: gate — positive

    @Test func previewPresentAndUndoFiresWhenRecordedRunIsOnTop() {
        let manager = isolatedManager()
        let run = UUID()
        let marker = Marker()
        registerRun(manager, name: "Sync run", marker: marker)
        manager.recordSyncHistory([record(run: run)])       // captures top name = "Sync run"

        let preview = manager.lastSyncRunUndoPreview
        #expect(preview != nil)
        #expect(preview?.actionName == "Sync run")
        #expect(preview?.operationCount == 1)

        manager.undoLastSyncRun()
        #expect(marker.undone == true)                       // the recorded run was reversed
        #expect(manager.banner?.severity != .warning)
        #expect(manager.lastSyncRunUndoPreview == nil)       // consumed — can't reverse it twice
    }

    @Test func manualUndoOfASameNamedRunClosesTheGate() {
        // Every bulk run registers under the same literal name ("Sync run"), so the name gate
        // alone can't tell two runs apart. After one manual ⌘Z reverses run B, run A's
        // identically-named group sits on top — the stale pairing would pass the gate while the
        // preview still describes run B's records and undo() would reverse run A. The pairing
        // must die with the manual undo instead.
        let manager = isolatedManager()
        let markerA = Marker(), markerB = Marker()
        registerRun(manager, name: "Sync run", marker: markerA)
        manager.recordSyncHistory([record(run: UUID())])
        registerRun(manager, name: "Sync run", marker: markerB)
        let runB = UUID()
        manager.recordSyncHistory([record(run: runB), record(run: runB)])

        manager.undoManager!.undo()                          // manual ⌘Z — reverses run B
        #expect(markerB.undone == true)

        #expect(manager.lastSyncRunUndoPreview == nil)       // top is run A's group, not run B's
        manager.undoLastSyncRun()
        #expect(markerA.undone == false)                     // run A must NOT be reversed
        #expect(manager.banner?.severity == .warning)
        // Honest refusal: the top IS named "Sync run", so the old "…is “Sync run”, not a sync
        // run" text contradicted itself. A dead pairing reads as history-changed instead.
        #expect(manager.banner?.message.contains("undo history changed") == true)
    }

    @Test func manualRedoAlsoClosesTheGate() {
        // ⇧⌘Z re-registers the run's group under a fresh registration the pairing knows
        // nothing about — the gate must stay closed after a redo, exactly as after an undo.
        let manager = isolatedManager()
        let marker = Marker()
        registerRun(manager, name: "Sync run", marker: marker)
        manager.recordSyncHistory([record(run: UUID())])

        manager.undoManager!.undo()
        manager.undoManager!.redo()
        #expect(manager.lastSyncRunUndoPreview == nil)
    }

    @Test func swappingTheUndoManagerDropsThePairing() {
        // A window reopen injects a NEW UndoManager: a pairing armed against the old stack
        // must not be validated against the new one's identically-named groups.
        let manager = isolatedManager()
        let marker = Marker()
        registerRun(manager, name: "Sync run", marker: marker)
        manager.recordSyncHistory([record(run: UUID())])
        #expect(manager.lastSyncRunUndoPreview != nil)

        let fresh = UndoManager()
        fresh.groupsByEvent = false
        manager.undoManager = fresh
        #expect(manager.lastSyncRunUndoPreview == nil)
    }

    @Test func historyWithoutAnUndoNeverRepointsTheGate() {
        // An all-permanent delete records durable history but registers no undo (nothing
        // reached the Trash). Pairing those records with the stack's current top would make
        // "Undo Last Run" describe the delete while reversing the unrelated action on top.
        // The unpaired record must leave the previous run's (still correct) pairing intact.
        let manager = isolatedManager()
        let marker = Marker()
        registerRun(manager, name: "Copy 1 Items", marker: marker)
        let copyRun = UUID()
        manager.recordSyncHistory([record(.copy, run: copyRun)])

        manager.recordSyncHistory([record(.delete, run: UUID())], pairedWithUndo: false)

        let preview = manager.lastSyncRunUndoPreview
        #expect(preview?.actionName == "Copy 1 Items")
        #expect(preview?.records.first?.runId == copyRun)    // still the copy's records
        #expect(preview?.records.first?.action == .copy)     // never the delete's
    }

    @Test func allPermanentDeleteDoesNotHijackThePreviousRunsPairing() async throws {
        // End-to-end shape of the funnel above: copy a file (registers "Copy 1 Items"), then
        // delete another file on a volume where trashing fails and the user confirms the
        // permanent fallback. The delete's records must not pair with the copy's undo group.
        // Unlike the gate tests, the real op sites register their undos through the manager's
        // own grouping — so this manager keeps the UndoManager's default event grouping.
        let manager = isolatedManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/src/g.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
        #expect(manager.lastSyncRunUndoPreview?.actionName == "Copy 1 Items")

        // Trash-less volume: trashing g.txt fails non-transiently; the user confirms.
        mockFM.trashErrorOnce = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        manager.permanentDeleteConfirmer = { _ in true }
        _ = await manager.deleteItems(at: ["/src/g.txt"], fileManager: mockFM)
        #expect(mockFM.virtualDisk["/src/g.txt"] == nil)     // permanently deleted

        // The gate still points at the copy — preview and reversal agree.
        let preview = manager.lastSyncRunUndoPreview
        #expect(preview?.actionName == "Copy 1 Items")
        #expect(preview?.records.allSatisfy { $0.action == .copy } == true)
    }

    @Test func mixedDeleteInvalidatesAStalePairingUnderACollidingName() async throws {
        // The delete undo's action name embeds the TRASHED count ("Delete 1 Items"), so two
        // consecutive deletes can push identically-named groups: run 1 deletes one item (all
        // trashed, pairing armed), run 2 deletes two items of which only one reaches the Trash
        // (mixed → not armed, but a NEW group named "Delete 1 Items" now tops the stack). The
        // stale run-1 pairing would pass the name gate and preview run 1's paths while undo()
        // restored run 2's item. A mixed delete must invalidate the stale pairing outright.
        let manager = isolatedManager()
        manager.undoManager = UndoManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/src/b.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/src/c.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        manager.permanentDeleteConfirmer = { _ in true }

        _ = await manager.deleteItems(at: ["/src/a.txt"], fileManager: mockFM)
        #expect(manager.lastSyncRunUndoPreview?.actionName == "Delete 1 Items")   // run 1 armed

        // Run 2: one of the two trashes, the other goes permanent → group also "Delete 1 Items".
        mockFM.trashErrorOnce = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        _ = await manager.deleteItems(at: ["/src/b.txt", "/src/c.txt"], fileManager: mockFM)

        // The stack top is run 2's partial group; run 1's pairing must be dead, not matching
        // the colliding name.
        #expect(manager.lastSyncRunUndoPreview == nil)
    }

    // MARK: gate — negative (the bug this fixes)

    @Test func refusesAndNamesTheActionWhenANonSyncActionIsOnTop() {
        let manager = isolatedManager()
        let syncMarker = Marker()
        registerRun(manager, name: "Sync run", marker: syncMarker)
        manager.recordSyncHistory([record(run: UUID())])

        // A New Folder (not recorded to history) is created AFTER the sync run — now on top.
        let folderMarker = Marker()
        registerRun(manager, name: "New Folder", marker: folderMarker)

        #expect(manager.lastSyncRunUndoPreview == nil)       // gate closed

        manager.undoLastSyncRun()
        #expect(folderMarker.undone == false)                // the New Folder was NOT reversed
        #expect(syncMarker.undone == false)                  // nor the sync run
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("New Folder") == true)
    }

    @Test func refusesWhenNothingIsUndoable() {
        let manager = isolatedManager()                      // fresh UndoManager, nothing recorded
        #expect(manager.lastSyncRunUndoPreview == nil)
        manager.undoLastSyncRun()
        #expect(manager.banner?.severity == .warning)
    }

    @Test func previewGoneAfterAManualUndoChangesTheTop() {
        // Simulates ⌘Z between the recorded run and pressing the window button: the stack's top no
        // longer matches, so the button won't blindly reverse whatever is now on top.
        let manager = isolatedManager()
        let marker = Marker()
        registerRun(manager, name: "Sync run", marker: marker)
        manager.recordSyncHistory([record(run: UUID())])
        manager.undoManager?.undo()                          // user reverses it manually
        #expect(manager.lastSyncRunUndoPreview == nil)       // canUndo is now false → no preview
    }

    // MARK: preview formatting (pure)

    @Test func actionSummaryCountsByActionOmittingZeroBuckets() {
        let run = UUID()
        let recs = [record(.copy, run: run), record(.copy, run: run), record(.move, run: run)]
        let preview = SyncRunUndoPreview(actionName: "Sync run", records: recs)
        #expect(preview.actionSummary == "2 copies, 1 move")
        #expect(preview.operationCount == 3)
    }

    @Test func confirmationDetailCapsTheListAndCountsTheRemainder() {
        let run = UUID()
        let recs = (0..<10).map {
            SyncHistoryRecord(runId: run, action: .copy, sourcePath: "/a/file\($0).txt", destPath: "/dest/dir/file\($0).txt")
        }
        let detail = SyncRunUndoPreview(actionName: "Sync run", records: recs).confirmationDetail(maxLines: 3)
        #expect(detail.hasPrefix("This reverses 10 operations from the last run (10 copies):"))
        #expect(detail.contains("file0.txt"))
        #expect(detail.contains("→ dir"))
        #expect(detail.contains("and 7 more"))
        #expect(detail.contains("You can redo this afterward."))
        // Only 3 file bullets shown (the rest folded into "… and 7 more").
        #expect(detail.components(separatedBy: "  •  ").count - 1 == 3)
    }

    @Test func confirmationDetailPhrasesDeletesAsRestoreFromTrash() {
        let run = UUID()
        let rec = SyncHistoryRecord(runId: run, action: .delete, sourcePath: "/a/old.txt")
        let detail = SyncRunUndoPreview(actionName: "Delete", records: [rec]).confirmationDetail()
        #expect(detail.hasPrefix("This reverses 1 operation from the last run (1 delete):"))
        #expect(detail.contains("Restore"))
        #expect(detail.contains("old.txt"))
        #expect(detail.contains("from the Trash"))
    }
}
