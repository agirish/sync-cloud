import Testing
import Foundation
@testable import Sync

/// Pins the delete → refused undo → redo chain: when an undo's restore is REFUSED because a
/// different item now occupies the deleted item's path, that path must not be in the redo's
/// re-trash list — the delete was never actually undone there, so redoing it would trash the
/// unrelated occupant. Mirrors `registerMoveUndo`'s rule ("a refused item must never be in
/// redoParams"): the redo URL list is resolved AFTER the restore loop from only the items that
/// actually came back out of the Trash.
///
/// Both tests delete TWO items so the action name is "Delete 2 Items" — `UndoRedoLogLabelTests`
/// pins the "Delete 1 Items" labels against the shared Logger, and a parallel suite redoing a
/// one-item delete would trip its "no Redo logged yet" assertion.
@Suite struct DeleteRedoOccupantTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.permanentDeleteConfirmer = { _ in false }
        return manager
    }

    private func file(_ size: Int) -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: size], contents: nil)
    }

    @MainActor
    @Test func deleteUndoRefusedThenRedoLeavesOccupantAlone() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/docs"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/docs/report.pdf"] = file(100)
        mockFM.virtualDisk["/docs/notes.txt"] = file(50)

        // 1. User deletes both — they go to the (mock) Trash.
        let removed = await manager.deleteItems(at: ["/docs/report.pdf", "/docs/notes.txt"], fileManager: mockFM)
        #expect(removed == 2)
        #expect(mockFM.virtualDisk["/docs/report.pdf"] == nil)
        #expect(mockFM.virtualDisk["/docs/notes.txt"] == nil)
        let reportTrashPath = try #require(mockFM.trashedPaths.first(where: { $0.hasSuffix("report.pdf") }))
        #expect(mockFM.virtualDisk[reportTrashPath] != nil)

        // 2. A DIFFERENT file (size 555 — e.g. re-synced by a cloud daemon) appears at report.pdf's path.
        mockFM.virtualDisk["/docs/report.pdf"] = file(555)
        manager.banner = nil

        // 3. Undo — must refuse report.pdf (occupied) but restore notes.txt.
        manager.undoManager?.undo()
        await waitUntil("undo refuses the occupied restore") {
            manager.banner?.severity == .warning
        }
        await waitUntil("undo restores the unoccupied item") {
            mockFM.virtualDisk["/docs/notes.txt"] != nil
        }
        #expect(mockFM.virtualDisk["/docs/report.pdf"]?.attributes?[FileAttributeKey.size] as? Int == 555)
        #expect(mockFM.virtualDisk[reportTrashPath] != nil) // original still in Trash

        // Let the undo's enqueued file operation fully drain before redoing.
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        // The real macOS Trash uniquifies names ("report.pdf" → "report 12.34.56.pdf"), so a
        // second trash of the same name always succeeds. The mock's flat Trash dir would
        // spuriously collide with the original's stub — rename it aside to model reality.
        let stub = mockFM.virtualDisk.removeValue(forKey: reportTrashPath)
        #expect(stub != nil)
        mockFM.virtualDisk["/mock-trash-uniquified/report.pdf"] = stub!
        let trashCountBeforeRedo = mockFM.trashedPaths.count

        // 4. Redo — report.pdf's delete was never actually undone (the original is still in the
        //    Trash), so the redo must re-trash ONLY notes.txt and leave the unrelated 555-byte
        //    occupant in place.
        manager.undoManager?.redo()
        await waitUntil("redo re-trashes the restored item") {
            mockFM.virtualDisk["/docs/notes.txt"] == nil
        }
        // Draining IS "the loop finished", so no beat is needed after it: `registerTrashItems`'
        // handler runs synchronously inside `redo()` and pre-counts the operation before spawning
        // its Task, and `enqueueFileOperation` decrements only once its body has returned. A flat
        // 300ms used to follow this line — a guessed window guarding an absence assertion
        // (mechanism 2), which is the shape that goes vacuous rather than merely slow.
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(mockFM.virtualDisk["/docs/report.pdf"] != nil,
                "redo after a refused undo must not trash the unrelated occupant")
        #expect(mockFM.virtualDisk["/docs/report.pdf"]?.attributes?[FileAttributeKey.size] as? Int == 555)
        #expect(mockFM.trashedPaths.count == trashCountBeforeRedo + 1) // notes.txt only
    }

    /// The control case: when the undo DID restore the items, redo re-trashes them as before,
    /// and the chain keeps working for a second undo.
    @MainActor
    @Test func deleteUndoRestoredThenRedoReTrashes() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/docs"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/docs/a.txt"] = file(100)
        mockFM.virtualDisk["/docs/b.txt"] = file(200)

        await manager.deleteItems(at: ["/docs/a.txt", "/docs/b.txt"], fileManager: mockFM)
        #expect(mockFM.virtualDisk["/docs/a.txt"] == nil)
        #expect(mockFM.virtualDisk["/docs/b.txt"] == nil)

        manager.undoManager?.undo()
        await waitUntil("undo restores both items") {
            mockFM.virtualDisk["/docs/a.txt"] != nil && mockFM.virtualDisk["/docs/b.txt"] != nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        let trashCountBeforeRedo = mockFM.trashedPaths.count

        manager.undoManager?.redo()
        await waitUntil("redo re-trashes both restored items") {
            mockFM.virtualDisk["/docs/a.txt"] == nil && mockFM.virtualDisk["/docs/b.txt"] == nil
        }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.trashedPaths.count == trashCountBeforeRedo + 2)

        // And the chain keeps working: a second undo restores them again from the NEW trash locations.
        manager.undoManager?.undo()
        await waitUntil("second undo restores both items again") {
            mockFM.virtualDisk["/docs/a.txt"] != nil && mockFM.virtualDisk["/docs/b.txt"] != nil
        }
        await waitUntil("second undo op drains") { manager.activeFileOperationsCount == 0 }
    }
}
