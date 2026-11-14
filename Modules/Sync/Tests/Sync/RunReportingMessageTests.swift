import Testing
import Foundation
import Events
@testable import Sync

/// The message an operation posts names the Sync History run it recorded, by id, so Activity's
/// Events draws the message as that run's sentence: never another run's, and none when nothing
/// was recorded. Replaced a 30-second guess that linked a run to whichever message came next.
@MainActor
@Suite struct RunReportingMessageTests {

    /// A history store, a mock disk holding `folders`, and a manager with ⌘Z over both. The caller
    /// removes the store's files.
    private func world(_ folders: String...) throws
        -> (store: SyncHistoryStore, fm: MockFileManager, manager: FileSyncManager) {
        let store = makeTempHistoryStore(prefix: "RunReportingMessageTest")
        let fm = MockFileManager()
        for path in folders { try fm.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true) }
        let manager = FileSyncManager(fileManager: fm)
        manager.syncHistoryStore = store
        manager.undoManager = UndoManager()
        return (store, fm, manager)
    }

    /// A pane copy hands its run back through the receipt; the app writes the message from it.
    @Test func aCopyHandsBackTheRunItRecorded() async throws {
        let (store, fm, manager) = try world("/src", "/dst")
        defer { removeHistoryStoreFiles(store) }
        fm.virtualDisk["/src/a.txt"] = .file(10)
        let receipt = SyncRunReceipt()
        await manager.copyItems(nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)], fromLeft: true,
                                leftRoot: "/src", rightRoot: "/dst", fileManager: fm, receipt: receipt)
        let recorded = try #require(store.records.first?.runId)
        #expect(receipt.runId == recorded)
    }

    /// A move to a folder (drag and drop, Cut and Paste) does the same.
    @Test func aMoveToAFolderHandsBackTheRunItRecorded() async throws {
        let (store, fm, manager) = try world("/src", "/dst")
        defer { removeHistoryStoreFiles(store) }
        fm.virtualDisk["/src/m.txt"] = .file(10)
        let receipt = SyncRunReceipt()
        await manager.moveItems(nodes: [FileNode(id: "/src/m.txt", name: "m.txt", isDirectory: false)], toPath: "/dst",
                                fileManager: fm, receipt: receipt)
        #expect(receipt.runId == store.records.first?.runId)
        #expect(receipt.runId != nil)
    }

    /// A transfer that lands nothing records nothing, so its receipt stays empty.
    @Test func aTransferThatLandsNothingHandsBackNoRun() async throws {
        let (store, fm, manager) = try world("/src", "/dst")
        defer { removeHistoryStoreFiles(store) }
        let receipt = SyncRunReceipt()
        await manager.copyItems(nodes: [FileNode(id: "/src/gone.txt", name: "gone.txt", isDirectory: false)], fromLeft: true,
                                leftRoot: "/src", rightRoot: "/dst", fileManager: fm, receipt: receipt)
        #expect(store.records.isEmpty)
        #expect(receipt.runId == nil)
    }

    /// A delete reports its run in its own message and hands it back in its outcome, for
    /// Duplicates, whose "Reclaimed 1.2 MB" replaces the delete's message and must still report it.
    @Test func aDeleteReportsItsRunInItsMessageAndItsOutcome() async throws {
        let (store, fm, manager) = try world("/dst")
        defer { removeHistoryStoreFiles(store) }
        fm.virtualDisk["/dst/gone.txt"] = .file(10)
        let outcome = await manager.deleteItems(at: ["/dst/gone.txt"], fileManager: fm)
        let banner = try #require(manager.banner)
        #expect(banner.severity == .success)
        #expect(banner.runId != nil)
        #expect(banner.runId == store.records.first?.runId)
        #expect(outcome.runId == banner.runId)
        let nothing = await manager.deleteItems(at: ["/dst/never.txt"], fileManager: fm)
        #expect(nothing.runId == nil)
    }

    /// A Duplicates merge trashes the folded copy through `deleteItems`, which records a run and
    /// says "Moved 1 item…"; the merge's own "Merged …" replaces that message, so it must report
    /// the run in its place, or Events shows the run under the trash's sentence and the merge as a
    /// row of its own. A real file manager (the merge hashes real bytes) on a Trash-less volume, so
    /// nothing reaches the real Trash.
    @Test func aMergesMessageReportsTheRunItsTrashRecorded() async throws {
        let store = makeTempHistoryStore(prefix: "RunReportingMessageTest")
        defer { removeHistoryStoreFiles(store) }
        let base = try makeCanonicalTempRoot(prefix: "RunReportingMerge")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper"), redundant = base.appendingPathComponent("Copy")
        try writeBytes(keeper.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        try writeBytes(redundant.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        try writeBytes(redundant.appendingPathComponent("unique.txt"), bytes: 4000, fill: 0x55)
        let k = DuplicateCopy.stub(keeper.path, keeper: true, isDirectory: true, size: 4000)
        let r = DuplicateCopy.stub(redundant.path, keeper: false, isDirectory: true, size: 8000, itemCount: 2, unique: 1)
        let group = DuplicateGroup.stub([k, r], matchType: .overlapping(sharedFraction: 0.5), reclaimable: 4000)

        let manager = FileSyncManager(fileManager: TrashRefusingVolume())
        manager.syncHistoryStore = store
        manager.undoManager = UndoManager()
        manager.permanentDeleteConfirmer = { _ in true }
        manager.duplicateGroups = [group]

        #expect(await manager.mergeDuplicateGroup(group) == true)
        let banner = try #require(manager.banner)
        #expect(banner.message.hasPrefix("Merged “"), "\(banner.message)")
        let trashRun = try #require(store.records.first(where: { $0.action == .delete })?.runId,
                                    "the merge's trash recorded no run, so there is nothing to report")
        #expect(banner.runId == trashRun)
    }

    /// A bulk sync's message reports its run; a second run's message reports the second, not the first.
    @Test func eachBulkSyncsMessageReportsItsOwnRun() async throws {
        let (store, fm, manager) = try world("/src", "/dst")
        defer { removeHistoryStoreFiles(store) }
        func diff(_ name: String) -> FileDifference {
            FileDifference(relativePath: name, leftItemPath: "/src/\(name)", rightItemPath: "/dst/\(name)",
                           type: .missingOnRight, action: .copyToRight, description: "Missing on right", leftFileSize: 10)
        }
        fm.virtualDisk["/src/a.txt"] = .file(10)
        manager.differences = [diff("a.txt")]
        await manager.syncAll(direction: .copyToRight)
        let first = try #require(manager.banner?.runId)
        #expect(Set(store.records.map(\.runId)) == [first])

        fm.virtualDisk["/src/b.txt"] = .file(10)
        manager.differences = [diff("b.txt")]
        await manager.syncAll(direction: .copyToRight)
        let second = try #require(manager.banner?.runId)
        #expect(second != first)
        #expect(store.records.last?.runId == second)
    }

    /// Copy Remaining reports its run when it ran one direction, and none when it ran two: a
    /// message can lead one run's row, not two.
    @Test func copyRemainingReportsARunOnlyForOneDirection() async throws {
        let (store, fm, manager) = try world("/L", "/R")
        defer { removeHistoryStoreFiles(store) }
        func toRight(_ name: String) -> FileDifference {
            FileDifference(relativePath: name, leftItemPath: "/L/\(name)", rightItemPath: "/R/\(name)",
                           type: .missingOnRight, action: .copyToRight, description: "Missing on right", leftFileSize: 10)
        }
        func toLeft(_ name: String) -> FileDifference {
            FileDifference(relativePath: name, leftItemPath: "/L/\(name)", rightItemPath: "/R/\(name)",
                           type: .missingOnLeft, action: .copyToLeft, description: "Missing on left", rightFileSize: 10)
        }
        fm.virtualDisk["/L/a.txt"] = .file(10)
        let one = [toRight("a.txt")]
        manager.differences = one
        await manager.copyRemaining(one, isMove: false)
        let reported = try #require(manager.banner?.runId)
        #expect(store.records.last?.runId == reported)

        fm.virtualDisk["/L/b.txt"] = .file(10)
        fm.virtualDisk["/R/c.txt"] = .file(10)
        let two = [toRight("b.txt"), toLeft("c.txt")]
        manager.differences = two
        await manager.copyRemaining(two, isMove: false)
        #expect(Set(store.records.map(\.runId)).count == 3, "two directions are two runs")
        #expect(manager.banner?.runId == nil, "a message reported one of two runs")
    }
}
