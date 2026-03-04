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
}
