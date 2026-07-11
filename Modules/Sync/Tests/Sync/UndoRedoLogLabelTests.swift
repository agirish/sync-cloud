import Testing
import Foundation
import Events
@testable import Sync

/// Pins the direction labels on the delete undo/redo audit trail. The two registrars had them
/// swapped: undoing a delete (`registerRestoreItems`) logged "User triggered Redo" and redoing it
/// (`registerTrashItems`) logged "User triggered Undo" — so a forensic read of the log showed the
/// user doing the opposite of what actually ran. Each handler's header must match its direction,
/// and its trailing summary must agree with its header.
@Suite struct UndoRedoLogLabelTests {

    /// True when the shared Logger holds an entry with exactly `message`. Awaiting a fresh log
    /// task first guarantees everything enqueued before it is visible in `entries`.
    @MainActor
    private func loggerContains(_ message: String) async -> Bool {
        await Logger.shared.debug("label-pin flush marker").value
        return Logger.shared.entries.contains { $0.message == message }
    }

    /// Polls a main-actor condition until it holds or the timeout expires (recording a failure).
    @MainActor
    private func waitUntil(_ what: Comment, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition(), what)
    }

    @MainActor
    @Test func testDeleteUndoAndRedoLogTheirOwnDirection() async throws {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.permanentDeleteConfirmer = { _ in false }
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dst/label_pin.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        await manager.deleteItems(at: ["/dst/label_pin.txt"], fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/label_pin.txt"] == nil)

        // ⌘Z restores the item from the Trash — the header must say Undo, and the summary agrees.
        manager.undoManager?.undo()
        await waitUntil("undo restores the deleted item") { mockFM.virtualDisk["/dst/label_pin.txt"] != nil }
        #expect(await loggerContains("User triggered Undo: Delete 1 Items"))
        #expect(await loggerContains("Undo (Delete 1 Items): restored 1 of 1 deleted item(s) from Trash, 0 restore failure(s)"))
        // No delete redo has run yet, so no handler may have claimed the Redo label.
        #expect(!(await loggerContains("User triggered Redo: Delete 1 Items")))

        // ⌘⇧Z re-trashes the item — the header must say Redo, and the summary agrees.
        manager.undoManager?.redo()
        await waitUntil("redo re-trashes the item") { mockFM.virtualDisk["/dst/label_pin.txt"] == nil }
        #expect(await loggerContains("User triggered Redo: Delete 1 Items"))
        #expect(await loggerContains("Redo (Delete 1 Items): trashed 1 of 1 item(s)"))
    }
}
