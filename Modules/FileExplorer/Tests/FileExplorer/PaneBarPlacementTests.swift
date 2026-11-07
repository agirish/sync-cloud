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

    @Test func testGlobalOffsetDoesNotShiftTheThreshold() {
        // Rows report in global (window) coordinates, so a list sitting 210pt below the window top
        // must not flip 210pt early. The 5th row of an 11-row list (visual bottom ≈ 190 in a 430pt
        // viewport) stays at the bottom; a row visually inside the covered zone still flips. So the
        // global-origin subtraction happens before the on-screen clamp: an offset list must not
        // make every one of its rows look past the fold.
        let p = makePlacement(viewport: 430)
        p.viewportGlobalMinY = 210
        p.rowBottoms = ["/5": 210 + 190]
        #expect(p.resolveAtTop(selection: ["/5"]) == false)
        p.rowBottoms = ["/10": 210 + 400]   // visual 400 > 430 − 64 → the bar would cover it
        #expect(p.resolveAtTop(selection: ["/10"]) == true)
    }

    @Test func testNoSelectionOrNoVisibleRowStaysBottom() {
        let p = makePlacement()
        #expect(p.resolveAtTop(selection: []) == false)
        // Selected but scrolled out of view (not in rowBottoms): nothing on screen to cover.
        #expect(p.resolveAtTop(selection: ["/a"]) == false)
    }

    @Test func testRowAboveTheBarKeepsTheBarAtBottom() {
        // 530 is above the measured 64pt bar (which covers below 536), so a wider fixed band would
        // flip here too early.
        let p = makePlacement()
        p.rowBottoms = ["/a": 530]
        #expect(p.resolveAtTop(selection: ["/a"]) == false)
    }

    @Test func testExitNeedsClearanceBeyondTheCoverageZone() {
        // A row under the bar flips it to the top. Then move the row just above the coverage line,
        // inside the exit hysteresis, so the bar must STAY at the top rather than bounce back.
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

    // MARK: Only ON-SCREEN rows count

    /// `rowBottoms` also carries rows the List laid out past the fold. A selected row down there is
    /// invisible, so a bottom bar covers nothing of it; flipping to the top would just put the bar
    /// over rows the user can see.
    @Test func testRowBelowTheViewportDoesNotFlipTheBar() {
        let p = makePlacement()
        p.rowBottoms = ["/a": 900]      // viewport is 600 — well past the fold
        #expect(p.resolveAtTop(selection: ["/a"]) == false)
    }

    /// The same case in a multi-selection: one off-screen sibling must not drag the bar over the
    /// selected row that is on screen and uncovered.
    @Test func testOffscreenSiblingDoesNotFlipOverTheVisibleRow() {
        let p = makePlacement()
        p.rowBottoms = ["/visible": 40, "/offscreen": 3000]
        #expect(p.resolveAtTop(selection: ["/visible", "/offscreen"]) == false)
    }

    /// A row exactly at the viewport's bottom edge is still on screen, and a bottom bar covers it:
    /// the clamp must not exclude the boundary row it exists to protect.
    @Test func testRowExactlyAtTheViewportEdgeStillCounts() {
        let p = makePlacement()
        p.rowBottoms = ["/a": 600]
        #expect(p.resolveAtTop(selection: ["/a"]) == true)
    }

    /// A pane shorter than the bar is covered end to end at either edge, so no placement reveals
    /// anything: stay at the resting bottom. A negative `coveredFrom` would read every row as
    /// covered and pin the bar to the top of a tiny pane.
    @Test func testPaneShorterThanTheBarStaysAtTheBottom() {
        let p = makePlacement(viewport: 50, coverage: 64)
        p.rowBottoms = ["/a": 10]
        #expect(p.resolveAtTop(selection: ["/a"]) == false)
    }
}
