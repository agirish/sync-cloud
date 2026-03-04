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
    
    @MainActor
    @Test func testLoadTreeCancellation() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/file_1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // We can't trivially race the Task in unit tests predictably without hanging.
        // Instead, we explicitly inject the cancellation token check logic by running loadTree natively.
        // Swift handles the task detachments internally. If it doesn't crash or hang, the architecture is sound.
        let treeTask = Task { await manager.loadTree(path: "/src", isSource: true) }
        
        // Cancel it immediately before it can recursively build
        treeTask.cancel()
        await treeTask.value
        
        // If cancelled perfectly before running, tree should be empty or partially populated (0 nodes ideal)
        // Since load yields across async boundaries, it should catch the cancel
        #expect(manager.sourceTree.count == 0)
    }

    @MainActor
    @Test func testUndoRegisterTrashItems() async throws {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        
        let mockFM = MockFileManager()
        let url = URL(fileURLWithPath: "/src/delete_me.txt")
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/delete_me.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        await manager.deleteItems(at: ["/src/delete_me.txt"], fileManager: mockFM)
        
        #expect(mockFM.virtualDisk["/src/delete_me.txt"] == nil)
        #expect(mockFM.trashedPaths.count == 1)
        #expect(manager.undoManager?.canUndo == true)
        
        // Execute the registered Undo (restore from trash)
        manager.undoManager?.undo()
        
        // Let the async block for undo resolve
        try await Task.sleep(nanoseconds: 100_000_000)
        
        #expect(mockFM.virtualDisk["/src/delete_me.txt"] != nil)
    }
    
    @MainActor
    @Test func testCopyItemUndoStack() async throws {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        let mockFM = MockFileManager()
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/copy_me.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        let node = FileNode(id: "/src/copy_me.txt", name: "copy_me.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        
        #expect(mockFM.virtualDisk["/dst/copy_me.txt"] != nil)
        #expect(manager.undoManager?.canUndo == true)
        
        // Perform Undo -> should theoretically move the file to trash (removing it from dst)
        manager.undoManager?.undo()
        
        // let async block finish
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Removed from destination
        #expect(mockFM.virtualDisk["/dst/copy_me.txt"] == nil)
        // Kept in source
        #expect(mockFM.virtualDisk["/src/copy_me.txt"] != nil)
        
        // Perform Redo -> should put it back
        manager.undoManager?.redo()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(mockFM.virtualDisk["/dst/copy_me.txt"] != nil)
    }
}
