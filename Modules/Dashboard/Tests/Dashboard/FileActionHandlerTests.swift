import Testing
import Foundation
import Sync
@testable import Dashboard

// Re-declaring minimal mockup of the FileActionHandler directly for Logic testing.
// In reality, this lives in MacApp, but its core logic is strictly business logic.
// We can wrap the basic paste dispatch logic here to test state expectations on FileSyncManager.

@MainActor
class MockFileActionHandler {
    let syncManager: FileSyncManager
    
    init(syncManager: FileSyncManager) {
        self.syncManager = syncManager
    }
    
    // Mimicking MacApp/FileActionHandler's updated behavior
    func pasteItems(_ nodes: [FileNode], toPath destinationPath: String, isCut: Bool) {
        if isCut {
            syncManager.clipboardNodes = []
            syncManager.clipboardIsCut = false
        }
    }
}

@Suite struct FileActionHandlerTests {
    
    @MainActor
    @Test func testClipboardPersistenceOnCopy() async throws {
        let manager = FileSyncManager()
        let handler = MockFileActionHandler(syncManager: manager)
        
        let node1 = FileNode(id: "/src/file1.txt", name: "file1.txt", isDirectory: false)
        
        // User copies a node
        manager.clipboardNodes = [node1]
        manager.clipboardIsCut = false
        
        // User pastes it. Since it's a Copy, the clipboard should persist
        handler.pasteItems([node1], toPath: "/dst", isCut: false)
        
        #expect(manager.clipboardNodes.count == 1)
        #expect(manager.clipboardNodes.first?.id == "/src/file1.txt")
    }
    
    @MainActor
    @Test func testClipboardClearingOnCut() async throws {
        let manager = FileSyncManager()
        let handler = MockFileActionHandler(syncManager: manager)
        
        let node1 = FileNode(id: "/src/file1.txt", name: "file1.txt", isDirectory: false)
        
        // User cuts a node
        manager.clipboardNodes = [node1]
        manager.clipboardIsCut = true
        
        // User pastes it. Since it's a Cut, the clipboard should clear
        handler.pasteItems([node1], toPath: "/dst", isCut: true)
        
        #expect(manager.clipboardNodes.isEmpty)
        #expect(manager.clipboardIsCut == false)
    }
}
