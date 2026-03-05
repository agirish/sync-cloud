import Testing
import Foundation
import Sync
@testable import FileExplorer

@Suite struct FileExplorerTests {
    
    @MainActor
    @Test func testPaneActionDelegateSorting() async throws {
        let manager = FileSyncManager()
        let delegate = PaneActionDelegate(
            handler: nil, 
            syncManager: manager, 
            isSource: true, 
            sourceProviderId: "iCloud", 
            destProviderId: "iCloud"
        )
        
        #expect(manager.sortOption == .name)
        
        delegate.handleSort(.dateModified)
        #expect(manager.sortOption == .dateModified)
        
        delegate.handleSort(.size)
        #expect(manager.sortOption == .size)
    }
}

// Minimal mock delegate for testing ContentView-like logic in isolation
@MainActor
struct PaneActionDelegate: FileActionDelegate {
    let handler: Any? // Not needed for this test
    let syncManager: FileSyncManager
    let isSource: Bool
    let sourceProviderId: String
    let destProviderId: String
    
    func handleFocus(_ node: FileNode) {}
    func handleCopy(_ nodes: [FileNode]) {}
    func handleMove(_ nodes: [FileNode]) {}
    func handleDelete(_ nodes: [FileNode]) {}
    func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) { 
        syncManager.clipboardNodes = nodes
        syncManager.clipboardIsCut = isCut 
    }
    func handlePaste(_ targetDir: FileNode) {}
    func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
    func handlePasteToPath(_ path: String) {}
    func handleRename(_ node: FileNode) {}
    func handleCreateFolder(at path: String) {}
    func handleGetInfo(for path: String) {}
    func handleSort(_ option: SortOption) { syncManager.sortOption = option }
}
