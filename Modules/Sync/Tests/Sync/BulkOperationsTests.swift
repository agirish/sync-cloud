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
        
        await manager.copyItems(nodes: selection, fromSource: true, sourceRoot: "/src", destinationRoot: "/dst", fileManager: mockFM)
        
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
        manager.collisionResolver = { _, _ in .keepBoth }
        
        await manager.copyItems(nodes: [node], fromSource: true, sourceRoot: "/src", destinationRoot: "/dst", fileManager: mockFM)
        
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
        manager.collisionResolver = { _, _ in .replace }
        
        await manager.copyItems(nodes: [node], fromSource: true, sourceRoot: "/src", destinationRoot: "/dst", fileManager: mockFM)
        
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
        manager.collisionResolver = { _, _ in .skip }
        
        await manager.copyItems(nodes: [node], fromSource: true, sourceRoot: "/src", destinationRoot: "/dst", fileManager: mockFM)
        
        // Verify original destination remains and nothing was copied
        let attrs = try mockFM.attributesOfItem(atPath: "/dst/old.txt")
        #expect(attrs[.creationDate] as? Date == Date.distantPast)
    }
}
