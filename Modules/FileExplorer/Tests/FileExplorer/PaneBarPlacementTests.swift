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
        // Rows report in window coordinates, so a list 210pt below the window top must not flip
        // 210pt early: the origin is subtracted before the on-screen clamp.
        let p = makePlacement(viewport: 430)
        p.viewportGlobalMinY = 210
        p.rowBottoms = ["/5": 210 + 190]
        #expect(p.resolveAtTop(selection: ["/5"]) == false)
        p.rowBottoms = ["/10": 210 + 400]   // visual 400 > 430 − 64 → the bar would cover it
        #expect(p.resolveAtTop(selection: ["/10"]) == true)
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

    /// One resolve from a fresh placement: (why, viewport, coverage, row bottoms, selection, at top).
    @Test(arguments: [
        ("no selection", 600, 64, [:], [], false),
        // Not in rowBottoms: nothing on screen to cover.
        ("selected but scrolled out of view", 600, 64, [:], ["/a"], false),
        // A wider fixed band would flip here too early.
        ("530 is above the measured 64pt bar, which covers below 536", 600, 64, ["/a": 530], ["/a"], false),
        ("a taller measured bar raises the flip line to 600-100=500", 600, 100, ["/a": 520], ["/a"], true),
        // rowBottoms also carries rows laid out past the fold; flipping would cover visible rows.
        ("a selected row past the fold is invisible", 600, 64, ["/a": 900], ["/a"], false),
        ("an off-screen sibling must not drag the bar over the visible row", 600, 64,
         ["/visible": 40, "/offscreen": 3000], ["/visible", "/offscreen"], false),
        // The clamp must not exclude the boundary row it exists to protect.
        ("a row exactly at the viewport's bottom edge is on screen and covered", 600, 64, ["/a": 600], ["/a"], true),
        // Covered end to end at either edge; a negative `coveredFrom` would pin it to the top.
        ("a pane shorter than the bar stays at the resting bottom", 50, 64, ["/a": 10], ["/a"], false),
    ] as [(String, CGFloat, CGFloat, [String: CGFloat], Set<String>, Bool)])
    func aSingleResolve(why: String, viewport: CGFloat, coverage: CGFloat, rowBottoms: [String: CGFloat],
                        selection: Set<String>, atTop: Bool) {
        let p = makePlacement(viewport: viewport, coverage: coverage)
        p.rowBottoms = rowBottoms
        #expect(p.resolveAtTop(selection: selection) == atTop, "\(why)")
    }
}
