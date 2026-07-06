import Testing
import Foundation
import Events
@testable import Sync

/// Pins the behavioral differences between the four copy/move entry points
/// (`copyItems(fromLeft:)`, `moveItems(fromLeft:)`, `copyItems(toPath:)`, `moveItems(toPath:)`)
/// ahead of collapsing them into one shared implementation:
/// - same-URL handling: copies keep-both via `generateUniqueURL`, moves skip,
/// - which undo registrar runs (Copy vs Move action names),
/// - the final debug log per variant, including the "N of M" partial-count form,
/// - the error message per family ("Error copying items" vs "Error moving items"),
/// - the order and content of the returned nodes.
/// Every test mocks the collision seams: the production defaults show blocking NSAlerts.
@Suite struct CopyMoveBehaviorPinTests {

    /// True when the shared Logger holds an entry with exactly `message`. Awaiting a fresh log
    /// task first guarantees everything enqueued before it is visible in `entries`.
    @MainActor
    private func loggerContains(_ message: String) async -> Bool {
        await Logger.shared.debug("pin-test flush marker").value
        return Logger.shared.entries.contains { $0.message == message }
    }

    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _, _ in .replace }
        manager.bulkCollisionResolver = { _, _ in (.replace, true) }
        manager.permanentDeleteConfirmer = { _ in false }
        return manager
    }

    // MARK: - Same-URL handling (source == derived target)

    /// Copying onto itself (both panes rooted at the same directory) keeps both: the copy lands
    /// under a uniquified name, is undoable as a Copy, and counts as fully copied.
    @MainActor
    @Test func testCopyItemsFromLeftOntoItselfKeepsBoth() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/pinSameCopyPane.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/pinSameCopyPane.txt", name: "pinSameCopyPane.txt", isDirectory: false)

        let copied = await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/src", fileManager: mockFM)

        #expect(mockFM.virtualDisk["/src/pinSameCopyPane.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/pinSameCopyPane 2.txt"] != nil)
        #expect(copied.map(\.id) == ["/src/pinSameCopyPane.txt"])
        #expect(manager.currentError == nil)
        #expect(manager.undoManager?.canUndo == true)
        #expect(manager.undoManager?.undoActionName == "Copy 1 Items")
        #expect(await loggerContains("Copied 1 items between panes"))
    }

    /// Moving onto itself is skipped (with a debug trace), returns no moved nodes, and registers
    /// no undo; the final log reports the partial count 0 of 1.
    @MainActor
    @Test func testMoveItemsFromLeftOntoItselfSkips() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/pinSameMovePane.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/pinSameMovePane.txt", name: "pinSameMovePane.txt", isDirectory: false)

        let moved = await manager.moveItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/src", fileManager: mockFM)

        #expect(moved.isEmpty)
        #expect(mockFM.virtualDisk["/src/pinSameMovePane.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/pinSameMovePane 2.txt"] == nil)
        #expect(manager.currentError == nil)
        #expect(manager.undoManager?.canUndo == false)
        #expect(await loggerContains("Skipping move of \"pinSameMovePane.txt\": source and destination are the same location."))
        #expect(await loggerContains("Moved 0 of 1 items between panes"))
    }

    /// Copy-to-path onto the source directory keeps both, same as the pane variant.
    @MainActor
    @Test func testCopyItemsToPathOntoItselfKeepsBoth() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/pinSameCopyPath.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/pinSameCopyPath.txt", name: "pinSameCopyPath.txt", isDirectory: false)

        let copied = await manager.copyItems(nodes: [node], toPath: "/src", fileManager: mockFM)

        #expect(mockFM.virtualDisk["/src/pinSameCopyPath.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/pinSameCopyPath 2.txt"] != nil)
        #expect(copied.map(\.id) == ["/src/pinSameCopyPath.txt"])
        #expect(manager.currentError == nil)
        #expect(manager.undoManager?.canUndo == true)
        #expect(manager.undoManager?.undoActionName == "Copy 1 Items")
        #expect(await loggerContains("Copied 1 items to /src"))
    }

    /// Move-to-path onto the source directory is skipped: nothing moves, nothing to undo.
    @MainActor
    @Test func testMoveItemsToPathOntoItselfSkips() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/pinSameMovePath.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/pinSameMovePath.txt", name: "pinSameMovePath.txt", isDirectory: false)

        let moved = await manager.moveItems(nodes: [node], toPath: "/src", fileManager: mockFM)

        #expect(moved.isEmpty)
        #expect(mockFM.virtualDisk["/src/pinSameMovePath.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/pinSameMovePath 2.txt"] == nil)
        #expect(manager.currentError == nil)
        #expect(manager.undoManager?.canUndo == false)
    }

    // MARK: - Partial counts, returned order, and undo registrars

    /// One of three copies is skipped via the collision dialog: the returned nodes keep source
    /// order, the log uses the "N of M" form, and the undo action counts only real copies.
    @MainActor
    @Test func testCopyItemsFromLeftPartialSkipReportsPartialCount() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        // Strictly increasing id lengths so the length-sorted prune order equals input order.
        for name in ["pcA.txt", "pcBB.txt", "pcCCC.txt"] {
            mockFM.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        mockFM.virtualDisk["/dst/pcBB.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let nodes = ["pcA.txt", "pcBB.txt", "pcCCC.txt"].map {
            FileNode(id: "/src/\($0)", name: $0, isDirectory: false)
        }
        manager.collisionResolver = { _, _ in .skip }

        let copied = await manager.copyItems(nodes: nodes, fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        #expect(copied.map(\.name) == ["pcA.txt", "pcCCC.txt"])
        #expect(mockFM.virtualDisk["/dst/pcA.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/pcCCC.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/pcBB 2.txt"] == nil)
        #expect(manager.currentError == nil)
        #expect(manager.undoManager?.undoActionName == "Copy 2 Items")
        #expect(await loggerContains("Copied 2 of 3 items between panes"))
    }

    /// Same shape for the pane move: partial log, Move undo registrar, and undo restores the
    /// moved file to its source.
    @MainActor
    @Test func testMoveItemsFromLeftPartialSkipReportsPartialCountAndUndoes() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        for name in ["pmA.txt", "pmBB.txt"] {
            mockFM.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        mockFM.virtualDisk["/dst/pmBB.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let nodes = ["pmA.txt", "pmBB.txt"].map {
            FileNode(id: "/src/\($0)", name: $0, isDirectory: false)
        }
        manager.collisionResolver = { _, _ in .skip }

        let moved = await manager.moveItems(nodes: nodes, fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        #expect(moved.map(\.name) == ["pmA.txt"])
        #expect(mockFM.virtualDisk["/dst/pmA.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/pmA.txt"] == nil)
        #expect(mockFM.virtualDisk["/src/pmBB.txt"] != nil)
        #expect(manager.undoManager?.undoActionName == "Move 1 Items")
        #expect(await loggerContains("Moved 1 of 2 items between panes"))

        // The Move registrar really is wired: undo brings the file back to its source.
        manager.undoManager?.undo()
        let deadline = Date().addingTimeInterval(3.0)
        while mockFM.virtualDisk["/src/pmA.txt"] == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        #expect(mockFM.virtualDisk["/src/pmA.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/pmA.txt"] == nil)
    }

    /// Copy-to-path sibling of the partial-count pin.
    @MainActor
    @Test func testCopyItemsToPathPartialSkipReportsPartialCount() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        for name in ["ptA.txt", "ptBB.txt"] {
            mockFM.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        mockFM.virtualDisk["/dst/ptBB.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let nodes = ["ptA.txt", "ptBB.txt"].map {
            FileNode(id: "/src/\($0)", name: $0, isDirectory: false)
        }
        manager.collisionResolver = { _, _ in .skip }

        let copied = await manager.copyItems(nodes: nodes, toPath: "/dst", fileManager: mockFM)

        #expect(copied.map(\.name) == ["ptA.txt"])
        #expect(mockFM.virtualDisk["/dst/ptA.txt"] != nil)
        #expect(manager.undoManager?.undoActionName == "Copy 1 Items")
        #expect(await loggerContains("Copied 1 of 2 items to /dst"))
    }

    /// Known drift in moveItems(toPath:): its final log reports the *selection* count, not the
    /// moved count, and lacks the "N of M" partial form its three siblings have. This pins the
    /// current (wrong) message; the unified implementation deliberately aligns it with the
    /// siblings, at which point this expectation flips to "Moved 1 of 2 items to /dst".
    @MainActor
    @Test func testMoveItemsToPathPartialSkipLogsMovedCount() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        for name in ["pdA.txt", "pdBB.txt"] {
            mockFM.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }
        mockFM.virtualDisk["/dst/pdBB.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let nodes = ["pdA.txt", "pdBB.txt"].map {
            FileNode(id: "/src/\($0)", name: $0, isDirectory: false)
        }
        manager.collisionResolver = { _, _ in .skip }

        let moved = await manager.moveItems(nodes: nodes, toPath: "/dst", fileManager: mockFM)

        #expect(moved.map(\.name) == ["pdA.txt"])
        #expect(mockFM.virtualDisk["/dst/pdA.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/pdBB.txt"] != nil)
        #expect(manager.undoManager?.undoActionName == "Move 1 Items")
        #expect(await loggerContains("Moved 2 items to /dst"))
    }

    /// Full-count happy-path logs for the two move variants (the copy ones are pinned above).
    @MainActor
    @Test func testMoveItemsFullCountLogsPerVariant() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dstPane"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dstPath"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/fullPane.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/fullPath.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let paneNode = FileNode(id: "/src/fullPane.txt", name: "fullPane.txt", isDirectory: false)
        let pathNode = FileNode(id: "/src/fullPath.txt", name: "fullPath.txt", isDirectory: false)

        await manager.moveItems(nodes: [paneNode], fromLeft: true, leftRoot: "/src", rightRoot: "/dstPane", fileManager: mockFM)
        await manager.moveItems(nodes: [pathNode], toPath: "/dstPath", fileManager: mockFM)

        #expect(await loggerContains("Moved 1 items between panes"))
        #expect(await loggerContains("Moved 1 items to /dstPath"))
    }

    // MARK: - Error messages per family

    /// A nesting violation surfaces as "Error copying items" for the copy family…
    @MainActor
    @Test func testCopyItemsErrorMessageUsesCopyingWording() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        mockFM.virtualDisk["/src/errCopyDir"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: [])
        let node = FileNode(id: "/src/errCopyDir", name: "errCopyDir", isDirectory: true)

        let copied = await manager.copyItems(nodes: [node], toPath: "/src/errCopyDir", fileManager: mockFM)

        #expect(copied.isEmpty)
        #expect(manager.currentError == "Error copying items: Cannot move or copy a directory into itself or its subdirectories.")
    }

    /// …and as "Error moving items" for the move family.
    @MainActor
    @Test func testMoveItemsErrorMessageUsesMovingWording() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        mockFM.virtualDisk["/src/errMoveDir"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: [])
        let node = FileNode(id: "/src/errMoveDir", name: "errMoveDir", isDirectory: true)

        let moved = await manager.moveItems(nodes: [node], toPath: "/src/errMoveDir", fileManager: mockFM)

        #expect(moved.isEmpty)
        #expect(manager.currentError == "Error moving items: Cannot move or copy a directory into itself or its subdirectories.")
    }
}
