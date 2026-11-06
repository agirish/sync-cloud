import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// Pins the direction labels on the delete undo/redo audit trail: undoing a delete
/// (`registerRestoreItems`) logs "User triggered Undo" and redoing it (`registerTrashItems`) logs
/// "User triggered Redo", and each summary agrees with its header. Swapped, the log would show the
/// user doing the opposite of what ran.
@Suite struct UndoRedoLogLabelTests {

    /// True when `log` captured an entry with exactly `message`. A capture, not the shared buffer,
    /// so the rest of the package logging past the line cannot take it away.
    @MainActor
    private func loggerContains(_ log: LogCapture, _ message: String) async -> Bool {
        await log.entries.contains { $0.message == message }
    }


    @MainActor
    @Test func testDeleteUndoAndRedoLogTheirOwnDirection() async throws {
        let log = LogCapture()
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.permanentDeleteConfirmer = { _ in false }
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dst/label_pin.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        await manager.deleteItems(at: ["/dst/label_pin.txt"], fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/label_pin.txt"] == nil)

        // ⌘Z restores the item from the Trash: the header says Undo, and the summary agrees.
        manager.undoManager?.undo()
        await waitUntil("undo restores the deleted item") { mockFM.virtualDisk["/dst/label_pin.txt"] != nil }
        #expect(await loggerContains(log, "User triggered Undo: Move to Trash"))
        #expect(await loggerContains(log, "Undo (Move to Trash): restored 1 of 1 deleted item(s) from Trash, 0 restore failure(s)"))
        // No delete redo has run yet, so no handler may have claimed the Redo label.
        #expect(!(await loggerContains(log, "User triggered Redo: Move to Trash")))

        // ⌘⇧Z re-trashes the item: the header says Redo, and the summary agrees.
        manager.undoManager?.redo()
        await waitUntil("redo re-trashes the item") { mockFM.virtualDisk["/dst/label_pin.txt"] == nil }
        #expect(await loggerContains(log, "User triggered Redo: Move to Trash"))
        #expect(await loggerContains(log, "Redo (Move to Trash): trashed 1 of 1 item(s)"))
    }
}
