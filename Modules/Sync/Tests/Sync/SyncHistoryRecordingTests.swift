import Testing
import Foundation
import Events
@testable import Sync

/// Integration coverage for the X2 recording wiring: each op site (transfer copy/move, delete,
/// bulk sync) appends `SyncHistoryRecord`s to the injected `SyncHistoryStore`, with the right
/// action, paths, direction, and a per-run id. Recording is synchronous at the op sites, so the
/// records are present the moment the awaited call returns — no polling needed.
@MainActor
@Suite struct SyncHistoryRecordingTests {

    @Test func testCopyItemsRecordsACopyWithPaneDirection() async throws {
        let store = makeTempHistoryStore(prefix: "SyncHistoryRecordingTest")
        defer { removeHistoryStoreFiles(store) }
        let manager = FileSyncManager()
        manager.syncHistoryStore = store
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
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
        let store = makeTempHistoryStore(prefix: "SyncHistoryRecordingTest")
        defer { removeHistoryStoreFiles(store) }
        let manager = FileSyncManager()
        manager.syncHistoryStore = store
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
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
        let store = makeTempHistoryStore(prefix: "SyncHistoryRecordingTest")
        defer { removeHistoryStoreFiles(store) }
        let manager = FileSyncManager()
        manager.syncHistoryStore = store
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/dst/gone.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        await manager.deleteItems(at: ["/dst/gone.txt"], fileManager: mockFM)

        #expect(store.records.count == 1)
        let record = try #require(store.records.first)
        #expect(record.action == .delete)
        #expect(record.sourcePath == "/dst/gone.txt")
        #expect(record.destPath == nil)
    }

    @Test func testSyncAllRecordsAllItemsUnderOneRunAndGroupsUndo() async throws {
        let store = makeTempHistoryStore(prefix: "SyncHistoryRecordingTest")
        defer { removeHistoryStoreFiles(store) }
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        manager.syncHistoryStore = store
        manager.undoManager = UndoManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/one.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 10], contents: nil)
        mockFM.virtualDisk["/src/two.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 20], contents: nil)

        let d1 = FileDifference(relativePath: "one.txt", leftItemPath: "/src/one.txt", rightItemPath: "/dst/one.txt", type: .missingOnRight, action: .copyToRight, description: "missing", leftFileSize: 10)
        let d2 = FileDifference(relativePath: "two.txt", leftItemPath: "/src/two.txt", rightItemPath: "/dst/two.txt", type: .missingOnRight, action: .copyToRight, description: "missing", leftFileSize: 20)
        manager.rawDifferences = [d1, d2]
        manager.differences = [d1, d2]

        await manager.syncAll(direction: .copyToRight, confirmed: true)

        // Both items recorded, sharing ONE run id, with size carried from the differences.
        #expect(store.records.count == 2)
        #expect(Set(store.records.map(\.runId)).count == 1)
        #expect(store.records.allSatisfy { $0.action == .copy && $0.direction == "→ Right" })
        #expect(Set(store.records.compactMap(\.sizeBytes)) == [10, 20])
        #expect(store.recordsForRun(try #require(store.lastRunId)).count == 2)

        // The whole run is ONE undo step: a single undo removes both copies.
        #expect(mockFM.virtualDisk["/dst/one.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/two.txt"] != nil)
        #expect(manager.undoManager?.canUndo == true)
        manager.undoManager?.undo()
        await waitUntil("one undo reverses the whole bulk run") {
            mockFM.virtualDisk["/dst/one.txt"] == nil && mockFM.virtualDisk["/dst/two.txt"] == nil
        }
    }

    /// **A row's Copy to … sent against its suggestion is recorded the way it went, and its undo
    /// gives back the newer file it overwrote** (review E13). The row suggests left → right; the
    /// user copies it right → left (`redirected(to:)`, what the menu item sends), over the NEWER
    /// left file. Real disk, so the overwritten file goes to a real (scratch) Trash and comes back.
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
