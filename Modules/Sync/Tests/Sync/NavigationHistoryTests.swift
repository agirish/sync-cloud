import Testing
import Foundation
@testable import Sync

@Suite struct NavigationHistoryTests {
    
    @MainActor
    @Test func testBackForwardHistory() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let root = "/src"
        try mockFM.createDirectory(at: URL(fileURLWithPath: root), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "\(root)/folder1"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "\(root)/folder1/sub"), withIntermediateDirectories: true)
        
        // 1. Initial State
        #expect(manager.sourceRelativePath == "")
        #expect(!manager.canGoBack)
        #expect(!manager.canGoForward)
        
        // 2. Navigate to folder1
        manager.focusOn(relativePath: "folder1", isSource: true, otherProviderPath: "/dst")
        #expect(manager.sourceRelativePath == "folder1")
        #expect(manager.canGoBack)
        #expect(!manager.canGoForward)
        
        // 3. Navigate to sub
        manager.focusOn(relativePath: "folder1/sub", isSource: true, otherProviderPath: "/dst")
        #expect(manager.sourceRelativePath == "folder1/sub")
        #expect(manager.historyIndex == 2)
        
        // 4. Go Back
        manager.goBack()
        #expect(manager.sourceRelativePath == "folder1")
        #expect(manager.canGoBack)
        #expect(manager.canGoForward)
        
        // 5. Go Back to Root
        manager.goBack()
        #expect(manager.sourceRelativePath == "")
        #expect(!manager.canGoBack)
        #expect(manager.canGoForward)
        
        // 6. Go Forward
        manager.goForward()
        #expect(manager.sourceRelativePath == "folder1")
        #expect(manager.canGoBack)
        #expect(manager.canGoForward)
    }
    
    @MainActor
    @Test func testHistoryTrimming() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        manager.focusOn(relativePath: "a", isSource: true, otherProviderPath: "/dst")
        manager.focusOn(relativePath: "a/b", isSource: true, otherProviderPath: "/dst")
        
        #expect(manager.history.count == 3) // Root, a, a/b
        
        manager.goBack() // Now at "a"
        #expect(manager.sourceRelativePath == "a")
        
        // Navigate to new path "c"
        manager.focusOn(relativePath: "c", isSource: true, otherProviderPath: "/dst")
        
        // Forward history "a/b" should be trimmed
        #expect(manager.history.count == 3)
        #expect(manager.history.last?.source == "c")
        #expect(!manager.canGoForward)
    }
    
    @MainActor
    @Test func testMatchingPathNavigation() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/common"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/common"), withIntermediateDirectories: true)
        
        // Navigate source to "common"
        manager.focusOn(relativePath: "common", isSource: true, otherProviderPath: "/dst")
        
        // Both should have updated if findMatchingPath succeeded
        #expect(manager.sourceRelativePath == "common")
        #expect(manager.destRelativePath == "common")
    }
    
    @MainActor
    @Test func testNonMatchingPathFallsBackToRoot() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/photos"), withIntermediateDirectories: true)
        // Destination intentionally does not have /dst/photos
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        manager.focusOn(relativePath: "photos", isSource: true, otherProviderPath: "/dst")
        
        #expect(manager.sourceRelativePath == "photos")
        #expect(manager.destRelativePath == "")
    }
}
