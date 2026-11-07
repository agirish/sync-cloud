import CoreGraphics
import Testing
@testable import SyncCloud

/// Where the pinned Ask Claude column fits, and what folds for it (`PaneLogic.pinRoom`). All at
/// Unified's zero gutter, the 373 pt column (372 and its seam) and the default 180 pt sidebar
/// (181 with its seam), unless a test says otherwise.
@Suite struct PinRoomTests {

    private func input(_ workspace: PaneLogic.PinWorkspace, _ row: CGFloat, sidebar: Bool = true, gutter: CGFloat = 0,
                       reopened: Bool = false, foldedByHand: Bool = false, dragging: Bool = false,
                       canFold: Bool = true) -> PaneLogic.PinRoomInput {
        PaneLogic.PinRoomInput(workspace: workspace, rowWidth: row, columnWidth: 373, gutter: gutter,
                               sidebarShown: sidebar, sidebarStored: 180, sidebarReopenedByHand: reopened,
                               foldedByHand: foldedByHand, dragging: dragging, canFold: canFold)
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
        // To File is 72% of what the sidebar leaves; under 640 pt it folds. Unfolded, it fits from 1,084.
        #expect(verdict(input(.organize, 1442)) == .init(fits: true, folds: true))
        #expect(verdict(input(.organize, 1443)) == .init(fits: true, folds: false))
        #expect(verdict(input(.organize, 1600)) == .init(fits: true, folds: false))
    }

    @Test func organizeFoldedNeedsOnlyItsSpineAndTheLens() {
        // Spine 34 and To File 340, no sidebar: 747. With the sidebar brought back by hand, 898.
        #expect(verdict(input(.organize, 746)).fits == false)
        #expect(verdict(input(.organize, 747)) == .init(fits: true, folds: true))
        #expect(verdict(input(.organize, 897, reopened: true)).fits == false)
        #expect(verdict(input(.organize, 898, reopened: true)).fits)
    }

    @Test func aPaneFoldedByHandIsNeverTheOnesToFold() {
        // The person folded it: nothing for the pin to fold, and it needs only what folded needs.
        #expect(verdict(input(.organize, 1000, foldedByHand: true)) == .init(fits: true, folds: false))
        #expect(verdict(input(.organize, 746, foldedByHand: true)).fits == false)
    }

    // MARK: Edit folds its list

    @Test func editFoldsItsListWhenTheDocumentWouldLoseItsWidth() {
        // The document is under 600 pt below a 1,420 pt row; folded it needs only 818.
        #expect(verdict(input(.edit, 1419)) == .init(fits: true, folds: true))
        #expect(verdict(input(.edit, 1420)) == .init(fits: true, folds: false))
        #expect(verdict(input(.edit, 817)).fits == false)
        #expect(verdict(input(.edit, 818)) == .init(fits: true, folds: true))
        #expect(verdict(input(.edit, 817, foldedByHand: true)).fits == false)
        #expect(verdict(input(.edit, 818, foldedByHand: true)) == .init(fits: true, folds: false), "a hand fold is not the pin's")
    }

    // MARK: A window on a line does not flip

    @Test func aFoldKeepsItselfUntilFortyPointsPastTheLine() {
        let folded = PaneLogic.PinVerdict(fits: true, folds: true)
        let open = PaneLogic.PinVerdict(fits: true, folds: false)
        // 1,443 is past the line, but a folded pane waits for the 40-pt margin (to about 1,499).
        #expect(verdict(input(.organize, 1443), after: folded).folds)
        #expect(verdict(input(.organize, 1498), after: folded).folds)
        #expect(verdict(input(.organize, 1499), after: folded).folds == false)
        // Open, it stays open down to the line itself.
        #expect(verdict(input(.organize, 1443), after: open).folds == false)
        #expect(verdict(input(.organize, 1442), after: open).folds)
    }

    @Test func aFloatingPanelPinsAgainOnlyFortyPointsPastWhatItNeeds() {
        let floating = PaneLogic.PinVerdict.floating
        let pinned = PaneLogic.PinVerdict(fits: true, folds: false)
        #expect(verdict(input(.browse, 800), after: floating).fits == false)
        #expect(verdict(input(.browse, 813), after: floating).fits == false)
        #expect(verdict(input(.browse, 814), after: floating).fits)
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
