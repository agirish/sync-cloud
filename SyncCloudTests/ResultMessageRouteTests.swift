import Testing
@testable import SyncCloud

/// **Where a result message shows** (Banner Room, CA): where the reader was working — never over
/// the window's top, where it covered the pane header's Delete for five seconds after a delete.
@Suite struct ResultMessageRouteTests {

    private func home(_ layout: ContentView.ContentLayout, focusedLeft: Bool = true,
                      inPane: Bool = false) -> ResultMessageHome {
        ResultMessageRoute.home(layout: layout, focusedPaneIsLeft: focusedLeft, lastWorkedInPane: inPane)
    }

    @Test func browseHasOnePaneAndItGoesThere() {
        #expect(home(.browseFull) == .pane(isLeft: true))
        #expect(home(.browseFull, focusedLeft: false) == .pane(isLeft: true))
    }

    /// Compare: the pane the action happened in, which every pane action focuses first — so the
    /// other pane, and the seam's ⇄ and 🔗 between them, stay uncovered (TE212).
    @Test func compareShowsItInTheFocusedPane() {
        #expect(home(.compareSplit, focusedLeft: true) == .pane(isLeft: true))
        #expect(home(.compareSplit, focusedLeft: false) == .pane(isLeft: false))
    }

    /// Organize and Edit: the source pane after a click there, otherwise the lens or the editor —
    /// where To File's moves and the editor's saves happen.
    @Test func organizeAndEditFollowTheLastClick() {
        for layout in [ContentView.ContentLayout.singleExpanded, .editorExpanded] {
            #expect(home(layout, inPane: true) == .pane(isLeft: true))
            #expect(home(layout, inPane: false) == .workspace)
        }
    }

    @Test func aCollapsedPaneIsNoPlaceForIt() {
        for layout in [ContentView.ContentLayout.singleCollapsed, .editorCollapsed] {
            #expect(home(layout, inPane: true) == .workspace)
        }
    }

    /// The window-top overlay is gone, and nothing else draws the message across the window.
    @Test func theWindowTopBannerIsGone() throws {
        let view = try macAppFile("ContentView.swift")
        #expect(view.contains("func paneColumn(isLeft: Bool)"), "the scan cannot find the pane column — vacuous")
        #expect(!view.contains("OperationBannerView("), "the message is drawn over the window again")
        #expect(view.contains("paneMessagePiece(isLeft: isLeft, message: message, atTop: barAtTop,"),
                "the pane's list no longer docks the message beside its bar")
    }
}
