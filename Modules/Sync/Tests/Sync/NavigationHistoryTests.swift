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
        #expect(manager.leftRelativePath == "")
        #expect(!manager.canGoBack)
        #expect(!manager.canGoForward)
        
        // 2. Navigate to folder1
        manager.focusOn(relativePath: "folder1", isLeft: true)
        #expect(manager.leftRelativePath == "folder1")
        #expect(manager.canGoBack)
        #expect(!manager.canGoForward)
        
        // 3. Navigate to sub
        manager.focusOn(relativePath: "folder1/sub", isLeft: true)
        #expect(manager.leftRelativePath == "folder1/sub")
        #expect(manager.historyIndex == 2)
        
        // 4. Go Back
        manager.goBack()
        #expect(manager.leftRelativePath == "folder1")
        #expect(manager.canGoBack)
        #expect(manager.canGoForward)
        
        // 5. Go Back to Root
        manager.goBack()
        #expect(manager.leftRelativePath == "")
        #expect(!manager.canGoBack)
        #expect(manager.canGoForward)
        
        // 6. Go Forward
        manager.goForward()
        #expect(manager.leftRelativePath == "folder1")
        #expect(manager.canGoBack)
        #expect(manager.canGoForward)
    }
    
    @MainActor
    @Test func testHistoryTrimming() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        manager.focusOn(relativePath: "a", isLeft: true)
        manager.focusOn(relativePath: "a/b", isLeft: true)
        
        #expect(manager.history.count == 3) // Root, a, a/b
        
        manager.goBack() // Now at "a"
        #expect(manager.leftRelativePath == "a")
        
        // Navigate to new path "c"
        manager.focusOn(relativePath: "c", isLeft: true)
        
        // Forward history "a/b" should be trimmed
        #expect(manager.history.count == 3)
        #expect(manager.history.last?.left == "c")
        #expect(!manager.canGoForward)
    }
    
    @MainActor
    @Test func testMatchingPathNavigation() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/common"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst/common"), withIntermediateDirectories: true)
        
        // Navigate source to "common"
        manager.focusOn(relativePath: "common", isLeft: true)
        
        // focusOn only updates the focused pane; dest is unchanged
        #expect(manager.leftRelativePath == "common")
        #expect(manager.rightRelativePath == "")
    }
    
    @MainActor
    @Test func testNonMatchingPathFallsBackToRoot() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/photos"), withIntermediateDirectories: true)
        // Destination intentionally does not have /dst/photos
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        manager.focusOn(relativePath: "photos", isLeft: true)
        
        #expect(manager.leftRelativePath == "photos")
        #expect(manager.rightRelativePath == "")
    }
}
