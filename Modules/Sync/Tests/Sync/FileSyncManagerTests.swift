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
        manager.leftTree = [node1, node2]
        
        // Select both
        manager.selectedLeftPaths = ["/src/file1.txt", "/src/file2.txt"]
        
        // Simulate removal of file2.txt from tree
        manager.leftTree = [node1]
        
        // Prune
        manager.pruneSelection()
        
        // Verify file2.txt is removed from selection, but file1.txt remains
        #expect(manager.selectedLeftPaths.count == 1)
        #expect(manager.selectedLeftPaths.contains("/src/file1.txt"))
        #expect(!manager.selectedLeftPaths.contains("/src/file2.txt"))
    }
    
    @MainActor
    @Test func testPruneSelectionRecursive() async throws {
        let manager = FileSyncManager()
        
        let subNode = FileNode(id: "/src/folder/sub.txt", name: "sub.txt", isDirectory: false)
        let folderNode = FileNode(id: "/src/folder", name: "folder", isDirectory: true, children: [subNode])
        manager.leftTree = [folderNode]
        
        manager.selectedLeftPaths = ["/src/folder", "/src/folder/sub.txt"]
        
        // Remove only the subfile
        let emptyFolderNode = FileNode(id: "/src/folder", name: "folder", isDirectory: true, children: [])
        manager.leftTree = [emptyFolderNode]
        
        manager.pruneSelection()
        
        #expect(manager.selectedLeftPaths.count == 1)
        #expect(manager.selectedLeftPaths.contains("/src/folder"))
        #expect(!manager.selectedLeftPaths.contains("/src/folder/sub.txt"))
    }
    
    @MainActor
    @Test func testLoadTreeCancellation() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/file_1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        // The test body runs on the main actor, so `treeTask` cannot start before cancel() below:
        // loadTree begins already-cancelled, and the cancellation must propagate through its
        // inner task and the detached tree walk for the load to be discarded.
        let treeTask = Task { await manager.loadTree(path: "/src", isLeft: true) }

        // Cancel it immediately before it can recursively build
        treeTask.cancel()
        await treeTask.value

        // An uncancelled load of the mock disk would populate file_1.txt; a propagated
        // cancellation discards the (partial) walk and leaves the tree untouched.
        #expect(manager.leftTree.count == 0)
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

        await waitUntil("undo restores the trashed file") { mockFM.virtualDisk["/src/delete_me.txt"] != nil }
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

        await waitUntil("undo removes the copied file") { mockFM.virtualDisk["/dst/copy_me.txt"] == nil }
        // Removed from destination
        #expect(mockFM.virtualDisk["/dst/copy_me.txt"] == nil)
        // Kept in source
        #expect(mockFM.virtualDisk["/src/copy_me.txt"] != nil)

        // Perform Redo -> should put it back
        manager.undoManager?.redo()
        await waitUntil("redo restores the copied file") { mockFM.virtualDisk["/dst/copy_me.txt"] != nil }
        #expect(mockFM.virtualDisk["/dst/copy_me.txt"] != nil)
    }
    
    @MainActor
    @Test func testActiveOperationTracking() async throws {
        let manager = FileSyncManager()
        #expect(manager.activeFileOperationsCount == 0)

        // A long operation that parks until the test has observed it in flight — deterministic,
        // unlike the old sleep pairing that flaked under a loaded parallel test run.
        let release = DispatchSemaphore(value: 0)
        let operationTask = Task {
            await manager.enqueueFileOperation {
                await awaitSignal(release)
            }
        }

        await waitUntil("operation counted in flight") { manager.activeFileOperationsCount == 1 }
        #expect(manager.activeFileOperationsCount == 1)

        release.signal()
        await operationTask.value
        #expect(manager.activeFileOperationsCount == 0)
    }
    
    @MainActor
    @Test func testResetNavigation() async throws {
        let manager = FileSyncManager()
        manager.leftRelativePath = "some/path"
        manager.rightRelativePath = "other/path"

        manager.resetNavigation()

        #expect(manager.leftRelativePath == "")
        #expect(manager.rightRelativePath == "")
    }
    
    @MainActor
    @Test func testRefreshTreesAndScanCancellation() async throws {
        let manager = FileSyncManager()
        let provider1 = CloudProvider(id: "p1", displayName: "P1", imageName: "", path: "/tmp/p1", type: .iCloud)
        let provider2 = CloudProvider(id: "p2", displayName: "P2", imageName: "", path: "/tmp/p2", type: .iCloud)
        
        // Start a refresh
        let task1 = Task {
            await manager.refreshTreesAndScan(left: provider1, right: provider2)
        }
        
        // Immediately start another one
        let task2 = Task {
            await manager.refreshTreesAndScan(left: provider1, right: provider2)
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
        await manager.scanDirectories(left: provider1, leftPath: "/non-existent", right: provider2, rightPath: "/tmp/p2")
        
        #expect(manager.differences.isEmpty)
        #expect(!manager.isScanning)
        #expect(manager.hasScanned) // Successfully completed with []
    }
    
    @MainActor
    @Test func testLoadingStateAccuracy() async throws {
        let mockFM = MockFileManager()
        // Deterministic: the walk parks at the gate (no wall-clock delay/sleep pairing to lose
        // under a loaded parallel test run), so "load in flight" stays observable for exactly
        // as long as the test needs.
        let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        mockFM.enumeratorGate = gate
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)

        let task = Task { await manager.loadTree(path: "/src", isLeft: true) }

        await awaitSignal(gate.entered)              // the walk is parked inside the load
        #expect(manager.isLoadingLeftTree)

        gate.release.signal()
        await task.value
        #expect(!manager.isLoadingLeftTree)
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
            leftItemPath: "/src/test.txt",
            rightItemPath: "/dst/test.txt",
            type: .missingOnRight,
            action: .copyToRight,
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
            leftItemPath: "/src/test_move.txt",
            rightItemPath: "/dst/test_move.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing",
            isSyncing: false
        )
        
        manager.differences = [diff]
        
        // Set isMove to true
        await manager.syncFile(diff, isMove: true, fileManager: mockFM)
        
        // Should exist on right but NOT left (Moved)
        #expect(mockFM.virtualDisk["/src/test_move.txt"] == nil)
        #expect(mockFM.virtualDisk["/dst/test_move.txt"] != nil)

        #expect(manager.undoManager?.canUndo == true)
        manager.undoManager?.undo()
        // The undo's file I/O runs on the detached operation queue; poll for its result
        // instead of one fixed sleep, which flaked under a loaded parallel test run.
        for _ in 0..<100 where mockFM.virtualDisk["/src/test_move.txt"] == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

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
