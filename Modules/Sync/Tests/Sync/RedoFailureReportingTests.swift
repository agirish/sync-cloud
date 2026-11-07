import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// The redo and cleanup failure paths in FileSyncManager+Undo: copy, move and folder redo, and the
/// copy undo's confirmed permanent delete. Each failure (a source vanishing between undo and redo,
/// or a file squatting on a folder's path) must be surfaced with an `.error` log and a `.warning`
/// banner, and the failed item must stay out of the next undo state, so that undo is a quiet no-op
/// rather than a phantom operation, such as a "permanently delete?" prompt for a missing file.
@Suite struct RedoFailureReportingTests {

    /// True when `log` captured an `.error` entry containing `fragment`. A capture, not the shared
    /// buffer, so the rest of the package logging past the line can't take it away.
    @MainActor
    private func loggerHasError(_ log: LogCapture, containing fragment: String) async -> Bool {
        await log.holds(.error, containing: fragment)
    }

    /// A manager with every alert seam mocked, so no test can pop a real NSAlert.
    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, false) }
        manager.permanentDeleteConfirmer = { _ in false }
        return manager
    }

    /// Records whether the permanent-delete confirmation was requested. Runs on the main actor
    /// (the confirmer seam is @MainActor), so plain state is race-free with the polling tests.
    @MainActor
    private final class ConfirmerSpy {
        private(set) var called = false
        func confirm(_ answer: Bool) -> @MainActor ([String]) -> Bool {
            { [weak self] _ in
                self?.called = true
                return answer
            }
        }
    }

    /// A mock disk with `/src/f.txt` (100 bytes) and an empty `/dst`.
    private func disk() throws -> MockFileManager {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)
        return mockFM
    }

    private func file(_ size: Int) -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: size], contents: nil)
    }

    // MARK: Copy redo — the source vanished between undo and redo

    /// Undo of a copy trashes the destination; with the source then deleted externally, the redo's
    /// re-copy fails. The failure is surfaced, and the next undo must not try to trash the
    /// never-recreated destination and prompt to "permanently delete" a phantom file.
    @MainActor
    @Test func testCopyRedoFailureIsSurfacedAndNextUndoIsNoOp() async throws {
        let log = LogCapture()
        let manager = makeManager()
        let mockFM = try disk()

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)

        manager.undoManager?.undo()
        await waitUntil("undo trashes the copied file") { mockFM.virtualDisk["/dst/f.txt"] == nil }

        // The source is deleted externally before the redo, so the re-copy must fail.
        mockFM.virtualDisk.removeValue(forKey: "/src/f.txt")
        manager.banner = nil

        manager.undoManager?.redo()

        await waitUntil("copy redo failure raises a warning banner") {
            manager.banner?.severity == .warning
        }
        #expect(manager.banner?.message.contains("Redo couldn’t re-apply") == true)
        #expect(manager.banner?.message.contains("f.txt") == true)
        #expect(await loggerHasError(log, containing: "FAILED to redo \"f.txt\""))

        // The failed item stayed out of the redo's new undo state: undoing now is a quiet no-op,
        // with no permanent-delete prompt for a file not on disk.
        let spy = ConfirmerSpy()
        manager.permanentDeleteConfirmer = spy.confirm(true)
        manager.banner = nil
        manager.undoManager?.undo()
        await waitUntil("the no-op undo settles") { manager.activeFileOperationsCount == 0 }
        #expect(!spy.called)
        #expect(manager.banner == nil)
    }

    // MARK: Move redo — the source vanished between undo and redo

    /// Undo of a move puts the file back at its source; with that file then deleted externally, the
    /// redo's re-move fails. The failure is surfaced, and the next undo must not try to "restore"
    /// from the destination the move never populated.
    @MainActor
    @Test func testMoveRedoFailureIsSurfacedAndNextUndoIsNoOp() async throws {
        let log = LogCapture()
        let manager = makeManager()
        let mockFM = try disk()

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)

        manager.undoManager?.undo()
        await waitUntil("undo moves the file back to its source") { mockFM.virtualDisk["/src/f.txt"] != nil }

        mockFM.virtualDisk.removeValue(forKey: "/src/f.txt")
        manager.banner = nil

        manager.undoManager?.redo()

        await waitUntil("move redo failure raises a warning banner") {
            manager.banner?.severity == .warning
        }
        #expect(manager.banner?.message.contains("Redo couldn’t re-apply") == true)
        #expect(await loggerHasError(log, containing: "FAILED to redo \"f.txt\""))

        // The next undo has nothing registered for the failed item: no phantom move-back, no
        // spurious "couldn't restore" banner, and the disk is untouched.
        manager.banner = nil
        manager.undoManager?.undo()
        await waitUntil("the no-op undo settles") { manager.activeFileOperationsCount == 0 }
        #expect(manager.banner == nil)
        #expect(mockFM.virtualDisk["/src/f.txt"] == nil)
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
    }

    // MARK: Move redo after a REFUSED undo — must not re-run the move the undo declined

    /// Undo of a move refuses when a different file has appeared at the source (it won't clobber an
    /// unrelated occupant). The redo must then do nothing, since the move was never reversed. Redo
    /// params built eagerly from every item would move the occupant over the real file.
    @MainActor
    @Test func testRedoAfterARefusedMoveUndoDoesNotClobberTheDestination() async throws {
        let manager = makeManager()
        let mockFM = try disk()   // /src/f.txt is the real file S

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)

        // An UNRELATED file Z appears at the source before the undo, occupying the move-back target.
        mockFM.virtualDisk["/src/f.txt"] = file(55)   // Z

        manager.undoManager?.undo()   // move-back refuses: /src/f.txt is occupied by Z
        await waitUntil("the refused undo settles") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)  // S stayed
        #expect(mockFM.virtualDisk["/src/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 55)   // Z stayed

        manager.banner = nil
        manager.undoManager?.redo()   // must NOT re-run the move the undo refused
        await waitUntil("the redo settles") { manager.activeFileOperationsCount == 0 }

        // The redo did nothing: S is untouched at the destination and Z stayed at the source. A
        // wrong redo would move Z over S and back the real file up to the Trash.
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect(mockFM.virtualDisk["/src/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 55)
        #expect(mockFM.trashedPaths.isEmpty)   // S was never displaced to the Trash
    }

    // MARK: Folder redo — a file has taken the folder's path

    /// Redo of New Folder fails when a file now occupies the path. The failure is surfaced, and the
    /// next undo must not touch the interloper: it isn't the folder this undo created, so it is
    /// neither trashed nor offered for permanent delete.
    @MainActor
    @Test func testFolderRedoFailureIsSurfacedAndNextUndoSparesTheInterloper() async throws {
        let log = LogCapture()
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        await manager.createFolder(named: "New Folder", in: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/New Folder"]?.isDirectory == true)

        manager.undoManager?.undo()
        await waitUntil("undo trashes the created folder") { mockFM.virtualDisk["/dst/New Folder"] == nil }

        // A FILE takes the folder's path before the redo, so createDirectory must fail.
        mockFM.virtualDisk["/dst/New Folder"] = file(7)
        manager.banner = nil

        manager.undoManager?.redo()

        await waitUntil("folder redo failure raises a warning banner") {
            manager.banner?.severity == .warning
        }
        #expect(manager.banner?.message.contains("Redo couldn’t re-apply") == true)
        #expect(await loggerHasError(log, containing: "FAILED to redo \"New Folder\""))
        #expect(mockFM.virtualDisk["/dst/New Folder"]?.isDirectory == false)

        // The undo registered by the failed redo skips anything not a directory at the registered
        // path: the squatting file survives untouched, with no prompt.
        let spy = ConfirmerSpy()
        manager.permanentDeleteConfirmer = spy.confirm(true)
        manager.banner = nil
        manager.undoManager?.undo()
        await waitUntil("the guarded undo settles") { manager.activeFileOperationsCount == 0 }
        #expect(!spy.called)
        #expect(mockFM.virtualDisk["/dst/New Folder"]?.isDirectory == false)
        #expect(mockFM.trashedPaths.count == 1) // only the original folder undo ever trashed
    }

    // MARK: Copy undo — confirmed permanent delete fails

    /// On a trash-less volume, the copy undo falls back to a confirmed permanent removeItem. When
    /// that fails, the copy survives: the failure is surfaced, and the overwritten original's
    /// in-place backup stays put, since restoring it over the surviving copy would collide.
    @MainActor
    @Test func testCopyUndoConfirmedRemoveFailureIsSurfacedAndLeavesBackupInPlace() async throws {
        let log = LogCapture()
        let manager = makeManager()
        let mockFM = try disk()
        mockFM.virtualDisk["/dst/f.txt"] = file(5)
        mockFM.shouldFailTrash = true // trash-less volume: the overwritten original stays as .rollback_
        manager.permanentDeleteConfirmer = { _ in true }

        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        let backupPath = try #require(mockFM.virtualDisk.keys.first { $0.hasPrefix("/dst/.rollback_") })

        // The confirmed permanent delete of the copy fails (e.g. permissions dropped mid-undo).
        mockFM.failRemovePathsOnce = ["/dst/f.txt"]
        manager.banner = nil

        manager.undoManager?.undo()

        await waitUntil("the failed permanent delete raises a warning banner") {
            manager.banner?.severity == .warning
        }
        #expect(manager.banner?.message.contains("Undo couldn’t remove") == true)
        #expect(manager.banner?.message.contains("f.txt") == true)
        #expect(await loggerHasError(log, containing: "FAILED to permanently delete \"f.txt\""))

        // No state changed: the copy survives, and the backup was not restored over it.
        await waitUntil("the failed undo settles") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect(mockFM.virtualDisk[backupPath] != nil)
    }
}
