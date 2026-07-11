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
        
        // Assert that the copy was performed, and specifically check if pruneNestedNodes worked
        // If pruning failed, we might have seen redundant copies or errors (though copyItem would throw if dst exists)
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
        // Verify only one trash operation was attempted (for the parent)
        #expect(mockFM.trashedPaths.count == 1)
        #expect(mockFM.trashedPaths.first?.hasSuffix("/parent") == true)
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
        manager.collisionResolver = { _, _, _ in .keepBoth }
        
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
        manager.collisionResolver = { _, _, _ in .replace }
        
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
        manager.collisionResolver = { _, _, _ in .skip }
        
        await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)
        
        // Verify original destination remains and nothing was copied
        let attrs = try mockFM.attributesOfItem(atPath: "/dst/old.txt")
        #expect(attrs[.creationDate] as? Date == Date.distantPast)
    }

    /// Two items in one bulk run must never resolve to the SAME destination. A keep-both
    /// uniquified name ("report 2.txt") can coincide with a DIFFERENT item's real target that the
    /// up-front batch stat saw as missing — `syncAll` resolves every target before the parallel
    /// (concurrency-4) copy phase, so a disk-only `generateUniqueURL` can't see the other pending
    /// target. Both would then write the same path and one worker overwrites the other's file:
    /// silent data loss. Every distinct source must survive under a distinct destination.
    @MainActor
    @Test func testSyncAllKeepBothDoesNotCollideWithAnotherBatchTarget() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        // "report.txt" collides with an existing dst file → keep-both wants "report 2.txt".
        mockFM.virtualDisk["/src/report.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 100], contents: nil)
        mockFM.virtualDisk["/dst/report.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 5], contents: nil)
        // A DIFFERENT source literally named "report 2.txt", missing on dst → its plain target is
        // exactly the name keep-both wants for the first item.
        mockFM.virtualDisk["/src/report 2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 200], contents: nil)

        manager.bulkCollisionResolver = { _, _, _ in (.keepBoth, true) }

        let d1 = FileDifference(relativePath: "report.txt", leftItemPath: "/src/report.txt", rightItemPath: "/dst/report.txt", type: .differentDates, action: .copyToRight, description: "collision")
        let d2 = FileDifference(relativePath: "report 2.txt", leftItemPath: "/src/report 2.txt", rightItemPath: "/dst/report 2.txt", type: .missingOnRight, action: .copyToRight, description: "missing")
        manager.rawDifferences = [d1, d2]
        manager.differences = [d1, d2]

        await manager.syncAll(direction: .copyToRight)

        // Exactly three files in /dst carrying all three distinct payloads — nothing overwritten.
        // Asserted by size (not name) so the exact keep-both suffix doesn't matter.
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
        let provider = CloudProvider(id: "test", displayName: "Test", imageName: "test", path: "/test", type: .iCloud)
        
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
    @Test func testLatestQueuedScanWins() async throws {
        let mockFM = MockFileManager()
        mockFM.enumeratorDelay = 0.05
        let manager = FileSyncManager(fileManager: mockFM)

        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src1"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst1"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src2"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst2"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src2/latest.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let source = CloudProvider(id: "src", displayName: "Source", imageName: "test", path: "/", type: .iCloud)
        let destination = CloudProvider(id: "dst", displayName: "Destination", imageName: "test", path: "/", type: .iCloud)

        let firstScan = Task {
            await manager.scanDirectories(left: source, leftPath: "/src1", right: destination, rightPath: "/dst1")
        }

        try await Task.sleep(nanoseconds: 10_000_000)

        let secondScan = Task {
            await manager.scanDirectories(left: source, leftPath: "/src2", right: destination, rightPath: "/dst2")
        }

        await firstScan.value
        await secondScan.value

        // The queued scan is drained on a fresh task (so it can't inherit a superseded scan's
        // cancellation); wait for it to settle rather than piggybacking on the first task.
        let deadline = Date().addingTimeInterval(5)
        while !(manager.hasScanned && !manager.isScanning && manager.pendingScanRequest == nil), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(manager.hasScanned)
        #expect(!manager.isScanning)
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
        
        // Rollback check: Dest should be restored securely
        // My toughened logic ensures destination is removed before restoration
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
        
        // Verify source is GONE (Directly removed because trash failed)
        #expect(mockFM.virtualDisk["/src/data.bin"] == nil)
        // Verify destination exists
        #expect(mockFM.virtualDisk["/dst/data.bin"] != nil)
    }
}
