import SwiftUI
import Testing
import Design
@testable import Dashboard

/// The pane bar's words: when they are drawn, when they are declined, and what they say.
///
/// Not machine-pinned: `PaneBarLadderTests` reads painted pixels and so never runs on CI, while
/// these decisions, above all the text-size gate that keeps a title out of a header that can't
/// hold it, are arithmetic over published constants and run everywhere. Where the gate's line
/// belongs is a question about drawn ink, settled by
/// `PaneBarLadderTests.theTitledHeaderClearsBothEdges`; this suite holds the resulting table.
///
/// The claims are behavioural, not point sizes, so a font whose metrics moved fails these for the
/// same reason a code change would: the bar would be wrong.
@MainActor
@Suite struct PaneBarTitleTests {

    /// The items a full Columns pane offers, as `PaneHeader.availableItems` builds them for a header
    /// with every binding passed.
    private static let available: [PaneBarItem] =
        [.backForward, .sort, .hiddenFiles, .viewMode, .scan, .newFolder, .delete, .search]

    private static func ladder(_ mode: PaneBarLabelMode, scale: CGFloat = 1) -> PaneBarLadder {
        PaneBarLadder(arrangement: .default, available: available, ceiling: PaneBarIconSize.regular.ceiling,
                      labelMode: mode, scale: scale)
    }

    // MARK: - The text-size gate

    /// Which of the slider's text sizes get words, as a table. A row the header can't hold falls
    /// back to `iconOnly`. Every selectable percentage is listed, written out rather than derived
    /// from `rowBudget`, since a table that recomputes the budget agrees with any budget, wrong ones
    /// included. `theTableCoversEverySelectableSize` fails if the slider gains a size.
    @Test(arguments: [(90, true), (95, true), (100, true), (105, true), (110, true), (115, true),
                      (120, false), (125, false), (130, false), (135, false)])
    func theTextSizesThatGetWords(percent: Int, expected: Bool) {
        let scale = FontSize(percent: percent).scale
        let bar = Self.ladder(.iconAndText, scale: scale)
        let row = PaneBarTitleMetrics.rowHeight(pillHeight: PaneNavMetrics.pill(.small).height, scale: scale)
        #expect((bar.titledRungs == 1) == expected,
                "at \(percent)% the titled row is \(row)pt against a \(PaneBarTitleMetrics.rowBudget)pt budget")
    }

    /// The table above covers exactly the sizes the app offers. Its arguments are hand-written, so
    /// without this a percentage added to the slider would go unasked.
    @Test func theTableCoversEverySelectableSize() {
        #expect(Self.gatedPercents == FontSize.selectablePercents)
    }

    private static let gatedPercents = [90, 95, 100, 105, 110, 115, 120, 125, 130, 135]

    /// Both sides of the gate are real, and the budget sits clear of the rows on each side.
    /// `rowBudget` falls between two producible row heights (36 and 37); a budget nudged onto
    /// either still passes the table above but fails here. The producible rows are consecutive
    /// integers, so half a point is the widest margin there is.
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
        #expect(admitted.map(\.row).max()! <= PaneBarTitleMetrics.rowBudget - Self.gateMargin,
                "the widest admitted row (\(admitted.map(\.row).max()!)pt) is flush against the \(PaneBarTitleMetrics.rowBudget)pt budget")
        #expect(refused.map(\.row).min()! >= PaneBarTitleMetrics.rowBudget + Self.gateMargin,
                "the narrowest refused row (\(refused.map(\.row).min()!)pt) is flush against the \(PaneBarTitleMetrics.rowBudget)pt budget")
        // The rows really are a point apart, which is what makes half a point the right margin.
        let distinct = Set(rows.map(\.row)).sorted()
        #expect(zip(distinct, distinct.dropFirst()).allSatisfy { $1 - $0 == 1 },
                "the producible rows are \(distinct) — no longer one point apart, so re-derive the margin instead of keeping \(Self.gateMargin)")
    }

    /// How far the budget must sit from the nearest row it decides about, in either direction.
    private static let gateMargin: CGFloat = 0.5

    /// `iconOnly` is a pin downward: no width and no text size ever produces a title.
    @Test(arguments: FontSize.selectablePercents)
    func iconOnlyNeverTitles(percent: Int) {
        #expect(Self.ladder(.iconOnly, scale: FontSize(percent: percent).scale).titledRungs == 0)
    }

    /// With titles declined, by the preference or by the gate, the ladder is the plain one: no rung
    /// taller than its own pill and no titled head. Asserted against the pill at every size, and a
    /// gated size must land on the same ladder as Icon Only.
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

    /// Titles go all together, ahead of the step down to `.mini`, as in `WorkspaceBarMetrics`: a bar
    /// mixing words and bare glyphs reads as two controls. Rung 0 and rung 1 carry an identical plan
    /// and differ only in being titled.
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

    /// The glyphs shrink on the rung after the untitled one, not on the same step as the titles.
    @Test func theSizeStepComesAfterTheTitleStep() {
        let bar = Self.ladder(.iconAndText)
        #expect(bar.controlSize(forRung: bar.titledRungs + 1) == .mini)
    }

    // MARK: - What the words say

    /// A title names the control; the glyph reports its state. Hidden Files' eye swaps open and
    /// slashed while its word holds.
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
        // No cancel handler: the rung stays a disabled Scan, so its word does too, not a "Stop"
        // that can't stop anything.
        #expect(ScanRungMode.resolve(isRefreshing: true, canCancel: false).barTitle == "Scan")
    }

    /// An item whose word can change is laid out at its widest word, so the bar can't reflow under
    /// the cursor. Both of Scan's words fit its pill today, so the item is pill-wide.
    @Test func aSwappingWordNeverChangesItsItemsWidth() {
        let pill = PaneNavMetrics.pill(.small)
        let reserved = PaneBarLayout.titledWidth(of: .scan, pill: pill, compactsViewMode: false, scale: 1)
        for word in PaneBarItem.scan.titleVariants {
            #expect(LabelMetrics.width(of: word, font: PaneBarTitleMetrics.font, scale: 1) <= reserved)
        }
        #expect(reserved == pill.width, "both of Scan's words fit its pill, so the item is pill-wide")
    }

    /// Every control has a word, or a new `PaneBarItem` would ship as a pill with a blank line under
    /// it, which no geometry assertion notices.
    @Test func everyControlHasAWordAndEverySpacerHasNone() {
        for item in PaneBarItem.allCases {
            if item.isSpacer {
                #expect(item.barTitle.isEmpty, "\(item.rawValue) is layout, not a control")
            } else {
                #expect(!item.barTitle.isEmpty, "\(item.rawValue) has no bar title")
            }
        }
    }

    /// The bar's word can be shorter than the menu's name: "Collapse Pane" is wider than the pill it
    /// would sit under.
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
        // The overflow costs exactly a pill and its gap, priced in both modes.
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
