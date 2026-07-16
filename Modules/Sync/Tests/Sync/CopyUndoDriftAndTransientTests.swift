import Testing
import Foundation
@testable import Sync

/// Pins the two copy-undo gaps closed in round 4:
///
/// 1. **Drift guard** — `registerCopyUndo` snapshots each copied item's byte size at
///    registration; the undo REFUSES to trash a destination whose current size differs (it is
///    no longer the copied item — replaced or edited since), matching the "still the same
///    item?" guards the move- and delete-undos already carry. A refused item stays out of the
///    redo params.
/// 2. **Transient trash failures** — a busy/locked destination (EBUSY et al.) is reported as
///    retryable instead of escalating to the permanent-delete prompt, the same
///    `isTransientTrashFailure` distinction `deleteItems` applies. `registerCreateFolderUndo`
///    gets the identical treatment.
@Suite struct CopyUndoDriftAndTransientTests {

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

    private static func transientBusyError() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
    }

    // MARK: Drift guard

    /// The copied file was replaced by a different-size item before the undo: the undo must
    /// refuse to trash it (warning banner), leave it on disk, keep its overwritten backup in
    /// the Trash, and keep it out of the redo params (redo is a no-op for it).
    @MainActor
    @Test func copyUndoRefusesWhenDestinationSizeDrifted() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)
        mockFM.virtualDisk["/dst/f.txt"] = file(5) // will be overwritten (collision .replace) and trashed

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        let backupPath = try #require(mockFM.trashedPaths.first)
        #expect(mockFM.virtualDisk[backupPath] != nil)

        // A different item (size 777) takes the copy's place before the undo.
        mockFM.virtualDisk["/dst/f.txt"] = file(777)
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("copy undo refuses the drifted destination") {
            manager.banner?.severity == .warning
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(manager.banner?.message.contains("changed since the copy") == true)
        // The drifted item is untouched, and the 5-byte backup was NOT restored over it.
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 777)
        #expect(mockFM.virtualDisk[backupPath] != nil)

        // Redo must skip the refused item: nothing is re-copied over the drifted survivor.
        manager.banner = nil
        manager.undoManager?.redo()
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 777)
    }

    /// Control: an unchanged copy still undoes cleanly — trashed, backup restored, no banner.
    @MainActor
    @Test func copyUndoStillRemovesUnchangedCopy() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)
        mockFM.virtualDisk["/dst/f.txt"] = file(5)

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("undo restores the overwritten original") {
            mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 5
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(manager.banner == nil)
    }

    // MARK: Transient trash failures

    /// A transiently busy copy (EBUSY on trash) must NOT reach the permanent-delete prompt:
    /// the item stays on disk for a retry and a warning banner is raised.
    @MainActor
    @Test func copyUndoTransientTrashFailureNeverPromptsPermanentDelete() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)

        // The permanent-delete prompt must never fire for a transient failure — even one that
        // would answer "yes". Installed BEFORE the copy so the undo registration captures it.
        var promptFired = false
        manager.permanentDeleteConfirmer = { _ in
            promptFired = true
            return true
        }

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)

        mockFM.trashErrorOnce = Self.transientBusyError()
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("transient trash failure surfaces a warning") {
            manager.banner?.severity == .warning
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(manager.banner?.message.contains("looks busy") == true)
        // The copy survives on disk — not trashed, not permanently removed. (safeCopyItem's
        // .tmp_ staging cleanup shows up in attemptedRemovePaths; only the real file matters.)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
        #expect(!mockFM.attemptedRemovePaths.contains("/dst/f.txt"))
        #expect(promptFired == false)
    }

    /// A genuinely Trash-less volume (ENOTSUP) still escalates to the confirmation, preserving
    /// the pre-existing permanent-delete fallback for real Trash-less volumes.
    @MainActor
    @Test func copyUndoNonTransientTrashFailureStillEscalates() async throws {
        let manager = makeManager() // confirmer declines
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)

        mockFM.shouldFailTrash = true // ENOTSUP — non-transient
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("the declined-confirm undo settles") { manager.activeFileOperationsCount == 0 }
        // Declined permanent delete: the copy stays, exactly as before this change.
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
    }

    // MARK: Create-folder undo

    /// Undoing New Folder with a transiently busy folder must not offer the permanent-delete
    /// prompt either — the folder stays for a retry, with a warning banner.
    @MainActor
    @Test func createFolderUndoTransientTrashFailureNeverPromptsPermanentDelete() async throws {
        let manager = makeManager()
        var promptFired = false
        manager.permanentDeleteConfirmer = { _ in
            promptFired = true
            return true
        }
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/New Folder"), withIntermediateDirectories: true)

        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/dst/New Folder"), fileManager: mockFM)

        mockFM.trashErrorOnce = Self.transientBusyError()
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("transient folder-trash failure surfaces a warning") {
            manager.banner?.severity == .warning
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        // The folder survives — not trashed, not permanently removed, no prompt.
        #expect(mockFM.virtualDisk["/dst/New Folder"] != nil)
        #expect(mockFM.attemptedRemovePaths.isEmpty)
        #expect(promptFired == false)
    }

    /// Control: a trash-less volume (ENOTSUP) still prompts, and a confirmed prompt removes the
    /// folder permanently — the pre-existing fallback.
    @MainActor
    @Test func createFolderUndoNonTransientFailureStillPromptsAndRemoves() async throws {
        let manager = makeManager()
        var promptFired = false
        manager.permanentDeleteConfirmer = { _ in
            promptFired = true
            return true
        }
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/New Folder"), withIntermediateDirectories: true)

        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/dst/New Folder"), fileManager: mockFM)

        mockFM.shouldFailTrash = true // ENOTSUP — non-transient

        manager.undoManager?.undo()
        await waitUntil("the confirmed permanent delete removes the folder") {
            mockFM.virtualDisk["/dst/New Folder"] == nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(promptFired == true)
    }
}
