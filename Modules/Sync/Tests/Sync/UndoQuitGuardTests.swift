import Testing
import Foundation
@testable import Sync

/// Pins the quit-guard accounting for undo/redo: the handlers spawn a `Task` to run their file
/// I/O, so `activeFileOperationsCount` must be bumped synchronously inside the handler itself —
/// otherwise ⌘Z immediately followed by ⌘Q reads a zero counter in
/// `applicationShouldTerminate` before the undo's operation is even scheduled.
@Suite struct UndoQuitGuardTests {

    @MainActor
    @Test func testUndoHandlerCountsOperationBeforeItsTaskRuns() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let undoManager = UndoManager()
        manager.undoManager = undoManager
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        let folderURL = URL(fileURLWithPath: "/dst/New Folder")
        manager.registerCreateFolderRedo(url: folderURL, fileManager: mockFM)
        #expect(manager.activeFileOperationsCount == 0)

        // undo() invokes the handler synchronously on the MainActor; the counter must already
        // be nonzero when it returns, before the handler's spawned Task has had any chance to run.
        undoManager.undo()
        #expect(manager.activeFileOperationsCount > 0)

        // The shared decrement is unconditional: once the operation completes, the counter
        // returns to zero (no double-count from enqueueFileOperation(alreadyCounted: true)).
        let deadline = ContinuousClock.now + .seconds(5)
        while manager.activeFileOperationsCount != 0, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(manager.activeFileOperationsCount == 0)
        #expect(mockFM.virtualDisk[folderURL.path] != nil)
    }

    /// Same guarantee for a state-resolver-based handler (copy undo), which trashes the copied
    /// item — the counter moves synchronously even though the operation awaits resolver state.
    @MainActor
    @Test func testCopyUndoHandlerCountsOperationBeforeItsTaskRuns() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let undoManager = UndoManager()
        manager.undoManager = undoManager
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dst/copied.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let resolver = AsyncValueResolver<[FileSyncManager.CopyItemState]>()
        await resolver.resolve([(
            source: URL(fileURLWithPath: "/src/copied.txt"),
            destination: URL(fileURLWithPath: "/dst/copied.txt"),
            overwritten: nil
        )])
        manager.registerCopyUndo(stateResolver: resolver, actionName: "Sync copied.txt", fileManager: mockFM)
        #expect(manager.activeFileOperationsCount == 0)

        undoManager.undo()
        #expect(manager.activeFileOperationsCount > 0)

        let deadline = ContinuousClock.now + .seconds(5)
        while manager.activeFileOperationsCount != 0, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(manager.activeFileOperationsCount == 0)
        #expect(mockFM.virtualDisk["/dst/copied.txt"] == nil)
    }
}
