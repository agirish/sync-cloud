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
/// arithmetic over published constants and run everywhere.
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

    /// **The decision this whole feature turns on.** A 10pt title sits below `FontSize.knee`, so it
    /// takes the full multiplier while `PaneNavMetrics.pill` — a fixed constant — does not. At Large
    /// the row wants 37pt and at Larger 38pt, against the 34pt the pinned 81pt header allows.
    ///
    /// Falling back to `iconOnly` is the deliberate answer, and the alternative is worth stating so
    /// nobody re-derives it: clamping the title so it never grows would give the person who chose
    /// Larger — because small text is hard for them to read — the one label in the app that refuses
    /// to. They get the bar that ships today instead.
    @Test(arguments: [(CGFloat(0.9), true), (CGFloat(1.0), true), (CGFloat(1.25), false), (CGFloat(1.35), false)])
    func titlesAreDrawnOnlyAtTextSizesWhoseRowFitsTheHeader(scale: CGFloat, expected: Bool) {
        let bar = Self.ladder(.iconAndText, scale: scale)
        let row = PaneBarTitleMetrics.rowHeight(pillHeight: PaneNavMetrics.pill(.small).height, scale: scale)
        #expect((bar.titledRungs == 1) == expected,
                "at scale \(scale) the titled row is \(row)pt against a \(PaneBarTitleMetrics.rowBudget)pt budget")
        if expected {
            #expect(bar.height(forRung: 0) <= PaneBarTitleMetrics.rowBudget)
        }
    }

    /// Both scales that *do* title must actually fit, and both that do not must actually overflow —
    /// the gate is only meaningful if its two sides are real. A gate whose "false" branch never
    /// triggers is a gate that has never been tested.
    @Test func theGateHasBothDirections() {
        let pill = PaneNavMetrics.pill(.small).height
        #expect(PaneBarTitleMetrics.rowFits(pillHeight: pill, scale: 1.0))
        #expect(!PaneBarTitleMetrics.rowFits(pillHeight: pill, scale: 1.25))
    }

    /// `iconOnly` is a pin downward: no width and no text size ever produces a title.
    @Test(arguments: [CGFloat(0.9), 1.0, 1.25, 1.35])
    func iconOnlyNeverTitles(scale: CGFloat) {
        #expect(Self.ladder(.iconOnly, scale: scale).titledRungs == 0)
    }

    /// With titles declined, the ladder is *exactly* the one that shipped before them — same rung
    /// count, same widths. This is what makes Icon Only and the large text sizes free of regression
    /// risk rather than merely believed to be.
    @Test func decliningTitlesRestoresTheOriginalLadder() {
        let titled = Self.ladder(.iconAndText, scale: 1.35)   // gate declines
        let plain = Self.ladder(.iconOnly, scale: 1.35)
        #expect(titled.terminal == plain.terminal)
        for rung in 0...plain.terminal {
            #expect(titled.width(forRung: rung) == plain.width(forRung: rung), "rung \(rung)")
            #expect(titled.height(forRung: rung) == plain.height(forRung: rung), "rung \(rung)")
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
        // The overflow contributes exactly a pill and its gap, titled or not.
        let plan = bar.plan(forRung: deep)
        let withOverflow = PaneBarLayout.width(of: plan, controlSize: bar.controlSize(forRung: deep))
        let itemsOnly = PaneBarLayout.width(
            of: PaneBarLayoutPlan(visible: plan.visible, overflow: [], compactsViewMode: plan.compactsViewMode),
            controlSize: bar.controlSize(forRung: deep))
        #expect(withOverflow - itemsOnly == pill.width + PaneNavMetrics.itemGap)
    }
}
