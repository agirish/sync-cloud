import Testing
import Foundation
@testable import Sync

/// Pins Finding 5 of the data-corruption review: the undo/redo blocks used to restore an
/// overwritten/deleted original from its Trash backup with a best-effort, silent `try?`. If the
/// backup was emptied or auto-purged between the operation and the undo, undo first trashes/removes
/// the CURRENT file and then silently failed to put the original back — leaving the destination
/// EMPTY with no log line and no user signal.
///
/// These tests simulate the vanished backup by deleting the trashed stub from `virtualDisk` before
/// the undo, and assert the failure is now SURFACED (a `.warning` banner) rather than swallowed.
/// The success cases assert we do NOT over-surface (no false warning when the restore works).
@Suite struct UndoRestoreFailureTests {

    /// A manager with every alert seam mocked so no test can ever pop a real NSAlert.
    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, false) }
        manager.permanentDeleteConfirmer = { _ in false }
        return manager
    }

    private func file(_ size: Int) -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: size], contents: nil)
    }

    // MARK: Move undo — overwritten original's Trash backup is gone

    /// A Move that replaced an existing file trashes the overwritten original. When that backup is
    /// emptied from the Trash before the undo, the undo moves the file back to its source (vacating
    /// the destination) and then cannot restore the overwritten original — the destination is left
    /// empty, so a warning banner is raised instead of silently swallowing the loss.
    @MainActor
    @Test func testMoveUndoSurfacesWarningWhenOverwrittenBackupIsGone() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)
        mockFM.virtualDisk["/dst/f.txt"] = file(5) // will be overwritten and trashed

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)

        // The move replaced /dst/f.txt (now the 100-byte source) and trashed the old 5-byte original.
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect(mockFM.virtualDisk["/src/f.txt"] == nil)
        let backupPath = try #require(mockFM.trashedPaths.first)
        #expect(mockFM.virtualDisk[backupPath] != nil)

        // Simulate the Trash being emptied / auto-purged before the undo.
        mockFM.virtualDisk.removeValue(forKey: backupPath)
        manager.banner = nil

        manager.undoManager?.undo()

        // The undo moves the file back to /src, then fails to restore the overwritten original into
        // /dst — the loss is surfaced as a warning banner, not silently swallowed.
        await waitUntil("move undo raises a warning when the overwritten backup is gone") {
            manager.banner?.severity == .warning
        }
        #expect(manager.banner?.message.contains("couldn't restore") == true)
        #expect(manager.banner?.message.contains("f.txt") == true)

        // The file returned to its source, but the destination is left empty (nothing to restore).
        await waitUntil("the moved file returns to its source") { mockFM.virtualDisk["/src/f.txt"] != nil }
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
    }

    /// The mirror of the above: when the overwritten backup is still in the Trash, the undo restores
    /// it cleanly and must NOT raise a warning banner (no over-surfacing).
    @MainActor
    @Test func testMoveUndoRaisesNoWarningWhenBackupIntact() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)
        mockFM.virtualDisk["/dst/f.txt"] = file(5)

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        manager.banner = nil

        manager.undoManager?.undo()

        // Undo moves the file home and restores the 5-byte original from its intact backup.
        await waitUntil("undo restores the overwritten original") {
            mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 5
        }
        #expect(mockFM.virtualDisk["/src/f.txt"] != nil)
        // A clean restore surfaces nothing to the user.
        #expect(manager.banner == nil)
    }

    // MARK: Delete undo (registerRestoreItems) — the trashed item is gone

    /// Undoing a Delete restores each item from its Trash location. When the Trash was emptied before
    /// the undo, the restore fails; that failure is surfaced as a warning banner rather than leaving
    /// the item silently unrestored.
    @MainActor
    @Test func testDeleteUndoSurfacesWarningWhenTrashedItemIsGone() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dst/f.txt"] = file(42)

        await manager.deleteItems(at: ["/dst/f.txt"], fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
        let backupPath = try #require(mockFM.trashedPaths.first)
        #expect(mockFM.virtualDisk[backupPath] != nil)

        // The Trash is emptied before the undo can pull the item back out of it.
        mockFM.virtualDisk.removeValue(forKey: backupPath)
        manager.banner = nil

        #expect(manager.undoManager?.canUndo == true)
        manager.undoManager?.undo()

        await waitUntil("delete undo raises a warning when the trashed item is gone") {
            manager.banner?.severity == .warning
        }
        #expect(manager.banner?.message.contains("couldn't restore") == true)
        // The item was NOT resurrected (there was nothing left in the Trash to restore).
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
    }

    /// The mirror: an intact Trash backup restores cleanly on undo and raises no warning banner.
    @MainActor
    @Test func testDeleteUndoRaisesNoWarningWhenTrashedItemIntact() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dst/f.txt"] = file(42)

        await manager.deleteItems(at: ["/dst/f.txt"], fileManager: mockFM)
        manager.banner = nil

        manager.undoManager?.undo()

        await waitUntil("delete undo restores the item from an intact Trash backup") {
            mockFM.virtualDisk["/dst/f.txt"] != nil
        }
        #expect(manager.banner == nil)
    }

    // MARK: Copy undo on a trash-less volume — the in-place backup is gone

    /// A Copy that replaced an existing file on a trash-less volume keeps the old file as a hidden
    /// in-place backup. Undoing the copy removes the copied file (after the permanent-delete
    /// confirmation) and restores the backup — but if that backup has since vanished, the undo
    /// removes the current file and cannot restore the original, so it raises a warning banner and
    /// leaves the destination empty.
    @MainActor
    @Test func testCopyUndoSurfacesWarningWhenInPlaceBackupIsGone() async throws {
        let manager = makeManager() // collisionResolver is .replace
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)
        mockFM.virtualDisk["/dst/f.txt"] = file(5)
        manager.permanentDeleteConfirmer = { _ in true }

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        let backupPath = try #require(mockFM.trashedPaths.first)

        // The volume loses Trash support (network share) AND the overwritten backup is purged before
        // the undo, so the undo must fall through to a permanent removeItem + a failing restore.
        mockFM.shouldFailTrash = true
        mockFM.virtualDisk.removeValue(forKey: backupPath)
        manager.banner = nil

        manager.undoManager?.undo()

        await waitUntil("copy undo raises a warning when the in-place backup is gone") {
            manager.banner?.severity == .warning
        }
        #expect(manager.banner?.message.contains("couldn't restore") == true)
        // The copy was removed and the original could not be restored — destination is empty.
        await waitUntil("the copied file was removed") { mockFM.virtualDisk["/dst/f.txt"] == nil }
    }

    /// On a trash-less volume, undoing a copy needs the permanent-delete confirmation to remove the
    /// copied file. If the user DECLINES, the undo aborts as a safe no-op: the copied file stays in
    /// place, nothing is removed or restored, and no failure is surfaced.
    @MainActor
    @Test func testCopyUndoDeclinedPermanentDeleteLeavesCopyInPlace() async throws {
        let manager = makeManager() // permanentDeleteConfirmer defaults to { _ in false } → declines
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)
        // No pre-existing /dst/f.txt: the copy creates it fresh, so there is no overwrite backup.

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)

        // Trash-less volume: undo's trashItem(copied file) fails → needs confirmation, which is declined.
        mockFM.shouldFailTrash = true
        manager.banner = nil

        // preCountFileOperation runs synchronously inside undo(), so the count is ≥1 on return;
        // wait for the undo's enqueued operation to drain back to 0.
        manager.undoManager?.undo()
        await waitUntil("the declined-confirm undo settles") { manager.activeFileOperationsCount == 0 }

        // The copied file was NOT removed and nothing was surfaced — a clean no-op.
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect(manager.banner == nil)
    }
}
