import Testing
import Foundation
import CoreGraphics
import SwiftUI
import AppKit
import Design
import FileExplorer
@testable import SyncCloud

/// The workspace bar's shedding rule.
///
/// The failure it guards is invisible: a toolbar that does not fit does not truncate or wrap.
/// macOS folds the overflow behind a chevron, and the only control for switching workspace
/// disappears with no error and no cue. It covers the ⌘K pill too, because the two share one row
/// and so are one decision, `styles(...)`; every assertion pays for a real pill.
@Suite struct WorkspaceBarMetricsTests {

    /// The narrowest window there is: `ContentView`'s `.frame(minWidth: 804, …)`, which
    /// `.windowResizability(.contentMinSize)` makes a floor rather than a preference. One constant,
    /// because "the floor" is a claim every test here makes, and a repeated literal can be left
    /// behind when the window changes.
    private static let windowFloor: CGFloat = 804

    /// The pill's two measured widths at a text scale, so every assertion below charges for the
    /// control that is actually on the row.
    private func searchWidths(scale: CGFloat = 1) -> (label: CGFloat, keycap: CGFloat) {
        (CommandPaletteBarMetrics.labelWidth(CommandPaletteBar.label, scale: scale),
         CommandPaletteBarMetrics.keycapWidth(symbol: AppChord.commandPalette.display, scale: scale))
    }

    /// `styles(...)` at a text scale, with the real pill measured at that same scale.
    private func styles(contentWidth: CGFloat, labelWidths: [CGFloat],
                        scale: CGFloat = 1) -> ToolbarBarStyles {
        let search = searchWidths(scale: scale)
        return WorkspaceBarMetrics.styles(contentWidth: contentWidth, labelWidths: labelWidths,
                                          searchLabelWidth: search.label,
                                          searchKeycapWidth: search.keycap)
    }

    /// The real labels at the real weight, so these assertions measure the shipping bar. Semibold
    /// because that is the selected segment's weight, and the widest; `.medium` would under-measure
    /// the one segment that is always bold.
    private func labelWidths(scale: CGFloat = 1) -> [CGFloat] {
        let font = NSFont.systemFont(ofSize: 12 * scale, weight: .semibold)
        return Workspace.allCases.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }
    }

    /// The labels survive the narrowest window, beside a compact pill. A new segment or toolbar
    /// control would push the threshold up through the floor; this fails naming the number rather
    /// than letting a glyph-only floor return unannounced. The fix is a decision about the window
    /// or the labels, never under-measuring the row, which is what folds it behind the chevron.
    @Test func testTheLabelsSurviveTheNarrowestWindow() {
        let widths = labelWidths()
        let search = searchWidths()
        let keepsWords = WorkspaceBarMetrics.fullWidth(labelWidths: widths)
            + CommandPaletteBarMetrics.width(style: .compact, labelWidth: search.label,
                                             keycapWidth: search.keycap)
            + WorkspaceBarMetrics.reservedChrome
        #expect(styles(contentWidth: keepsWords, labelWidths: widths).workspace == .full)
        #expect(styles(contentWidth: keepsWords - 1, labelWidths: widths).workspace == .iconOnly)
        // The labels have to survive the narrowest window the app allows; this fails if the row
        // grows past it.
        #expect(keepsWords <= Self.windowFloor,
                "the bar sheds its labels at \(keepsWords)pt, above the window's own \(Self.windowFloor)pt floor — the narrowest window is glyphs again")
        // An absolute ceiling, so the floor cannot simply be raised to whatever the row wants: the
        // window opens at ~85% of the screen, so the shedding band has to stay a corner of the
        // range. A new workspace must be paid for by a measurement and a decision, not by moving
        // this number.
        #expect(keepsWords < 850,
                "the labels survive only above \(keepsWords)pt — that is no longer a narrow window")
    }

    @Test func testTheGlyphRungAndTheCompactPillDoFitTheFloorTogether() {
        // The last rung has to actually solve it, at every text size including the largest, or
        // shedding buys nothing and the row goes behind the chevron anyway.
        for scale in FontSize.allCases.map(\.scale) {
            let search = searchWidths(scale: scale)
            let row = WorkspaceBarMetrics.iconOnlyWidth(segmentCount: Workspace.allCases.count)
                + CommandPaletteBarMetrics.width(style: .compact, labelWidth: search.label,
                                                 keycapWidth: search.keycap)
            #expect(row <= Self.windowFloor - WorkspaceBarMetrics.reservedChrome,
                    "the narrowest rung does not fit the \(Self.windowFloor)pt floor at text scale \(scale)")
        }
    }

    /// What the floor lands on, per text size: the bar keeps its labels at every size, and the
    /// pill spells itself out at the smaller sizes and drops its word at the two larger ones.
    /// Erring toward shedding is the safe direction, since an over-optimistic row folds behind the
    /// chevron; `reservedChrome` is deliberately generous and unmeasured.
    @Test func testTheFloorKeepsItsLabelsAtEveryTextSize() {
        // Every size keeps the words at the narrowest window. The tightest margin is at Largest,
        // and it is what another label or a wider pill would spend first.
        for size in FontSize.allCases {
            let resolved = styles(contentWidth: Self.windowFloor,
                                  labelWidths: labelWidths(scale: size.scale), scale: size.scale)
            #expect(resolved.workspace == .full,
                    "at the \(Self.windowFloor)pt floor the bar is \(resolved.workspace) at \(size.displayName) — the narrowest window is glyphs again at this size")
            // The pill splits instead: spelled out at Small and Default, compact at the two larger
            // sizes. The cheap word goes first and the navigation labels never go. Asserted per
            // size, because a flat answer could be right by accident and hide a split.
            let expectedPill: CommandPaletteBarStyle =
                (size == .large || size == .extraLarge) ? .compact : .full
            #expect(resolved.search == expectedPill,
                    "at the floor the ⌘K pill is \(resolved.search) at \(size.displayName), expected \(expectedPill)")
        }
    }

    /// The order of the ladder, which is the whole design decision in it. The pill's word is the
    /// cheapest thing on the row (the magnifier and the ⌘K key still say what it is), so it goes
    /// first; the workspace labels are the primary navigation and go last. Nothing but this test
    /// would notice the two swapping.
    @Test func testThePillLosesItsWordBeforeTheBarLosesItsLabels() {
        let widths = labelWidths()
        let search = searchWidths()
        let both = WorkspaceBarMetrics.fullWidth(labelWidths: widths)
            + CommandPaletteBarMetrics.width(style: .full, labelWidth: search.label,
                                             keycapWidth: search.keycap)
            + WorkspaceBarMetrics.reservedChrome
        #expect(styles(contentWidth: both, labelWidths: widths)
                == ToolbarBarStyles(workspace: .full, search: .full))
        // One point under: the pill gives up its word and the bar keeps every label.
        #expect(styles(contentWidth: both - 1, labelWidths: widths)
                == ToolbarBarStyles(workspace: .full, search: .compact))
        // There is no rung that sheds the labels while the pill still shows its word.
        for width in stride(from: 400.0, through: 1600.0, by: 1.0) {
            let s = styles(contentWidth: width, labelWidths: widths)
            #expect(!(s.workspace == .iconOnly && s.search == .full),
                    "at \(width)pt the bar is glyphs while the pill still spells itself out")
        }
    }

    /// The shipping bar never reaches the icon-only rung (with the field closed), at any legal
    /// window width or text size, yet the rung is still live.
    ///
    /// It stays because it runs on every layout pass and answers `.iconOnly` for a wider bar, and
    /// one more segment would bring it back into the shipping range. Both directions are asserted:
    /// if the shipping bar ever sheds again, the first assertion fails and names the size.
    @Test func testTheIconOnlyRungIsOutOfTheShippingBarsReachButStillLive() {
        // The shipping bar, at the floor, at the largest text the app offers: the hardest case.
        // It keeps its labels.
        #expect(styles(contentWidth: Self.windowFloor,
                       labelWidths: labelWidths(scale: FontSize.extraLarge.scale),
                       scale: FontSize.extraLarge.scale).workspace == .full,
                "the shipping four-segment bar sheds its labels at the floor — the rung is back in reach, so this test and the floor test above now disagree and one of them is describing an app that no longer exists")

        // …and no width in the app's legal range reaches it either. Swept from the floor, because
        // narrower is not a window a user can make.
        for size in FontSize.allCases {
            let widths = labelWidths(scale: size.scale)
            for width in stride(from: Self.windowFloor, through: 2400.0, by: 5.0) {
                #expect(styles(contentWidth: width, labelWidths: widths, scale: size.scale).workspace == .full,
                        "at \(width)pt and \(size.displayName) the shipping bar is glyphs — the rung is reachable again")
            }
        }

        // The rung itself still works, which keeps this from being dead code: six labelled
        // segments shed at the floor as they should.
        let queued = ["Browse", "Compare", "Organize", "Edit", "Backup", "Home"]
        let font = NSFont.systemFont(ofSize: 12 * FontSize.large.scale, weight: .semibold)
        let widths = queued.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        #expect(styles(contentWidth: Self.windowFloor, labelWidths: widths,
                       scale: FontSize.large.scale).workspace == .iconOnly,
                "even six labelled segments fit the floor — the shedding rule is now unreachable by any bar, which makes it genuinely dead rather than merely dormant")
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
        // The window opens at ~85% of the screen, so the common case must be labelled; an
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
        // The widths are measured, not tabulated, because the app scales its own type: a constant
        // would be right at one Settings ▸ Text size and overflow at the rest. At a width that
        // exactly seats the smallest setting's whole row, the largest must give something up.
        // That is the row degrading, not the labels: the pill's word goes first.
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
        // ...and specifically, it is the pill's word that goes first at this width.
        #expect(atLarge.search == .compact)
    }

    /// Every segment is one height, and `segmentChrome` is exact rather than approximate.
    ///
    /// The workspace symbols render at different sizes at one font size (see
    /// `WorkspaceBarMetrics.glyphSide`), so without the glyph frame the segments differ in height.
    /// The selected pill is a `Capsule` sized to its own segment inside a `matchedGeometryEffect`,
    /// so it would change size while sliding, and a glyph-width guess in `segmentChrome` would
    /// under-measure the bar, the direction that folds it behind the chevron.
    ///
    /// The test carries its own control: unframed must give more than one height, framed exactly
    /// one. If the first stops finding a spread, the test says so rather than passing quietly.
    @MainActor
    @Test func theBarDrawsEverySegmentAtOneHeight() {
        func segment(_ workspace: Workspace, framed: Bool, full: Bool) -> CGSize {
            let glyph = Image(systemName: workspace.symbol).font(.system(size: 12, weight: .medium))
            let row = HStack(spacing: 6) {
                if framed {
                    glyph.frame(width: WorkspaceBarMetrics.glyphSide,
                                height: WorkspaceBarMetrics.glyphSide)
                } else {
                    glyph
                }
                if full { Text(workspace.title).font(.system(size: 12, weight: .semibold)) }
            }
            .padding(.horizontal, full ? 12 : 10)
            .padding(.vertical, 4)
            return NSHostingView(rootView: AnyView(row)).fittingSize
        }

        for full in [true, false] {
            let rung = full ? "labelled" : "icon-only"
            // The control: without the frame the heights disagree, or the assertion below is
            // measuring nothing.
            let unframed = Set(Workspace.allCases.map { segment($0, framed: false, full: full).height })
            #expect(unframed.count > 1, """
                    the \(rung) segments are already one height unframed \(unframed.sorted()) — \
                    either the symbols now agree or this measurement cannot see a difference, and \
                    the claim below proves nothing either way
                    """)
            // The claim.
            let framed = Set(Workspace.allCases.map { segment($0, framed: true, full: full).height })
            #expect(framed.count == 1, """
                    the \(rung) segments come out at \(framed.sorted())pt — the selected pill is \
                    sized to its own segment, so it changes height as it slides between them
                    """)
        }

        // And the width constant is true of every symbol, not just the narrowest.
        for workspace in Workspace.allCases {
            let drawn = segment(workspace, framed: true, full: true).width
            let label = NSHostingView(rootView: AnyView(
                Text(workspace.title).font(.system(size: 12, weight: .semibold)))).fittingSize.width
            #expect(abs(drawn - label - WorkspaceBarMetrics.segmentChrome) < 0.51, """
                    \(workspace.title) draws \(drawn)pt around a \(label)pt label, which is \
                    \(drawn - label)pt of chrome against segmentChrome's \
                    \(WorkspaceBarMetrics.segmentChrome) — the bar is measuring a width it does not draw
                    """)
            let icon = segment(workspace, framed: true, full: false).width
            #expect(abs(icon - WorkspaceBarMetrics.iconOnlySegmentWidth) < 0.51, """
                    \(workspace.title) draws \(icon)pt icon-only against \
                    \(WorkspaceBarMetrics.iconOnlySegmentWidth)
                    """)
        }
    }

    @Test func testWidthGrowsWithTheSegmentsItActuallyDraws() {
        // Guards the arithmetic itself: the gap term is easy to drop, and a width that ignores it
        // under-measures and never sheds when it should.
        let one = WorkspaceBarMetrics.fullWidth(labelWidths: [40])
        let two = WorkspaceBarMetrics.fullWidth(labelWidths: [40, 40])
        #expect(two == one + 40 + WorkspaceBarMetrics.segmentChrome + WorkspaceBarMetrics.segmentGap)
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

    // MARK: The open field's share of the row (§7)

    /// `styles(...)` with the field open, at a text scale.
    private func openStyles(contentWidth: CGFloat, labelWidths: [CGFloat],
                            scale: CGFloat = 1) -> ToolbarBarStyles {
        let search = searchWidths(scale: scale)
        return WorkspaceBarMetrics.styles(
            contentWidth: contentWidth, labelWidths: labelWidths,
            searchLabelWidth: search.label, searchKeycapWidth: search.keycap,
            openField: OpenFieldRequest(keycapWidth: search.keycap, scale: scale))
    }

    /// Nothing moves on a wide window: the field reaches its ceiling with every label still
    /// spelled out. This is the state a large display is always in, so it would hide a broken
    /// ladder from anyone testing by hand there.
    @Test func testAWideWindowOpensTheFieldAtItsCeilingAndMovesNothingElse() {
        let resolved = openStyles(contentWidth: 1700, labelWidths: labelWidths())
        #expect(resolved.workspace == .full, "the bar shed labels it did not need to")
        #expect(resolved.field?.width == GoToFieldMetrics.ceilingWidth)
        #expect(resolved.field?.placeholder == .full)
    }

    /// The field takes the spare, and stops at the ceiling. Between the two ends it is exactly what
    /// the row has left, which makes the open field part of the toolbar rather than a card on it.
    @Test func testTheFieldTakesWhatTheRowHasLeft() {
        let widths = labelWidths()
        let bar = WorkspaceBarMetrics.fullWidth(labelWidths: widths)
        // A width chosen so the spare lands strictly between the floor and the ceiling; at either
        // end the fixture proves nothing.
        let spare = (GoToFieldMetrics.floorWidth + GoToFieldMetrics.ceilingWidth) / 2
        let contentWidth = WorkspaceBarMetrics.reservedChrome + bar + spare
        let resolved = openStyles(contentWidth: contentWidth, labelWidths: widths)
        #expect(spare > GoToFieldMetrics.floorWidth && spare < GoToFieldMetrics.ceilingWidth)
        #expect(resolved.workspace == .full)
        #expect(resolved.field?.width == spare, "the field did not take the row's spare width")
    }

    /// The labels shed only when the field would otherwise be under its floor, and the shed has to
    /// buy the field width, or the bar loses its words for nothing.
    @Test func testTheLabelsShedForTheFieldAndTheShedBuysItWidth() {
        let widths = labelWidths()
        let bar = WorkspaceBarMetrics.fullWidth(labelWidths: widths)
        // One point under the floor with the labels up: the last width at which the bar sheds.
        let contentWidth = WorkspaceBarMetrics.reservedChrome + bar + GoToFieldMetrics.floorWidth - 1
        let resolved = openStyles(contentWidth: contentWidth, labelWidths: widths)
        #expect(resolved.workspace == .iconOnly, "the field was left under its floor with the labels up")
        let gained = bar - WorkspaceBarMetrics.iconOnlyWidth(segmentCount: widths.count)
        #expect(gained > 0)
        #expect(resolved.field?.width == GoToFieldMetrics.floorWidth - 1 + gained,
                "the shed did not reach the field")
        // And one point wider, the labels stay: this is a band, not a general rule.
        #expect(openStyles(contentWidth: contentWidth + 1, labelWidths: widths).workspace == .full)
    }

    /// At the window's own floor the field is still above its floor, so a field opened under 320pt
    /// cannot happen in this app. The icon-only bar's width does not depend on text size, so the
    /// narrowest window leaves the field over its floor at every size. The field floor's real job
    /// is to decide when the labels shed; the branch that opens the field under it is defensive,
    /// until another segment, a wider `reservedChrome` or a lower window minimum changes that.
    @Test func testTheNarrowestWindowStillClearsTheFieldsFloor() throws {
        for size in FontSize.allCases {
            let resolved = openStyles(contentWidth: Self.windowFloor,
                                      labelWidths: labelWidths(scale: size.scale), scale: size.scale)
            let width = try #require(resolved.field?.width)
            #expect(resolved.workspace == .iconOnly)
            #expect(width >= GoToFieldMetrics.floorWidth,
                    "at the window floor / \(size.displayName) the field opens at \(width), under its own floor")
        }
    }

    /// What the narrow end costs is the invitation, not the field: at the floor the full
    /// placeholder does not fit, so the short rung absorbs it.
    @Test func testTheNarrowestWindowShortensTheInvitation() {
        #expect(openStyles(contentWidth: Self.windowFloor, labelWidths: labelWidths()).field?.placeholder
                == .short)
        // And it is a rung, not a permanent state: the wide window says the whole sentence.
        #expect(openStyles(contentWidth: 1700, labelWidths: labelWidths()).field?.placeholder == .full)
    }

    /// The shed is a band, and both of its edges are silent. Above it the field reaches its ceiling
    /// with the labels up; below it the bar is icon-only at rest, so opening the field changes
    /// nothing visible. Only in between does the row rearrange, which is what a person would notice
    /// being wrong.
    @Test func testTheShedIsABandWithTwoSilentEdges() {
        let widths = labelWidths()
        var band: [CGFloat] = []
        for contentWidth in stride(from: Self.windowFloor, through: 1600, by: 1) {
            let closed = styles(contentWidth: contentWidth, labelWidths: widths)
            let open = openStyles(contentWidth: contentWidth, labelWidths: widths)
            if closed.workspace == .iconOnly {
                #expect(open.workspace == .iconOnly,
                        "at \(contentWidth)pt opening the field moved a bar that was already glyphs")
            }
            if closed.workspace == .full && open.workspace == .iconOnly { band.append(contentWidth) }
            // Above the band the field is at its ceiling, which is the other silent edge.
            if open.field?.width == GoToFieldMetrics.ceilingWidth {
                #expect(open.workspace == .full,
                        "at \(contentWidth)pt the bar shed labels for a field already at its ceiling")
            }
        }
        let first = band.first ?? 0
        let last = band.last ?? 0
        #expect(!band.isEmpty, "the shed-on-open never happens at any width — the rule is dead")
        #expect(band.count == Int(last - first) + 1, "the band has a hole in it")
        // A band inside the window's own range, ending by 1100pt. Loose bounds, because the exact
        // edges move with the labels' rendered widths; a band outside them is a real change.
        #expect(first >= Self.windowFloor && last <= 1100,
                "the shed band is \(first)–\(last)pt, outside the range §7 describes")
    }

    /// The chevron guard, swept: at every width and text size the row never promises more than it
    /// has. A toolbar that does not fit folds behind an overflow chevron, and the control that
    /// disappears is whichever one macOS picks.
    @Test func testTheOpenFieldNeverOverspendsTheRowAtAnyWidthOrTextSize() {
        for size in FontSize.allCases {
            let widths = labelWidths(scale: size.scale)
            for contentWidth in stride(from: Self.windowFloor, through: 2400, by: 13) {
                let resolved = openStyles(contentWidth: contentWidth, labelWidths: widths,
                                          scale: size.scale)
                let bar = resolved.workspace == .full
                    ? WorkspaceBarMetrics.fullWidth(labelWidths: widths)
                    : WorkspaceBarMetrics.iconOnlyWidth(segmentCount: widths.count)
                let spent = bar + (resolved.field?.width ?? 0)
                let available = contentWidth - WorkspaceBarMetrics.reservedChrome
                #expect(spent <= available,
                        "at \(contentWidth)pt / \(size.displayName) the row spends \(spent) of \(available)")
                #expect((resolved.field?.width ?? 0) <= GoToFieldMetrics.ceilingWidth)
            }
        }
    }

    /// The closed row is untouched by the open field: `styles` without one resolves no field,
    /// which is what the rest of this suite asserts against.
    @Test func testAClosedFieldLeavesTheLadderExactlyAsItWas() {
        let widths = labelWidths()
        for contentWidth in stride(from: Self.windowFloor, through: 2000, by: 37) {
            #expect(styles(contentWidth: contentWidth, labelWidths: widths).field == nil)
        }
    }

    // MARK: The progress capsule (TE205, TE206)

    /// `styles(...)` with a run going, closed or open, at a text scale.
    private func runStyles(contentWidth: CGFloat, labelWidths: [CGFloat], scale: CGFloat = 1,
                           open: Bool = false) -> ToolbarBarStyles {
        let search = searchWidths(scale: scale)
        return WorkspaceBarMetrics.styles(
            contentWidth: contentWidth, labelWidths: labelWidths,
            searchLabelWidth: search.label, searchKeycapWidth: search.keycap,
            openField: open ? OpenFieldRequest(
                keycapWidth: CommandPaletteBarMetrics.keycapWidth(symbol: GoToFieldMetrics.closeKeycap,
                                                                  scale: scale),
                scale: scale) : nil,
            runShowing: true)
    }

    /// The chevron guard, with the capsule on the row. A capsule folded behind the chevron is a run
    /// nobody can see or stop, so at every width and text size the row seats the capsule (at least
    /// its ring) and never spends more than it has, closed or with the Go-to field open.
    @Test func testTheCapsuleIsAlwaysSeatedAndNeverOverspendsTheRow() {
        for size in FontSize.allCases {
            let widths = labelWidths(scale: size.scale)
            let search = searchWidths(scale: size.scale)
            for contentWidth in stride(from: Self.windowFloor, through: 2400, by: 13) {
                for open in [false, true] {
                    let resolved = runStyles(contentWidth: contentWidth, labelWidths: widths,
                                             scale: size.scale, open: open)
                    let run = try? #require(resolved.run, "no capsule at \(contentWidth)pt / \(size.displayName)")
                    guard let run else { continue }
                    let bar = resolved.workspace == .full
                        ? WorkspaceBarMetrics.fullWidth(labelWidths: widths)
                        : WorkspaceBarMetrics.iconOnlyWidth(segmentCount: widths.count)
                    let pill = resolved.field?.width ?? CommandPaletteBarMetrics.width(
                        style: resolved.search, labelWidth: search.label, keycapWidth: search.keycap)
                    let spent = bar + pill + WorkspaceBarMetrics.capsuleWidth(run)
                    let available = contentWidth - WorkspaceBarMetrics.reservedChrome
                    #expect(spent <= available,
                            "at \(contentWidth)pt / \(size.displayName)\(open ? " (field open)" : "") the row spends \(spent) of \(available)")
                }
            }
        }
    }

    /// The ring before the labels: there is a band where the capsule has shrunk to its ring and the
    /// bar still spells its segments out. The bar is the primary navigation; the capsule's words are
    /// in its tooltip.
    @Test func testTheCapsuleShrinksToItsRingBeforeTheLabelsShed() {
        let widths = labelWidths()
        let rungs = stride(from: Self.windowFloor, through: 2000, by: 1).map {
            runStyles(contentWidth: $0, labelWidths: widths)
        }
        #expect(rungs.contains { $0.run == .ring && $0.workspace == .full })
        // And never the other way round: labels shed while the full capsule stays.
        #expect(!rungs.contains { $0.run == .full && $0.workspace == .iconOnly })
    }

    /// The narrowest window keeps the ring and its stop button; an ordinary one has the whole
    /// capsule beside the full row.
    @Test func testTheFloorSeatsTheRingAndAnOrdinaryWindowTheWholeCapsule() {
        let widths = labelWidths()
        #expect(runStyles(contentWidth: Self.windowFloor, labelWidths: widths).run == .ring)
        let wide = runStyles(contentWidth: 1600, labelWidths: widths)
        #expect(wide.run == .full)
        #expect(wide.workspace == .full && wide.search == .full)
        // With the field open the capsule takes its ring and the field the rest.
        #expect(runStyles(contentWidth: 1600, labelWidths: widths, open: true).run == .ring)
    }

    /// No run, no capsule: the row without one resolves exactly as plain `styles` does, and the
    /// style set hands each of the four states its own answer.
    @Test func testWithNoRunTheRowIsUntouched() {
        let widths = labelWidths()
        let search = searchWidths()
        for contentWidth in stride(from: Self.windowFloor, through: 2000, by: 37) {
            let set = WorkspaceBarMetrics.styleSet(
                contentWidth: contentWidth, labelWidths: widths,
                searchLabelWidth: search.label, searchKeycapWidth: search.keycap,
                fieldKeycapWidth: CommandPaletteBarMetrics.keycapWidth(symbol: GoToFieldMetrics.closeKeycap,
                                                                       scale: 1),
                scale: 1)
            #expect(set.resolved(fieldOpen: false, runShowing: false) == styles(contentWidth: contentWidth, labelWidths: widths))
            #expect(set.resolved(fieldOpen: false, runShowing: false).run == nil)
            #expect(set.resolved(fieldOpen: true, runShowing: false).run == nil)
            #expect(set.resolved(fieldOpen: false, runShowing: true) == runStyles(contentWidth: contentWidth, labelWidths: widths))
            #expect(set.resolved(fieldOpen: true, runShowing: true) == runStyles(contentWidth: contentWidth, labelWidths: widths, open: true))
        }
    }

    /// A message wears the run's row. At every width a message alone gets exactly the row a run
    /// would, the full capsule wherever a run's is full, so a run's ending never drops to a bare ✓;
    /// and a run's row is untouched by a message over it. The sweep must reach both rungs, and a
    /// width where the message sheds a label for its full capsule.
    @Test func testAMessageWearsTheRunsRow() {
        let widths = labelWidths()
        let search = searchWidths()
        var rungs: Set<String> = []
        var shedForTheMessage = false
        for contentWidth in stride(from: Self.windowFloor, through: 2000, by: 7) {
            let set = WorkspaceBarMetrics.styleSet(
                contentWidth: contentWidth, labelWidths: widths,
                searchLabelWidth: search.label, searchKeycapWidth: search.keycap,
                fieldKeycapWidth: CommandPaletteBarMetrics.keycapWidth(symbol: GoToFieldMetrics.closeKeycap,
                                                                       scale: 1),
                scale: 1)
            for open in [false, true] {
                let bare = set.resolved(fieldOpen: open, runShowing: false)
                let message = set.resolved(fieldOpen: open, runShowing: false, messageShowing: true)
                #expect(message == set.resolved(fieldOpen: open, runShowing: true),
                        "a message at \(contentWidth)pt did not wear the run's row")
                #expect(message.run != nil, "a message at \(contentWidth)pt had no capsule")
                if message.run == .full, message.workspace != bare.workspace || message.search != bare.search {
                    shedForTheMessage = true
                }
                rungs.insert("\(message.run.map { "\($0)" } ?? "none")")
                #expect(set.resolved(fieldOpen: open, runShowing: true, messageShowing: true)
                        == set.resolved(fieldOpen: open, runShowing: true))
            }
        }
        #expect(rungs == ["full", "ring"], "the sweep never reached one of the rungs: \(rungs)")
        #expect(shedForTheMessage, "no width had the message shed a label for its full capsule — TE230's rule is back")
    }
}
