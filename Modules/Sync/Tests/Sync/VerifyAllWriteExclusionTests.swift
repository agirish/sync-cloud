import Testing
import Foundation
@testable import Sync

/// Pins Verify All's exclusion guard in the WRITE direction: Verify All refuses to start
/// while anything is writing, but a write starting MID-verify could still overwrite a file
/// as it's hashed — the pair can read "identical" against bytes that no longer exist,
/// poisoning the copy-to-match-dates offer. `syncFile` and the copy/move entry points
/// (`transferItems`) must refuse with a visible banner while the verify run is in flight,
/// and proceed normally once it's done.
@Suite struct VerifyAllWriteExclusionTests {

    @MainActor
    private func makeFixture() throws -> (FileSyncManager, MockFileManager) {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        return (manager, mockFM)
    }

    @MainActor
    @Test func syncFileRefusedWhileVerifyAllInFlight() async throws {
        let (manager, mockFM) = try makeFixture()
        let diff = FileDifference(
            relativePath: "f.txt",
            leftItemPath: "/src/f.txt",
            rightItemPath: "/dst/f.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "test"
        )

        manager.isVerifyAllRunning = true
        let ran = await manager.syncFile(diff, fileManager: mockFM)

        #expect(ran == false)
        // (Field comparison — banner equality includes a per-publish id.)
        #expect(manager.banner?.message == "Wait for Verify All to finish before syncing")
        #expect(manager.banner?.severity == .warning)
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
        // The refusal happens before the row is marked and must not leak an in-flight id
        // (a leaked id would refuse Verify All and pane swaps for the session).
        #expect(manager.syncingDifferenceIds.isEmpty)
        // The refusal path must not reset the running run's flag.
        #expect(manager.isVerifyAllRunning)

        // With the verify run finished, the identical call goes through.
        manager.isVerifyAllRunning = false
        manager.banner = nil
        let ranAfter = await manager.syncFile(diff, fileManager: mockFM)
        #expect(ranAfter)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
    }

    @MainActor
    @Test func copyItemsRefusedWhileVerifyAllInFlight() async throws {
        let (manager, mockFM) = try makeFixture()
        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)

        manager.isVerifyAllRunning = true
        let transferred = await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)

        #expect(transferred.isEmpty)
        #expect(manager.banner?.message == "Wait for Verify All to finish before copying or moving items")
        #expect(manager.banner?.severity == .warning)
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
        // The guard fires before the operation pre-count latches — a refusal must not leave
        // a phantom in-flight operation that would refuse the NEXT Verify All forever.
        #expect(manager.activeFileOperationsCount == 0)
        #expect(manager.isVerifyAllRunning)

        // With the verify run finished, the identical call goes through.
        manager.isVerifyAllRunning = false
        manager.banner = nil
        let transferredAfter = await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(transferredAfter.count == 1)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
    }

    @MainActor
    @Test func moveItemsRefusedWhileVerifyAllInFlight() async throws {
        let (manager, mockFM) = try makeFixture()
        let node = FileNode(id: "/src/f.txt", name: "f.txt", isDirectory: false)

        manager.isVerifyAllRunning = true
        let transferred = await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)

        #expect(transferred.isEmpty)
        #expect(manager.banner?.message == "Wait for Verify All to finish before copying or moving items")
        #expect(manager.banner?.severity == .warning)
        // A refused move must leave the source exactly where it was.
        #expect(mockFM.virtualDisk["/src/f.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
        #expect(manager.activeFileOperationsCount == 0)
        manager.isVerifyAllRunning = false
    }

    @MainActor
    @Test func deleteItemsRefusedWhileVerifyAllInFlight() async throws {
        let (manager, mockFM) = try makeFixture()

        manager.isVerifyAllRunning = true
        let removed = await manager.deleteItems(at: ["/src/f.txt"], fileManager: mockFM)

        #expect(removed == 0)
        #expect(manager.banner?.message == "Wait for Verify All to finish before deleting items")
        #expect(manager.banner?.severity == .warning)
        #expect(mockFM.virtualDisk["/src/f.txt"] != nil, "nothing may leave the disk mid-verify")
        #expect(mockFM.trashedPaths.isEmpty)
        #expect(manager.isVerifyAllRunning)

        // With the verify run finished, the identical call goes through.
        manager.isVerifyAllRunning = false
        manager.banner = nil
        let removedAfter = await manager.deleteItems(at: ["/src/f.txt"], fileManager: mockFM)
        #expect(removedAfter == 1)
        #expect(mockFM.virtualDisk["/src/f.txt"] == nil)
    }

    @MainActor
    @Test func mergeDuplicateGroupRefusedWhileVerifyAllInFlight() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        // Both folders on disk — only the verify run blocks the merge.
        mockFM.virtualDisk["/base/K"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["kfile"])
        mockFM.virtualDisk["/base/K/kfile"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 5000], contents: nil)
        mockFM.virtualDisk["/base/R"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["rfile"])
        mockFM.virtualDisk["/base/R/rfile"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 5000], contents: nil)
        let k = DuplicateCopy(id: "/base/K", name: "K", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 1, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: "/base/R", name: "R", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 1, depth: 1, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: "K",
                                   isDirectory: true, copies: [k, r], reclaimableBytes: 2500)
        manager.duplicateGroups = [group]

        manager.isVerifyAllRunning = true
        let ok = await manager.mergeDuplicateGroup(group)

        #expect(ok == false)
        #expect(manager.banner?.message == "Wait for Verify All to finish before merging duplicates")
        #expect(manager.banner?.severity == .warning)
        // The merge copies into the keeper while Verify All may be hashing it — nothing may move.
        #expect(mockFM.virtualDisk["/base/K/rfile"] == nil)
        #expect(mockFM.virtualDisk["/base/R"] != nil)
        #expect(manager.duplicateGroups.count == 1)
        manager.isVerifyAllRunning = false
    }

    @MainActor
    @Test func applyFilingSuggestionRefusedWhileVerifyAllInFlight() async throws {
        let (manager, mockFM) = try makeFixture()
        let s = FilingSuggestion(filePath: "/src/f.txt", fileName: "f.txt", size: 1,
                                 modificationDate: nil, candidates: [])
        let dest = FilingDestination(path: "/dst", confidence: .high, reasons: [], newSegments: [])
        manager.filingSuggestions = [s]

        manager.isVerifyAllRunning = true
        let ok = await manager.applyFilingSuggestion(s, to: dest)

        #expect(ok == false)
        #expect(manager.banner?.message == "Wait for Verify All to finish before filing")
        #expect(manager.banner?.severity == .warning)
        #expect(mockFM.virtualDisk["/src/f.txt"] != nil, "the file must stay put mid-verify")
        #expect(manager.filingSuggestions.count == 1, "a refused filing must not vanish the card")
        manager.isVerifyAllRunning = false
    }

    @MainActor
    @Test func applyRecommendedFilingRefusedWhileVerifyAllInFlight() async throws {
        let (manager, mockFM) = try makeFixture()
        let dest = FilingDestination(path: "/dst", confidence: .high, reasons: [], newSegments: [])
        let s = FilingSuggestion(filePath: "/src/f.txt", fileName: "f.txt", size: 1,
                                 modificationDate: nil, candidates: [dest])
        manager.filingSuggestions = [s]

        manager.isVerifyAllRunning = true
        await manager.applyRecommendedFiling()

        #expect(manager.banner?.message == "Wait for Verify All to finish before filing")
        #expect(manager.banner?.severity == .warning)
        #expect(mockFM.virtualDisk["/src/f.txt"] != nil, "the batch must not move files mid-verify")
        #expect(manager.filingSuggestions.count == 1)
        manager.isVerifyAllRunning = false
    }
}
