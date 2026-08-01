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

    @Test func testTheFullBarDoesNotFitTheWindowsMinimumWidth() {
        // The premise of the whole shedding rule, asserted rather than assumed. Six labelled
        // segments plus the traffic lights and the utility pill exceed the 600pt `minWidth`
        // ContentView pins. If this ever stops being true the icon-only rung is dead code —
        // which is worth finding out from a failing test, not by deleting it on a hunch.
        #expect(WorkspaceBarMetrics.style(contentWidth: 600, labelWidths: labelWidths()) == .iconOnly)
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

        // And the separator is charged for, so the rule between Compare and the lenses can't
        // silently overflow the bar it divides.
        let withRule = WorkspaceBarMetrics.fullWidth(labelWidths: [40, 40], separators: 1)
        #expect(withRule == two + WorkspaceBarMetrics.separatorWidth)
    }

    @Test func testAnEmptyBarHasNoWidth() {
        // Not a real state, but the `count - 1` gap terms underflow on an empty array, and an
        // enormous negative width would read as "everything fits" forever.
        #expect(WorkspaceBarMetrics.fullWidth(labelWidths: []) == 0)
        #expect(WorkspaceBarMetrics.iconOnlyWidth(segmentCount: 0) == 0)
    }
}
