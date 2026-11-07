import Testing
import Foundation
@testable import Sync

/// Pins delete, refused undo, redo: when an undo's restore is refused because a different item now
/// occupies the path, that path stays off the redo's re-trash list, since the delete was never
/// undone there and redoing it would trash the occupant. As in `registerMoveUndo`, the redo list is
/// built after the restore loop from only the items that came back out of the Trash.
///
/// Each test deletes two items so the action is "Move 2 Items to Trash": `UndoRedoLogLabelTests`
/// pins the one-item label against the shared Logger, and a parallel one-item redo would trip it.
@Suite struct DeleteRedoOccupantTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        FileSyncManager.forTests()
    }

    @MainActor
    @Test func deleteUndoRefusedThenRedoLeavesOccupantAlone() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/docs"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/docs/report.pdf"] = .file(100)
        mockFM.virtualDisk["/docs/notes.txt"] = .file(50)

        // 1. User deletes both — they go to the (mock) Trash.
        let removed = await manager.deleteItems(at: ["/docs/report.pdf", "/docs/notes.txt"], fileManager: mockFM).removed
        #expect(removed == 2)
        #expect(mockFM.virtualDisk["/docs/report.pdf"] == nil)
        #expect(mockFM.virtualDisk["/docs/notes.txt"] == nil)
        let reportTrashPath = try #require(mockFM.trashedPaths.first(where: { $0.hasSuffix("report.pdf") }))
        #expect(mockFM.virtualDisk[reportTrashPath] != nil)

        // 2. A DIFFERENT file (size 555 — e.g. re-synced by a cloud daemon) appears at report.pdf's path.
        mockFM.virtualDisk["/docs/report.pdf"] = .file(555)
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

        // The real Trash uniquifies names ("report.pdf" → "report 12.34.56.pdf"), so a second
        // trash of one name succeeds. The mock's flat Trash would collide, so move the stub aside.
        let stub = mockFM.virtualDisk.removeValue(forKey: reportTrashPath)
        #expect(stub != nil)
        mockFM.virtualDisk["/mock-trash-uniquified/report.pdf"] = stub!
        let trashCountBeforeRedo = mockFM.trashedPaths.count

        // 4. Redo: report.pdf's delete was never undone (the original is still in the Trash), so
        //    the redo re-trashes only notes.txt and leaves the 555-byte occupant in place.
        manager.undoManager?.redo()
        await waitUntil("redo re-trashes the restored item") {
            mockFM.virtualDisk["/docs/notes.txt"] == nil
        }
        // Draining means the loop finished, so no sleep follows: `registerTrashItems`' handler
        // pre-counts the operation inside `redo()`, and `enqueueFileOperation` decrements only
        // after its body returns. A fixed sleep guarding an absence assertion would go vacuous
        // (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps").
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(mockFM.virtualDisk["/docs/report.pdf"] != nil,
                "redo after a refused undo must not trash the unrelated occupant")
        #expect(mockFM.virtualDisk["/docs/report.pdf"]?.attributes?[FileAttributeKey.size] as? Int == 555)
        #expect(mockFM.trashedPaths.count == trashCountBeforeRedo + 1) // notes.txt only
    }

    /// A redo trashes by identity, not by path. The restore succeeded, so the path is on the redo's
    /// list, which means "the undo put our item back here" until anything replaces it. The
    /// move-redo refuses the same shape. `notes.txt` is untouched and must still be re-trashed, so
    /// the guard can't become "never redo".
    @MainActor
    @Test func redoDoesNotTrashAnItemThatReplacedTheRestoredOne() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/docs"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/docs/report.pdf"] = .file(100)
        mockFM.virtualDisk["/docs/notes.txt"] = .file(50)

        let removed = await manager.deleteItems(at: ["/docs/report.pdf", "/docs/notes.txt"], fileManager: mockFM).removed
        #expect(removed == 2)

        // Undo restores both: nothing occupies either path, so both are on the redo's list.
        manager.undoManager?.undo()
        await waitUntil("undo restores both") {
            mockFM.virtualDisk["/docs/report.pdf"] != nil && mockFM.virtualDisk["/docs/notes.txt"] != nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.virtualDisk["/docs/report.pdf"]?.attributes?[FileAttributeKey.size] as? Int == 100)

        // A different file takes report.pdf's path: same name, not the restored item.
        mockFM.virtualDisk["/docs/report.pdf"] = .file(555)
        manager.banner = nil
        let trashCountBeforeRedo = mockFM.trashedPaths.count

        // Bounded by this test's own markers and matched on a path only this fixture uses:
        // `Logger.shared` is process-wide, and a window bounds time, not authorship.
        let tag = "redo-refusal-\(UUID().uuidString)"
        let lines = try await logLines(tag: tag) {
            manager.undoManager?.redo()
            await waitUntil("redo re-trashes the untouched item") {
                mockFM.virtualDisk["/docs/notes.txt"] == nil
            }
            await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        }

        #expect(mockFM.virtualDisk["/docs/report.pdf"]?.attributes?[FileAttributeKey.size] as? Int == 555,
                "the redo trashed a file that merely shares the restored item's path")
        #expect(mockFM.trashedPaths.count == trashCountBeforeRedo + 1,
                "exactly one item — notes.txt — was the redo's to trash")
        #expect(manager.banner?.severity == .warning,
                "a refused redo that leaves a file on disk has to say so")
        // The refusal is logged, not just performed: a silent one leaves a file on disk with no reason.
        #expect(lines.contains { $0.contains("REFUSED to trash") && $0.contains("/docs/report.pdf") },
                "the redo left a file on disk and the log did not say why")
    }

    /// The control: when the undo restored the items, redo re-trashes them, and the chain keeps
    /// working for a second undo.
    @MainActor
    @Test func deleteUndoRestoredThenRedoReTrashes() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/docs"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/docs/a.txt"] = .file(100)
        mockFM.virtualDisk["/docs/b.txt"] = .file(200)

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

        // A second undo restores them again from the new Trash locations.
        manager.undoManager?.undo()
        await waitUntil("second undo restores both items again") {
            mockFM.virtualDisk["/docs/a.txt"] != nil && mockFM.virtualDisk["/docs/b.txt"] != nil
        }
        await waitUntil("second undo op drains") { manager.activeFileOperationsCount == 0 }
    }
}
