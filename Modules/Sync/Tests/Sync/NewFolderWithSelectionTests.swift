import Foundation
import Testing
@testable import Sync

/// Finder's New Folder with Selection: the folder is made beside the items, they move in, and one
/// ⌘Z takes back both. Real disk with a `ScratchTrash`: the claims are about where things end up.
@MainActor
@Suite struct NewFolderWithSelectionTests {

    private func manager() -> FileSyncManager {
        let m = FileSyncManager()
        m.undoManager = UndoManager()
        m.permanentDeleteConfirmer = { _ in false }
        m.syncHistoryStore = makeTempHistoryStore(prefix: "NewFolderWithSelection")
        return m
    }

    @Test func theItemsMoveIntoTheNewFolderAndOneUndoTakesBackBoth() async throws {
        let root = try makeCanonicalTempRoot(prefix: "new-folder-with-selection")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try writeText("a", a)
        try writeText("b", b)
        let m = manager()
        defer { removeHistoryStoreFiles(m.syncHistoryStore) }
        // The name was the question: no transfer prompt follows it.
        m.transferConfirmer = { _ in Issue.record("New Folder with Selection asked to confirm the move"); return false }
        let nodes = [a, b].map { FileNode(id: $0.path, name: $0.lastPathComponent, isDirectory: false) }

        let made = await m.moveIntoNewFolder(nodes, named: "Receipts", in: root.path, fileManager: trash)
        let folder = root.appendingPathComponent("Receipts")
        #expect(made?.folder == folder.path)
        #expect(made?.moved.count == 2)
        #expect(readText(folder.appendingPathComponent("a.txt")) == "a")
        #expect(readText(folder.appendingPathComponent("b.txt")) == "b")
        #expect(!entryExists(a) && !entryExists(b))
        #expect(m.undoManager?.undoActionName == FileSyncManager.newFolderWithSelectionActionName)

        m.undoManager?.undo()
        await waitUntil("the undo drains") { m.activeFileOperationsCount == 0 }
        #expect(readText(a) == "a")
        #expect(readText(b) == "b")
        #expect(!entryExists(folder), "one ⌘Z leaves the emptied folder behind")
        #expect(m.undoManager?.canUndo == false, "the folder and the move are one step, not two")

        m.undoManager?.redo()
        await waitUntil("the redo drains") { m.activeFileOperationsCount == 0 }
        #expect(readText(folder.appendingPathComponent("a.txt")) == "a")
        #expect(readText(folder.appendingPathComponent("b.txt")) == "b")
        #expect(!entryExists(a) && !entryExists(b))
        #expect(m.banner == nil || m.banner?.severity == .success,
                "banner: \(String(describing: m.banner?.message))")
    }

    /// The moved rows leave the selection as they land, not at the next rescan: until then Info
    /// reads a path that is gone and says "Can't show this item".
    @Test func theMovedRowsLeaveTheSelectionAtOnce() async throws {
        let root = try makeCanonicalTempRoot(prefix: "new-folder-with-selection-selection")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt"), keep = root.appendingPathComponent("keep.txt")
        try writeText("a", a)
        try writeText("k", keep)
        let m = manager()
        defer { removeHistoryStoreFiles(m.syncHistoryStore) }
        // The tree as the pane holds it until the rescan: both rows still listed, so the prune the
        // move schedules keeps both paths. Only the new code takes the moved one out.
        let nodeA = FileNode(id: a.path, name: "a.txt", isDirectory: false)
        m.leftTree = [nodeA, FileNode(id: keep.path, name: "keep.txt", isDirectory: false)]
        m.selectedLeftPaths = [a.path, keep.path]

        _ = await m.moveIntoNewFolder([nodeA], named: "Receipts", in: root.path, fileManager: ScratchTrash(in: root))
        #expect(m.selectedLeftPaths == [keep.path], "selection: \(m.selectedLeftPaths)")
    }

    @Test func aNameAlreadyTakenMakesNothingAndMovesNothing() async throws {
        let root = try makeCanonicalTempRoot(prefix: "new-folder-with-selection-taken")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt")
        try writeText("a", a)
        try writeText("there", root.appendingPathComponent("Receipts"))
        let m = manager()
        defer { removeHistoryStoreFiles(m.syncHistoryStore) }

        let made = await m.moveIntoNewFolder([FileNode(id: a.path, name: "a.txt", isDirectory: false)],
                                             named: "Receipts", in: root.path, fileManager: ScratchTrash(in: root))
        #expect(made == nil)
        #expect(readText(a) == "a")
        #expect(readText(root.appendingPathComponent("Receipts")) == "there")
        #expect(m.currentError != nil, "the refusal is said, not silent")
    }

    /// Nothing landed, so no stray empty folder stays behind.
    @Test func whenNothingMovesTheFolderIsRemovedAgain() async throws {
        let root = try makeCanonicalTempRoot(prefix: "new-folder-with-selection-gone")
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appendingPathComponent("gone.txt")
        let m = manager()
        defer { removeHistoryStoreFiles(m.syncHistoryStore) }

        let made = await m.moveIntoNewFolder([FileNode(id: gone.path, name: "gone.txt", isDirectory: false)],
                                             named: "Receipts", in: root.path, fileManager: ScratchTrash(in: root))
        await waitUntil("the clean-up drains") { m.activeFileOperationsCount == 0 }
        #expect(made?.moved.isEmpty == true)
        #expect(!entryExists(root.appendingPathComponent("Receipts")))
    }

    @Test func theParentIsTheOneFolderEveryItemIsIn() {
        func n(_ path: String, dir: Bool = false) -> FileNode {
            FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: dir)
        }
        #expect(FileSyncManager.newFolderWithSelectionParent([n("/r/a"), n("/r/b")]) == "/r")
        #expect(FileSyncManager.newFolderWithSelectionParent([n("/r/a"), n("/r/sub/b")]) == nil,
                "rows from two folders have no one place for the folder")
        #expect(FileSyncManager.newFolderWithSelectionParent([]) == nil)
        // A row inside a selected folder travels with it, so it doesn't count as a second folder.
        let sub = FileNode(id: "/r/sub", name: "sub", isDirectory: true, children: [n("/r/sub/b")])
        #expect(FileSyncManager.newFolderWithSelectionParent([n("/r/a"), sub, n("/r/sub/b")]) == "/r")
    }

    @Test func theSuggestedNameStepsPastOneTaken() throws {
        let root = try makeCanonicalTempRoot(prefix: "new-folder-with-selection-name")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FileSyncManager.newFolderWithSelectionName(in: root.path) == "New Folder With Items")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("New Folder With Items"),
                                                withIntermediateDirectories: false)
        #expect(FileSyncManager.newFolderWithSelectionName(in: root.path) == "New Folder With Items 2")
    }
}
