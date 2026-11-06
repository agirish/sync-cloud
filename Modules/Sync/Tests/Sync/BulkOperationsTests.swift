import Testing
import Foundation
@testable import Sync

@Suite struct BulkOperationsTests {
    
    @MainActor
    @Test func testBulkCopyPruning() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        
        // Setup Source: /src/folder containing /src/folder/file.txt
        mockFM.virtualDisk["/src/folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["file.txt"])
        mockFM.virtualDisk["/src/folder/file.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        let folderNode = FileNode(id: "/src/folder", name: "folder", isDirectory: true, children: [
            FileNode(id: "/src/folder/file.txt", name: "file.txt", isDirectory: false)
        ])
        let fileNode = FileNode(id: "/src/folder/file.txt", name: "file.txt", isDirectory: false)
        
        // User selects BOTH the folder and the file inside it
        let selection = [folderNode, fileNode]
        
        await manager.copyItems(nodes: selection, fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)
        
        // The copy landed with no error: without `pruneNestedNodes` the nested file would be
        // copied twice, and the second copy could fail on the first.
        #expect(mockFM.virtualDisk["/dst/folder/file.txt"] != nil)
        #expect(manager.currentError == nil)
    }
    
    @MainActor
    @Test func testBulkDeleteNestedPaths() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        
        mockFM.virtualDisk["/src/parent"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["child.txt"])
        mockFM.virtualDisk["/src/parent/child.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // Select both parent and child for deletion
        let pathsToDelete = ["/src/parent", "/src/parent/child.txt"]
        
        await manager.deleteItems(at: pathsToDelete, fileManager: mockFM)
        
        // Verify everything is gone
        #expect(mockFM.virtualDisk["/src/parent"] == nil)
        #expect(mockFM.virtualDisk["/src/parent/child.txt"] == nil)
        
        // Verify only one trash operation was attempted (for the parent)
        #expect(mockFM.trashedPaths.count == 1)
        #expect(mockFM.trashedPaths.first?.hasSuffix("/parent") == true)
    }

    /// `deleteItems` returns the count actually removed, a pruned nested family counting once via
    /// its ancestor. Callers compare it with what they asked for to tell partial success from full,
    /// so double-counting a child would make a partial batch read as complete.
    @MainActor
    @Test func testDeleteItemsCountsAPrunedFamilyOnce() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        mockFM.virtualDisk["/src/parent"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["child.txt"])
        mockFM.virtualDisk["/src/parent/child.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/solo.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let removed = await manager.deleteItems(
            at: ["/src/parent", "/src/parent/child.txt", "/src/solo.txt"], fileManager: mockFM).removed

        #expect(removed == 2, "parent+child count once via the ancestor; solo counts on its own")
        #expect(mockFM.virtualDisk["/src/parent"] == nil)
        #expect(mockFM.virtualDisk["/src/solo.txt"] == nil)

        // And a delete where nothing leaves the disk reports zero, not the request size.
        mockFM.shouldFailTrash = true                       // Trash-less volume…
        mockFM.virtualDisk["/src/stuck.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let stuck = await manager.deleteItems(at: ["/src/stuck.txt"], fileManager: mockFM).removed
        #expect(stuck == 0, "…and the permanent-delete fallback was declined")
        #expect(mockFM.virtualDisk["/src/stuck.txt"] != nil)
    }

    /// The delete prune must only drop real descendants: a path that merely starts with another
    /// path's characters (no "/" boundary) is a sibling and must still be deleted.
    @MainActor
    @Test func testBulkDeleteKeepsStringPrefixSiblings() async throws {
        let manager = FileSyncManager()
        manager.permanentDeleteConfirmer = { _ in false }
        let mockFM = MockFileManager()

        mockFM.virtualDisk["/src/report"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: [])
        mockFM.virtualDisk["/src/report copy.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        await manager.deleteItems(at: ["/src/report", "/src/report copy.txt"], fileManager: mockFM)

        #expect(mockFM.virtualDisk["/src/report"] == nil)
        #expect(mockFM.virtualDisk["/src/report copy.txt"] == nil)
        #expect(mockFM.trashedPaths.count == 2)
    }
    
    @MainActor
    @Test func testCollisionResolutionKeepBoth() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/report.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/report.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil) // Already exists
        
        let node = FileNode(id: "/src/report.pdf", name: "report.pdf", isDirectory: false)
        
        // Mock resolver to always "Keep Both"
        manager.collisionResolver = { _ in .keepBoth }
        
        await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)
        
        // Verify both exist at destination (original and unique one)
        #expect(mockFM.virtualDisk["/dst/report.pdf"] != nil)
        #expect(mockFM.virtualDisk["/dst/report 2.pdf"] != nil)
    }
    
    @MainActor
    @Test func testCollisionResolutionReplace() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/data.csv"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/dst/data.csv"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 50], contents: nil)
        
        let node = FileNode(id: "/src/data.csv", name: "data.csv", isDirectory: false)
        
        // Mock resolver to "Replace"
        manager.collisionResolver = { _ in .replace }
        
        await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)
        
        // Verify replaced (size should match source)
        let attrs = try mockFM.attributesOfItem(atPath: "/dst/data.csv")
        #expect(attrs[.size] as? Int == 100)
    }

    @MainActor
    @Test func testCollisionResolutionSkip() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/old.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/old.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.creationDate: Date.distantPast], contents: nil)
        
        let node = FileNode(id: "/src/old.txt", name: "old.txt", isDirectory: false)
        
        // Mock resolver to "Skip"
        manager.collisionResolver = { _ in .skip }
        
        await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)
        
        // Verify original destination remains and nothing was copied
        let attrs = try mockFM.attributesOfItem(atPath: "/dst/old.txt")
        #expect(attrs[.creationDate] as? Date == Date.distantPast)
    }

    /// Two items in one bulk run never resolve to the same destination. `syncAll` resolves every
    /// target before its parallel copy phase, so a keep-both name ("report 2.txt") found free on
    /// disk can be another item's pending target, and one worker would overwrite the other's file:
    /// silent data loss. Every distinct source must land at a distinct destination.
    @MainActor
    @Test func testSyncAllKeepBothDoesNotCollideWithAnotherBatchTarget() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        // "report.txt" collides with an existing dst file → keep-both wants "report 2.txt".
        mockFM.virtualDisk["/src/report.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 100], contents: nil)
        mockFM.virtualDisk["/dst/report.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 5], contents: nil)
        // A different source named "report 2.txt", missing on dst: its target is the name keep-both
        // wants for the first item.
        mockFM.virtualDisk["/src/report 2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 200], contents: nil)

        manager.bulkCollisionResolver = { _ in (.keepBoth, true) }

        let d1 = FileDifference(relativePath: "report.txt", leftItemPath: "/src/report.txt", rightItemPath: "/dst/report.txt", type: .differentDates, action: .copyToRight, description: "collision")
        let d2 = FileDifference(relativePath: "report 2.txt", leftItemPath: "/src/report 2.txt", rightItemPath: "/dst/report 2.txt", type: .missingOnRight, action: .copyToRight, description: "missing")
        manager.rawDifferences = [d1, d2]
        manager.differences = [d1, d2]

        await manager.syncAll(direction: .copyToRight)

        // Three files in /dst with all three payloads, nothing overwritten. By size, not name, so
        // the keep-both suffix doesn't matter.
        let dstSizes = mockFM.virtualDisk
            .filter { $0.key.hasPrefix("/dst/") }
            .compactMap { $0.value.attributes?[.size] as? Int }
            .sorted()
        #expect(dstSizes == [5, 100, 200])
        #expect(manager.currentError == nil)
    }

    @MainActor
    @Test func testConcurrentScanProtection() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let provider = CloudProvider(id: "test", displayName: "Test", imageName: "test", rootPath: "/test", type: .iCloud)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/test"), withIntermediateDirectories: true)
        
        // Start first refresh
        let firstRefresh = Task {
            await manager.refreshTreesAndScan(left: provider, right: provider)
        }
        
        // Immediately start second refresh - should cancel the first
        let secondRefresh = Task {
            await manager.refreshTreesAndScan(left: provider, right: provider)
        }
        
        await firstRefresh.value
        await secondRefresh.value
        
        #expect(manager.isScanning == false)
        #expect(manager.hasScanned == true)
    }

    @MainActor
    @Test(.parksAThread) func testLatestQueuedScanWins() async throws {
        let mockFM = MockFileManager()
        // The first scan's walk parks here until released, so it holds the scan slot as long as
        // the test needs. A delay gives only a window, which a loaded run can miss, and then the
        // second request runs inline and the queue goes unexercised.
        let gate = ParkGate()
        mockFM.enumeratorGate = gate
        let manager = FileSyncManager(fileManager: mockFM)

        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src1"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst1"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src2"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst2"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src2/latest.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let source = CloudProvider(id: "src", displayName: "Source", imageName: "test", rootPath: "/", type: .iCloud)
        let destination = CloudProvider(id: "dst", displayName: "Destination", imageName: "test", rootPath: "/", type: .iCloud)

        let firstScan = Task {
            await manager.scanDirectories(left: source, leftPath: "/src1", right: destination, rightPath: "/dst1")
        }

        // The second request must arrive while the first scan holds the slot. `executeScan` sets
        // `isScanning` synchronously, before the walk parked at the gate, so this is asserted, not
        // waited for. Without it the scans could run in sequence and every assertion still pass.
        await awaitSignal(gate.entered, "the first scan never reached its walk — nothing held the slot")
        #expect(manager.isScanning, "the first scan is parked in its walk but does not hold the scan slot")

        // Queued, not run: `runOrQueueScan` returns without scanning, so no Task is needed and the
        // pending request is visible at once. Asserted so a free slot can't turn this into a test
        // of sequential scans.
        await manager.scanDirectories(left: source, leftPath: "/src2", right: destination, rightPath: "/dst2")
        #expect(manager.pendingScanRequest != nil, "the second request must queue behind the in-flight scan")

        gate.release.signal()
        await firstScan.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the first scan was never actually held in flight")

        // The queued scan drains on a fresh task (so it can't inherit a superseded scan's
        // cancellation), so wait for it to settle. All three clauses count: the drained scan is
        // done only once nothing is left pending.
        await waitUntil("the drained scan settles") {
            manager.hasScanned && !manager.isScanning && manager.pendingScanRequest == nil
        }

        #expect(manager.differences.count == 1)
        #expect(manager.differences.first?.relativePath == "latest.txt")
    }

    @Test func testSafeMoveItemRollbackHardened() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        let srcURL = URL(fileURLWithPath: "/src/data.bin")
        let dstURL = URL(fileURLWithPath: "/dst/data.bin")
        
        // Force the fallback temp copy to fail during the final rename
        mockFM.shouldFailMoveOnTempRename = true
        // Force the moveItem to fail to trigger EXDEV fallback
        mockFM.shouldFailMove = true
        
        do {
            try FileSyncManager.safeMoveItem(at: srcURL, to: dstURL, fileManager: mockFM)
            Issue.record("Expected safeMoveItem to throw")
        } catch {
            // Expected
        }
        
        // Rollback: the destination is restored and the source is left in place.
        #expect(mockFM.virtualDisk["/dst/data.bin"] != nil)
        #expect(mockFM.virtualDisk["/src/data.bin"] != nil)
    }

    @MainActor
    @Test func testCrossVolumeMoveCleanupWithoutTrashSupport() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        let srcURL = URL(fileURLWithPath: "/src/data.bin")
        let dstURL = URL(fileURLWithPath: "/dst/data.bin")
        
        // Force cross-volume fallback
        mockFM.shouldFailMove = true
        // Disable trash support
        mockFM.shouldFailTrash = true
        
        try FileSyncManager.safeMoveItem(at: srcURL, to: dstURL, fileManager: mockFM)
        
        // The source is gone: removed directly, since the Trash failed.
        #expect(mockFM.virtualDisk["/src/data.bin"] == nil)
        // Verify destination exists
        #expect(mockFM.virtualDisk["/dst/data.bin"] != nil)
    }
}
