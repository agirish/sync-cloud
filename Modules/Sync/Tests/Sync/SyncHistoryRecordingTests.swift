import Testing
import Foundation
import Events
@testable import Sync

/// Integration coverage for Sync History recording: each op site (transfer copy/move, delete; bulk
/// sync is in `FileSyncManagerStateTests`) appends `SyncHistoryRecord`s to the injected `SyncHistoryStore` with the right action,
/// paths, direction and a per-run id. Recording is synchronous at the op sites, so the records are
/// there the moment the awaited call returns; no polling needed.
@MainActor
@Suite struct SyncHistoryRecordingTests {

    /// A history store, a manager recording into it, and a mock disk holding `folders`. The caller
    /// removes the store's files.
    private func recordingWorld(_ folders: String...) throws
        -> (store: SyncHistoryStore, manager: FileSyncManager, mockFM: MockFileManager) {
        let store = makeTempHistoryStore(prefix: "SyncHistoryRecordingTest")
        let manager = FileSyncManager()
        manager.syncHistoryStore = store
        let mockFM = MockFileManager()
        for path in folders {
            try mockFM.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        }
        return (store, manager, mockFM)
    }

    @Test func testCopyItemsRecordsACopyWithPaneDirection() async throws {
        let (store, manager, mockFM) = try recordingWorld("/src", "/dst")
        defer { removeHistoryStoreFiles(store) }
        mockFM.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let node = FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        #expect(store.records.count == 1)
        let record = try #require(store.records.first)
        #expect(record.action == .copy)
        #expect(record.sourcePath == "/src/a.txt")
        #expect(record.destPath == "/dst/a.txt")
        #expect(record.direction == "→ Right")
        #expect(record.checksum == nil)
    }

    @Test func testMoveItemsRecordsAMove() async throws {
        let (store, manager, mockFM) = try recordingWorld("/src", "/dst")
        defer { removeHistoryStoreFiles(store) }
        mockFM.virtualDisk["/src/m.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let node = FileNode(id: "/src/m.txt", name: "m.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)

        #expect(store.records.count == 1)
        let record = try #require(store.records.first)
        #expect(record.action == .move)
        #expect(record.sourcePath == "/src/m.txt")
        #expect(record.destPath == "/dst/m.txt")
        // A move to an arbitrary folder has no two-pane direction.
        #expect(record.direction == nil)
    }

    @Test func testDeleteItemsRecordsDeletes() async throws {
        let (store, manager, mockFM) = try recordingWorld("/dst")
        defer { removeHistoryStoreFiles(store) }
        mockFM.virtualDisk["/dst/gone.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        await manager.deleteItems(at: ["/dst/gone.txt"], fileManager: mockFM)

        #expect(store.records.count == 1)
        let record = try #require(store.records.first)
        #expect(record.action == .delete)
        #expect(record.sourcePath == "/dst/gone.txt")
        #expect(record.destPath == nil)
    }

    /// A row's Copy to … sent against its suggestion is recorded the way it went, and its undo gives
    /// back the newer file it overwrote. The row suggests left → right; the user copies right → left
    /// (`redirected(to:)`, what the menu item sends) over the newer left file. Real disk, so the
    /// overwritten file goes to a scratch Trash and comes back.
    @Test func testARedirectedRowCopyRecordsLeftAndItsUndoRestoresTheNewerFile() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("RedirectedCopy-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let left = base.appendingPathComponent("left"), right = base.appendingPathComponent("right")
        for dir in [left, right] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let leftFile = left.appendingPathComponent("notes.txt"), rightFile = right.appendingPathComponent("notes.txt")
        try Data("newer, on the left".utf8).write(to: leftFile)
        try Data("older".utf8).write(to: rightFile)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: rightFile.path)

        let store = makeTempHistoryStore(prefix: "RedirectedCopyHistory")
        defer { removeHistoryStoreFiles(store) }
        let manager = FileSyncManager(fileManager: ScratchTrash(in: base))
        manager.syncHistoryStore = store
        manager.undoManager = UndoManager()
        manager.transferConfirmer = { _ in true }
        manager.collisionResolver = { _ in .replace }
        let row = FileDifference(relativePath: "notes.txt", leftItemPath: leftFile.path, rightItemPath: rightFile.path,
                                 type: .differentDates, action: .copyToRight, description: "Left is newer",
                                 leftFileSize: 18, rightFileSize: 5)

        let copied = await manager.syncFile(row.redirected(to: .copyToLeft))
        try #require(copied, "the premise: the redirected copy ran")
        try #require(try String(contentsOf: leftFile, encoding: .utf8) == "older", "the premise: the older file went left")

        let record = try #require(store.records.first, "the copy left nothing in Sync History")
        #expect(store.records.count == 1)
        #expect(record.action == .copy)
        #expect(record.direction == "← Left")
        #expect(record.sourcePath == rightFile.path)
        #expect(record.destPath == leftFile.path)
        #expect(record.backupPath != nil, "the overwritten newer file has no backup to come back from")

        try #require(manager.undoManager?.canUndo == true)
        manager.undoManager?.undo()
        await waitUntil("the undo gives the newer file back") {
            (try? String(contentsOf: leftFile, encoding: .utf8)) == "newer, on the left"
        }
        #expect(try String(contentsOf: rightFile, encoding: .utf8) == "older")
    }
}
