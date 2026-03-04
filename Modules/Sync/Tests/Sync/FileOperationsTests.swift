import Testing
import Foundation
@testable import Sync

@Suite struct FileOperationsTests {
    
    @Test func testSafeMoveCrossVolumeFallback() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // This flag isn't natively in our mock yet, but we will add it to mockFM shortly to simulate ENXIO / EXDEV
        mockFM.shouldFailMove = true
        
        let srcURL = URL(fileURLWithPath: "/src/data.bin")
        let dstURL = URL(fileURLWithPath: "/dst/data.bin")
        
        // This should trigger the fallback: copyItem -> removeItem
        try FileSyncManager.safeMoveItem(at: srcURL, to: dstURL, fileManager: mockFM)
        
        #expect(mockFM.virtualDisk["/dst/data.bin"] != nil)
        #expect(mockFM.virtualDisk["/src/data.bin"] == nil)
        #expect(mockFM.calledCopyItem == true)
    }
    
    @Test func testDeleteItemsTriggersPermanentRemovalOnTrashFailure() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // Simulate a network volume that doesn't support the trash bin
        mockFM.shouldFailTrash = true
        
        let targetURL = URL(fileURLWithPath: "/src/data.bin")
        
        try await FileSyncManager().deleteItems(at: [targetURL.path], fileManager: mockFM)
        
        #expect(mockFM.virtualDisk["/src/data.bin"] == nil)
        // Verify it didn't end up in the `.trashedPaths` mock stub array but was physically deleted instead
        #expect(mockFM.trashedPaths.isEmpty == true)
    }
    
    @Test func testRecursivePathValidation() async throws {
        let parentDir = URL(fileURLWithPath: "/src/folder")
        let targetChildDir = URL(fileURLWithPath: "/src/folder/child")
        
        // You cannot move/copy `/src/folder` INTO `/src/folder/child`
        #expect(throws: FileSyncManager.FileOperationError.nestingViolation) {
            try FileSyncManager.validateFileOperation(source: parentDir, destination: targetChildDir)
        }
        
        try #expect(FileSyncManager.validateFileOperation(source: parentDir, destination: URL(fileURLWithPath: "/src/otherFolder")) == ())
    }
    
    @MainActor
    @Test func testRenameFileCollision() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/fileA.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/fileB.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // Rename A to B, causing a collision
        await manager.renameItem(at: "/src/fileA.txt", to: "fileB.txt", fileManager: mockFM)
        
        let errStr = manager.currentError ?? ""
        // Ensure error was set since fileB exists and wasn't case only rename
        #expect(errStr.contains("already exists"))
        
        // Both files should still exist intact
        #expect(mockFM.virtualDisk["/src/fileA.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/fileB.txt"] != nil)
    }
    
    @MainActor
    @Test func testCreateFolder() async throws {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        
        await manager.createFolder(named: "New Folder", in: "/src", fileManager: mockFM)
        
        #expect(mockFM.virtualDisk["/src/New Folder"] != nil)
        #expect(manager.undoManager?.canUndo == true)
        
        manager.undoManager?.undo()
        try await Task.sleep(nanoseconds: 100_000_000)
        
        #expect(mockFM.virtualDisk["/src/New Folder"] == nil)
    }
    
    @MainActor
    @Test func testMoveFiles() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/f1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/f2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        let node1 = FileNode(id: "/src/f1.txt", name: "f1.txt", isDirectory: false)
        let node2 = FileNode(id: "/src/f2.txt", name: "f2.txt", isDirectory: false)
        
        await manager.moveItems(nodes: [node1, node2], toPath: "/dst", fileManager: mockFM)
        
        // Assert moved to dest
        #expect(mockFM.virtualDisk["/dst/f1.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/f2.txt"] != nil)
        
        // Assert removed from src
        #expect(mockFM.virtualDisk["/src/f1.txt"] == nil)
        #expect(mockFM.virtualDisk["/src/f2.txt"] == nil)
    }
    
    @MainActor
    @Test func testMoveDirectoryWithChildren() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        
        // Mock a deep nested directory structure in source
        mockFM.virtualDisk["/src"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["deep_folder"])
        mockFM.virtualDisk["/src/deep_folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["child_folder", "doc.txt"])
        mockFM.virtualDisk["/src/deep_folder/child_folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["data.bin"])
        mockFM.virtualDisk["/src/deep_folder/child_folder/data.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/deep_folder/doc.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        let folderNode = FileNode(id: "/src/deep_folder", name: "deep_folder", isDirectory: true)
        
        // User moves the entire deep_folder to /dst
        await manager.moveItems(nodes: [folderNode], toPath: "/dst", fileManager: mockFM)
        
        // Validate /dst contains the tree
        #expect(mockFM.virtualDisk["/dst/deep_folder"] != nil)
        #expect(mockFM.virtualDisk["/dst/deep_folder/child_folder"] != nil)
        #expect(mockFM.virtualDisk["/dst/deep_folder/child_folder/data.bin"] != nil)
        #expect(mockFM.virtualDisk["/dst/deep_folder/doc.txt"] != nil)
        
        // Validate original tree is removed
        #expect(mockFM.virtualDisk["/src/deep_folder"] == nil)
        #expect(mockFM.virtualDisk["/src/deep_folder/child_folder"] == nil)
        #expect(mockFM.virtualDisk["/src/deep_folder/child_folder/data.bin"] == nil)
    }
    
    @MainActor
    @Test func testCopyDirectoryWithChildren() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        
        // Form deep hierarchy in Source
        mockFM.virtualDisk["/src"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["copy_folder"])
        mockFM.virtualDisk["/src/copy_folder"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["sub"])
        mockFM.virtualDisk["/src/copy_folder/sub"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["item.png"])
        mockFM.virtualDisk["/src/copy_folder/sub/item.png"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        let folderNode = FileNode(id: "/src/copy_folder", name: "copy_folder", isDirectory: true)
        await manager.copyItems(nodes: [folderNode], toPath: "/dst", fileManager: mockFM)
        
        // Target should exist
        #expect(mockFM.virtualDisk["/dst/copy_folder/sub/item.png"] != nil)
        
        // Source should STILL exist
        #expect(mockFM.virtualDisk["/src/copy_folder/sub/item.png"] != nil)
    }
    
    @MainActor
    @Test func testRenameDirectory() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        
        mockFM.virtualDisk["/src/media"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["movies"])
        mockFM.virtualDisk["/src/media/movies"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["vid.mp4"])
        mockFM.virtualDisk["/src/media/movies/vid.mp4"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // Rename "media" directory to "Entertainment"
        await manager.renameItem(at: "/src/media", to: "Entertainment", fileManager: mockFM)
        
        #expect(mockFM.virtualDisk["/src/Entertainment"] != nil)
        #expect(mockFM.virtualDisk["/src/Entertainment/movies/vid.mp4"] != nil)
        
        #expect(mockFM.virtualDisk["/src/media"] == nil)
    }
    
    @MainActor
    @Test func testRenameCaseOnly() async throws {
        let manager = FileSyncManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/Notes.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // Case-only rename: Notes.txt -> notes.txt
        await manager.renameItem(at: "/src/Notes.txt", to: "notes.txt", fileManager: mockFM)
        
        // Verify current error is nil (meaning no collision error occurred)
        #expect(manager.currentError == nil)
        
        // Verify the file was physically relinked in RAM dictionary to notes.txt
        #expect(mockFM.virtualDisk["/src/notes.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/Notes.txt"] == nil)
    }
}
