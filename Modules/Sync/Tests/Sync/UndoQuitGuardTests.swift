import Testing
import Foundation
@testable import Sync

/// Pins the quit-guard accounting for undo/redo: the handlers spawn a `Task` for their file I/O,
/// so `activeFileOperationsCount` must be bumped synchronously in the handler itself, or ⌘Z then
/// ⌘Q reads a zero counter in `applicationShouldTerminate` before the undo is even scheduled.
///
/// The drains use `waitUntil`, not a seconds-only deadline: what they wait for arrives on
/// main-actor turns, which a congested run has fewer of per second. `waitUntil` is bounded by
/// polls too (`waitPollFloor`) and names the poll count, so a starved wait reads as one.
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
        await waitUntil("the create-folder undo's decrement returns the counter to zero") {
            manager.activeFileOperationsCount == 0
        }
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

        let resolver = AsyncValueResolver<[FileSyncManager.CopyUndoItemState]>()
        await resolver.resolve([(
            source: URL(fileURLWithPath: "/src/copied.txt"),
            destination: URL(fileURLWithPath: "/dst/copied.txt"),
            overwritten: nil,
            // The real identity of what is on the mock disk, so the drift guard passes and the
            // undo proceeds, which is what this test is about.
            destinationIdentity: ItemIdentity.snapshot(at: URL(fileURLWithPath: "/dst/copied.txt"),
                                                       fileManager: mockFM),
            overwrittenIdentity: .absent,
            copiedLock: false
        )])
        manager.registerCopyUndo(stateResolver: resolver, actionName: "Sync copied.txt", fileManager: mockFM)
        #expect(manager.activeFileOperationsCount == 0)

        undoManager.undo()
        #expect(manager.activeFileOperationsCount > 0)

        await waitUntil("the copy undo's decrement returns the counter to zero") {
            manager.activeFileOperationsCount == 0
        }
        #expect(mockFM.virtualDisk["/dst/copied.txt"] == nil)
    }
}
