import Testing
import Foundation
import FileExplorer
import Design
@testable import SyncCloud

/// **The spine's list buttons are Edit's alone, and each does what its lit state says** (TE77).
///
/// The rungs are `ContentView.spineRungs`, a pure function, and the buttons' rule is
/// `EditorRailFold`, because `railSpine` reads property wrappers off a `ContentView` no unit test
/// can construct. The drawn spine is the walkthrough's job.
///
/// **Local-only** — app target, invisible to CI; run by hand and named in the commit body.
@Suite struct EditorRailSpineTests {

    @Test func everySpineHasTheSourcePaneRung() {
        for workspace in Workspace.allCases {
            #expect(ContentView.spineRungs(workspace: workspace).first == .sourcePane,
                    "\(workspace.title) does not lead with the pane rung")
        }
    }

    /// The list is Edit's: a stray button in Organize's spine would be the first thing clicked.
    @Test func otherWorkspacesDrawOnlyThePaneRung() {
        for workspace in Workspace.allCases where workspace != .editor {
            #expect(ContentView.spineRungs(workspace: workspace) == [.sourcePane],
                    "\(workspace.title) draws a list button")
        }
    }

    /// Edit: one button per tab, under the pane's, whether the list is showing or not — the strip
    /// does not grow and shrink as the list opens and folds.
    @Test func editDrawsAButtonPerTabUnderThePaneRung() {
        let rungs = ContentView.spineRungs(workspace: .editor)
        #expect(rungs == [.sourcePane, .textFiles, .outline])
        #expect(rungs.compactMap(\.railTab) == EditorRailTab.shown(pdfIsOpen: false, pdfHasOutline: false),
                "a rail tab has no button in the strip, or a button opens the wrong tab")
        // A PDF adds the Pages tab to the rail, and its button to the strip — the same rule.
        let withPDF = ContentView.spineRungs(workspace: .editor, pdfIsOpen: true, pdfHasOutline: true)
        #expect(withPDF == [.sourcePane, .textFiles, .pages, .outline])
        #expect(withPDF.compactMap(\.railTab) == EditorRailTab.shown(pdfIsOpen: true, pdfHasOutline: true))
        // …and a PDF without a contents drops Outline from both (asked 2026-10-17).
        #expect(ContentView.spineRungs(workspace: .editor, pdfIsOpen: true, pdfHasOutline: false)
                    == [.sourcePane, .textFiles, .pages])
        #expect(ContentView.spineRungs(workspace: .browse, pdfIsOpen: true) == [.sourcePane],
                "a PDF open in Edit put a list button on another workspace's strip")
    }

    /// The glyph is the tab's own, so the button and the tab it opens match.
    @Test func eachButtonWearsItsTabsGlyph() {
        #expect(ContentView.railRungSymbol(.files) == "doc.text")
        #expect(ContentView.railRungSymbol(.outline) == "list.bullet.indent")
        #expect(ContentView.railRungSymbol(.pages) == "square.grid.2x2")
    }

    // MARK: What a button does

    /// Not on screen — folded by hand or put away by Expand: either button brings the list back,
    /// on its own tab, whichever tab was showing last.
    @Test(arguments: EditorRailTab.allCases)
    func aButtonShowsAHiddenListOnItsOwnTab(last: EditorRailTab) {
        for tab in EditorRailTab.allCases {
            #expect(EditorRailFold.rungAct(for: tab, railDrawn: false, currentTab: last) == .show(tab))
            #expect(!EditorRailFold.rungIsLit(tab, railDrawn: false, currentTab: last),
                    "a button is lit with no list on screen")
        }
    }

    /// On screen: the lit button — the tab showing — folds it; the other switches tabs and leaves
    /// it open. Mutation: make `.switchTo` fold and the other-tab row fails.
    @Test func theLitButtonFoldsAndTheOtherSwitchesTabs() {
        #expect(EditorRailFold.rungAct(for: .files, railDrawn: true, currentTab: .files) == .fold)
        #expect(EditorRailFold.rungAct(for: .outline, railDrawn: true, currentTab: .outline) == .fold)
        #expect(EditorRailFold.rungAct(for: .outline, railDrawn: true, currentTab: .files) == .switchTo(.outline))
        #expect(EditorRailFold.rungAct(for: .files, railDrawn: true, currentTab: .outline) == .switchTo(.files))
        #expect(EditorRailFold.rungIsLit(.files, railDrawn: true, currentTab: .files))
        #expect(!EditorRailFold.rungIsLit(.outline, railDrawn: true, currentTab: .files))
    }

    /// The tooltip names the next act, as Expand's word does: Hide on the lit button, Show on the rest.
    @Test func theTitleNamesTheNextAct() {
        #expect(EditorRailFold.rungTitle(.files, railDrawn: true, currentTab: .files) == "Hide the files")
        #expect(EditorRailFold.rungTitle(.outline, railDrawn: true, currentTab: .files) == "Show the outline")
        #expect(EditorRailFold.rungTitle(.files, railDrawn: false, currentTab: .files) == "Show the files")
        #expect(EditorRailFold.rungTitle(.pages, railDrawn: true, currentTab: .files) == "Show the pages")
        #expect(EditorRailFold.rungTitle(.pages, railDrawn: true, currentTab: .pages) == "Hide the pages")
        #expect(EditorRailFold.rungTitle(.outline, railDrawn: true, currentTab: .outline) == "Hide the outline")
    }

    // MARK: The hand fold beside Expand

    /// **Expand gives back a list folded by hand still folded, and an open one open.** Expand moves
    /// only its own bit; the hand fold is the other. So entering and leaving Expand from either
    /// state lands where it began.
    @Test(arguments: [false, true])
    func expandRoundTripsAListFoldedByHand(folded: Bool) {
        var expand = EditorExpand(railHidden: false, paneFolded: true,
                                  sidebarPutAway: false, paneFoldedByExpand: false)
        let before = TopPaneVisibility.editorRailIsDrawn(paneHidden: expand.paneFolded,
                                                         railHidden: expand.railHidden, railFolded: folded)
        expand.enter(sidebarShowing: true)
        #expect(!TopPaneVisibility.editorRailIsDrawn(paneHidden: expand.paneFolded,
                                                     railHidden: expand.railHidden, railFolded: folded))
        expand.leave()
        #expect(TopPaneVisibility.editorRailIsDrawn(paneHidden: expand.paneFolded,
                                                    railHidden: expand.railHidden, railFolded: folded) == before,
                "leaving Expand did not give back the list as it was (folded=\(folded))")
    }

    /// **Folding by hand does not turn Expand on.** Expand's lit state reads its own bit and the
    /// pane; the hand fold touches neither.
    @Test func aHandFoldLeavesExpandOff() {
        let expand = EditorExpand(railHidden: false, paneFolded: true,
                                  sidebarPutAway: false, paneFoldedByExpand: false)
        #expect(!expand.isOn)
        #expect(!TopPaneVisibility.editorRailIsDrawn(paneHidden: true, railHidden: expand.railHidden, railFolded: true))
    }

    // MARK: The pane as one of the strip's columns (asked 2026-10-17)

    /// The cloud follows the list buttons' rule: lit means showing, and the lit one folds.
    @Test func thePaneButtonOpensAFoldedPaneAndFoldsAnOpenOne() {
        #expect(EditorRailFold.paneRungAct(paneOpen: false) == .openPane)
        #expect(EditorRailFold.paneRungAct(paneOpen: true) == .foldPane)
        #expect(EditorRailFold.paneRungTitle(paneOpen: true, source: "iCloud") == "Hide the iCloud pane")
        #expect(EditorRailFold.paneRungTitle(paneOpen: false, source: "iCloud").hasPrefix("Show the iCloud pane"))
    }

    /// A list button beside an open pane shows the list: the list is not drawn there, so the rule
    /// answers `.show` — and the host folds the pane on the way (`showEditorRail`).
    @Test(arguments: EditorRailTab.allCases)
    func aListButtonBesideAnOpenPaneShowsTheList(tab: EditorRailTab) {
        #expect(EditorRailFold.rungAct(for: tab, railDrawn: false, currentTab: .files) == .show(tab))
    }

    /// **One width for the four columns, and one column for the pane by default.** The pane's slot
    /// is the column's card plus the gutter a card's insets add, as the rail's own slot is; and at
    /// the default width that card is under where Columns stops showing a second column, so the
    /// pane shows one with ‹ to walk back. Mutation: raise `railWidth` past 280 and the second fails.
    @Test func theOpenPaneIsTheListsWidthAndOneColumnWideByDefault() {
        let slot: CGFloat = ContentView.editorColumnSlot(EditorLayoutMetrics.railWidth)
        let railSlot: CGFloat = EditorLayoutMetrics.railWidth + LiquidGlass.cardGutter
        #expect(abs(slot - railSlot) < 0.001, "the pane's slot is \(slot)pt, the list's \(railSlot)pt")
        #expect(PaneViewMode.usesPushNavigation(paneWidth: EditorLayoutMetrics.railWidth))
    }

    /// **The shared width drags between the tabs' floor and the cap**, and never below the floor:
    /// the list's three tabs are measured to fit at exactly `railWidth`.
    @Test func theColumnWidthStaysBetweenTheTabsFloorAndTheCap() {
        #expect(EditorLayoutMetrics.clampedRailWidth(100) == EditorLayoutMetrics.railWidth)
        #expect(EditorLayoutMetrics.clampedRailWidth(300) == 300)
        #expect(EditorLayoutMetrics.clampedRailWidth(9_000) == EditorLayoutMetrics.maxRailWidth)
        #expect(EditorLayoutMetrics.maxRailWidth > EditorLayoutMetrics.railWidth)
    }
}
