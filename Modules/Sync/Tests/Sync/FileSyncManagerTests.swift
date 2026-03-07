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
    
    @MainActor
    @Test func testActiveOperationTracking() async throws {
        let manager = FileSyncManager()
        #expect(manager.activeFileOperationsCount == 0)
        
        // Use a task that sleeps to simulate a long operation
        let operationTask = Task {
            await manager.enqueueFileOperation {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        
        // Wait a bit for the operation to start and increment the count
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(manager.activeFileOperationsCount == 1)
        
        await operationTask.value
        #expect(manager.activeFileOperationsCount == 0)
    }
    
    @MainActor
    @Test func testResetNavigation() async throws {
        let manager = FileSyncManager()
        manager.sourceRelativePath = "some/path"
        manager.destRelativePath = "other/path"
        manager.sourceExpandedPaths = ["/root/some/path"]
        manager.destExpandedPaths = ["/root/other/path"]
        
        manager.resetNavigation()
        
        #expect(manager.sourceRelativePath == "")
        #expect(manager.destRelativePath == "")
        #expect(manager.sourceExpandedPaths.isEmpty)
        #expect(manager.destExpandedPaths.isEmpty)
    }
    
    @MainActor
    @Test func testRefreshTreesAndScanCancellation() async throws {
        let manager = FileSyncManager()
        let provider1 = CloudProvider(id: "p1", displayName: "P1", imageName: "", path: "/tmp/p1", type: .iCloud)
        let provider2 = CloudProvider(id: "p2", displayName: "P2", imageName: "", path: "/tmp/p2", type: .iCloud)
        
        // Start a refresh
        let task1 = Task {
            await manager.refreshTreesAndScan(source: provider1, destination: provider2)
        }
        
        // Immediately start another one
        let task2 = Task {
            await manager.refreshTreesAndScan(source: provider1, destination: provider2)
        }
        
        await task1.value
        await task2.value
        
        // If task1 was correctly cancelled, manager should be in a stable state.
        // We mainly verify it doesn't hang or crash.
        #expect(manager.activeRefreshTask != nil)
    }
    
    @MainActor
    @Test func testConcurrentFileOperationsStress() async throws {
        actor Counter {
            var value = 0
            func increment() { value += 1 }
            func get() -> Int { value }
        }
        
        let manager = FileSyncManager()
        let operationCount = 50
        let counter = Counter()
        
        // Enqueue 50 fast operations
        for _ in 0..<operationCount {
            Task {
                await manager.enqueueFileOperation {
                    // Minimal work
                    try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                    await counter.increment()
                }
            }
        }
        
        // Wait for all to finish. We use a timeout approach.
        let start = Date()
        var currentCount = 0
        while currentCount < operationCount && Date().timeIntervalSince(start) < 5.0 {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            currentCount = await counter.get()
        }
        
        #expect(currentCount == operationCount)
        #expect(manager.activeFileOperationsCount == 0)
    }
    
    @MainActor
    @Test func testCacheInvalidationOnToggle() async throws {
        let manager = FileSyncManager()
        
        // 1. Fill cache
        manager.prefetchedTrees["/src"] = [FileNode(id: "/src/a", name: "a", isDirectory: false)]
        #expect(!manager.prefetchedTrees.isEmpty)
        
        // 2. Toggle hidden files -> should clear cache
        manager.showHiddenFiles = true
        #expect(manager.prefetchedTrees.isEmpty)
        
        // 3. Fill again
        manager.prefetchedTrees["/src"] = [FileNode(id: "/src/a", name: "a", isDirectory: false)]
        #expect(!manager.prefetchedTrees.isEmpty)
        
        // 4. Change sort option -> should clear cache
        manager.sortOption = .size
        #expect(manager.prefetchedTrees.isEmpty)
    }

    @MainActor
    @Test func testScanFailureHandling() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        let provider1 = CloudProvider(id: "p1", displayName: "P1", imageName: "", path: "/tmp/p1", type: .iCloud)
        let provider2 = CloudProvider(id: "p2", displayName: "P2", imageName: "", path: "/tmp/p2", type: .iCloud)
        
        // Simulate a directory that doesn't exist to trigger an error in scanDirectories
        await manager.scanDirectories(source: provider1, sourcePath: "/non-existent", destination: provider2, destinationPath: "/tmp/p2")
        
        #expect(manager.differences.isEmpty)
        #expect(!manager.isScanning)
        #expect(manager.hasScanned) // Successfully completed with []
    }
    
    @MainActor
    @Test func testLoadingStateAccuracy() async throws {
        let mockFM = MockFileManager()
        mockFM.enumeratorDelay = 0.05
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        
        // Start loading and check state
        let task = Task { await manager.loadTree(path: "/src", isSource: true) }
        
        // Yield to allow task to start
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(manager.isLoadingSourceTree)
        
        await task.value
        #expect(!manager.isLoadingSourceTree)
    }
    
    @MainActor
    @Test func testSyncFileWithCopyAction() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/test.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        let diff = FileDifference(
            id: UUID(),
            relativePath: "test.txt",
            sourceItemPath: "/src/test.txt",
            destinationItemPath: "/dst/test.txt",
            type: .missingInDestination,
            action: .copyToDestination,
            description: "Missing",
            isSyncing: false
        )
        
        // Add to manager so it can find it by ID and mark as syncing
        manager.differences = [diff]
        
        // isMove is false by default
        await manager.syncFile(diff, isMove: false, fileManager: mockFM)
        
        // Should exist in both places (Copied)
        #expect(mockFM.virtualDisk["/src/test.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/test.txt"] != nil)
    }
    
    @MainActor
    @Test func testSyncFileWithMoveAction() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        manager.undoManager = UndoManager()
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/test_move.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        let diff = FileDifference(
            id: UUID(),
            relativePath: "test_move.txt",
            sourceItemPath: "/src/test_move.txt",
            destinationItemPath: "/dst/test_move.txt",
            type: .missingInDestination,
            action: .copyToDestination,
            description: "Missing",
            isSyncing: false
        )
        
        manager.differences = [diff]
        
        // Set isMove to true
        await manager.syncFile(diff, isMove: true, fileManager: mockFM)
        
        // Should exist in destination but NOT source (Moved)
        #expect(mockFM.virtualDisk["/src/test_move.txt"] == nil)
        #expect(mockFM.virtualDisk["/dst/test_move.txt"] != nil)

        #expect(manager.undoManager?.canUndo == true)
        manager.undoManager?.undo()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(mockFM.virtualDisk["/src/test_move.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/test_move.txt"] == nil)
    }
    
    @MainActor
    @Test func testMockEnumeratorSkipsSubdirectoryDescendants() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/folder"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/folder/child.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        let en = mockFM.enumerator(
            at: URL(fileURLWithPath: "/src"),
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: nil
        )
        
        var paths: [String] = []
        if let en {
            while let next = en.nextObject() as? URL {
                paths.append(next.path)
            }
        }
        
        #expect(paths.contains("/src/folder"))
        #expect(!paths.contains("/src/folder/child.txt"))
    }
}
