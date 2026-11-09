import Testing
import Foundation
import Sync
@testable import Dashboard

/// A pane's own Info describes that pane and never the other one. In Compare the panel that follows
/// the focused pane would describe the unfocused pane by the other pane's selection, or by none, so
/// each pane's Info is scoped (`ownPaneOnly`). Constructed, never rendered, as
/// `DetailsActivePathAgreementTests` explains.
@MainActor
@Suite struct DetailsOwnPaneTests {

    private func sidebar(_ manager: FileSyncManager, followsRight: Bool, overridePath: String? = nil,
                         ownPaneOnly: Bool = true) -> DetailsSidebar {
        DetailsSidebar(syncManager: manager, leftPath: "/left/root", rightPath: "/right/root",
                       overridePath: overridePath, singleSource: false, followsRight: followsRight,
                       ownPaneOnly: ownPaneOnly)
    }

    /// Both panes hold a selection: each pane's Info names its own. Mutation: reading the shared
    /// resolver, which prefers the left, must fail the right pane's line.
    @Test func eachPaneNamesItsOwnSelection() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/a.txt"]
        manager.selectedRightPaths = ["/right/b.txt"]
        #expect(sidebar(manager, followsRight: false).activePath == "/left/a.txt")
        #expect(sidebar(manager, followsRight: true).activePath == "/right/b.txt")
    }

    /// A pane with nothing selected shows its own folder, never the other pane's file. This is the
    /// case the focus-following panel got wrong for the unfocused pane.
    @Test func aPaneWithNothingSelectedShowsItsOwnFolder() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/a.txt"]
        let right = sidebar(manager, followsRight: true)
        #expect(right.activePath == "/right/root")
        #expect(right.isShowingFocusedFolderFallback)
        let left = sidebar(manager, followsRight: false)
        #expect(left.activePath == "/left/a.txt")
        #expect(!left.isShowingFocusedFolderFallback)
    }

    /// Several items in the other pane do not turn this pane's Info into a summary.
    @Test func theOtherPanesMultiSelectionIsNotThisPanesSummary() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/a.txt", "/left/b.txt"]
        manager.selectedRightPaths = ["/right/c.txt"]
        #expect(sidebar(manager, followsRight: true).selectionSummary == nil)
        #expect(sidebar(manager, followsRight: false).selectionSummary != nil)
    }

    /// A Get Info target still wins over the pane's selection, as it does for the shared panel.
    @Test func aGetInfoTargetStillWins() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/a.txt"]
        #expect(sidebar(manager, followsRight: false, overridePath: "/elsewhere/x.txt").activePath == "/elsewhere/x.txt")
    }

    /// Off, the panel is the shared one it was: the left pane first, unless the right is followed.
    @Test func withoutTheFlagNothingChanges() {
        let manager = FileSyncManager()
        manager.selectedLeftPaths = ["/left/a.txt"]
        manager.selectedRightPaths = ["/right/b.txt"]
        #expect(sidebar(manager, followsRight: false, ownPaneOnly: false).activePath == "/left/a.txt")
        #expect(sidebar(manager, followsRight: true, ownPaneOnly: false).activePath == "/right/b.txt")
    }
}
