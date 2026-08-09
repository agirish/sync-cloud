import Testing
import Foundation
import CoreGraphics
import AppKit
import Design
@testable import SyncCloud

/// The workspace bar's shedding rule.
///
/// This exists because the failure it guards is invisible: a toolbar that does not fit does not
/// truncate or wrap — macOS folds the overflow behind a chevron, and the only control for
/// switching workspace disappears with no error and no visual cue that anything was dropped.
@Suite struct WorkspaceBarMetricsTests {

    /// The real labels at the real weight, so these assertions measure the shipping bar rather
    /// than a hypothetical one. Semibold because that is the selected segment's weight, and the
    /// widest — sizing on `.medium` would under-measure the one segment that is always bold.
    private func labelWidths(scale: CGFloat = 1) -> [CGFloat] {
        let font = NSFont.systemFont(ofSize: 12 * scale, weight: .semibold)
        return Workspace.allCases.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }
    }

    @Test func testTheThreeSegmentBarKeepsItsLabelsAtTheWindowsMinimumWidth() {
        // **This assertion used to say the opposite, and the flip is the point of the fold.** Five
        // labelled segments plus the traffic lights and the utility pill exceeded the 600pt
        // `minWidth` ContentView pins, so the bar went to glyphs at the floor. Three fit, and the
        // whole window's narrowest state now keeps its words.
        #expect(WorkspaceBarMetrics.style(contentWidth: 600, labelWidths: labelWidths()) == .full)
    }

    @Test func testThreeSegmentsKeepTheirLabelsAtEveryTextSize() {
        // Not just at the default: the app scales its own type, and the floor has to hold at the
        // largest setting too or the win is only true for some people.
        for scale in [FontSize.small.scale, 1, FontSize.large.scale] {
            #expect(WorkspaceBarMetrics.style(contentWidth: 600,
                                              labelWidths: labelWidths(scale: scale)) == .full,
                    "three labels must fit the 600pt floor at text scale \(scale)")
        }
    }

    @Test func testTheIconOnlyRungIsDormantButStillCorrect() {
        // **Honest about the consequence of the fold: nothing sheds labels today.** Three segments
        // fit the floor at every text size (above), so `iconOnly` is currently unreachable in the
        // shipping app. That is worth stating rather than discovering later, and it is NOT a
        // reason to delete the rung: the Backup lens and Home are both queued for the bar, and the
        // fifth segment brings the shedding back.
        //
        // So the rung stays under test against the bar it will have, not the bar it has. Five
        // labels at the largest text size is the state this arithmetic existed to catch, and it
        // still catches it.
        let queued = ["Compare", "Organize", "Storage", "Backup", "Home"]
        let font = NSFont.systemFont(ofSize: 12 * FontSize.large.scale, weight: .semibold)
        let widths = queued.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        #expect(WorkspaceBarMetrics.style(contentWidth: 600, labelWidths: widths) == .iconOnly)
        // And the fallback still solves it, or shedding buys nothing.
        let iconOnly = WorkspaceBarMetrics.iconOnlyWidth(segmentCount: queued.count)
        #expect(iconOnly <= 600 - WorkspaceBarMetrics.reservedChrome)
    }

    @Test func testTheIconOnlyBarDoesFitTheWindowsMinimumWidth() {
        // And the fallback has to actually solve it, or shedding labels buys nothing.
        let iconOnly = WorkspaceBarMetrics.iconOnlyWidth(segmentCount: Workspace.allCases.count)
        #expect(iconOnly <= 600 - WorkspaceBarMetrics.reservedChrome)
    }

    @Test func testAnOrdinaryWindowSpellsTheSegmentsOut() {
        // The window opens at ~85% of the screen, so the common case must be labelled — an
        // always-glyph bar would be a regression dressed up as a fix.
        #expect(WorkspaceBarMetrics.style(contentWidth: 1400, labelWidths: labelWidths()) == .full)
    }

    @Test func testTheThresholdIsWhereTheArithmeticSaysItIs() {
        // Pin the boundary from both sides so a change to the chrome constants can't quietly
        // move it: one point below the required width sheds, one point at it does not.
        let widths = labelWidths()
        let needed = WorkspaceBarMetrics.fullWidth(labelWidths: widths) + WorkspaceBarMetrics.reservedChrome
        #expect(WorkspaceBarMetrics.style(contentWidth: needed, labelWidths: widths) == .full)
        #expect(WorkspaceBarMetrics.style(contentWidth: needed - 1, labelWidths: widths) == .iconOnly)
    }

    @Test func testLargerTextShedsSoonerThanSmaller() {
        // The reason the widths are measured instead of tabulated: the app scales its own type,
        // so a constant would be right at exactly one Settings ▸ Text size and would overflow at
        // the rest. At a width that seats the smallest setting, the largest must give up its
        // labels rather than push the bar behind the chevron.
        let small = labelWidths(scale: FontSize.small.scale)
        let large = labelWidths(scale: FontSize.large.scale)
        let needed = WorkspaceBarMetrics.fullWidth(labelWidths: small) + WorkspaceBarMetrics.reservedChrome

        #expect(WorkspaceBarMetrics.style(contentWidth: needed, labelWidths: small) == .full)
        #expect(WorkspaceBarMetrics.style(contentWidth: needed, labelWidths: large) == .iconOnly)
    }

    @Test func testWidthGrowsWithTheSegmentsItActuallyDraws() {
        // Guards the arithmetic itself: the gap and separator terms are easy to drop, and a
        // width that ignores them under-measures and never sheds when it should.
        let one = WorkspaceBarMetrics.fullWidth(labelWidths: [40], separators: 0)
        let two = WorkspaceBarMetrics.fullWidth(labelWidths: [40, 40], separators: 0)
        #expect(two == one + 40 + WorkspaceBarMetrics.segmentChrome + WorkspaceBarMetrics.segmentGap)
    }

    @Test func testTheSeparatorCostsItsOwnGapToo() {
        // The rule is a child of the same HStack, so adding it adds BOTH its width and one more
        // spacing gap. Charging only for the width under-measures the bar — the direction that
        // ships a toolbar claiming to fit when it doesn't, which is the failure with no visible
        // symptom short of the control vanishing.
        let without = WorkspaceBarMetrics.fullWidth(labelWidths: [40, 40], separators: 0)
        let with = WorkspaceBarMetrics.fullWidth(labelWidths: [40, 40], separators: 1)
        #expect(with == without + WorkspaceBarMetrics.separatorWidth + WorkspaceBarMetrics.segmentGap)
    }

    @Test func testGapsAreCountedOverChildrenNotSegments() {
        #expect(WorkspaceBarMetrics.gapWidth(children: 6) == 5 * WorkspaceBarMetrics.segmentGap)
        // Degenerate inputs must not go negative: one child has no gaps, and neither has none.
        #expect(WorkspaceBarMetrics.gapWidth(children: 1) == 0)
        #expect(WorkspaceBarMetrics.gapWidth(children: 0) == 0)
    }

    @Test func testAnEmptyBarHasNoWidth() {
        // Not a real state, but the `count - 1` gap terms underflow on an empty array, and an
        // enormous negative width would read as "everything fits" forever.
        #expect(WorkspaceBarMetrics.fullWidth(labelWidths: []) == 0)
        #expect(WorkspaceBarMetrics.iconOnlyWidth(segmentCount: 0) == 0)
    }
}
