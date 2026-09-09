import Testing
import Foundation
@testable import Sync

/// Pins the quit-guard accounting for undo/redo: the handlers spawn a `Task` to run their file
/// I/O, so `activeFileOperationsCount` must be bumped synchronously inside the handler itself —
/// otherwise ⌘Z immediately followed by ⌘Q reads a zero counter in
/// `applicationShouldTerminate` before the undo's operation is even scheduled.
///
/// **The two drains go through `waitUntil`, not a hand-rolled deadline.** They were
/// `ContinuousClock.now + .seconds(5)` loops, and on 2026-09-08 the first one lost that budget in a
/// full 3411-test parallel run at load average ~12: it failed on the final `== 0` reading 1, after
/// 8.270 s, against a suite that needs **21-25 ms** alone. Wall time is the wrong unit here — what
/// these wait for arrives on main-actor turns, and a congested run has fewer of them per second,
/// so a seconds-only budget shrinks exactly when the wait needs it most. `waitUntil` is bounded by
/// POLLS as well (`waitPollFloor`), which is the part that makes it survive congestion, and it
/// names the poll count in the failure so a starved wait can be told from a disproved one.
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
            // undo proceeds — which is what this test is about. It used to pass `nil`, which meant
            // the same thing only because nil SKIPPED the guard; there is no longer a value that
            // does that, so the intent has to be stated rather than fallen into.
            destinationIdentity: ItemIdentity.snapshot(at: URL(fileURLWithPath: "/dst/copied.txt"),
                                                       fileManager: mockFM)
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
