import Testing
import Foundation
@testable import Sync

/// An undoable completion banner's Undo button calls `undoManager.undo()`, which pops the current
/// top step. Once another operation registers an undo (New Folder, say, which posts no banner), that
/// button would reverse the wrong operation, so registering drops the stale undoable banner.
/// Warning and error banners are left alone.
@Suite struct UndoBannerInvalidationTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        FileSyncManager.forTests()
    }

    @MainActor
    @Test func testUndoableBannerClearedWhenAnotherOperationRegistersUndo() {
        let manager = makeManager()
        manager.banner = .success("Copied 5 items", undoable: true)
        // A subsequent New Folder registers an undo step and sets no banner of its own — the stale
        // "Copied 5 items" Undo would now trash the folder, so the banner must be dropped.
        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/tmp/does-not-matter/NewFolder"))
        #expect(manager.banner == nil)
    }

    @MainActor
    @Test func testUndoableBannerClearedByCopyRegistration() {
        let manager = makeManager()
        manager.banner = .success("Deleted 3 items", undoable: true)
        manager.registerCopyUndo(items: [], actionName: "Copy 1 Item")
        #expect(manager.banner == nil)
    }

    @MainActor
    @Test func testNonUndoableBannerSurvivesUndoRegistration() {
        let manager = makeManager()
        // A warning/error banner is not an undo affordance and is often sticky — an unrelated
        // operation must not make it vanish.
        manager.banner = .warning("Couldn’t file 2 files.")
        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/tmp/does-not-matter/NewFolder"))
        #expect(manager.banner?.message == "Couldn’t file 2 files.")
        #expect(manager.banner?.severity == .warning)
    }

    @MainActor
    @Test func testNoBannerStaysNil() {
        let manager = makeManager()
        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/tmp/does-not-matter/NewFolder"))
        #expect(manager.banner == nil)
    }
}
