import Testing
import Sync
import Foundation
import SwiftUI
import Design
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
    @Test func testSingleSourceInspectorIgnoresTheHiddenRightPane() async throws {
        // On the Tidy rail the right pane is hidden, so a selection lingering there (from a prior
        // Compare session) must not drive the inspector — otherwise it would describe a file in the
        // wrong provider. With `singleSource`, a right-only selection is ignored and the panel falls
        // back to the left rail's focused folder.
        let manager = FileSyncManager()
        let railFolder = "/rail/folder"
        let sidebar = DetailsSidebar(syncManager: manager, leftPath: railFolder, rightPath: "/hidden/right",
                                     singleSource: true)

        manager.selectedRightPaths = ["/hidden/right/other.txt"]
        #expect(sidebar.activePath == railFolder)
        #expect(sidebar.isShowingFocusedFolderFallback)

        // A real rail (left) selection still shows through.
        manager.selectedLeftPaths = ["/rail/folder/file.txt"]
        #expect(sidebar.activePath == "/rail/folder/file.txt")

        // The same view WITHOUT singleSource would follow the right selection — the default (Compare)
        // behavior is unchanged.
        let compare = DetailsSidebar(syncManager: manager, leftPath: railFolder, rightPath: "/hidden/right")
        manager.selectedLeftPaths = []
        #expect(compare.activePath == "/hidden/right/other.txt")
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

    /// The stale badge and the differences pill's dot are supposed to be ONE colour, not two that
    /// nearly match — the whole reason `FreshnessStyle.stale` reads out of Design instead of
    /// restating its triad. Pins the sharing itself rather than the values: a future re-tune of
    /// `.attention` should move the badge with it, and only a copy-paste regression should fail.
    @Test func staleFreshnessIsTheAttentionCapsule() {
        for scheme in [ColorScheme.light, .dark] {
            let badge = FreshnessStyle.of(.stale, scheme)
            let capsule = SemanticCapsuleStyle.of(.attention, scheme)
            #expect(badge.fill == capsule.fill)
            #expect(badge.content == capsule.content)
            #expect(badge.dot == capsule.dot)
        }
    }

    /// The three states must stay visually separable — `stale` moving from amber to terracotta
    /// walked it toward nothing, but a future tune could, and a badge whose colour no longer
    /// distinguishes "fresh" from "may be out of date" has lost its only job.
    @Test func theThreeFreshnessStatesAreDistinguishable() {
        for scheme in [ColorScheme.light, .dark] {
            let fills = [FreshnessState.fresh, .stale, .scanning].map { FreshnessStyle.of($0, scheme).fill }
            #expect(Set(fills.map { String(describing: $0) }).count == 3, "\(scheme) fills collapsed: \(fills)")
        }
    }
}
