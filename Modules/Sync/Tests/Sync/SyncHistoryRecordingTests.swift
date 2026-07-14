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

    private func makeStore() -> SyncHistoryStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncHistoryRecordingTest-\(UUID().uuidString).jsonl")
        return SyncHistoryStore(fileURL: url)
    }

    @Test func testCopyItemsRecordsACopyWithPaneDirection() async throws {
        let store = makeStore()
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
        let store = makeStore()
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
        let store = makeStore()
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
        let store = makeStore()
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

    /// Polls a main-actor condition until it holds or the timeout expires.
    @MainActor
    private func waitUntil(_ what: Comment, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition(), what)
    }
}
