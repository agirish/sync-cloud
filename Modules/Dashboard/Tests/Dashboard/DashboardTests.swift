import Testing
import Sync
import Foundation
@testable import Dashboard

@Suite struct DashboardTests {

    // testDetailsSidebarActivePathPriority and testSingleSourceInspectorIgnoresTheHiddenRightPane
    // were removed 2026-08-22. `activePath` now DELEGATES the pane-selection rule to
    // `CurrentSelection.primaryPanePath` (the fix DetailsActivePathAgreementTests exists for), so
    // each branch those two walked is pinned at the resolver (CurrentSelectionTests, in Sync:
    // left-wins, right-only, single-source, empty→nil) and the delegation plus fallback is pinned
    // by the agreement suite. Of the tests below, the leftPath-empty fallback and `pruneSelection`
    // have no other coverage; the multi-selection walk overlaps the same resolver pins and is kept
    // only as an end-to-end read through the sidebar.

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
