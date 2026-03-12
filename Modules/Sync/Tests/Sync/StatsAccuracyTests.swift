import Testing
import Foundation
@testable import Sync

@Suite struct StatsAccuracyTests {
    
    @MainActor
    @Test func testItemCountsWithNesting() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        // Setup nested structure:
        // /root (dir)
        //   /root/file1 (file)
        //   /root/subDir (dir)
        //     /root/subDir/file2 (file)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/file1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/subDir"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/subDir/file2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // Load the tree
        await manager.loadTree(path: "/src", isLeft: true)
        
        // Verification:
        // root/file1, root/subDir, root/subDir/file2 -> 3 items (excluding root itself as per buildTree logic)
        // Wait, buildNode logic for children returns nodes.
        // Let's check buildTree(url: rootURL)
        // It gets contents of /src, then builds nodes for each.
        // Contents of /src: [file1.txt, subDir]
        // Node for file1.txt: 1 item
        // Node for subDir: 1 item + 1 child (file2.txt) = 2 items
        // Total = 3
        
        #expect(manager.leftItemCount == 3)
    }
    
    @MainActor
    @Test func testDifferenceCountAccuracy() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", path: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", path: "/dst", type: .iCloud)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        // 1 missing in destination
        mockFM.virtualDisk["/src/only_in_src.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // 1 different (modification date)
        let now = Date()
        let later = now.addingTimeInterval(3600)
        mockFM.virtualDisk["/src/diff_date.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: now], contents: nil)
        mockFM.virtualDisk["/dst/diff_date.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: later], contents: nil)
        
        // 1 same
        mockFM.virtualDisk["/src/same.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: now], contents: nil)
        mockFM.virtualDisk["/dst/same.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: now], contents: nil)
        
        // Scan
        await manager.scanDirectories(source: srcProvider, sourcePath: "/src", destination: dstProvider, destinationPath: "/dst")
        
        // Should have 2 differences
        #expect(manager.differences.count == 2)
    }
    
    @MainActor
    @Test func testHiddenFilesStatsToggle() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/.hidden"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/visible.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // 1. Default (Hidden files skipped)
        manager.showHiddenFiles = false
        await manager.loadTree(path: "/src", isLeft: true)
        #expect(manager.leftItemCount == 1)
        
        // 2. Show Hidden enabled
        manager.showHiddenFiles = true
        await manager.loadTree(path: "/src", isLeft: true)
        #expect(manager.leftItemCount == 2)
    }
    
    @MainActor
    @Test func testEmptyDirectoryStats() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        
        await manager.loadTree(path: "/src", isLeft: true)
        
        #expect(manager.leftItemCount == 0)
        #expect(manager.leftTree.isEmpty)
    }
}
