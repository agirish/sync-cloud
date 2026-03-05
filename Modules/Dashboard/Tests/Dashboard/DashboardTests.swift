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
        
        let sidebar = DetailsSidebar(syncManager: manager, sourcePath: sourceFolder, destPath: destFolder)
        
        // 1. Initial state (no selection) -> Should fallback to source folder
        #expect(sidebar.activePath == sourceFolder)
        
        // 2. Select in Source -> Should show source selection
        manager.selectedSourcePaths = ["/src/folder/file1.txt"]
        #expect(sidebar.activePath == "/src/folder/file1.txt")
        
        // 3. Select in Dest (while Source is still selected) -> Should still favor Source (primary driver)
        manager.selectedDestinationPaths = ["/dst/folder/file2.txt"]
        #expect(sidebar.activePath == "/src/folder/file1.txt")
        
        // 4. Clear Source selection -> Should show Dest selection
        manager.selectedSourcePaths = []
        #expect(sidebar.activePath == "/dst/folder/file2.txt")
        
        // 5. Clear both -> Should fallback to source folder (or dest if source empty, but here both folders provided)
        manager.selectedDestinationPaths = []
        #expect(sidebar.activePath == sourceFolder)
    }
    
    @MainActor
    @Test func testDetailsSidebarFallbackToDestIfSourceEmpty() async throws {
        let manager = FileSyncManager()
        // If source path is empty string for some reason (not likely in normal app use but testable)
        let sidebar = DetailsSidebar(syncManager: manager, sourcePath: "", destPath: "/dst/fallback")
        
        #expect(sidebar.activePath == "/dst/fallback")
    }
}
