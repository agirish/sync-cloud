import Testing
import Sync
import Foundation
@testable import Dashboard

@Suite struct DashboardTests {

    // `activePath` delegates the pane-selection rule to `CurrentSelection.primaryPanePath`, whose
    // branches CurrentSelectionTests (in Sync) pins; DetailsActivePathAgreementTests pins the
    // delegation. Below, the leftPath-empty fallback and `pruneSelection` have no other coverage.

    @MainActor
    @Test func testDetailsSidebarFallbackToDestIfSourceEmpty() async throws {
        let manager = FileSyncManager()
        // An empty source path, unlikely in the app but possible.
        let sidebar = DetailsSidebar(syncManager: manager, leftPath: "", rightPath: "/dst/fallback")
        
        #expect(sidebar.activePath == "/dst/fallback")
    }
    
    @MainActor
    @Test func testSelectionPruningOnDeepMove() async throws {
        let manager = FileSyncManager()
        
        let file1 = FileNode(id: "/src/folder/file1.txt", name: "file1.txt", isDirectory: false)
        let folder = FileNode(id: "/src/folder", name: "folder", isDirectory: true, children: [file1])
        manager.leftTree = [folder]
        
        manager.selectedLeftPaths = ["/src/folder", "/src/folder/file1.txt"]
        
        // A Move or Delete that removes the folder.
        manager.leftTree = []
        manager.pruneSelection()
        
        #expect(manager.selectedLeftPaths.isEmpty)
    }
}
