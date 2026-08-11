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

    /// The narrowest window there is: `ContentView`'s `.frame(minWidth: 760, …)`, which
    /// `.windowResizability(.contentMinSize)` makes a floor rather than a preference.
    ///
    /// **One constant, because "the floor" is a claim every test here makes.** It was the literal
    /// 600 in six places until the window was raised, and a literal repeated six times is six
    /// chances to update five of them — the shape that leaves one assertion quietly measuring a
    /// width no window can have.
    private static let windowFloor: CGFloat = 760

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

    /// **What the fourth segment costs, stated as a number rather than discovered.**
    ///
    /// The history is the point of the number. Three labelled segments fit the window's old 600pt
    /// `minWidth` — the win of folding five workspaces down to three. The ⌘K pill then took part
    /// of that row and left a 17pt band above the floor where the bar is glyphs. Browse takes its
    /// label, its `segmentChrome` and one more `segmentGap`, and the band grew to ~108pt: below
    /// roughly 708pt the segments are icons.
    ///
    /// **That band is what raised the window rather than being shaved away.** Shortening a label
    /// people navigate by was the alternative, and under-measuring the row is exactly what folds
    /// the toolbar behind the overflow chevron — the failure this whole type exists to prevent.
    /// So the arithmetic stayed and the floor moved to 760: the labels now survive the narrowest
    /// window by ~52pt at the default text size, and the band lives entirely below a width no
    /// window can be dragged to. What is pinned here is that it stays that way — a fifth segment
    /// or another toolbar control would push the threshold back up through the floor, and this
    /// fails naming the number rather than letting a glyph-only floor return unannounced.
    @Test func testTheLabelsSurviveToWithinAShortDistanceOfTheFloor() {
        let widths = labelWidths()
        let search = searchWidths()
        let keepsWords = WorkspaceBarMetrics.fullWidth(labelWidths: widths)
            + CommandPaletteBarMetrics.width(style: .compact, labelWidth: search.label,
                                             keycapWidth: search.keycap)
            + WorkspaceBarMetrics.reservedChrome
        #expect(styles(contentWidth: keepsWords, labelWidths: widths).workspace == .full)
        #expect(styles(contentWidth: keepsWords - 1, labelWidths: widths).workspace == .iconOnly)
        // The labels have to survive the narrowest window the app allows. This is the assertion
        // the raise was made for, and the one that fails if the row grows again.
        #expect(keepsWords <= Self.windowFloor,
                "the bar sheds its labels at \(keepsWords)pt, above the window's own \(Self.windowFloor)pt floor — the narrowest window is glyphs again")
        // And from the other side, so the floor is not simply raised to whatever the row wants:
        // the window opens at ~85% of the screen, so the shedding band has to stay a corner of the
        // range rather than most of it.
        #expect(keepsWords < 800,
                "the labels survive only above \(keepsWords)pt — that is no longer a narrow window")
    }

    @Test func testTheGlyphRungAndTheCompactPillDoFitTheFloorTogether() {
        // The last rung has to actually solve it, at every text size, or shedding buys nothing and
        // the row goes behind the chevron anyway. Every size, including the largest — that is the
        // one that still reaches this rung at the floor.
        for scale in FontSize.allCases.map(\.scale) {
            let search = searchWidths(scale: scale)
            let row = WorkspaceBarMetrics.iconOnlyWidth(segmentCount: Workspace.allCases.count)
                + CommandPaletteBarMetrics.width(style: .compact, labelWidth: search.label,
                                                 keycapWidth: search.keycap)
            #expect(row <= Self.windowFloor - WorkspaceBarMetrics.reservedChrome,
                    "the narrowest rung does not fit the \(Self.windowFloor)pt floor at text scale \(scale)")
        }
    }

    /// **What the floor lands on, per text size** — the assertion the raise from 600 to 760 was
    /// made to change, and the one that would notice it being reverted.
    ///
    /// At 600 this was a single answer: `iconOnly` at every size, because the four labels need
    /// 708pt beside even a compact pill. At 760 it splits, and the split is the point — the
    /// labelled bar is what a user sees at the narrowest window they can make, unless they have
    /// also asked for the largest text, where the row genuinely does not fit (773pt needed).
    @Test func testTheFloorKeepsItsLabelsAtEveryTextSizeButTheLargest() {
        for size in FontSize.allCases {
            let resolved = styles(contentWidth: Self.windowFloor,
                                  labelWidths: labelWidths(scale: size.scale), scale: size.scale)
            let expected: WorkspaceBarStyle = size == .extraLarge ? .iconOnly : .full
            #expect(resolved.workspace == expected,
                    "at the \(Self.windowFloor)pt floor the bar is \(resolved.workspace) at \(size.displayName), expected \(expected)")
            // What the pill is doing there, which is not one answer either: at Small the whole row
            // fits spelled out (752pt needed against the 760pt floor), and from Default up the
            // pill pays first — it is the cheaper word to lose, and it pays before the bar does at
            // every size including the one where the bar sheds too. Written out per size rather
            // than asserted as "compact", which is what the first draft of this test claimed and
            // what the Small case refuted.
            let expectedPill: CommandPaletteBarStyle = size == .small ? .full : .compact
            #expect(resolved.search == expectedPill,
                    "at the floor the ⌘K pill is \(resolved.search) at \(size.displayName), expected \(expectedPill)")
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

    @Test func testTheIconOnlyRungIsLiveInTheShippingBar() {
        // **This rung is no longer dormant, and that is the headline of the fourth segment.** It
        // used to be unreachable: three labelled segments fit the old 600pt floor at every text
        // size, so nothing in the shipping app ever shed a label, and this test could only
        // exercise the arithmetic against a hypothetical five-segment bar. Browse changed that.
        //
        // **What raising the floor to 760 changed is WHERE it is live, not WHETHER.** It is no
        // longer the state of the narrowest window at every text size — that was the defect the
        // raise fixed — but the largest text size still needs 773pt, so a floor-sized window at
        // Larger sheds, and so does any window between 760 and the 708pt threshold at the sizes
        // below it. This asserts the rung on a real bar rather than a hypothetical one, at the
        // width where the shipping app still reaches it.
        //
        // **Photographed there, not only computed.** This arithmetic says the row fits; what it
        // cannot say is what macOS does with a toolbar it decides is too wide, which is to fold
        // the whole thing behind a chevron with no error and no visual cue. So the shipping build
        // was captured at a 600pt window — then the floor, now below it — and the pixels read
        // back: four glyph clusters in the capsule (the selected Browse pill 73px wide, then three
        // 22–31px glyphs), the compact ⌘K pill and all three trailing utilities still painted, and
        // nothing folded away. The rung the capture photographed is the one asserted here; only
        // the width at which a user meets it has moved.
        //
        // The same capture settled the one thing no assertion in this file can reach: WHERE the
        // rule is drawn. A 1pt darker column sits at x=365 — inside the Compare→Organize gap — and
        // the Browse→Compare gap has no darker column anywhere in it.
        //
        // Asserted with the app's OWN labels first, so the live behaviour is pinned, and then
        // against the queued bar so the arithmetic still has headroom under test.
        #expect(styles(contentWidth: Self.windowFloor,
                       labelWidths: labelWidths(scale: FontSize.extraLarge.scale),
                       scale: FontSize.extraLarge.scale).workspace == .iconOnly,
                "the shipping four-segment bar keeps its labels at the floor even at the largest text size — if that is now true, this test and the band above disagree")

        let queued = ["Browse", "Compare", "Organize", "Storage", "Backup", "Home"]
        let font = NSFont.systemFont(ofSize: 12 * FontSize.large.scale, weight: .semibold)
        let widths = queued.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        #expect(styles(contentWidth: Self.windowFloor, labelWidths: widths,
                       scale: FontSize.large.scale).workspace == .iconOnly)
        // And the fallback still solves it, or shedding buys nothing.
        let iconOnly = WorkspaceBarMetrics.iconOnlyWidth(segmentCount: queued.count)
        #expect(iconOnly <= Self.windowFloor - WorkspaceBarMetrics.reservedChrome)
    }

    @Test func testTheIconOnlyBarDoesFitTheWindowsMinimumWidth() {
        // And the fallback has to actually solve it, or shedding labels buys nothing.
        let iconOnly = WorkspaceBarMetrics.iconOnlyWidth(segmentCount: Workspace.allCases.count)
        #expect(iconOnly <= Self.windowFloor - WorkspaceBarMetrics.reservedChrome)
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

    /// **Where the rule is drawn, which this type cannot see.**
    ///
    /// `WorkspaceBarMetrics` is only ever told HOW MANY separators there are, so every assertion
    /// above stays green with the rule in the wrong place. It is a hardcoded index in
    /// `workspaceBar`, and it read `index == 1` when Compare led the bar — left alone, Browse
    /// arriving in front would have drawn it between Browse and Compare, splitting the two
    /// tree-lookers and grouping a looker with the actors.
    ///
    /// Asserted as the PROPERTY rather than the literal: everything before the rule shows no lens,
    /// everything after it shows one. A test reading `== 2` against a constant of `2` would have
    /// passed just as happily when `2` was wrong.
    @Test func testTheRuleSeparatesTheLookersFromTheActors() {
        let index = ContentView.workspaceRuleIndex
        let before = Workspace.allCases.prefix(index)
        let after = Workspace.allCases.dropFirst(index)

        #expect(before.map(\.title) == ["Browse", "Compare"])
        #expect(after.map(\.title) == ["Organize", "Storage"])
        #expect(before.allSatisfy { $0.lens == nil }, "a workspace with a lens is on the lookers' side of the rule")
        #expect(after.allSatisfy { $0.lens != nil }, "a workspace with no lens is on the actors' side of the rule")
        // One rule, and the metrics are charged for exactly that many. The bar's arithmetic and
        // the bar's drawing agreeing about the count is the other half of getting the rule right.
        #expect(index > 0 && index < Workspace.allCases.count,
                "the rule is drawn outside the bar, so it separates nothing")
    }

    @Test func testAnEmptyBarHasNoWidth() {
        // Not a real state, but the `count - 1` gap terms underflow on an empty array, and an
        // enormous negative width would read as "everything fits" forever.
        #expect(WorkspaceBarMetrics.fullWidth(labelWidths: []) == 0)
        #expect(WorkspaceBarMetrics.iconOnlyWidth(segmentCount: 0) == 0)
    }
}
