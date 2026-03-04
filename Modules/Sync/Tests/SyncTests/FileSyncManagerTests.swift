import Testing
import Foundation
@testable import Sync

@Suite struct FileSyncManagerTests {
    
    @MainActor
    @Test func testPruneSelection() async throws {
        let manager = FileSyncManager()
        
        // Setup initial trees
        let node1 = FileNode(id: "/src/file1.txt", name: "file1.txt", isDirectory: false)
        let node2 = FileNode(id: "/src/file2.txt", name: "file2.txt", isDirectory: false)
        manager.sourceTree = [node1, node2]
        
        // Select both
        manager.selectedSourcePaths = ["/src/file1.txt", "/src/file2.txt"]
        
        // Simulate removal of file2.txt from tree
        manager.sourceTree = [node1]
        
        // Prune
        manager.pruneSelection()
        
        // Verify file2.txt is removed from selection, but file1.txt remains
        #expect(manager.selectedSourcePaths.count == 1)
        #expect(manager.selectedSourcePaths.contains("/src/file1.txt"))
        #expect(!manager.selectedSourcePaths.contains("/src/file2.txt"))
    }
    
    @MainActor
    @Test func testPruneSelectionRecursive() async throws {
        let manager = FileSyncManager()
        
        let subNode = FileNode(id: "/src/folder/sub.txt", name: "sub.txt", isDirectory: false)
        let folderNode = FileNode(id: "/src/folder", name: "folder", isDirectory: true, children: [subNode])
        manager.sourceTree = [folderNode]
        
        manager.selectedSourcePaths = ["/src/folder", "/src/folder/sub.txt"]
        
        // Remove only the subfile
        let emptyFolderNode = FileNode(id: "/src/folder", name: "folder", isDirectory: true, children: [])
        manager.sourceTree = [emptyFolderNode]
        
        manager.pruneSelection()
        
        #expect(manager.selectedSourcePaths.count == 1)
        #expect(manager.selectedSourcePaths.contains("/src/folder"))
        #expect(!manager.selectedSourcePaths.contains("/src/folder/sub.txt"))
    }
}
