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
        #expect(mockFM.virtualDisk["/src/parent/child.txt"] == nil)
        #expect(mockFM.virtualDisk["/src/solo.txt"] == nil)
        // One trash for the family (the parent), one for solo: the child is never trashed alone.
        #expect(mockFM.trashedPaths.count == 2)
        #expect(mockFM.trashedPaths.first?.hasSuffix("/parent") == true)

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
    @Test(arguments: [CollisionResolution.keepBoth, .replace, .skip])
    func testCollisionResolution(_ resolution: CollisionResolution) async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()

        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        mockFM.virtualDisk["/src/data.csv"] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        mockFM.virtualDisk["/dst/data.csv"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [FileAttributeKey.size: 50, FileAttributeKey.creationDate: Date.distantPast], contents: nil) // Already exists

        let node = FileNode(id: "/src/data.csv", name: "data.csv", isDirectory: false)
        manager.collisionResolver = { _ in resolution }

        await manager.copyItems(nodes: [node], fromLeft: true, leftRoot: "/src", rightRoot: "/dst", fileManager: mockFM)

        let attrs = try mockFM.attributesOfItem(atPath: "/dst/data.csv")
        switch resolution {
        case .keepBoth:
            // Both exist at the destination: the original and a unique one.
            #expect(mockFM.virtualDisk["/dst/data.csv"] != nil)
            #expect(mockFM.virtualDisk["/dst/data 2.csv"] != nil)
        case .replace:
            // Replaced: the size matches the source.
            #expect(attrs[.size] as? Int == 100)
        case .skip:
            // The original destination remains and nothing was copied or trashed.
            #expect(attrs[.creationDate] as? Date == Date.distantPast)
            #expect(mockFM.trashedPaths.isEmpty)
        case .merge:
            Issue.record("not a case of this test")
        }
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
