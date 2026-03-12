import Testing
import Sync
import Foundation
@testable import Dashboard

@Suite struct DashboardTests {
    
    @MainActor
    @Test func testDetailsSidebarActivePathPriority() async throws {
        let manager = FileSyncManager()
        let sourceFolder = "/src/folder"
        let destFolder = "/dst/folder"
        
        let sidebar = DetailsSidebar(syncManager: manager, leftPath: sourceFolder, rightPath: destFolder)
        
        // 1. Initial state (no selection) -> Should fallback to source folder
        #expect(sidebar.activePath == sourceFolder)
        
        // 2. Select in Source -> Should show source selection
        manager.selectedLeftPaths = ["/src/folder/file1.txt"]
        #expect(sidebar.activePath == "/src/folder/file1.txt")
        
        // 3. Select in Dest (while Source is still selected) -> Should still favor Source (primary driver)
        manager.selectedRightPaths = ["/dst/folder/file2.txt"]
        #expect(sidebar.activePath == "/src/folder/file1.txt")
        
        // 4. Clear Source selection -> Should show Dest selection
        manager.selectedLeftPaths = []
        #expect(sidebar.activePath == "/dst/folder/file2.txt")
        
        // 5. Clear both -> Should fallback to source folder (or dest if source empty, but here both folders provided)
        manager.selectedRightPaths = []
        #expect(sidebar.activePath == sourceFolder)
    }
    
    @MainActor
    @Test func testDetailsSidebarFallbackToDestIfSourceEmpty() async throws {
        let manager = FileSyncManager()
        // If source path is empty string for some reason (not likely in normal app use but testable)
        let sidebar = DetailsSidebar(syncManager: manager, leftPath: "", rightPath: "/dst/fallback")
        
        #expect(sidebar.activePath == "/dst/fallback")
    }
    
    @MainActor
    @Test func testMultiSelectionAcrossPanes() async throws {
        let manager = FileSyncManager()
        let sidebar = DetailsSidebar(syncManager: manager, leftPath: "/src", rightPath: "/dst")
        
        // Select multiple in Source
        manager.selectedLeftPaths = ["/src/a.txt", "/src/b.txt"]
        // Select one in Dest
        manager.selectedRightPaths = ["/dst/c.txt"]
        
        // activePath should favor the first element of Source selection
        #expect(sidebar.activePath == "/src/a.txt")
        
        // Clear Source -> should favor Dest
        manager.selectedLeftPaths = []
        #expect(sidebar.activePath == "/dst/c.txt")
    }
    
    @MainActor
    @Test func testSelectionPruningOnDeepMove() async throws {
        let manager = FileSyncManager()
        
        let file1 = FileNode(id: "/src/folder/file1.txt", name: "file1.txt", isDirectory: false)
        let folder = FileNode(id: "/src/folder", name: "folder", isDirectory: true, children: [file1])
        manager.leftTree = [folder]
        
        // Select both folder and its child
        manager.selectedLeftPaths = ["/src/folder", "/src/folder/file1.txt"]
        
        // Simulate "Move" or "Delete" that removes the folder
        manager.leftTree = []
        manager.pruneSelection()
        
        // Both should be gone
        #expect(manager.selectedLeftPaths.isEmpty)
    }
}
