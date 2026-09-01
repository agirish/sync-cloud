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
/// This exists because the failure it guards is invisible: a toolbar that does not fit does not
/// truncate or wrap — macOS folds the overflow behind a chevron, and the only control for
/// switching workspace disappears with no error and no visual cue that anything was dropped.
///
/// It covers the ⌘K search pill too, because the two controls share one row and are therefore one
/// decision — `styles(...)`. Every assertion below that used to call `style(...)` now reads
/// `.workspace` off that result and pays for a real search pill while doing it, which is the point:
/// the old numbers were true of a toolbar this app no longer has.
@Suite struct WorkspaceBarMetricsTests {

    /// The narrowest window there is: `ContentView`'s `.frame(minWidth: 810, …)`, which
    /// `.windowResizability(.contentMinSize)` makes a floor rather than a preference.
    ///
    /// **One constant, because "the floor" is a claim every test here makes.** It was the bare
    /// literal 600, nine times across four tests, until the window was raised — and a literal
    /// repeated nine times is nine chances to update eight of them, the shape that leaves one
    /// assertion quietly measuring a width no window can have.
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
                        scale: CGFloat = 1) -> ToolbarBarStyles {
        let search = searchWidths(scale: scale)
        return WorkspaceBarMetrics.styles(contentWidth: contentWidth, labelWidths: labelWidths,
                                          searchLabelWidth: search.label,
                                          searchKeycapWidth: search.keycap)
    }

    private func labelWidths(scale: CGFloat = 1) -> [CGFloat] {
        let font = NSFont.systemFont(ofSize: 12 * scale, weight: .semibold)
        return Workspace.allCases.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }
    }

    /// **What each new segment costs, stated as a number rather than discovered.**
    ///
    /// The history is the point of the number. Three labelled segments fit the window's old 600pt
    /// `minWidth` — the win of folding five workspaces down to three. The ⌘K pill then took part
    /// of that row and left a 17pt band above the floor where the bar is glyphs. Browse took its
    /// label, its `segmentChrome` and one more `segmentGap`, and the band grew: below roughly
    /// 720pt the segments were icons. (720 and not the 708 this said until 2026-08-30 —
    /// `segmentChrome` had assumed a 14pt glyph where the symbols draw at 14, 15, 16 and 17.)
    ///
    /// **That band is what raised the window rather than being shaved away.** Shortening a label
    /// people navigate by was the alternative, and under-measuring the row is exactly what folds
    /// the toolbar behind the overflow chevron — the failure this whole type exists to prevent.
    /// So the arithmetic stayed and the floor moved: to 760 for four labels, and to **810** when
    /// Edit made it five. Its label costs ~23pt plus 47 of chrome and a 4pt gap; deleting the group
    /// rule handed 13 of that back, so the threshold went from 720.2 to **781.2** at the default
    /// text size and the floor sits ~29pt clear of it.
    ///
    /// **781.2 and not the 793.4 this said while the label read "Editor"** — the tab was renamed to
    /// "Edit", which is 12.2pt narrower at the default size and moves every number here with it.
    /// The floor stays at 810 rather than following the label back down: Default still needs 781,
    /// so a return to 760 would put the ordinary text size back behind the chevron. What the
    /// shorter word bought is margin, not a smaller window.
    ///
    /// What is pinned here is that it stays that way — a sixth segment or another toolbar control
    /// would push the threshold back up through the floor, and this fails naming the number rather
    /// than letting a glyph-only floor return unannounced.
    @Test func testTheLabelsSurviveTheNarrowestWindow() {
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
        // **An absolute ceiling, so the floor cannot simply be raised to whatever the row wants.**
        // The window opens at ~85% of the screen, so the shedding band has to stay a corner of the
        // range rather than most of it. 850 is the floor's 810 plus one segment's worth of room:
        // the next workspace has to be paid for by a measurement and a decision, not by dragging
        // this number along behind it. Measured at 781.2 today.
        #expect(keepsWords < 850,
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
    /// At 600 this was a single answer: `iconOnly` at every size. At 760 it splits, and the split
    /// is the point — the labelled bar is what a user sees at the narrowest window they can make,
    /// until the text is large enough that the row genuinely does not fit.
    ///
    /// **Where that line falls moved on 2026-08-30, and mostly because the arithmetic stopped being
    /// wrong rather than because the bar grew.** `segmentChrome` had assumed a 14pt glyph while the
    /// four symbols draw at 16, 14, 16 and 15, so every width here was 5pt optimistic across the
    /// four segments. Framing the glyph to `WorkspaceBarMetrics.glyphSide` made the constant exact
    /// and padded the three narrower glyphs out to 17 as well, which is why the computed width moved
    /// by 12 rather than by 5. Two answers at the floor changed with it: **Large sheds its labels**
    /// where it used to keep them, and **Small's pill drops its word** where the row used to spell
    /// everything out.
    ///
    /// Both moved toward shedding, which is the safe direction — an over-optimistic row does not
    /// truncate, it folds behind the overflow chevron. Neither is a free win, though: a Large-text
    /// user at the narrowest window now navigates by glyphs. Reclaiming that would mean buying back
    /// ~12pt from `reservedChrome` (deliberately generous, and unmeasured) or from the segments' own
    /// padding, and that is a design call rather than an arithmetic one.
    @Test func testTheFloorKeepsItsLabelsAtEveryTextSize() {
        // **Every size now, and that is what the Storage fold bought.** This asserted `.iconOnly`
        // at Large and Largest, because five labels needed 833 and 853pt against an 810 floor. Four
        // labels need **666.8 / 683.8 / 725.1 / 741.6** at Small / Default / Large / Largest —
        // measured through `styles`, all of them under the restored 760 floor. So a user at the
        // narrowest window the app allows keeps the words at every text size the app ships, which
        // is the state the 600 → 760 raise was originally trying to reach and never quite did.
        //
        // The tightest margin is Largest: 741.6 against 760, **18.4pt**. That is real headroom but
        // it is not generous, and it is the number a sixth label or a wider pill would spend first.
        for size in FontSize.allCases {
            let resolved = styles(contentWidth: Self.windowFloor,
                                  labelWidths: labelWidths(scale: size.scale), scale: size.scale)
            #expect(resolved.workspace == .full,
                    "at the \(Self.windowFloor)pt floor the bar is \(resolved.workspace) at \(size.displayName) — the narrowest window is glyphs again at this size")
            // **The pill now splits where the bar used to.** It read `.compact` at every size at
            // the 810 floor with five labels — the pill pays first, so it was already paying before
            // the bar started to. With four labels there is room to spell it out at Small and
            // Default, and the two larger sizes still spend it. That is the ladder working exactly
            // as designed: the cheap word goes first and the navigation labels never go at all.
            //
            // Asserted per size rather than flat, because a flat answer is what hid the previous
            // split: this test asserted a flat `.compact` and was right by accident once the bar
            // had grown enough to make it true everywhere.
            let expectedPill: CommandPaletteBarStyle =
                (size == .large || size == .extraLarge) ? .compact : .full
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

    /// **The shipping bar no longer reaches the icon-only rung, and that is a finding rather than
    /// a tidy-up.**
    ///
    /// This test used to assert the opposite, and the history is the point. At the 600pt floor the
    /// rung was unreachable: three labelled segments fitted at every text size, so nothing in the
    /// shipping app ever shed a label. Browse made it reachable, Edit made it reachable at more
    /// sizes, and this test was renamed to say so. **Folding Storage in has made it unreachable
    /// again** — four labels need at most 741.6pt (Largest) against the restored 760pt floor, so
    /// there is no legal window width at any text size where the shipping bar sheds.
    ///
    /// **It is not deleted, for two reasons.** The rung is still *live code* — the arithmetic runs
    /// on every layout pass and still answers `.iconOnly` for a wider bar, which the queued-bar half
    /// below exercises. And it is one segment from mattering again: ROADMAP costs Backup out as the
    /// fifth workspace this fold makes room for, and five labels at 833/853 put the rung straight
    /// back into the shipping range. Deleting it now would mean rediscovering it then.
    ///
    /// What this test asserts is therefore the CURRENT truth in both directions: the shipping bar
    /// does not reach the rung, and a wider bar still does. If a change ever makes the shipping bar
    /// shed again, the first assertion fails and names the size — which is the notification worth
    /// having, and the reason this is not simply an `.disabled` test.
    @Test func testTheIconOnlyRungIsOutOfTheShippingBarsReachButStillLive() {
        // The shipping bar, at the floor, at the largest text the app offers — the single hardest
        // case there is. It keeps its labels.
        #expect(styles(contentWidth: Self.windowFloor,
                       labelWidths: labelWidths(scale: FontSize.extraLarge.scale),
                       scale: FontSize.extraLarge.scale).workspace == .full,
                "the shipping four-segment bar sheds its labels at the floor — the rung is back in reach, so this test and the floor test above now disagree and one of them is describing an app that no longer exists")

        // …and no width in the app's whole legal range reaches it either, which is the claim the
        // single case above cannot make on its own. Swept from the floor, because narrower than
        // the floor is not a window a user can make.
        for size in FontSize.allCases {
            let widths = labelWidths(scale: size.scale)
            for width in stride(from: Self.windowFloor, through: 2400.0, by: 5.0) {
                #expect(styles(contentWidth: width, labelWidths: widths, scale: size.scale).workspace == .full,
                        "at \(width)pt and \(size.displayName) the shipping bar is glyphs — the rung is reachable again")
            }
        }

        // **The rung itself still works**, which is what keeps this from being dead code. Six
        // labelled segments — Backup and one more beyond it — shed at the floor exactly as they
        // should. This is the half that will matter when Backup lands.
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

    /// **Every segment is one height, and `segmentChrome` is exact rather than approximate.**
    ///
    /// Neither claim had a test, and both were false. The four workspace symbols render at four
    /// different sizes at the same font size — `folder` 16×13, `arrow.left.arrow.right` 14×17,
    /// `folder.badge.gearshape` 16×14, `chart.pie` 15×15 — so Compare's segment was 25pt and the
    /// rest 23pt (icon-only: 21, 25, 22, 23). Three things followed, and none of them was visible
    /// from the padding literals or from any assertion in this file:
    ///
    /// - the selected pill is a `Capsule` sized to its own segment inside a `matchedGeometryEffect`,
    ///   so it grew or shrank *while sliding* between Compare and anything else;
    /// - a capsule nests concentrically in a capsule only at a uniform inset, and the vertical inset
    ///   was 4pt for three segments against the horizontal 3pt;
    /// - `segmentChrome` assumed 14pt of glyph, under-measuring the drawn bar by 5pt across four
    ///   — the direction that folds the toolbar behind the overflow chevron.
    ///
    /// **This test carries its own control.** Measuring the framed segments alone would pass just as
    /// well if `fittingSize` were blind to the difference, or if every symbol happened to agree
    /// today. So it measures both: unframed must produce MORE than one height (the defect, still
    /// reproducible), framed must produce exactly one. If the first line ever stops finding a
    /// spread, this test has stopped proving anything and says so rather than passing quietly.
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
            // The control: without the frame the heights disagree. This is the defect, and it has
            // to still be reproducible or the assertion below is measuring nothing.
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

        // And the width constant is now true of every symbol rather than of the narrowest one.
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

    /// **Nothing moves on a wide window.** The field reaches its ceiling with every label still
    /// spelled out — the state the primary machine is always in (its window is ~1700pt), and
    /// therefore the state that would hide a broken ladder from the only person running this.
    @Test func testAWideWindowOpensTheFieldAtItsCeilingAndMovesNothingElse() {
        let resolved = openStyles(contentWidth: 1700, labelWidths: labelWidths())
        #expect(resolved.workspace == .full, "the bar shed labels it did not need to")
        #expect(resolved.field?.width == GoToFieldMetrics.ceilingWidth)
        #expect(resolved.field?.placeholder == .full)
    }

    /// **The field takes the spare, and stops at the ceiling.** Between the two ends it is neither
    /// fixed nor greedy: exactly what the row has left, which is what makes the open field feel
    /// like part of the toolbar rather than a card that happens to be up there.
    @Test func testTheFieldTakesWhatTheRowHasLeft() {
        let widths = labelWidths()
        let bar = WorkspaceBarMetrics.fullWidth(labelWidths: widths)
        // A width chosen so the spare lands strictly between the floor and the ceiling — the
        // fixture is worthless if it happens to sit at either end.
        let spare = (GoToFieldMetrics.floorWidth + GoToFieldMetrics.ceilingWidth) / 2
        let contentWidth = WorkspaceBarMetrics.reservedChrome + bar + spare
        let resolved = openStyles(contentWidth: contentWidth, labelWidths: widths)
        #expect(spare > GoToFieldMetrics.floorWidth && spare < GoToFieldMetrics.ceilingWidth)
        #expect(resolved.workspace == .full)
        #expect(resolved.field?.width == spare, "the field did not take the row's spare width")
    }

    /// **The labels shed only when the field would otherwise be under its floor — and shedding
    /// has to actually buy something.** The second half is what a rule like this gets wrong: a
    /// shed that leaves the field the same width is a bar that lost its words for nothing.
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

    /// **At the window's own floor the field is still above its floor — so §7's "below the 320pt
    /// floor" case cannot happen in this app.**
    ///
    /// Measured, not assumed, and it is the reverse of what the section predicted. The icon-only
    /// bar's width does not depend on the text size (it is glyphs and padding), so the narrowest
    /// window there is leaves the field ~359pt at every text size — comfortably over its 320
    /// floor. The floor's real job is therefore not to clamp the field but to decide **when the
    /// labels shed**, and the last-resort branch that opens the field under its floor is defensive
    /// rather than reachable. It stops being defensive the moment a fifth workspace lands, or
    /// `reservedChrome` grows, or the window's minimum is lowered — which is what this pins.
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

    /// **What the narrow end actually costs is the invitation, not the field.** At the floor the
    /// full placeholder needs ~390pt of field against the ~359 there is, so the short rung is what
    /// absorbs it — and the rung exists precisely because this state is reachable and the wide one
    /// is the common one.
    @Test func testTheNarrowestWindowShortensTheInvitation() {
        #expect(openStyles(contentWidth: Self.windowFloor, labelWidths: labelWidths()).field?.placeholder
                == .short)
        // And it is a rung, not a permanent state: the wide window says the whole sentence.
        #expect(openStyles(contentWidth: 1700, labelWidths: labelWidths()).field?.placeholder == .full)
    }

    /// **The shed is a band, and both of its edges are silent.** Above it the field reaches its
    /// ceiling with the labels up; below it the bar is icon-only at rest, so opening the field
    /// changes nothing a user can see. Only in between does the row visibly rearrange — which is
    /// the claim §7 makes and the one thing about this rule a person would notice being wrong.
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
        // The numbers §7 quotes, held to the arithmetic rather than to prose: a band inside the
        // window's own range, roughly 810–1045 — it moved up with the fifth label, from the
        // 710–950 four labels put it at. Loose bounds, because the exact edges move with the
        // labels' rendered widths; a band that walked out of this range would be a real change.
        #expect(first >= Self.windowFloor && last <= 1100,
                "the shed band is \(first)–\(last)pt, outside the range §7 describes")
    }

    /// **The chevron guard, swept.** Everything above is a claim about one width; this is the
    /// claim that matters at every width — the row never promises more than it has. A toolbar that
    /// does not fit does not truncate: macOS folds it behind an overflow chevron, and the control
    /// that disappears is whichever one macOS picks.
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

    /// The closed row is untouched by all of this: `styles` without a field resolves exactly what
    /// it resolved before, which is what the rest of this suite is asserting.
    @Test func testAClosedFieldLeavesTheLadderExactlyAsItWas() {
        let widths = labelWidths()
        for contentWidth in stride(from: Self.windowFloor, through: 2000, by: 37) {
            #expect(styles(contentWidth: contentWidth, labelWidths: widths).field == nil)
        }
    }
}
