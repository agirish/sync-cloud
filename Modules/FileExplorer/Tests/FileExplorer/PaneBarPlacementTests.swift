import Testing
import CoreGraphics
@testable import FileExplorer

/// The action bar's top/bottom placement math. Geometry convention: a 600pt viewport with a 64pt
/// measured bar coverage, so a bottom-docked bar covers rows whose bottom edge is below 536.
@Suite struct PaneBarPlacementTests {

    private func makePlacement(viewport: CGFloat = 600, coverage: CGFloat = 64) -> PaneBarPlacement {
        let p = PaneBarPlacement()
        p.viewportHeight = viewport
        p.coverage = coverage
        return p
    }

    @Test func testNoSelectionOrNoVisibleRowStaysBottom() {
        let p = makePlacement()
        #expect(p.resolveAtTop(selection: []) == false)
        // Selected but scrolled out of view (not in rowBottoms): nothing on screen to cover.
        #expect(p.resolveAtTop(selection: ["/a"]) == false)
    }

    @Test func testRowAboveTheBarKeepsTheBarAtBottom() {
        // The old flat 72pt band flipped here prematurely: 530 is inside 600-72 territory but the
        // real 64pt bar (covering below 536) does NOT overlap a row ending at 530.
        let p = makePlacement()
        p.rowBottoms = ["/a": 530]
        #expect(p.resolveAtTop(selection: ["/a"]) == false)
    }

    @Test func testRowUnderTheBarFlipsToTop() {
        let p = makePlacement()
        p.rowBottoms = ["/a": 560]
        #expect(p.resolveAtTop(selection: ["/a"]) == true)
    }

    @Test func testExitNeedsClearanceBeyondTheCoverageZone() {
        // Flip to top, then move the row just above the coverage line — inside the exit
        // hysteresis, so the bar must STAY at the top rather than bounce straight back.
        let p = makePlacement()
        p.rowBottoms = ["/a": 560]
        #expect(p.resolveAtTop(selection: ["/a"]) == true)
        p.rowBottoms = ["/a": 520]
        #expect(p.resolveAtTop(selection: ["/a"]) == true)
        // Well clear of the zone (536 - 44 = 492 threshold): back to the bottom.
        p.rowBottoms = ["/a": 480]
        #expect(p.resolveAtTop(selection: ["/a"]) == false)
    }

    @Test func testMultiSelectionFollowsTheLowestVisibleRow() {
        // Any selected row the bottom bar would cover flips it — the lowest row decides.
        let p = makePlacement()
        p.rowBottoms = ["/a": 100, "/b": 560]
        #expect(p.resolveAtTop(selection: ["/a", "/b"]) == true)
        p.rowBottoms = ["/a": 100, "/b": 300]
        p.rowBottoms["/b"] = 300
        #expect(p.resolveAtTop(selection: ["/a", "/b"]) == false)
    }

    @Test func testClearingTheSelectionResetsTheAnchor() {
        // atTop must not leak hysteresis into the NEXT selection: after a clear, a fresh click on
        // a mid-list row resolves bottom from a clean anchor.
        let p = makePlacement()
        p.rowBottoms = ["/a": 560]
        #expect(p.resolveAtTop(selection: ["/a"]) == true)
        #expect(p.resolveAtTop(selection: []) == false)
        p.rowBottoms = ["/b": 520]
        #expect(p.resolveAtTop(selection: ["/b"]) == false)
    }

    @Test func testResolveIsIdempotentForUnchangedInputs() {
        // The host calls this on every render; repeated calls with the same geometry and
        // selection must keep returning the same edge (no self-oscillation).
        let p = makePlacement()
        p.rowBottoms = ["/a": 560]
        let first = p.resolveAtTop(selection: ["/a"])
        for _ in 0..<5 {
            #expect(p.resolveAtTop(selection: ["/a"]) == first)
        }
    }

    @Test func testMeasuredCoverageMovesTheThreshold() {
        // A taller measured bar covers more of the list, so the flip line rises with it.
        let p = makePlacement(coverage: 100)
        p.rowBottoms = ["/a": 520]   // above a 64pt bar, but under a 100pt one (600-100=500)
        #expect(p.resolveAtTop(selection: ["/a"]) == true)
    }
}
