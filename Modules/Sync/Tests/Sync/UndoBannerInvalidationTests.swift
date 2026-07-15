import Testing
import Foundation
@testable import Sync

/// Pins the fix for the review's C1: a still-showing *undoable* completion banner offers an Undo
/// button wired to `undoManager.undo()`, which pops the CURRENT top step. Once any other operation
/// registers an undo (e.g. New Folder, which posts no banner of its own), that button would reverse
/// the wrong operation. Registration now invalidates the stale undoable banner. Non-undoable
/// (warning/error) banners must be left alone.
@Suite struct UndoBannerInvalidationTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.permanentDeleteConfirmer = { _ in false }
        return manager
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
        manager.registerCopyUndo(items: [], actionName: "Copy 1 Items")
        #expect(manager.banner == nil)
    }

    @MainActor
    @Test func testNonUndoableBannerSurvivesUndoRegistration() {
        let manager = makeManager()
        // A warning/error banner is not an undo affordance and is often sticky — an unrelated
        // operation must not make it vanish.
        manager.banner = .warning("Couldn't file 2 files.")
        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/tmp/does-not-matter/NewFolder"))
        #expect(manager.banner?.message == "Couldn't file 2 files.")
        #expect(manager.banner?.severity == .warning)
    }

    @MainActor
    @Test func testNoBannerStaysNil() {
        let manager = makeManager()
        manager.registerCreateFolderUndo(url: URL(fileURLWithPath: "/tmp/does-not-matter/NewFolder"))
        #expect(manager.banner == nil)
    }
}
