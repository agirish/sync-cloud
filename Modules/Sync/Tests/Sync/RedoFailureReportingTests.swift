import Testing
import Foundation
import Events
@testable import Sync

/// Pins the redo/cleanup failure paths that used to be silent `try?` swallows in
/// FileSyncManager+Undo:
/// - copy-redo `safeCopyItem`, move-redo `safeMoveItem`, folder-redo `createDirectory`, and the
///   copy-undo confirmed-permanent-delete `removeItem` all failed with no log line and no banner;
/// - worse, the redo paths still registered the failed item in the NEXT undo state, so a
///   subsequent undo operated on a phantom item — up to a confusing "permanently delete?" prompt
///   for a file that is not on disk.
/// These tests simulate the classic failure (the source vanishing between undo and redo, or a
/// file squatting on a folder's path) and assert the failure is SURFACED (`.error` log +
/// `.warning` banner) and that the following undo is a quiet no-op, never a phantom operation.
@Suite struct RedoFailureReportingTests {

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

    /// True when the shared Logger holds an `.error` entry containing `fragment`. Awaiting a
    /// fresh log task first guarantees everything enqueued before it is visible in `entries`.
    @MainActor
    private func loggerHasError(containing fragment: String) async -> Bool {
        await Logger.shared.debug("redo-fail flush marker").value
        return Logger.shared.entries.contains { $0.level == .error && $0.message.contains(fragment) }
    }

    /// A manager with every alert seam mocked so no test can ever pop a real NSAlert.
    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _, _, _ in .replace }
        manager.bulkCollisionResolver = { _, _, _ in (.replace, false) }
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

    private func file(_ size: Int) -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: size], contents: nil)
    }

    // MARK: Copy redo — the source vanished between undo and redo

    /// Undo of a copy trashes the destination; when the source is then deleted externally, the
    /// redo's re-copy fails. That failure must be surfaced (error log + warning banner), and the
    /// item must stay out of the next undo state — a subsequent undo must NOT try to trash the
    /// never-recreated destination and prompt to "permanently delete" a phantom file.
    @MainActor
    @Test func testCopyRedoFailureIsSurfacedAndNextUndoIsNoOp() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)

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
        #expect(manager.banner?.message.contains("Redo couldn't re-apply") == true)
        #expect(manager.banner?.message.contains("f.txt") == true)
        #expect(await loggerHasError(containing: "FAILED to redo \"f.txt\""))

        // The failed item stayed out of the redo's freshly registered undo state: undoing now is
        // a quiet no-op — in particular, no permanent-delete prompt for a file not on disk.
        let spy = ConfirmerSpy()
        manager.permanentDeleteConfirmer = spy.confirm(true)
        manager.banner = nil
        manager.undoManager?.undo()
        await waitUntil("the no-op undo settles") { manager.activeFileOperationsCount == 0 }
        #expect(!spy.called)
        #expect(manager.banner == nil)
    }

    // MARK: Move redo — the source vanished between undo and redo

    /// Undo of a move puts the file back at its source; when that file is then deleted
    /// externally, the redo's re-move fails. The failure must be surfaced, and the next undo must
    /// not attempt to "restore" from the destination the move never populated.
    @MainActor
    @Test func testMoveRedoFailureIsSurfacedAndNextUndoIsNoOp() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)

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
        #expect(manager.banner?.message.contains("Redo couldn't re-apply") == true)
        #expect(await loggerHasError(containing: "FAILED to redo \"f.txt\""))

        // The next undo has nothing registered for the failed item: no phantom move-back, no
        // spurious "couldn't restore" banner, and the disk is untouched.
        manager.banner = nil
        manager.undoManager?.undo()
        await waitUntil("the no-op undo settles") { manager.activeFileOperationsCount == 0 }
        #expect(manager.banner == nil)
        #expect(mockFM.virtualDisk["/src/f.txt"] == nil)
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
    }

    // MARK: Folder redo — a file has taken the folder's path

    /// Redo of New Folder fails when a file now occupies the path. The failure must be surfaced,
    /// and the subsequent undo must not touch the interloper: it is not the folder this undo
    /// created, so it must neither be trashed nor trigger a permanent-delete prompt.
    @MainActor
    @Test func testFolderRedoFailureIsSurfacedAndNextUndoSparesTheInterloper() async throws {
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
        #expect(manager.banner?.message.contains("Redo couldn't re-apply") == true)
        #expect(await loggerHasError(containing: "FAILED to redo \"New Folder\""))
        #expect(mockFM.virtualDisk["/dst/New Folder"]?.isDirectory == false)

        // The undo registered by the failed redo skips anything that is not a directory at the
        // registered path — the squatting file survives untouched, with no prompt.
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
    /// that removal fails, the copy survives on disk: the failure must be surfaced, and the
    /// overwritten original's in-place backup must stay put — restoring it over the surviving
    /// copy would collide (the old code silently attempted exactly that).
    @MainActor
    @Test func testCopyUndoConfirmedRemoveFailureIsSurfacedAndLeavesBackupInPlace() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = file(100)
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
        #expect(manager.banner?.message.contains("Undo couldn't remove") == true)
        #expect(manager.banner?.message.contains("f.txt") == true)
        #expect(await loggerHasError(containing: "FAILED to permanently delete \"f.txt\""))

        // No state was changed: the copy survives, and the backup was NOT restored over it.
        await waitUntil("the failed undo settles") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect(mockFM.virtualDisk[backupPath] != nil)
    }
}
