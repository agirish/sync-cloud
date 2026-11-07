import Testing
import Foundation
@testable import Sync

/// An undo that can't restore an overwritten or deleted original from its Trash backup (emptied
/// or purged since) has already removed the current file, leaving the destination empty, so the
/// failure must be surfaced as a `.warning` banner, not swallowed. The vanished backup is simulated
/// by deleting the trashed stub before the undo; the success cases check no false warning.
@Suite struct UndoRestoreFailureTests {

    /// A manager with every alert seam mocked so no test can ever pop a real NSAlert.
    @MainActor
    private func makeManager() -> FileSyncManager {
        FileSyncManager.forTests(collision: .replace, bulk: (.replace, false))
    }

    // MARK: Move undo — overwritten original's Trash backup is gone

    /// A Move that replaced a file trashed the original. With that backup emptied before the undo,
    /// the undo moves the file back to its source, can't restore the original, and leaves the
    /// destination empty, so it raises a warning banner.
    @MainActor
    @Test func testMoveUndoSurfacesWarningWhenOverwrittenBackupIsGone() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = .file(100)
        mockFM.virtualDisk["/dst/f.txt"] = .file(5) // will be overwritten and trashed

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

        // The undo moves the file back to /src, then fails to restore the original into /dst, and
        // says so in a warning banner.
        await waitUntil("move undo raises a warning when the overwritten backup is gone") {
            manager.banner?.severity == .warning
        }
        #expect(manager.banner?.message.contains("couldn’t restore") == true)
        #expect(manager.banner?.message.contains("f.txt") == true)

        // The file returned to its source, but the destination is left empty (nothing to restore).
        await waitUntil("the moved file returns to its source") { mockFM.virtualDisk["/src/f.txt"] != nil }
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
    }

    /// The mirror: with the backup still in the Trash, the undo restores it cleanly and raises no
    /// warning.
    @MainActor
    @Test func testMoveUndoRaisesNoWarningWhenBackupIntact() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = .file(100)
        mockFM.virtualDisk["/dst/f.txt"] = .file(5)

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

    /// Undoing a Delete restores each item from the Trash. When the Trash was emptied before the
    /// undo, the restore fails, and a warning banner says so.
    @MainActor
    @Test func testDeleteUndoSurfacesWarningWhenTrashedItemIsGone() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dst/f.txt"] = .file(42)

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
        #expect(manager.banner?.message.contains("couldn’t restore") == true)
        // Nothing came back: there was nothing left in the Trash to restore.
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
    }

    /// The mirror: an intact Trash backup restores cleanly on undo and raises no warning banner.
    @MainActor
    @Test func testDeleteUndoRaisesNoWarningWhenTrashedItemIntact() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dst/f.txt"] = .file(42)

        await manager.deleteItems(at: ["/dst/f.txt"], fileManager: mockFM)
        manager.banner = nil

        manager.undoManager?.undo()

        await waitUntil("delete undo restores the item from an intact Trash backup") {
            mockFM.virtualDisk["/dst/f.txt"] != nil
        }
        #expect(manager.banner == nil)
    }

    // MARK: Copy undo on a trash-less volume — the in-place backup is gone

    /// A Copy that replaced a file trashed the original. If the volume then loses Trash support
    /// and the backup vanishes, the undo removes the copy permanently (once confirmed), can't
    /// restore the original, raises a warning banner and leaves the destination empty.
    @MainActor
    @Test func testCopyUndoSurfacesWarningWhenInPlaceBackupIsGone() async throws {
        let manager = makeManager() // collisionResolver is .replace
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = .file(100)
        mockFM.virtualDisk["/dst/f.txt"] = .file(5)
        manager.permanentDeleteConfirmer = { _ in true }

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        let backupPath = try #require(mockFM.trashedPaths.first)

        // The volume loses Trash support (a network share) and the backup is purged before the
        // undo, so it falls through to a permanent removeItem and a failing restore.
        mockFM.shouldFailTrash = true
        mockFM.virtualDisk.removeValue(forKey: backupPath)
        manager.banner = nil

        manager.undoManager?.undo()

        await waitUntil("copy undo raises a warning when the in-place backup is gone") {
            manager.banner?.severity == .warning
        }
        #expect(manager.banner?.message.contains("couldn’t restore") == true)
        // The copy was removed and the original couldn't be restored: the destination is empty.
        await waitUntil("the copied file was removed") { mockFM.virtualDisk["/dst/f.txt"] == nil }
    }
}
