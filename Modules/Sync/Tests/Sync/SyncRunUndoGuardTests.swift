import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// "Undo Last Run" scoping: the reversal fires only while the last recorded sync run is still the
/// top of the shared undo stack, refuses (naming what's there) when a non-sync action is on top,
/// and itemizes what it will reverse. Uses a synchronous `UndoManager` with marker targets so the
/// gate is tested without the async reversal.
@MainActor
@Suite struct SyncRunUndoGuardTests {

    /// A tiny undoable target: flips `undone` when its registered undo runs.
    private final class Marker { var undone = false }

    private func isolatedManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.syncHistoryStore = makeTempHistoryStore(prefix: "SyncRunUndoGuardTest")
        let um = UndoManager()
        um.groupsByEvent = false            // deterministic manual grouping + synchronous undo()
        manager.undoManager = um
        return manager
    }

    private func record(_ action: SyncAction = .move, run: UUID) -> SyncHistoryRecord {
        SyncHistoryRecord(runId: run, action: action, sourcePath: "/a/x.txt", destPath: "/b/x.txt")
    }

    /// Registers one named, grouped undo (as the op sites register a run) that flips the marker
    /// when reversed.
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
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let run = UUID()
        let marker = Marker()
        registerRun(manager, name: "Sync run", marker: marker)
        manager.recordSyncHistory([record(run: run)])       // captures top name = "Sync run"

        let preview = manager.lastSyncRunUndoPreview
        #expect(preview != nil)
        #expect(preview?.actionName == "Sync run")
        #expect(preview?.operationCount == 1)

        #expect(manager.undoLastSyncRunAskingFirst(confirm: { _ in true }) == nil)
        #expect(marker.undone == true)                       // the recorded run was reversed
        #expect(manager.lastSyncRunUndoPreview == nil)       // consumed — can't reverse it twice
    }

    @Test func manualUndoOfASameNamedRunClosesTheGate() {
        // Every bulk run registers under the same name ("Sync run"), so the name gate alone can't
        // tell two runs apart. After a manual ⌘Z reverses run B, run A's same-named group is on top:
        // a stale pairing would pass the gate while the preview described run B's records and
        // undo() reversed run A. The pairing must die with the manual undo.
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let markerA = Marker(), markerB = Marker()
        registerRun(manager, name: "Sync run", marker: markerA)
        manager.recordSyncHistory([record(run: UUID())])
        registerRun(manager, name: "Sync run", marker: markerB)
        let runB = UUID()
        manager.recordSyncHistory([record(run: runB), record(run: runB)])

        manager.undoManager!.undo()                          // manual ⌘Z — reverses run B
        #expect(markerB.undone == true)

        #expect(manager.lastSyncRunUndoPreview == nil)       // top is run A's group, not run B's
        let refusal = manager.undoLastSyncRunAskingFirst(confirm: { _ in true })
        #expect(markerA.undone == false)                     // run A must NOT be reversed
        // The top is named "Sync run", so "…is “Sync run”, not a sync run" would contradict
        // itself; a dead pairing reads as the history having changed.
        #expect(refusal == "The undo history changed since the last sync run — use Edit ▸ Undo (⌘Z) in the main window to step back.")
    }

    @Test func manualRedoAlsoClosesTheGate() {
        // ⇧⌘Z re-registers the run's group under a fresh registration the pairing knows nothing
        // about, so the gate stays closed after a redo, as after an undo.
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let marker = Marker()
        registerRun(manager, name: "Sync run", marker: marker)
        manager.recordSyncHistory([record(run: UUID())])

        manager.undoManager!.undo()
        manager.undoManager!.redo()
        #expect(manager.lastSyncRunUndoPreview == nil)
    }

    @Test func swappingTheUndoManagerDropsThePairing() {
        // A window reopen injects a new UndoManager: a pairing armed against the old stack must
        // not be validated against the new one's same-named groups.
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
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
        // An all-permanent delete records history but registers no undo (nothing reached the
        // Trash). Pairing those records with the current top would make "Undo Last Run" describe
        // the delete while reversing the unrelated action on top, so the previous run's pairing
        // must stay intact.
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let marker = Marker()
        registerRun(manager, name: "Copy 1 Item", marker: marker)
        let copyRun = UUID()
        manager.recordSyncHistory([record(.copy, run: copyRun)])

        manager.recordSyncHistory([record(.delete, run: UUID())], pairedWithUndo: false)

        let preview = manager.lastSyncRunUndoPreview
        #expect(preview?.actionName == "Copy 1 Item")
        #expect(preview?.records.first?.runId == copyRun)    // still the copy's records
        #expect(preview?.records.first?.action == .copy)     // never the delete's
    }

    @Test func allPermanentDeleteDoesNotHijackThePreviousRunsPairing() async throws {
        // End to end: copy a file (registers "Copy 1 Item"), then delete another on a volume where
        // trashing fails and the user confirms the permanent fallback. The delete's records must
        // not pair with the copy's undo group. The real op sites register through the manager's
        // own grouping, so this manager keeps the UndoManager's default event grouping.
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
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
        #expect(manager.lastSyncRunUndoPreview?.actionName == "Copy 1 Item")

        // Trash-less volume: trashing g.txt fails non-transiently; the user confirms.
        mockFM.trashErrorOnce = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        manager.permanentDeleteConfirmer = { _ in true }
        _ = await manager.deleteItems(at: ["/src/g.txt"], fileManager: mockFM)
        #expect(mockFM.virtualDisk["/src/g.txt"] == nil)     // permanently deleted

        // The gate still points at the copy: preview and reversal agree.
        let preview = manager.lastSyncRunUndoPreview
        #expect(preview?.actionName == "Copy 1 Item")
        #expect(preview?.records.allSatisfy { $0.action == .copy } == true)
    }

    @Test func mixedDeleteInvalidatesAStalePairingUnderACollidingName() async throws {
        // The delete undo's name follows the trashed count ("Move to Trash" for one), so two
        // deletes can push same-named groups: run 1 trashes one item (pairing armed), run 2 deletes
        // two of which only one reaches the Trash (mixed, not armed, but a new "Move to Trash"
        // group tops the stack). A stale run-1 pairing would pass the name gate, preview run 1's
        // paths and restore run 2's item, so a mixed delete must invalidate it outright.
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        manager.undoManager = UndoManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/src/b.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/src/c.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        manager.permanentDeleteConfirmer = { _ in true }

        _ = await manager.deleteItems(at: ["/src/a.txt"], fileManager: mockFM)
        #expect(manager.lastSyncRunUndoPreview?.actionName == "Move to Trash")   // run 1 armed
        #expect(manager.banner?.message == "Moved “a.txt” to the Trash")

        // Run 2: one of the two trashes, the other goes permanent; its group is "Move to Trash" too.
        mockFM.trashErrorOnce = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        _ = await manager.deleteItems(at: ["/src/b.txt", "/src/c.txt"], fileManager: mockFM)
        // Part of this batch is gone for good, so the banner may not say "to the Trash".
        #expect(manager.banner?.message == "Deleted 2 items")
        // Sync History tells the two apart from the record itself: the item that reached the Trash
        // reads "Move to Trash", the one deleted outright "Delete", and run 1's item "Move to Trash".
        let labels = manager.syncHistoryStore.records.map(\.actionLabel)
        #expect(labels.count == 3, "\(labels)")
        #expect(labels.first == "Move to Trash")
        #expect(labels.dropFirst().sorted() == ["Delete", "Move to Trash"])

        // The top is run 2's partial group; run 1's pairing must be dead, not matching the
        // colliding name.
        #expect(manager.lastSyncRunUndoPreview == nil)
    }

    // MARK: gate — negative (the bug this fixes)

    @Test func previewGoneAfterAManualUndoChangesTheTop() {
        // ⌘Z between the recorded run and the window button: the stack's top no longer matches,
        // so the button won't blindly reverse whatever is on top now.
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let marker = Marker()
        registerRun(manager, name: "Sync run", marker: marker)
        manager.recordSyncHistory([record(run: UUID())])
        manager.undoManager?.undo()                          // user reverses it manually
        #expect(manager.lastSyncRunUndoPreview == nil)       // canUndo is now false → no preview
    }

    // MARK: the Sync History window's entry point

    /// After a relaunch the undo stack is empty while Sync History still lists records. The
    /// asking entry point hands the reason back for the History window to show (a banner in the
    /// main window would make the click look dead), sets no banner, and never asks to confirm a
    /// run it can't reverse.
    @Test func historyClickWithNothingToUndoReturnsTheReasonAndLeavesTheBannerAlone() {
        let manager = isolatedManager()                      // a fresh stack: the relaunch case
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        var asked = 0

        let refusal = manager.undoLastSyncRunAskingFirst(confirm: { _ in asked += 1; return true })

        #expect(refusal == "There’s no recent sync run to undo — the undo history resets when SyncCloud restarts.")
        #expect(asked == 0)
        #expect(manager.banner == nil)
    }

    @Test func historyClickNamesTheActionOnTopAndReversesNothing() {
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let syncMarker = Marker()
        registerRun(manager, name: "Sync run", marker: syncMarker)
        manager.recordSyncHistory([record(run: UUID())])
        let folderMarker = Marker()
        registerRun(manager, name: "New Folder", marker: folderMarker)

        let refusal = manager.undoLastSyncRunAskingFirst(confirm: { _ in true })

        // "in the main window": ⌘Z pressed in Sync History acts on that window's own empty stack.
        #expect(refusal == "The most recent action is “New Folder”, not a sync run — use Edit ▸ Undo (⌘Z) in the main window to reverse it.")
        #expect(folderMarker.undone == false)
        #expect(syncMarker.undone == false)
        #expect(manager.banner == nil)
    }

    /// A refusal is logged: Sync History's alert leaves nothing behind, so the log line is the
    /// record. The action's name carries a UUID so no sibling case's refusal can satisfy the capture.
    @Test func historyClickRefusalIsLogged() async {
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let name = "Rename \(UUID().uuidString)"
        registerRun(manager, name: name, marker: Marker())
        let log = LogCapture()

        let refusal = manager.undoLastSyncRunAskingFirst(confirm: { _ in true })

        #expect(refusal != nil)
        #expect(await log.holds(.info, containing: "Undo Last Run refused: The most recent action is “\(name)”"),
                "a refused Undo Last Run left no line in the log")
    }

    @Test func historyClickWithAnUnnamedActionOnTopSendsTheUserToTheMainWindow() {
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        registerRun(manager, name: "", marker: Marker())

        let refusal = manager.undoLastSyncRunAskingFirst(confirm: { _ in true })

        #expect(refusal == "The most recent action isn’t a sync run — use Edit ▸ Undo (⌘Z) in the main window to reverse it.")
    }

    @Test func historyClickAsksAndReversesOnlyOnYes() {
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let marker = Marker()
        registerRun(manager, name: "Sync run", marker: marker)
        manager.recordSyncHistory([record(run: UUID())])
        #expect(manager.lastSyncRunUndoRefusal == nil)       // it would act, so there is no reason

        var askedAbout: String?
        #expect(manager.undoLastSyncRunAskingFirst(confirm: { askedAbout = $0.actionName; return false }) == nil)
        #expect(askedAbout == "Sync run")
        #expect(marker.undone == false)                      // declined: nothing reversed

        #expect(manager.undoLastSyncRunAskingFirst(confirm: { _ in true }) == nil)
        #expect(marker.undone == true)
        #expect(manager.lastSyncRunUndoPreview == nil)       // consumed
    }

    // MARK: a long run going (Banner Room, CF)

    /// Undo Last Run waits for a long run, and says which, without asking: the run on top stays
    /// put, and the reason is the running job's own lock sentence.
    @Test func historyClickDuringARunWaitsAndSaysWhy() {
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let marker = Marker()
        registerRun(manager, name: "Sync run", marker: marker)
        manager.recordSyncHistory([record(run: UUID())])
        let run = Progress(totalUnitCount: 10)
        run.runLockReason = Progress.runLockReason(waitingFor: "the merge")
        manager.activeProgress = run

        var asked = 0
        #expect(manager.undoLastSyncRunAskingFirst(confirm: { _ in asked += 1; return true })
                == "Wait for the merge to finish")
        #expect(asked == 0, "it asked to reverse a run while another was going")
        #expect(marker.undone == false)
        #expect(manager.lastSyncRunUndoRefusal == "Wait for the merge to finish")

        manager.activeProgress = nil
        #expect(manager.undoLastSyncRunAskingFirst(confirm: { _ in true }) == nil)
        #expect(marker.undone == true, "the run's end did not let the undo through")
    }

    /// A run that starts behind the confirmation stops the reversal the alert agreed to.
    @Test func aRunStartedBehindTheConfirmationStopsTheReversal() {
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let marker = Marker()
        registerRun(manager, name: "Sync run", marker: marker)
        manager.recordSyncHistory([record(run: UUID())])
        let refusal = manager.undoLastSyncRunAskingFirst(confirm: { _ in
            manager.activeProgress = Progress(totalUnitCount: 1)
            return true
        })
        #expect(refusal == Progress.genericRunLockReason)
        #expect(marker.undone == false)
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

    /// A delete run is a move to the Trash, and Undo Last Run says so: "2 moves to the Trash … Put
    /// back", not "deletes … restored".
    @Test func confirmationDetailPhrasesTrashMovesAsPutBack() {
        let run = UUID()
        let recs = ["old.txt", "older.txt"].map {
            SyncHistoryRecord(runId: run, action: .delete, sourcePath: "/a/\($0)", backupPath: "/Users/me/.Trash/\($0)")
        }
        let detail = SyncRunUndoPreview(actionName: "Move 2 Items to Trash", records: recs).confirmationDetail()
        #expect(detail == """
            This reverses 2 operations from the last run (2 moves to the Trash):
              •  Put back “old.txt” from the Trash
              •  Put back “older.txt” from the Trash

            Items moved to the Trash are put back. You can redo this afterward.
            """)
        let one = SyncRunUndoPreview(actionName: "Move to Trash", records: [recs[0]])
        #expect(one.actionSummary == "1 move to the Trash")
    }

    /// A card that made a folder and moved a file in says both, and that the folder goes only if
    /// empty.
    @Test func confirmationDetailSaysANewFolderGoesOnlyIfEmpty() {
        let run = UUID()
        let recs = [SyncHistoryRecord(runId: run, action: .newFolder, sourcePath: "/d/Japan 2026"),
                    SyncHistoryRecord(runId: run, action: .move, sourcePath: "/dl/JAL.pdf", destPath: "/d/Japan 2026/JAL.pdf")]
        let preview = SyncRunUndoPreview(actionName: "Put the Tickets in Japan 2026", records: recs)
        #expect(preview.actionSummary == "1 move, 1 new folder")
        let detail = preview.confirmationDetail()
        #expect(detail.contains("  •  Remove the folder “Japan 2026” if it’s empty"))
        #expect(detail.contains("Moved files go back to where they were; folders it made are removed if they’re empty."))
    }

    /// The closing note says what this run's undo does: a copy-only run's undo moves nothing back,
    /// it sends the copies to the Trash.
    @Test func confirmationDetailDescribesACopyRunsUndoAsTrashingTheCopies() {
        let run = UUID()
        let copy = SyncHistoryRecord(runId: run, action: .copy, sourcePath: "/a/new.txt", destPath: "/dest/dir/new.txt")
        let copyOnly = SyncRunUndoPreview(actionName: "Sync run", records: [copy]).confirmationDetail()
        let note = copyOnly.components(separatedBy: "\n").last ?? ""
        #expect(note == "The copies it made go to the Trash, and any file a copy replaced is put back. You can redo this afterward.")
        #expect(!copyOnly.contains("move back"))
        #expect(!copyOnly.contains("go back to where they were"))

        let move = SyncHistoryRecord(runId: run, action: .move, sourcePath: "/a/m.txt", destPath: "/dest/dir/m.txt")
        let delete = SyncHistoryRecord(runId: run, action: .delete, sourcePath: "/a/old.txt")
        let mixed = SyncRunUndoPreview(actionName: "Sync run", records: [delete, move, copy]).confirmationDetail()
        #expect(mixed.components(separatedBy: "\n").last == "The copies it made go to the Trash, and any file a copy replaced is put back; moved files go back to where they were; items moved to the Trash are put back. You can redo this afterward.")

        let moveOnly = SyncRunUndoPreview(actionName: "Sync run", records: [move]).confirmationDetail()
        #expect(moveOnly.components(separatedBy: "\n").last == "Moved files go back to where they were. You can redo this afterward.")
    }
}
