import Testing
import Foundation
import Combine
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

    @MainActor
    @Test func testFocusOnRightPaneWithUnknownPathNavigatesClearsIgnoredAndFiresRefresh() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "somewhere", isLeft: true)
        manager.ignoredPaths = ["noise.txt"]

        var refreshCount = 0
        let subscription = manager.refreshSubject.sink { refreshCount += 1 }
        defer { subscription.cancel() }

        // The focused path exists on no disk: focusOn does not validate it, it just re-focuses
        // the one pane, resets the per-folder ignore list, appends to history, and fires the
        // refresh subject (which is what triggers the follow-up tree load and scan).
        manager.focusOn(relativePath: "does/not/exist", isLeft: false)

        #expect(manager.rightRelativePath == "does/not/exist")
        #expect(manager.leftRelativePath == "somewhere") // the other pane is untouched
        #expect(manager.ignoredPaths.isEmpty)
        #expect(refreshCount == 1)
        #expect(manager.history.count == 3)
        #expect(manager.canGoBack)
        #expect(!manager.canGoForward)
    }

    @MainActor
    @Test func testAncestorFocusAppendsToHistoryLikeAnyFocus() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())

        manager.focusOn(relativePath: "docs", isLeft: true)
        manager.focusOn(relativePath: "docs/projects/app", isLeft: true)

        // Breadcrumb jump to an ancestor is a plain focus: it appends a new history
        // entry rather than rewinding, so Back returns to the deeper folder.
        manager.focusOn(relativePath: "docs/projects", isLeft: true)

        #expect(manager.leftRelativePath == "docs/projects")
        #expect(manager.history.count == 4)
        #expect(manager.canGoBack)
        #expect(!manager.canGoForward)

        manager.goBack()
        #expect(manager.leftRelativePath == "docs/projects/app")
        manager.goForward()
        #expect(manager.leftRelativePath == "docs/projects")
    }

    @MainActor
    @Test func testFocusBothMovesBothPanesWithOneHistoryEntry() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "docs/a", isLeft: true)
        manager.focusOn(relativePath: "docs/b", isLeft: false)
        manager.ignoredPaths = ["noise.txt"]

        var refreshCount = 0
        let subscription = manager.refreshSubject.sink { refreshCount += 1 }
        defer { subscription.cancel() }

        // ⌥-click on a breadcrumb: both panes converge on the same relative path,
        // recorded as a single history entry so one Back undoes the whole jump.
        manager.focusBoth(relativePath: "docs")

        #expect(manager.leftRelativePath == "docs")
        #expect(manager.rightRelativePath == "docs")
        #expect(manager.ignoredPaths.isEmpty)
        #expect(refreshCount == 1)
        #expect(manager.history.count == 4)

        manager.goBack()
        #expect(manager.leftRelativePath == "docs/a")
        #expect(manager.rightRelativePath == "docs/b")
    }

    @MainActor
    @Test func testFocusBothIsNoOpWhenBothPanesAlreadyThere() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusBoth(relativePath: "shared")
        #expect(manager.history.count == 2)

        var refreshCount = 0
        let subscription = manager.refreshSubject.sink { refreshCount += 1 }
        defer { subscription.cancel() }

        manager.focusBoth(relativePath: "shared")

        #expect(manager.history.count == 2)
        #expect(refreshCount == 0)
    }

    @MainActor
    @Test func testFocusBothTrimsForwardHistory() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "a", isLeft: true)
        manager.focusOn(relativePath: "a/b", isLeft: true)
        manager.goBack()

        manager.focusBoth(relativePath: "c")

        #expect(manager.history.count == 3)
        #expect(manager.history.last?.left == "c")
        #expect(manager.history.last?.right == "c")
        #expect(!manager.canGoForward)
    }

    @MainActor
    @Test func testAncestorFocusOnRightPaneWhenLeftIsAtRoot() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())

        // Only the right pane is focused (the breadcrumb bar's fallback case).
        manager.focusOn(relativePath: "photos/2026/july", isLeft: false)
        manager.focusOn(relativePath: "photos", isLeft: false)

        #expect(manager.rightRelativePath == "photos")
        #expect(manager.leftRelativePath == "")
        #expect(manager.history.count == 3)

        manager.goBack()
        #expect(manager.rightRelativePath == "photos/2026/july")
    }
}
