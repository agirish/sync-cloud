import Testing
import Foundation
import CoreGraphics
import AppKit
import Design
import FileExplorer
@testable import SyncCloud

/// The workspace bar's shedding rule.
///
/// This exists because the failure it guards is invisible: a toolbar that does not fit does not
/// truncate or wrap — macOS folds the overflow behind a chevron, and the only control for
/// switching workspace disappears with no error and no visual cue that anything was dropped.
///
/// It covers the ⌘K search pill too, because the two controls share one row and are therefore one
/// decision — `styles(...)`. Every assertion below that used to call `style(...)` now reads
/// `.workspace` off that result and pays for a real search pill while doing it, which is the point:
/// the old numbers were true of a toolbar this app no longer has.
@Suite struct WorkspaceBarMetricsTests {

    /// The real labels at the real weight, so these assertions measure the shipping bar rather
    /// than a hypothetical one. Semibold because that is the selected segment's weight, and the
    /// widest — sizing on `.medium` would under-measure the one segment that is always bold.
    /// The pill's two measured widths at a text scale, so every assertion below charges for the
    /// control that is actually on the row.
    private func searchWidths(scale: CGFloat = 1) -> (label: CGFloat, keycap: CGFloat) {
        (CommandPaletteBarMetrics.labelWidth(CommandPaletteBar.label, scale: scale),
         CommandPaletteBarMetrics.keycapWidth(symbol: AppChord.commandPalette.display, scale: scale))
    }

    /// `styles(...)` at a text scale, with the real pill measured at that same scale.
    private func styles(contentWidth: CGFloat, labelWidths: [CGFloat],
                        scale: CGFloat = 1, separators: Int = 1) -> ToolbarBarStyles {
        let search = searchWidths(scale: scale)
        return WorkspaceBarMetrics.styles(contentWidth: contentWidth, labelWidths: labelWidths,
                                          searchLabelWidth: search.label,
                                          searchKeycapWidth: search.keycap, separators: separators)
    }

    private func labelWidths(scale: CGFloat = 1) -> [CGFloat] {
        let font = NSFont.systemFont(ofSize: 12 * scale, weight: .semibold)
        return Workspace.allCases.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }
    }

    /// **What the ⌘K pill costs, stated as a number rather than discovered.**
    ///
    /// Three labelled segments used to fit the window's 600pt `minWidth` — that was the win of
    /// folding five workspaces down to three, and the assertion here used to say so. The search
    /// pill spends part of that row, so the bar now keeps its words down to ~617pt at the default
    /// text size and goes to glyphs in the 17pt band above the hard floor.
    ///
    /// That band is the whole cost and it is pinned from both sides, because the tempting way to
    /// "fix" a failing floor test is to shave `reservedChrome` — which buys the labels back by
    /// under-measuring the row, and under-measuring is what folds the toolbar behind the chevron.
    @Test func testTheLabelsSurviveToWithinAShortDistanceOfTheFloor() {
        let widths = labelWidths()
        let search = searchWidths()
        let keepsWords = WorkspaceBarMetrics.fullWidth(labelWidths: widths)
            + CommandPaletteBarMetrics.width(style: .compact, labelWidth: search.label,
                                             keycapWidth: search.keycap)
            + WorkspaceBarMetrics.reservedChrome
        #expect(styles(contentWidth: keepsWords, labelWidths: widths).workspace == .full)
        #expect(styles(contentWidth: keepsWords - 1, labelWidths: widths).workspace == .iconOnly)
        // The band above the 600pt floor where the labels are gone. Small enough to be a corner of
        // a deliberately-shrunk window rather than the ordinary state; if a future control on this
        // row pushes it wide, this fails and says by how much.
        #expect(keepsWords - 600 < 40,
                "the bar sheds its labels \(keepsWords - 600)pt above the window's floor — the toolbar row has grown enough that a narrow window is glyphs for most of its range")
    }

    @Test func testTheGlyphRungAndTheCompactPillDoFitTheFloorTogether() {
        // The last rung has to actually solve it, at every text size, or shedding buys nothing and
        // the row goes behind the chevron anyway.
        for scale in [FontSize.small.scale, 1, FontSize.large.scale] {
            let search = searchWidths(scale: scale)
            let row = WorkspaceBarMetrics.iconOnlyWidth(segmentCount: Workspace.allCases.count)
                + CommandPaletteBarMetrics.width(style: .compact, labelWidth: search.label,
                                                 keycapWidth: search.keycap)
            #expect(row <= 600 - WorkspaceBarMetrics.reservedChrome,
                    "the narrowest rung does not fit the 600pt floor at text scale \(scale)")
            #expect(styles(contentWidth: 600, labelWidths: labelWidths(scale: scale),
                           scale: scale) == ToolbarBarStyles(workspace: .iconOnly, search: .compact),
                    "the floor must land on the narrowest rung at text scale \(scale)")
        }
    }

    /// **The order of the ladder, which is the whole design decision in it.**
    ///
    /// The pill's word is the cheapest thing on the row — the magnifier and the ⌘K key still say
    /// what the control is and how to open it — so it goes first. The workspace labels are the
    /// primary navigation and go last. Shedding them while keeping a decorative word beside them
    /// would be backwards, and nothing but this test would notice the two clauses swapping.
    @Test func testThePillLosesItsWordBeforeTheBarLosesItsLabels() {
        let widths = labelWidths()
        let search = searchWidths()
        let both = WorkspaceBarMetrics.fullWidth(labelWidths: widths)
            + CommandPaletteBarMetrics.width(style: .full, labelWidth: search.label,
                                             keycapWidth: search.keycap)
            + WorkspaceBarMetrics.reservedChrome
        #expect(styles(contentWidth: both, labelWidths: widths)
                == ToolbarBarStyles(workspace: .full, search: .full))
        // One point under: the PILL gives up its word and the bar keeps every label.
        #expect(styles(contentWidth: both - 1, labelWidths: widths)
                == ToolbarBarStyles(workspace: .full, search: .compact))
        // There is no rung that sheds the labels while the pill still shows its word.
        for width in stride(from: 400.0, through: 1600.0, by: 1.0) {
            let s = styles(contentWidth: width, labelWidths: widths)
            #expect(!(s.workspace == .iconOnly && s.search == .full),
                    "at \(width)pt the bar is glyphs while the pill still spells itself out")
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
        #expect(styles(contentWidth: 600, labelWidths: widths,
                       scale: FontSize.large.scale).workspace == .iconOnly)
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
        #expect(styles(contentWidth: 1400, labelWidths: labelWidths()).workspace == .full)
    }

    @Test func testTheThresholdIsWhereTheArithmeticSaysItIs() {
        // Pin the boundary from both sides so a change to the chrome constants can't quietly
        // move it: one point below the required width sheds, one point at it does not.
        let widths = labelWidths()
        let search = searchWidths()
        let needed = WorkspaceBarMetrics.fullWidth(labelWidths: widths)
            + CommandPaletteBarMetrics.width(style: .full, labelWidth: search.label,
                                             keycapWidth: search.keycap)
            + WorkspaceBarMetrics.reservedChrome
        #expect(styles(contentWidth: needed, labelWidths: widths).workspace == .full)
        #expect(styles(contentWidth: needed - 1, labelWidths: widths).search == .compact,
                "one point under the full-row width must drop the PILL's word, not the bar's labels")
    }

    @Test func testLargerTextShedsSoonerThanSmaller() {
        // The reason the widths are measured instead of tabulated: the app scales its own type,
        // so a constant would be right at exactly one Settings ▸ Text size and would overflow at
        // the rest. At a width that exactly seats the smallest setting's whole row, the largest
        // must give something up rather than push the row behind the chevron.
        //
        // **It asserts the ROW degrading, not the bar's labels specifically, and that is the
        // update the pill forced.** Before the pill there was one thing to shed, so "sheds sooner"
        // and "goes to glyphs" were the same sentence; now the first thing to go is the pill's
        // word, and the bar keeps its labels a while longer. Asserting `.iconOnly` here failed a
        // correct ladder — the test was describing a toolbar with one control on it.
        let small = labelWidths(scale: FontSize.small.scale)
        let large = labelWidths(scale: FontSize.large.scale)
        let smallSearch = searchWidths(scale: FontSize.small.scale)
        let needed = WorkspaceBarMetrics.fullWidth(labelWidths: small)
            + CommandPaletteBarMetrics.width(style: .full, labelWidth: smallSearch.label,
                                             keycapWidth: smallSearch.keycap)
            + WorkspaceBarMetrics.reservedChrome

        let atSmall = styles(contentWidth: needed, labelWidths: small, scale: FontSize.small.scale)
        let atLarge = styles(contentWidth: needed, labelWidths: large, scale: FontSize.large.scale)
        #expect(atSmall == ToolbarBarStyles(workspace: .full, search: .full),
                "the width that exactly seats the small setting must seat all of it")
        #expect(atLarge != atSmall,
                "the largest text size fits the same width as the smallest — the widths are not tracking the app's own type scale")
        // ...and specifically: it is the pill's word that goes first, at this width.
        #expect(atLarge.search == .compact)
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
