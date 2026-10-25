import Testing
import CoreGraphics
@testable import FileExplorer

/// The result message docks in one stack with the action bar (Banner Room, CA), so the bar's flip
/// rule decides the pair's edge and the zone it covers is the two together. Same geometry as
/// `PaneBarPlacementTests`: a 600pt viewport, a 64pt bar, here a 60pt message.
@Suite struct PaneResultStackPlacementTests {

    private func makePlacement() -> PaneBarPlacement {
        let p = PaneBarPlacement()
        p.viewportHeight = 600
        p.coverage = 64
        p.messageCoverage = 60
        return p
    }

    @Test func theMessageWidensTheZoneTheBarCovers() {
        // A row ending at 500 clears a 64pt bar (covered from 536) but not bar + message (from 476).
        let p = makePlacement()
        p.rowBottoms = ["/a": 500]
        #expect(p.resolveAtTop(guarding: ["/a"], bar: true, message: false) == false)
        #expect(p.resolveAtTop(guarding: ["/a"], bar: true, message: true) == true,
                "the message would have drawn over the selected row")
    }

    @Test func aMessageAloneUsesItsOwnHeight() {
        // Browse has no bar: only the message's 60pt counts (covered from 540).
        let p = makePlacement()
        p.rowBottoms = ["/a": 530]
        #expect(p.resolveAtTop(guarding: ["/a"], bar: false, message: true) == false)
        p.rowBottoms = ["/a": 560]
        #expect(p.resolveAtTop(guarding: ["/a"], bar: false, message: true) == true)
    }

    @Test func anEmptyStackNeverLeavesTheBottom() {
        // Nothing to draw covers nothing — the render that only records the selection must not flip.
        let p = makePlacement()
        p.rowBottoms = ["/a": 590]
        #expect(p.resolveAtTop(guarding: ["/a"], bar: false, message: false) == false)
    }

    @Test func afterADeleteTheMessageStaysClearOfTheDeletedRowsSlot() {
        // The row is selected near the foot, the render records it, then the delete prunes both
        // the selection and the row. The message that arrives next must still dock at the top.
        let p = makePlacement()
        p.rowBottoms = ["/doomed": 580, "/next": 600]
        p.resolveAtTop(guarding: ["/doomed"], bar: false, message: false)
        p.rowBottoms = ["/next": 580]
        #expect(p.resolveAtTop(guarding: [], bar: false, message: true) == true,
                "the message covered the slot the deleted row left — where the next row now sits")
    }

    @Test func aDeletedRowNearTheTopLeavesTheMessageAtTheFoot() {
        // The opposite edge from the row acted on: a delete at the top keeps the message below.
        let p = makePlacement()
        p.rowBottoms = ["/doomed": 40]
        p.resolveAtTop(guarding: ["/doomed"], bar: false, message: false)
        p.rowBottoms = [:]
        #expect(p.resolveAtTop(guarding: [], bar: false, message: true) == false)
    }

    @Test func aScrollBeforeTheActMovesTheSlot() {
        // The geometry callback re-resolves with the selection of record, so the slot follows the
        // row while it is still on screen — a selection made low, then scrolled up, is no longer low.
        let p = makePlacement()
        p.rowBottoms = ["/doomed": 580]
        p.resolveAtTop(guarding: ["/doomed"], bar: false, message: false)
        p.rowBottoms = ["/doomed": 200]
        _ = p.reresolveMovedEdge()
        p.rowBottoms = [:]
        #expect(p.resolveAtTop(guarding: [], bar: false, message: true) == false)
    }

    @Test func aSelectionScrolledAwayIsNotReplacedByTheSlot() {
        // The slot stands in only for a selection that is GONE. One that is merely off screen has
        // nothing on screen to cover, as for the bar.
        let p = makePlacement()
        p.rowBottoms = ["/a": 580]
        p.resolveAtTop(guarding: ["/a"], bar: false, message: false)
        p.rowBottoms = [:]
        #expect(p.resolveAtTop(guarding: ["/a"], bar: false, message: true) == false)
    }
}
