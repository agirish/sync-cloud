import CoreGraphics
import Testing
@testable import SyncCloud

/// Where Ask Claude's column fits beside the workspace, and what folds for it (`PaneLogic.pinRoom`). All at
/// Unified's zero gutter, the 373 pt column (372 and its seam) and the default 180 pt sidebar
/// (181 with its seam), unless a test says otherwise.
@Suite struct PinRoomTests {

    private func input(_ workspace: PaneLogic.PinWorkspace, _ row: CGFloat, sidebar: Bool = true, gutter: CGFloat = 0,
                       reopened: Bool = false, railFraction: Double = 0.28, foldedByHand: Bool = false,
                       dragging: Bool = false, canFold: Bool = true) -> PaneLogic.PinRoomInput {
        PaneLogic.PinRoomInput(workspace: workspace, rowWidth: row, columnWidth: 373, gutter: gutter,
                               sidebarShown: sidebar, sidebarStored: 180, sidebarReopenedByHand: reopened,
                               railFraction: railFraction, foldedByHand: foldedByHand, dragging: dragging, canFold: canFold)
    }

    private func verdict(_ i: PaneLogic.PinRoomInput, after previous: PaneLogic.PinVerdict? = nil) -> PaneLogic.PinVerdict {
        PaneLogic.pinRoom(i, previous: previous)
    }

    // MARK: Where it fits

    @Test func browseFitsOnceItsSidebarHasSqueezed() {
        // One pane at 250 and the sidebar at its 150 floor, with the column: 773 floats, 774 pins.
        #expect(verdict(input(.browse, 773)).fits == false)
        #expect(verdict(input(.browse, 774)).fits)
        #expect(verdict(input(.browse, 700, sidebar: false)).fits, "no sidebar: only the pane's 250")
        #expect(verdict(input(.browse, 622, sidebar: false)).fits == false)
        #expect(verdict(input(.browse, 623, sidebar: false)).fits)
    }

    @Test func compareNeedsBothPanes() {
        #expect(verdict(input(.compare, 1023)).fits == false)
        #expect(verdict(input(.compare, 1024)).fits)
        #expect(verdict(input(.compare, 1440)).fits && !verdict(input(.compare, 1440)).folds, "Compare never folds")
    }

    // MARK: Organize folds its folder pane, and its sidebar with it

    @Test func organizeFoldsWhenToFileWouldLoseItsButtons() {
        // To File is 72% of what the sidebar leaves; under 520 pt it folds (where its summary row starts moving buttons into ⋯). Unfolded, it fits from 1,084.
        #expect(verdict(input(.organize, 1276)) == .init(fits: true, folds: true))
        #expect(verdict(input(.organize, 1277)) == .init(fits: true, folds: false))
        // The common 13-inch window folds nothing.
        #expect(verdict(input(.organize, 1440)) == .init(fits: true, folds: false))
        #expect(verdict(input(.organize, 1600)) == .init(fits: true, folds: false))
    }

    @Test func organizeFoldedNeedsOnlyItsSpineAndTheLens() {
        // Spine 34 and To File 340, no sidebar: 747. With the sidebar brought back by hand, 898.
        #expect(verdict(input(.organize, 746)).fits == false)
        #expect(verdict(input(.organize, 747)) == .init(fits: true, folds: true))
        #expect(verdict(input(.organize, 897, reopened: true)).fits == false)
        #expect(verdict(input(.organize, 898, reopened: true)).fits)
    }

    /// To File is what the rail leaves, so a wider rail folds sooner: at 1,400 pt the default 28%
    /// rail leaves To File 609 pt, a 45% rail 465.
    @Test func organizesFoldLineMovesWithTheRailsSplit() {
        #expect(verdict(input(.organize, 1400)) == .init(fits: true, folds: false))
        #expect(verdict(input(.organize, 1400, railFraction: 0.45)) == .init(fits: true, folds: true))
    }

    /// The window feeds the rule the sidebar it brought back by hand and the rail's split as drawn,
    /// a drag's value first. Before, neither reached it, and the rule read its defaults.
    @Test func theWindowFeedsTheRuleTheReopenedSidebarAndTheLiveRail() throws {
        let call = try CallArguments(of: "PaneLogic.PinRoomInput(", in: normalizedCode(macAppFile("ContentView+AskClaude.swift")))
        #expect(call.passes("sidebarReopenedByHand", "askClaudePinSidebarShown"))
        #expect(call.passes("railFraction", "railDragFraction ?? railFraction"))
    }

    @Test func aPaneFoldedByHandIsNeverTheOnesToFold() {
        // The person folded it: nothing for the pin to fold, and it needs only what folded needs.
        #expect(verdict(input(.organize, 1000, foldedByHand: true)) == .init(fits: true, folds: false))
        #expect(verdict(input(.organize, 746, foldedByHand: true)).fits == false)
    }

    // MARK: Edit folds its list

    @Test func editFoldsItsListWhenTheDocumentWouldLoseItsWidth() {
        // The document is under 450 pt below a 1,270 pt row; folded it needs only 818.
        #expect(verdict(input(.edit, 1269)) == .init(fits: true, folds: true))
        #expect(verdict(input(.edit, 1270)) == .init(fits: true, folds: false))
        // The common 13-inch window folds nothing.
        #expect(verdict(input(.edit, 1440)) == .init(fits: true, folds: false))
        #expect(verdict(input(.edit, 817)).fits == false)
        #expect(verdict(input(.edit, 818)) == .init(fits: true, folds: true))
        #expect(verdict(input(.edit, 817, foldedByHand: true)).fits == false)
        #expect(verdict(input(.edit, 818, foldedByHand: true)) == .init(fits: true, folds: false), "a hand fold is not the pin's")
    }

    // MARK: A window on a line does not flip

    @Test func aFoldKeepsItselfUntilFortyPointsPastTheLine() {
        let folded = PaneLogic.PinVerdict(fits: true, folds: true)
        let open = PaneLogic.PinVerdict(fits: true, folds: false)
        // 1,277 is past the line, but a folded pane waits for the 40-pt margin (to about 1,332).
        #expect(verdict(input(.organize, 1277), after: folded).folds)
        #expect(verdict(input(.organize, 1331), after: folded).folds)
        #expect(verdict(input(.organize, 1332), after: folded).folds == false)
        // Open, it stays open down to the line itself.
        #expect(verdict(input(.organize, 1277), after: open).folds == false)
        #expect(verdict(input(.organize, 1276), after: open).folds)
    }

    @Test func aFloatingPanelPinsAgainOnlyFortyPointsPastWhatItNeeds() {
        let overlaid = PaneLogic.PinVerdict.overlay
        let pinned = PaneLogic.PinVerdict(fits: true, folds: false)
        #expect(verdict(input(.browse, 800), after: overlaid).fits == false)
        #expect(verdict(input(.browse, 813), after: overlaid).fits == false)
        #expect(verdict(input(.browse, 814), after: overlaid).fits)
        // Pinned, it stays down to what it needs.
        #expect(verdict(input(.browse, 774), after: pinned).fits)
        #expect(verdict(input(.browse, 773), after: pinned).fits == false)
    }

    @Test func nothingSwitchesWhileASplitterIsDragged() {
        let pinned = PaneLogic.PinVerdict(fits: true, folds: false)
        #expect(verdict(input(.browse, 300, dragging: true), after: pinned) == pinned, "it holds until the drag ends")
        #expect(verdict(input(.browse, 300, dragging: false), after: pinned).fits == false)
        // With nothing to hold, a dragged window still gets an answer.
        #expect(verdict(input(.browse, 300, dragging: true)).fits == false)
    }

    // MARK: Before the window can fold

    /// Until the window can fold a pane, a pin that would need the fold floats instead, rather than
    /// squeezing Organize or Edit below its minimum.
    @Test func withoutFoldingTheWorkspaceNeedsItsPanesOpen() {
        #expect(verdict(input(.organize, 1083, canFold: false)).fits == false)
        #expect(verdict(input(.organize, 1084, canFold: false)) == .init(fits: true, folds: false))
        #expect(verdict(input(.edit, 1049, canFold: false)).fits == false)
        #expect(verdict(input(.edit, 1050, canFold: false)) == .init(fits: true, folds: false))
        // A pane the person folded needs only what folded needs, with or without the pin's fold.
        #expect(verdict(input(.organize, 747, foldedByHand: true, canFold: false)).fits)
        #expect(verdict(input(.browse, 774, canFold: false)).fits)
    }

    // MARK: Cards: the five-point gutters

    @Test func cardsCostTheGutterOnTheSidebarAndTheSpine() {
        // The sidebar's overhead is the gutter plus its seam, and the spine's card adds a gutter.
        #expect(verdict(input(.browse, 778, gutter: 5)).fits == false)
        #expect(verdict(input(.browse, 779, gutter: 5)).fits)
        #expect(verdict(input(.organize, 751, gutter: 5)).fits == false)
        #expect(verdict(input(.organize, 752, gutter: 5)).fits)
    }
}

/// What the pin folds is computed, never stored: a fold made by hand is never overwritten, and
/// opening a pane the pin folded ends the pin's fold without touching what is stored.
@Suite struct PinFoldTests {

    @Test func thePinsFoldIsOnlyDrawnNeverStoredOverAHandFold() {
        // Nothing stored, nothing wanted: the pane is open.
        #expect(PaneLogic.panesDrawnHidden(stored: false, pinFoldWanted: false, releasedByHand: false) == false)
        // The pin wants it folded: drawn folded, with nothing stored.
        #expect(PaneLogic.panesDrawnHidden(stored: false, pinFoldWanted: true, releasedByHand: false))
        // The person opened it: the pin's fold is over, and the stored value was never touched.
        #expect(PaneLogic.panesDrawnHidden(stored: false, pinFoldWanted: true, releasedByHand: true) == false)
        // A fold made by hand stays, whatever the pin says.
        #expect(PaneLogic.panesDrawnHidden(stored: true, pinFoldWanted: false, releasedByHand: false))
        #expect(PaneLogic.panesDrawnHidden(stored: true, pinFoldWanted: true, releasedByHand: true))
    }

    /// The sidebar brought back beside a folded Organize pane has more room than one beside an open
    /// rail: the rail's 220 minimum becomes the spine and its gutter.
    @Test func aSidebarBesideTheSpineGetsTheRoomTheRailWouldHaveTaken() {
        let open = PaneLogic.lensSidebarWidth(stored: 280, totalWidth: 1000, minSidebar: 150, gutter: 0)
        let folded = PaneLogic.lensSidebarWidth(stored: 280, totalWidth: 1000, minSidebar: 150, gutter: 0, railCollapsed: true)
        #expect(open == 280)
        #expect(folded == 280, "room for 280 beside a 34 pt spine and To File's 340")
        // At the floor the open rail squeezes it to 150; the spine leaves it more.
        let squeezedOpen = PaneLogic.lensSidebarWidth(stored: 280, totalWidth: 760, minSidebar: 150, gutter: 0)
        let squeezedFolded = PaneLogic.lensSidebarWidth(stored: 280, totalWidth: 760, minSidebar: 150, gutter: 0, railCollapsed: true)
        #expect(squeezedFolded > squeezedOpen)
        #expect(squeezedOpen == 199)
    }
}
