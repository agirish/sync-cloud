import Testing
import Sync
import Foundation
@testable import Dashboard

@Suite struct DashboardTests {

    // `activePath` delegates the pane-selection rule to `CurrentSelection.primaryPanePath`, whose
    // branches CurrentSelectionTests (in Sync) pins; DetailsActivePathAgreementTests pins the
    // delegation. Below, the leftPath-empty fallback has no other coverage.

    @MainActor
    @Test func testDetailsSidebarFallbackToDestIfSourceEmpty() async throws {
        let manager = FileSyncManager()
        // An empty source path, unlikely in the app but possible.
        let sidebar = DetailsSidebar(syncManager: manager, leftPath: "", rightPath: "/dst/fallback")

        #expect(sidebar.activePath == "/dst/fallback")
    }
}
