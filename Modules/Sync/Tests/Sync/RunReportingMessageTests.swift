import Testing
import Foundation
import Events
@testable import Sync

/// The message an operation posts names the Sync History run it recorded, by id, so Activity's
/// Events draws the message as that run's sentence: never another run's, and none when nothing
/// was recorded. Replaced a 30-second guess that linked a run to whichever message came next.
@MainActor
@Suite struct RunReportingMessageTests {

    private func manager(_ store: SyncHistoryStore, _ fm: MockFileManager) -> FileSyncManager {
        let manager = FileSyncManager(fileManager: fm)
        manager.syncHistoryStore = store
        manager.undoManager = UndoManager()
        return manager
    }

    private func folders(_ fm: MockFileManager, _ paths: String...) throws {
        for path in paths { try fm.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true) }
    }

    private func file(_ fm: MockFileManager, _ path: String, size: Int = 10) {
        fm.virtualDisk[path] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: size], contents: nil)
    }

    /// A pane copy hands its run back through the receipt; the app writes the message from it.
    @Test func aCopyHandsBackTheRunItRecorded() async throws {
        let store = makeTempHistoryStore(prefix: "RunReportingMessageTest")
        defer { removeHistoryStoreFiles(store) }
        let fm = MockFileManager()
        try folders(fm, "/src", "/dst")
        file(fm, "/src/a.txt")
        let manager = manager(store, fm)
        let receipt = SyncRunReceipt()
        await manager.copyItems(nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)], fromLeft: true,
                                leftRoot: "/src", rightRoot: "/dst", fileManager: fm, receipt: receipt)
        let recorded = try #require(store.records.first?.runId)
        #expect(receipt.runId == recorded)
    }

    /// A move to a folder (drag and drop, Cut and Paste) does the same.
    @Test func aMoveToAFolderHandsBackTheRunItRecorded() async throws {
        let store = makeTempHistoryStore(prefix: "RunReportingMessageTest")
        defer { removeHistoryStoreFiles(store) }
        let fm = MockFileManager()
        try folders(fm, "/src", "/dst")
        file(fm, "/src/m.txt")
        let manager = manager(store, fm)
        let receipt = SyncRunReceipt()
        await manager.moveItems(nodes: [FileNode(id: "/src/m.txt", name: "m.txt", isDirectory: false)], toPath: "/dst",
                                fileManager: fm, receipt: receipt)
        #expect(receipt.runId == store.records.first?.runId)
        #expect(receipt.runId != nil)
    }

    /// A copy with no receipt still records its run: handing the id back is optional, recording
    /// is not.
    @Test func aCopyWithNoReceiptStillRecordsItsRun() async throws {
        let store = makeTempHistoryStore(prefix: "RunReportingMessageTest")
        defer { removeHistoryStoreFiles(store) }
        let fm = MockFileManager()
        try folders(fm, "/src", "/dst")
        file(fm, "/src/a.txt")
        let manager = manager(store, fm)
        await manager.copyItems(nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)], fromLeft: true,
                                leftRoot: "/src", rightRoot: "/dst", fileManager: fm)
        #expect(store.records.count == 1)
    }

    /// A transfer that lands nothing records nothing, so its receipt stays empty.
    @Test func aTransferThatLandsNothingHandsBackNoRun() async throws {
        let store = makeTempHistoryStore(prefix: "RunReportingMessageTest")
        defer { removeHistoryStoreFiles(store) }
        let fm = MockFileManager()
        try folders(fm, "/src", "/dst")
        let manager = manager(store, fm)
        let receipt = SyncRunReceipt()
        await manager.copyItems(nodes: [FileNode(id: "/src/gone.txt", name: "gone.txt", isDirectory: false)], fromLeft: true,
                                leftRoot: "/src", rightRoot: "/dst", fileManager: fm, receipt: receipt)
        #expect(store.records.isEmpty)
        #expect(receipt.runId == nil)
    }

    /// A delete's own message reports its run.
    @Test func aDeletesMessageReportsItsRun() async throws {
        let store = makeTempHistoryStore(prefix: "RunReportingMessageTest")
        defer { removeHistoryStoreFiles(store) }
        let fm = MockFileManager()
        try folders(fm, "/dst")
        file(fm, "/dst/gone.txt")
        let manager = manager(store, fm)
        await manager.deleteItems(at: ["/dst/gone.txt"], fileManager: fm)
        let banner = try #require(manager.banner)
        #expect(banner.severity == .success)
        #expect(banner.runId == store.records.first?.runId)
        #expect(banner.runId != nil)
    }

    /// A delete of something already gone records nothing, and its message reports no run.
    @Test func aDeleteThatRemovedNothingReportsNoRun() async throws {
        let store = makeTempHistoryStore(prefix: "RunReportingMessageTest")
        defer { removeHistoryStoreFiles(store) }
        let fm = MockFileManager()
        try folders(fm, "/dst")
        let manager = manager(store, fm)
        await manager.deleteItems(at: ["/dst/never.txt"], fileManager: fm, reportsNothingToDo: true)
        #expect(store.records.isEmpty)
        #expect(manager.banner?.runId == nil)
    }

    /// A bulk sync's message reports its run; a second run's message reports the second, not the first.
    @Test func eachBulkSyncsMessageReportsItsOwnRun() async throws {
        let store = makeTempHistoryStore(prefix: "RunReportingMessageTest")
        defer { removeHistoryStoreFiles(store) }
        let fm = MockFileManager()
        try folders(fm, "/src", "/dst")
        let manager = manager(store, fm)
        func diff(_ name: String) -> FileDifference {
            FileDifference(relativePath: name, leftItemPath: "/src/\(name)", rightItemPath: "/dst/\(name)",
                           type: .missingOnRight, action: .copyToRight, description: "Missing on right", leftFileSize: 10)
        }
        file(fm, "/src/a.txt")
        manager.differences = [diff("a.txt")]
        await manager.syncAll(direction: .copyToRight)
        let first = try #require(manager.banner?.runId)
        #expect(Set(store.records.map(\.runId)) == [first])

        file(fm, "/src/b.txt")
        manager.differences = [diff("b.txt")]
        await manager.syncAll(direction: .copyToRight)
        let second = try #require(manager.banner?.runId)
        #expect(second != first)
        #expect(store.records.last?.runId == second)
    }

    /// A rename records a run and posts no message: the next message is not that run's.
    @Test func aRenamesRunIsNotTheNextMessagesRun() async throws {
        let store = makeTempHistoryStore(prefix: "RunReportingMessageTest")
        defer { removeHistoryStoreFiles(store) }
        let fm = MockFileManager()
        try folders(fm, "/dst")
        file(fm, "/dst/old.txt")
        let manager = manager(store, fm)
        await manager.renameItem(at: "/dst/old.txt", to: "new.txt", fileManager: fm)
        #expect(store.records.count == 1)
        await manager.deleteItems(at: ["/dst/never.txt"], fileManager: fm, reportsNothingToDo: true)
        #expect(manager.banner != nil)
        #expect(manager.banner?.runId == nil, "the rename's run was handed to an unrelated message")
    }
}
