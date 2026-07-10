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
/// Every test mocks the collision seams to the specific resolution it exercises; the unwired
/// defaults fail safe (skip / don't delete), which UnwiredManagerSafeDefaultsTests pins.
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
        manager.collisionResolver = { _, _, _ in .replace }
        manager.bulkCollisionResolver = { _, _, _ in (.replace, true) }
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
        manager.collisionResolver = { _, _, _ in .skip }

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
        manager.collisionResolver = { _, _, _ in .skip }

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
        manager.collisionResolver = { _, _, _ in .skip }

        let copied = await manager.copyItems(nodes: nodes, toPath: "/dst", fileManager: mockFM)

        #expect(copied.map(\.name) == ["ptA.txt"])
        #expect(mockFM.virtualDisk["/dst/ptA.txt"] != nil)
        #expect(manager.undoManager?.undoActionName == "Copy 1 Items")
        #expect(await loggerContains("Copied 1 of 2 items to /dst"))
    }

    /// moveItems(toPath:)'s final log had drifted from its three siblings: it reported the
    /// *selection* count instead of the moved count and lacked the "N of M" partial form. The
    /// unified implementation deliberately aligns it, so a partial move now logs "1 of 2".
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
        manager.collisionResolver = { _, _, _ in .skip }

        let moved = await manager.moveItems(nodes: nodes, toPath: "/dst", fileManager: mockFM)

        #expect(moved.map(\.name) == ["pdA.txt"])
        #expect(mockFM.virtualDisk["/dst/pdA.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/pdBB.txt"] != nil)
        #expect(manager.undoManager?.undoActionName == "Move 1 Items")
        #expect(await loggerContains("Moved 1 of 2 items to /dst"))
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
        #expect(manager.currentError?.title == "Copy Failed")
        #expect(manager.currentError?.reason == "Cannot move or copy a directory into itself or its subdirectories.")
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
        #expect(manager.currentError?.title == "Move Failed")
        #expect(manager.currentError?.reason == "Cannot move or copy a directory into itself or its subdirectories.")
    }

    // MARK: - Pane-root hardening (empty roots, prefix aliasing, vanished destination)

    /// An empty destination root (the pane's provider vanished from settings) aborts the whole
    /// operation before any I/O. Previously "" produced a relative target path that
    /// URL(fileURLWithPath:) resolved against the process CWD — a move relocated files out of
    /// the source pane into a CWD-relative tree.
    @MainActor
    @Test func testMoveItemsEmptyDestinationRootAbortsWithoutWrites() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/hardEmptyDst.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/hardEmptyDst.txt", name: "hardEmptyDst.txt", isDirectory: false)

        let moved = await manager.moveItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "", fileManager: mockFM)

        #expect(moved.isEmpty)
        #expect(manager.currentError?.title == "Move Failed")
        #expect(mockFM.virtualDisk["/src/hardEmptyDst.txt"] != nil)
        #expect(mockFM.calledCopyItem == false)
        #expect(mockFM.attemptedRemovePaths.isEmpty)
        #expect(manager.undoManager?.canUndo == false)
    }

    /// An empty *source* root must fail too: "" prefix-matched every node, so the old code kept
    /// the node's near-absolute path as the "relative" part and grafted it under the destination.
    @MainActor
    @Test func testCopyItemsEmptySourceRootFailsInsteadOfGrafting() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/hardEmptySrc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/hardEmptySrc.txt", name: "hardEmptySrc.txt", isDirectory: false)

        let copied = await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "", rightRoot: "/dst", fileManager: mockFM)

        #expect(copied.isEmpty)
        #expect(manager.currentError?.title == "Copy Failed")
        #expect(manager.currentError?.reason == "The source pane's folder is no longer available. Rescan before copying or moving items.")
        #expect(mockFM.calledCopyItem == false)
        #expect(!mockFM.virtualDisk.keys.contains { $0.hasPrefix("/dst/") })
    }

    /// A node outside the source root fails per item — the old fallback grafted its absolute
    /// path under the destination root, the mechanism behind the misdirected
    /// `<newRoot>/Users/…/<oldRoot>/…` copies seen during pane swaps. A sibling that IS under
    /// the root still transfers in the same call.
    @MainActor
    @Test func testCopyItemsNodeOutsideSourceRootFailsPerItem() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/outside"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/hardIn.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/outside/hardOutBB.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        // Strictly increasing id lengths so the length-sorted prune order equals input order.
        let inNode = FileNode(id: "/src/hardIn.txt", name: "hardIn.txt", isDirectory: false)
        let outNode = FileNode(id: "/outside/hardOutBB.txt", name: "hardOutBB.txt", isDirectory: false)

        let copied = await manager.copyItems(nodes: [inNode, outNode], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        #expect(copied.map(\.name) == ["hardIn.txt"])
        #expect(mockFM.virtualDisk["/dst/hardIn.txt"] != nil)
        #expect(manager.currentError?.title == "Copy Failed")
        #expect(manager.currentError?.reason == "\"hardOutBB.txt\" is not inside the source pane's folder. Rescan and try again.")
        // No grafted path: the outside node landed nowhere under /dst, and its original is intact.
        #expect(!mockFM.virtualDisk.keys.contains { $0.hasPrefix("/dst/outside") })
        #expect(mockFM.virtualDisk["/outside/hardOutBB.txt"] != nil)
    }

    /// Root "/data/foo" must not claim "/data/foobar/…" via a bare prefix match: previously the
    /// remainder after the aliased prefix ("bar/…") became the relative path and the file was
    /// silently copied to "<toRoot>/bar/…".
    @MainActor
    @Test func testMoveItemsPrefixAliasedRootFailsInsteadOfMisdirecting() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/data/foo"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/data/foobar"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/data/foobar/hardAlias.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/data/foobar/hardAlias.txt", name: "hardAlias.txt", isDirectory: false)

        let moved = await manager.moveItems(nodes: [node], fromLeft: true, leftRoot: "/data/foo", rightRoot: "/dst", fileManager: mockFM)

        #expect(moved.isEmpty)
        #expect(manager.currentError?.title == "Move Failed")
        #expect(mockFM.virtualDisk["/dst/bar/hardAlias.txt"] == nil)
        #expect(mockFM.virtualDisk["/data/foobar/hardAlias.txt"] != nil)
        #expect(mockFM.attemptedRemovePaths.isEmpty)
    }

    /// A destination pane root that no longer exists on disk (provider unmounted, e.g. the
    /// Google Drive app quit) fails the operation instead of being silently recreated as a
    /// plain local folder tree the FileProvider would never sync.
    @MainActor
    @Test func testCopyItemsMissingDestinationRootIsNotRecreated() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/hardGone.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/hardGone.txt", name: "hardGone.txt", isDirectory: false)

        let copied = await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        #expect(copied.isEmpty)
        #expect(manager.currentError?.title == "Copy Failed")
        #expect(manager.currentError?.reason == "The destination folder is no longer available. Rescan before copying or moving items.")
        #expect(mockFM.virtualDisk["/dst"] == nil)
        #expect(mockFM.calledCopyItem == false)
    }

    /// Same guard on the toPath route (drag & drop and paste): a vanished drop target is an
    /// error, not a directory to recreate — and a move leaves the originals in place.
    @MainActor
    @Test func testMoveItemsToPathMissingDestinationFailsWithoutWrites() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/hardDrop.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/hardDrop.txt", name: "hardDrop.txt", isDirectory: false)

        let moved = await manager.moveItems(nodes: [node], toPath: "/gone", fileManager: mockFM)

        #expect(moved.isEmpty)
        #expect(manager.currentError?.title == "Move Failed")
        #expect(mockFM.virtualDisk["/gone"] == nil)
        #expect(mockFM.virtualDisk["/src/hardDrop.txt"] != nil)
        #expect(mockFM.attemptedRemovePaths.isEmpty)
    }

    /// Regression guard: missing intermediate folders UNDER an existing destination root must
    /// still be created (bulk sync of nested files relies on it) — only the root itself is
    /// never auto-created.
    @MainActor
    @Test func testCopyItemsCreatesMissingIntermediatesUnderExistingRoot() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/sub"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/sub/hardDeep.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let node = FileNode(id: "/src/sub/hardDeep.txt", name: "hardDeep.txt", isDirectory: false)

        let copied = await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        #expect(copied.map(\.name) == ["hardDeep.txt"])
        #expect(mockFM.virtualDisk["/dst/sub"]?.isDirectory == true)
        #expect(mockFM.virtualDisk["/dst/sub/hardDeep.txt"] != nil)
        #expect(manager.currentError == nil)
    }
}
