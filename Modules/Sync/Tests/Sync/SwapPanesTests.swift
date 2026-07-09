import Testing
import Foundation
@testable import Sync

@Suite struct SwapPanesTests {

    @MainActor
    @Test func testSwapPanesExchangesPathsSelectionsAndHistories() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())

        // Drive each pane to a distinct focused folder (which also builds a distinct history),
        // and select in one pane (the one-pane-selected invariant is enforced at the UI layer).
        manager.focusOn(relativePath: "left/deep", isLeft: true)
        manager.focusOn(relativePath: "right", isLeft: false)
        manager.selectedLeftPaths = ["/l/a", "/l/b"]

        let leftRelBefore = manager.leftRelativePath      // "left/deep"
        let rightRelBefore = manager.rightRelativePath    // "right"
        let leftHistBefore = manager.leftHistory
        let rightHistBefore = manager.rightHistory
        let leftSelBefore = manager.selectedLeftPaths      // ["/l/a", "/l/b"]
        let rightSelBefore = manager.selectedRightPaths    // []

        manager.swapPanes()

        // Every paired field lands on the opposite side.
        #expect(manager.leftRelativePath == rightRelBefore)
        #expect(manager.rightRelativePath == leftRelBefore)
        #expect(manager.selectedLeftPaths == rightSelBefore)
        #expect(manager.selectedRightPaths == leftSelBefore)
        #expect(manager.leftHistory == rightHistBefore)
        #expect(manager.rightHistory == leftHistBefore)
        // The relative paths stay consistent with the swapped histories' current entries, so
        // per-pane Back/Forward still walks the right stack after the flip.
        #expect(manager.leftRelativePath == manager.leftHistory.current)
        #expect(manager.rightRelativePath == manager.rightHistory.current)

        // Swapping again is an exact inverse — the original arrangement is restored.
        manager.swapPanes()
        #expect(manager.leftRelativePath == leftRelBefore)
        #expect(manager.rightRelativePath == rightRelBefore)
        #expect(manager.leftHistory == leftHistBefore)
        #expect(manager.rightHistory == rightHistBefore)
        #expect(manager.selectedLeftPaths == leftSelBefore)
        #expect(manager.selectedRightPaths == rightSelBefore)
    }
}
