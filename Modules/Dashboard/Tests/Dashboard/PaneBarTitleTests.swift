import SwiftUI
import Testing
import Design
@testable import Dashboard

/// The pane bar's words: when they are drawn, when they are declined, and what they say.
///
/// **Deliberately not `.machinePinned`.** `PaneBarLadderTests` carries the geometry and is pinned
/// because it reads painted pixels back out of a live renderer, which means none of it runs on CI.
/// The decisions below are the ones that must not regress unnoticed — above all the text-size gate,
/// which is the only thing keeping a title out of a header that cannot hold it — so they are
/// arithmetic over published constants and run everywhere. Where the gate's *line* belongs is a
/// question about drawn ink and cannot be settled here; `PaneBarLadderTests.theTitledHeaderClearsBothEdges`
/// settles it, and this suite holds the resulting table.
///
/// Nothing here asserts a point size for its own sake. The claims are behavioural (does the bar
/// title at this text size, does this word change when that state does), so a font whose metrics
/// moved would fail these for the same reason a code change would: the bar would be wrong.
@MainActor
@Suite struct PaneBarTitleTests {

    /// The items a full Columns pane offers — the same list `PaneHeader.availableItems` builds for
    /// a header with every binding passed.
    private static let available: [PaneBarItem] =
        [.backForward, .sort, .hiddenFiles, .viewMode, .scan, .newFolder, .preview, .delete, .search]

    private static func ladder(_ mode: PaneBarLabelMode, scale: CGFloat = 1) -> PaneBarLadder {
        PaneBarLadder(arrangement: .default, available: available, ceiling: PaneBarIconSize.regular.ceiling,
                      labelMode: mode, scale: scale)
    }

    // MARK: - The text-size gate

    /// **Which of the ten text sizes the slider offers get words, stated as a table.**
    ///
    /// The gate itself is right and always was — a row the header cannot hold falls back to
    /// `iconOnly` — but its budget was the *retired provider capsule's* 34pt rather than the
    /// header's own room, which put the cliff at **110%**: the first step up from the default, and
    /// six of these ten. The doc beside it said Large and Larger. Reported as "icon + text mode
    /// isn't showing text any more" by someone sitting at 110%.
    ///
    /// **This test could not have caught that, and the reason is the arguments it used to take.**
    /// They were `0.9, 1.0, 1.25, 1.35` — the four *named presets*, which were the only sizes that
    /// existed when the gate was written. `FontSize` became a 90–135 slider in steps of 5 and the
    /// six sizes in between were never asked about by anything. So the table below is the whole
    /// selectable set, spelled percentage by percentage, and it is written out rather than derived
    /// from `rowBudget` — a table that recomputes the thing it is checking agrees with any budget
    /// it is given, including the wrong one.
    ///
    /// If the slider's range or step ever widens, this fails as unhandled percentages rather than
    /// passing silently over them, which is the whole point of listing them.
    @Test(arguments: [(90, true), (95, true), (100, true), (105, true), (110, true), (115, true),
                      (120, false), (125, false), (130, false), (135, false)])
    func theTextSizesThatGetWords(percent: Int, expected: Bool) {
        let scale = FontSize(percent: percent).scale
        let bar = Self.ladder(.iconAndText, scale: scale)
        let row = PaneBarTitleMetrics.rowHeight(pillHeight: PaneNavMetrics.pill(.small).height, scale: scale)
        #expect((bar.titledRungs == 1) == expected,
                "at \(percent)% the titled row is \(row)pt against a \(PaneBarTitleMetrics.rowBudget)pt budget")
    }

    /// The table above covers exactly the sizes the app offers, and nothing outside it.
    ///
    /// A pair of tables that drift apart is the failure this prevents: the arguments above are
    /// hand-written, so without this a percentage added to the slider would simply go unasked.
    @Test func theTableCoversEverySelectableSize() {
        #expect(Self.gatedPercents == FontSize.selectablePercents)
    }

    private static let gatedPercents = [90, 95, 100, 105, 110, 115, 120, 125, 130, 135]

    /// Both sides of the gate are real — some sizes title and some do not — and the boundary is not
    /// sitting on the budget by a hair.
    ///
    /// **The margin is the assertion.** `rowBudget` was calibrated to fall *between* two of the five
    /// row heights the app can produce (35 and 37), so the widest admitted row and the narrowest
    /// refused one should each be a point clear of it. A budget nudged onto either of those values
    /// still passes the table above, and fails here — which is what stops the next edit from
    /// re-creating the original defect by moving the line onto a measured number.
    @Test func theGateHasBothDirectionsWithMarginOnEach() {
        let pill = PaneNavMetrics.pill(.small).height
        let rows = FontSize.selectablePercents.map {
            (percent: $0, row: PaneBarTitleMetrics.rowHeight(pillHeight: pill,
                                                             scale: FontSize(percent: $0).scale))
        }
        let admitted = rows.filter { $0.row <= PaneBarTitleMetrics.rowBudget }
        let refused = rows.filter { $0.row > PaneBarTitleMetrics.rowBudget }
        #expect(!admitted.isEmpty && !refused.isEmpty,
                "one side of the gate is empty, so it has never been exercised")
        #expect(admitted.map(\.row).max()! <= PaneBarTitleMetrics.rowBudget - 1,
                "the widest admitted row is flush against the budget")
        #expect(refused.map(\.row).min()! >= PaneBarTitleMetrics.rowBudget + 1,
                "the narrowest refused row is flush against the budget")
    }

    /// `iconOnly` is a pin downward: no width and no text size ever produces a title.
    @Test(arguments: FontSize.selectablePercents)
    func iconOnlyNeverTitles(percent: Int) {
        #expect(Self.ladder(.iconOnly, scale: FontSize(percent: percent).scale).titledRungs == 0)
    }

    /// With titles declined — by the preference or by the gate — the ladder is *exactly* the one
    /// that shipped before them: no rung taller than its own pill, and one rung shorter for having
    /// no titled head. This is what makes Icon Only and the large text sizes free of regression
    /// risk rather than merely believed to be.
    ///
    /// **Asserted against the pill rather than against the titled ladder at one hard-coded scale.**
    /// It used to compare `iconAndText` at 1.35 with `iconOnly` at 1.35 and expect them equal,
    /// which says nothing at all about any size the gate admits — and would have gone on passing if
    /// the gate had started refusing every size there is.
    @Test(arguments: FontSize.selectablePercents)
    func decliningTitlesRestoresTheOriginalLadder(percent: Int) {
        let plain = Self.ladder(.iconOnly, scale: FontSize(percent: percent).scale)
        #expect(plain.titledRungs == 0)
        for rung in 0...plain.terminal {
            #expect(plain.height(forRung: rung)
                    == PaneNavMetrics.pill(plain.controlSize(forRung: rung)).height,
                    "rung \(rung) at \(percent)% is taller than its own pill")
        }
        // And a size the gate refuses lands on that same ladder by the other route.
        let gated = Self.ladder(.iconAndText, scale: FontSize(percent: percent).scale)
        guard gated.titledRungs == 0 else { return }
        #expect(gated.terminal == plain.terminal)
        for rung in 0...plain.terminal {
            #expect(gated.width(forRung: rung) == plain.width(forRung: rung), "rung \(rung)")
            #expect(gated.height(forRung: rung) == plain.height(forRung: rung), "rung \(rung)")
        }
    }

    // MARK: - Titles shed as one rung

    /// Titles go **all together**, ahead of the step down to `.mini` — the rule
    /// `WorkspaceBarMetrics` already applies, because a bar where some items are words and others
    /// are glyphs reads as two controls.
    ///
    /// Asserted as "the same items, drawn differently": rung 0 and rung 1 must carry an identical
    /// plan and differ only in whether they are titled. If shedding a title ever cost an item as
    /// well, this is where it shows.
    @Test func titlesShedAsOneRungBeforeAnythingElseChanges() {
        let bar = Self.ladder(.iconAndText)
        #expect(bar.titledRungs == 1)
        #expect(bar.isTitled(forRung: 0))
        #expect(!bar.isTitled(forRung: 1))
        #expect(bar.plan(forRung: 0).visible == bar.plan(forRung: 1).visible)
        #expect(bar.plan(forRung: 0).overflow == bar.plan(forRung: 1).overflow)
        #expect(bar.controlSize(forRung: 0) == bar.controlSize(forRung: 1))
        // And the titled rung is the wider of the two, or it could never be the one that steps down.
        #expect(bar.width(forRung: 0) > bar.width(forRung: 1))
    }

    /// The rung after the untitled one is where the glyphs shrink — titles are not competing with
    /// `.mini` for the same step.
    @Test func theSizeStepComesAfterTheTitleStep() {
        let bar = Self.ladder(.iconAndText)
        #expect(bar.controlSize(forRung: bar.titledRungs + 1) == .mini)
    }

    // MARK: - What the words say

    /// A title names the control; the glyph reports its state. Hidden Files is the case that makes
    /// the rule visible — its eye swaps open and slashed while the word holds.
    @Test func onlyTheScanRungChangesItsWord() {
        for item in PaneBarItem.allCases where !item.isSpacer {
            #expect(item.titleVariants.first == item.barTitle)
            if item == .scan {
                #expect(item.titleVariants.count == 2, "scan's word swaps with its glyph")
            } else {
                #expect(item.titleVariants.count == 1,
                        "\(item.rawValue) has more than one word — only Scan should")
            }
        }
    }

    /// Scan's word follows `ScanRungMode`, so the glyph and the word cannot disagree about which
    /// act the rung performs.
    @Test func scansWordFollowsItsMode() {
        #expect(ScanRungMode.resolve(isRefreshing: false, canCancel: true).barTitle == "Scan")
        #expect(ScanRungMode.resolve(isRefreshing: true, canCancel: true).barTitle == "Stop")
        // No cancel handler: the rung stays a (disabled) Scan, so its word must too — a "Stop" on a
        // control that cannot stop anything is the disagreement this pairing exists to prevent.
        #expect(ScanRungMode.resolve(isRefreshing: true, canCancel: false).barTitle == "Scan")
    }

    /// The reservation: an item whose word can change is laid out at the widest of them, so the bar
    /// cannot re-flow under the cursor. Today both of Scan's words are narrower than its pill, so
    /// the guarantee costs nothing — which is exactly why it needs a test rather than a comment.
    @Test func aSwappingWordNeverChangesItsItemsWidth() {
        let pill = PaneNavMetrics.pill(.small)
        let reserved = PaneBarLayout.titledWidth(of: .scan, pill: pill, compactsViewMode: false, scale: 1)
        for word in PaneBarItem.scan.titleVariants {
            #expect(LabelMetrics.width(of: word, font: PaneBarTitleMetrics.font, scale: 1) <= reserved)
        }
        #expect(reserved == pill.width, "both of Scan's words fit its pill, so the item is pill-wide")
    }

    /// Every control has a word. A new `PaneBarItem` that forgets one would otherwise ship as a
    /// pill with a blank line under it, which no geometry assertion notices.
    @Test func everyControlHasAWordAndEverySpacerHasNone() {
        for item in PaneBarItem.allCases {
            if item.isSpacer {
                #expect(item.barTitle.isEmpty, "\(item.rawValue) is layout, not a control")
            } else {
                #expect(!item.barTitle.isEmpty, "\(item.rawValue) has no bar title")
            }
        }
    }

    /// The short title is a *different* string from the menu's, not a copy — that is the whole
    /// reason it exists. Collapse is the case that forced it: "Collapse Pane" is wider than the
    /// pill it would sit under.
    @Test func theBarsWordIsShorterThanTheMenusWhereItHadToBe() {
        #expect(PaneBarItem.collapse.barTitle != PaneBarItem.collapse.displayName)
        #expect(LabelMetrics.width(of: PaneBarItem.collapse.barTitle, font: PaneBarTitleMetrics.font, scale: 1)
                < LabelMetrics.width(of: PaneBarItem.collapse.displayName, font: PaneBarTitleMetrics.font, scale: 1))
    }

    // MARK: - The overflow takes no word

    /// ⋯ stays a pill wide in both modes. Finder labels its *Action* menu, but that is a fixed
    /// contextual menu; our analogue is Finder's unlabelled `»`, whose contents depend on what
    /// happened to fit.
    @Test func theOverflowPillIsNotWidenedByTitles() {
        let bar = Self.ladder(.iconAndText)
        // A rung deep enough to fold something, so the ⋯ is present at all.
        let deep = bar.terminal
        #expect(!bar.plan(forRung: deep).overflow.isEmpty)
        let pill = PaneNavMetrics.pill(bar.controlSize(forRung: deep))
        // The overflow contributes exactly a pill and its gap — **priced in BOTH modes**, which is
        // what this test's name claims and what neither call used to ask for: every `width(of:)`
        // here omitted `titled:`, so it measured the untitled rung twice and the word "titled" in
        // the name was answered by nothing.
        let plan = bar.plan(forRung: deep)
        let itemsOnlyPlan = PaneBarLayoutPlan(visible: plan.visible, overflow: [],
                                              compactsViewMode: plan.compactsViewMode)
        for titled in [false, true] {
            let withOverflow = PaneBarLayout.width(of: plan, controlSize: bar.controlSize(forRung: deep),
                                                   titled: titled)
            let itemsOnly = PaneBarLayout.width(of: itemsOnlyPlan,
                                                controlSize: bar.controlSize(forRung: deep),
                                                titled: titled)
            #expect(withOverflow - itemsOnly == pill.width + PaneNavMetrics.itemGap(titled: titled),
                    "the ⋯ costs more than a pill and its gap with titled=\(titled)")
        }
    }
}
