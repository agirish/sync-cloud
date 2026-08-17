import Testing
import Foundation
@testable import Sync

/// Systematic undo→redo resolution matrix across the three registrar chains (move / copy /
/// delete), pinning EXACTLY which items each redo acts on for the three batch shapes round 4's
/// resolver fixes (f18f723, a73529b, and DeleteRedoOccupantTests' chain) must keep straight:
///
///   (a) every item succeeds → the redo re-applies the FULL batch;
///   (b) one item's undo is REFUSED (occupant at the move-back target / copy-destination size
///       drift) → the redo re-applies ONLY the items actually undone, and never touches what
///       the undo refused to disturb;
///   (c) the SAME path appears twice in one batch → the duplicate resolves to a single
///       effective item end-to-end (one trash, one restore, one redo), never a double
///       operation or a phantom second undo state.
///
/// The refusal cases mirror the single-item tests in RedoFailureReportingTests /
/// CopyUndoDriftAndTransientTests / DeleteRedoOccupantTests but in a MIXED batch, so a
/// regression that resolves redo params from the wrong item set (the original eager list, or
/// the refused subset) flips the untouched sibling's assertions here even when the single-item
/// pins stay green.
///
/// Batches use ≥2 distinct items throughout: `UndoRedoLogLabelTests` pins the "Delete 1 Items"
/// labels against the shared Logger, and a parallel-suite one-item delete would trip its
/// "no Redo logged yet" assertion.
@Suite struct UndoRedoResolutionMatrixTests {

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
    private func node(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false)
    }
    @MainActor
    private func size(_ mockFM: MockFileManager, _ path: String) -> Int? {
        mockFM.virtualDisk[path]?.attributes?[FileAttributeKey.size] as? Int
    }

    // MARK: - Move

    /// (a) All items succeed: undo moves BOTH back, redo re-moves BOTH.
    @MainActor
    @Test func moveAllSucceedRedoReappliesFullBatch() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = file(100)
        mockFM.virtualDisk["/src/b.txt"] = file(200)

        let moved = await manager.moveItems(nodes: [node("/src/a.txt"), node("/src/b.txt")], toPath: "/dst", fileManager: mockFM)
        #expect(moved.count == 2)

        manager.undoManager?.undo()
        await waitUntil("undo moves both back") {
            mockFM.virtualDisk["/src/a.txt"] != nil && mockFM.virtualDisk["/src/b.txt"] != nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil && mockFM.virtualDisk["/dst/b.txt"] == nil)

        manager.undoManager?.redo()
        await waitUntil("redo re-moves both") {
            mockFM.virtualDisk["/dst/a.txt"] != nil && mockFM.virtualDisk["/dst/b.txt"] != nil
        }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.virtualDisk["/src/a.txt"] == nil && mockFM.virtualDisk["/src/b.txt"] == nil)
        #expect(size(mockFM, "/dst/a.txt") == 100 && size(mockFM, "/dst/b.txt") == 200)
    }

    /// (b) One move-back refused (occupant at the source): the redo re-moves ONLY the restored
    /// sibling — the occupant must survive both the undo AND the redo, and the refused item
    /// stays at the destination throughout.
    @MainActor
    @Test func moveOneRefusedRedoActsOnlyOnTheRestoredItem() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = file(100)
        mockFM.virtualDisk["/src/b.txt"] = file(200)

        await manager.moveItems(nodes: [node("/src/a.txt"), node("/src/b.txt")], toPath: "/dst", fileManager: mockFM)
        #expect(size(mockFM, "/dst/a.txt") == 100 && size(mockFM, "/dst/b.txt") == 200)

        // An UNRELATED file Z occupies a.txt's original location before the undo.
        mockFM.virtualDisk["/src/a.txt"] = file(55)
        manager.banner = nil

        manager.undoManager?.undo()   // a refused (occupied), b moved back
        await waitUntil("undo restores the unoccupied sibling") { mockFM.virtualDisk["/src/b.txt"] != nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(manager.banner?.severity == .warning)                 // the refusal was surfaced
        #expect(size(mockFM, "/src/a.txt") == 55)                     // occupant untouched
        #expect(size(mockFM, "/dst/a.txt") == 100)                    // refused item stayed at dst
        #expect(mockFM.virtualDisk["/dst/b.txt"] == nil)

        manager.undoManager?.redo()   // must re-move ONLY b
        await waitUntil("redo re-moves the restored sibling") { mockFM.virtualDisk["/dst/b.txt"] != nil }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(size(mockFM, "/src/a.txt") == 55, "redo must never move the unrelated occupant")
        #expect(size(mockFM, "/dst/a.txt") == 100, "the refused item must not be clobbered by redo")
        #expect(mockFM.virtualDisk["/src/b.txt"] == nil)
        #expect(size(mockFM, "/dst/b.txt") == 200)
        #expect(mockFM.trashedPaths.isEmpty, "nothing may be displaced to the Trash by a refused-then-redone move")
    }

    /// (c) The same path twice in one move batch: the duplicate collapses to ONE effective move
    /// (the second attempt finds its source gone and errors), the undo restores the file once,
    /// and the redo re-moves it once. Characterization: a duplicated selection must never
    /// double-move or leave a phantom second undo state.
    @MainActor
    @Test func moveDuplicatePathResolvesToASingleItem() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = file(100)
        mockFM.virtualDisk["/src/b.txt"] = file(200)

        // b.txt keeps the batch ≥2 effective items (see the suite comment); a.txt is duplicated.
        await manager.moveItems(nodes: [node("/src/a.txt"), node("/src/a.txt"), node("/src/b.txt")],
                                toPath: "/dst", fileManager: mockFM)
        await waitUntil("both distinct files arrive") {
            mockFM.virtualDisk["/dst/a.txt"] != nil && mockFM.virtualDisk["/dst/b.txt"] != nil
        }
        #expect(size(mockFM, "/dst/a.txt") == 100)

        manager.undoManager?.undo()
        await waitUntil("undo restores both distinct files") {
            mockFM.virtualDisk["/src/a.txt"] != nil && mockFM.virtualDisk["/src/b.txt"] != nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(size(mockFM, "/src/a.txt") == 100)
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil && mockFM.virtualDisk["/dst/b.txt"] == nil)

        manager.undoManager?.redo()
        await waitUntil("redo re-moves both distinct files once each") {
            mockFM.virtualDisk["/dst/a.txt"] != nil && mockFM.virtualDisk["/dst/b.txt"] != nil
        }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.virtualDisk["/src/a.txt"] == nil && mockFM.virtualDisk["/src/b.txt"] == nil)
        #expect(size(mockFM, "/dst/a.txt") == 100 && size(mockFM, "/dst/b.txt") == 200)
    }

    // MARK: - Copy

    /// (a) All items succeed: undo trashes BOTH copies, redo re-copies BOTH.
    @MainActor
    @Test func copyAllSucceedRedoReappliesFullBatch() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = file(100)
        mockFM.virtualDisk["/src/b.txt"] = file(200)

        let copied = await manager.copyItems(nodes: [node("/src/a.txt"), node("/src/b.txt")], toPath: "/dst", fileManager: mockFM)
        #expect(copied.count == 2)

        manager.undoManager?.undo()
        await waitUntil("undo trashes both copies") {
            mockFM.virtualDisk["/dst/a.txt"] == nil && mockFM.virtualDisk["/dst/b.txt"] == nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(size(mockFM, "/src/a.txt") == 100 && size(mockFM, "/src/b.txt") == 200) // sources untouched

        manager.undoManager?.redo()
        await waitUntil("redo re-copies both") {
            mockFM.virtualDisk["/dst/a.txt"] != nil && mockFM.virtualDisk["/dst/b.txt"] != nil
        }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(size(mockFM, "/dst/a.txt") == 100 && size(mockFM, "/dst/b.txt") == 200)
    }

    /// (b) One copy-undo refused (destination size drifted): the undo trashes ONLY the unchanged
    /// sibling, and the redo re-copies ONLY that sibling — the drifted item is never trashed,
    /// never re-copied over.
    @MainActor
    @Test func copyOneDriftedRedoActsOnlyOnTheUndoneItem() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = file(100)
        mockFM.virtualDisk["/src/b.txt"] = file(200)

        await manager.copyItems(nodes: [node("/src/a.txt"), node("/src/b.txt")], toPath: "/dst", fileManager: mockFM)
        #expect(size(mockFM, "/dst/a.txt") == 100 && size(mockFM, "/dst/b.txt") == 200)

        // a.txt's copy is replaced by different content (size 777) before the undo.
        mockFM.virtualDisk["/dst/a.txt"] = file(777)
        manager.banner = nil

        manager.undoManager?.undo()   // a refused (drifted), b trashed
        await waitUntil("undo trashes the unchanged sibling") { mockFM.virtualDisk["/dst/b.txt"] == nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(manager.banner?.severity == .warning)                 // the refusal was surfaced
        #expect(size(mockFM, "/dst/a.txt") == 777, "the drifted item must be left in place")

        manager.undoManager?.redo()   // must re-copy ONLY b
        await waitUntil("redo re-copies the undone sibling") { mockFM.virtualDisk["/dst/b.txt"] != nil }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(size(mockFM, "/dst/a.txt") == 777, "redo must not re-copy over the drifted item")
        #expect(size(mockFM, "/dst/b.txt") == 200)
    }

    /// (c) The same path twice in one copy batch: with a `.replace` resolver the second copy
    /// replaces the first at the SAME destination, so the registered undo state carries two
    /// items for one path. The undo trashes the destination once and REFUSES the second item
    /// (its destination is now gone — size drifted from its snapshot); the redo then re-copies
    /// exactly once. Characterization of the double-registration shape — if the undo ever
    /// starts double-trashing or the redo double-copying, this flips.
    @MainActor
    @Test func copyDuplicatePathUndoesOnceAndRedoesOnce() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = file(100)
        mockFM.virtualDisk["/src/b.txt"] = file(200)

        let copied = await manager.copyItems(nodes: [node("/src/a.txt"), node("/src/a.txt"), node("/src/b.txt")],
                                             toPath: "/dst", fileManager: mockFM)
        // Both attempts "succeed" (the second replaces the first), so three registered items.
        #expect(copied.count == 3)
        #expect(size(mockFM, "/dst/a.txt") == 100)
        let trashesAfterCopy = mockFM.trashedPaths.count   // the replace displaced copy #1

        manager.undoManager?.undo()
        await waitUntil("undo empties the destination") {
            mockFM.virtualDisk["/dst/a.txt"] == nil && mockFM.virtualDisk["/dst/b.txt"] == nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        // Exactly TWO new trash events (a.txt once, b.txt once) — the duplicate registration
        // must not trash a second time; its second item is refused (destination gone).
        #expect(mockFM.trashedPaths.count == trashesAfterCopy + 2)
        #expect(size(mockFM, "/src/a.txt") == 100 && size(mockFM, "/src/b.txt") == 200)

        manager.undoManager?.redo()
        await waitUntil("redo re-copies both paths once each") {
            mockFM.virtualDisk["/dst/a.txt"] != nil && mockFM.virtualDisk["/dst/b.txt"] != nil
        }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(size(mockFM, "/dst/a.txt") == 100 && size(mockFM, "/dst/b.txt") == 200)
    }

    // MARK: - Delete

    /// (a)+(c) combined for the delete chain: a batch with a DUPLICATED path trashes each
    /// distinct file exactly once (the second occurrence finds the path already gone and is
    /// silently skipped), the undo restores each exactly once, and the redo re-trashes each
    /// exactly once. The refused-occupant case (b) is pinned by DeleteRedoOccupantTests.
    @MainActor
    @Test func deleteDuplicatePathTrashesRestoresAndRedoesOnceEach() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/docs"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/docs/a.txt"] = file(100)
        mockFM.virtualDisk["/docs/b.txt"] = file(200)

        // a.txt listed twice: the return value counts each DISTINCT file once.
        let removed = await manager.deleteItems(at: ["/docs/a.txt", "/docs/b.txt", "/docs/a.txt"], fileManager: mockFM).removed
        #expect(removed == 2)
        #expect(mockFM.virtualDisk["/docs/a.txt"] == nil && mockFM.virtualDisk["/docs/b.txt"] == nil)
        #expect(mockFM.trashedPaths.count == 2)

        manager.undoManager?.undo()
        await waitUntil("undo restores both distinct files") {
            mockFM.virtualDisk["/docs/a.txt"] != nil && mockFM.virtualDisk["/docs/b.txt"] != nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(size(mockFM, "/docs/a.txt") == 100 && size(mockFM, "/docs/b.txt") == 200)

        // The mock's flat Trash dir would collide on a same-name re-trash (the real Trash
        // uniquifies) — move the drained backups aside to model reality, as
        // DeleteRedoOccupantTests does.
        for trashPath in mockFM.trashedPaths {
            if let stub = mockFM.virtualDisk.removeValue(forKey: trashPath) {
                mockFM.virtualDisk["/mock-trash-drained/" + (trashPath as NSString).lastPathComponent] = stub
            }
        }
        let trashesBeforeRedo = mockFM.trashedPaths.count

        manager.undoManager?.redo()
        await waitUntil("redo re-trashes both distinct files") {
            mockFM.virtualDisk["/docs/a.txt"] == nil && mockFM.virtualDisk["/docs/b.txt"] == nil
        }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(mockFM.trashedPaths.count == trashesBeforeRedo + 2, "each distinct file re-trashed exactly once")
    }
}
