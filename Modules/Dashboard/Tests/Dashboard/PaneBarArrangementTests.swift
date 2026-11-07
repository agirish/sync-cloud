import SwiftUI
import Testing
@testable import Dashboard

/// The pane bar's model: what is on the bar, in what order, and what a narrow pane gives up first.
/// The view tests measure the rendered result; these pin the arithmetic behind it, because the
/// arrangement is persisted and a rule changed here silently rewrites bars people already arranged.
@Suite struct PaneBarArrangementTests {

    /// Every item a Compare pane in Columns mode can offer.
    private static let allAvailable: [PaneBarItem] =
        [.viewMode, .collapse, .backForward, .scan, .newFolder, .sort, .hiddenFiles,
         .search, .delete, .typeFilter]

    // MARK: Persistence

    @Test func testTheDefaultIsTodaysBar() {
        // The shipped bar, restated literally rather than read off `PaneBarArrangement.default`,
        // so changing it is a decision someone has to write down. Search sits at the trailing end,
        // the first thing the ladder sheds, since it has a keyboard equivalent on every surface;
        // Filter by Type and Delete sit just before it. A header draws Delete only when the host
        // passes a delete handler. No leading `flexibleSpace`: the bar starts where the breadcrumb
        // below it starts. No Preview: the preview lives in the Info inspector.
        #expect(PaneBarArrangement.default.items == [
            .viewMode, .collapse, .backForward, .scan, .newFolder, .sort, .hiddenFiles,
            .delete, .typeFilter, .search
        ])
        #expect(PaneBarArrangement.default.items.last == .search,
                "Search left the trailing end, so the ladder no longer gives it up first, though it is the one control here with a keyboard equivalent")
    }

    /// A stored bar that still lists the retired `preview` draws everything else. The token rides
    /// through `encoded`, so the sheet's write-back doesn't take it from a maintenance-line build
    /// reading the same defaults.
    @Test func testAStoredRetiredPreviewIsCarriedButNotDrawn() {
        let stored = PaneBarArrangement(encoded: "viewMode,backForward,scan,preview,sort")
        #expect(stored.items == [.viewMode, .backForward, .scan, .sort])
        #expect(stored.encoded == "viewMode,backForward,scan,sort,preview")
        let plan = PaneBarLayout.plan(arrangement: stored, available: Self.allAvailable, depth: 0)
        #expect(plan.visible == [.viewMode, .backForward, .scan, .sort])
        #expect(plan.overflow.isEmpty)
    }

    @Test func testEncodingRoundTrips() {
        let arrangement = PaneBarArrangement([.backForward, .scan, .flexibleSpace, .sort])
        #expect(PaneBarArrangement(encoded: arrangement.encoded) == arrangement)
    }

    @Test func testEmptyStringIsAnEmptyBarNotTheDefault() {
        // Removing everything is a legitimate arrangement and must not spring back to the default.
        // Only `scan` returns, because it can't be removed.
        #expect(PaneBarArrangement(encoded: "").items == [.scan])
    }

    @Test func testDuplicateControlsCollapseButSpacersRepeat() {
        let parsed = PaneBarArrangement(encoded: "sort,space,sort,space,flexibleSpace,scan")
        #expect(parsed.items == [.sort, .space, .space, .flexibleSpace, .scan])
    }

    @Test func testScanIsRestoredWhenAStoredArrangementLacksIt() {
        // The hand-edited-plist case; the sheet can't reach it. A pane that can't be scanned is
        // broken, not customized.
        #expect(PaneBarArrangement(encoded: "backForward,sort").items.contains(.scan))
    }

    @Test func testAnOverlongArrangementIsCapped() {
        let tooMany = Array(repeating: PaneBarItem.space, count: 40)
        let arrangement = PaneBarArrangement(tooMany)
        #expect(arrangement.items.count == PaneBarArrangement.maxItems)
        // …and the cap never costs the one item that cannot be dropped.
        #expect(arrangement.items.contains(.scan))
    }

    // MARK: Editing

    @Test func testInsertingAnItemAlreadyOnTheBarMovesItRatherThanDuplicating() {
        var arrangement = PaneBarArrangement([.backForward, .scan, .sort])
        arrangement.insert(.sort, at: 0)
        #expect(arrangement.items == [.sort, .backForward, .scan])
    }

    @Test func testSpacersDuplicateFreelyOnInsert() {
        var arrangement = PaneBarArrangement([.scan, .flexibleSpace])
        arrangement.insert(.flexibleSpace, at: 0)
        #expect(arrangement.items == [.flexibleSpace, .scan, .flexibleSpace])
    }

    @Test func testScanCannotBeRemoved() {
        var arrangement = PaneBarArrangement([.backForward, .scan])
        arrangement.remove(at: 1)
        #expect(arrangement.items == [.backForward, .scan])
        #expect(!arrangement.canRemove(1))
    }

    @Test func testMoveUsesPreMoveIndices() {
        var arrangement = PaneBarArrangement([.backForward, .scan, .sort, .hiddenFiles])
        // Drop `hiddenFiles` (index 3) into the slot before `scan` (slot 1).
        arrangement.move(from: 3, to: 1)
        #expect(arrangement.items == [.backForward, .hiddenFiles, .scan, .sort])
    }

    @Test func testMoveToItsOwnSlotsIsANoOp() {
        let original = PaneBarArrangement([.backForward, .scan, .sort])
        for destination in [1, 2] {
            var arrangement = original
            arrangement.move(from: 1, to: destination)
            #expect(arrangement == original, "moving index 1 to slot \(destination) should change nothing")
        }
    }

    @Test func testNudgeSwapsAndStopsAtTheEnds() {
        var arrangement = PaneBarArrangement([.backForward, .scan, .sort])
        arrangement.nudge(0, by: -1)
        #expect(arrangement.items == [.backForward, .scan, .sort], "nudging off the leading edge moved something")
        arrangement.nudge(2, by: 1)
        #expect(arrangement.items == [.backForward, .scan, .sort], "nudging off the trailing edge moved something")
        arrangement.nudge(2, by: -1)
        #expect(arrangement.items == [.backForward, .sort, .scan])
    }

    // MARK: What the ladder sheds

    @Test func testDepthZeroShowsEverythingAndOffersNoOverflow() {
        let plan = PaneBarLayout.plan(arrangement: .default, available: Self.allAvailable, depth: 0)
        #expect(plan.visible == PaneBarArrangement.default.items)
        #expect(plan.overflow.isEmpty)
        #expect(!plan.compactsViewMode)
    }

    @Test func testFoldingFollowsTheUsersOwnOrderFromTheRight() {
        // The arrangement is the priority list: the user put Sort last, so Sort is what a cramped
        // pane gives up first.
        let arrangement = PaneBarArrangement([.flexibleSpace, .backForward, .scan, .hiddenFiles, .sort])
        let plan = PaneBarLayout.plan(arrangement: arrangement, available: Self.allAvailable, depth: 1)
        #expect(plan.visible == [.flexibleSpace, .backForward, .scan, .hiddenFiles])
        // What just folded goes into ⋯, where you look for it.
        #expect(plan.overflow.first == .sort)
    }

    @Test func testFixedSpacesAreGivenUpBeforeAnyControl() {
        // Air costs nothing to lose and everything to keep when the pane is out of room.
        let arrangement = PaneBarArrangement([.backForward, .space, .scan, .sort])
        let unfolded = PaneBarLayout.plan(arrangement: arrangement, available: Self.allAvailable, depth: 0)
        let plan = PaneBarLayout.plan(arrangement: arrangement, available: Self.allAvailable, depth: 1)
        #expect(plan.visible == [.backForward, .scan, .sort], "the first rung gave up a control, not the air")
        #expect(plan.overflow == unfolded.overflow,
                "a shed space is layout, not an ability — it must add no menu entry")
    }

    @Test func testFlexibleSpacesSurviveEveryRung() {
        let arrangement = PaneBarArrangement([.flexibleSpace, .backForward, .scan, .sort, .hiddenFiles])
        let plan = PaneBarLayout.plan(arrangement: arrangement, available: Self.allAvailable, depth: .max)
        #expect(plan.visible.contains(.flexibleSpace),
                "dropping the flexible space would slide the whole bar sideways at the worst moment")
    }

    @Test func testTheFloorKeepsNavigationAndScanAtAnyDepth() {
        let plan = PaneBarLayout.plan(arrangement: .default, available: Self.allAvailable, depth: .max)
        #expect(plan.visible.contains(.scan))
        #expect(plan.visible.contains(.backForward))
        #expect(!plan.overflow.contains(.scan))
        #expect(!plan.overflow.contains(.backForward))
    }

    @Test func testTheViewSwitchCompactsOnlyAtTheLastRung() {
        let available = Self.allAvailable
        let maxDepth = PaneBarLayout.maxDepth(arrangement: .default, available: available)
        let penultimate = PaneBarLayout.plan(arrangement: .default, available: available, depth: maxDepth - 1)
        let last = PaneBarLayout.plan(arrangement: .default, available: available, depth: maxDepth)
        #expect(!penultimate.compactsViewMode)
        #expect(last.compactsViewMode)
        // Compacting is not folding: the switch is still on the bar, as one pill instead of two.
        #expect(last.visible.contains(.viewMode))
        #expect(!last.overflow.contains(.viewMode))
    }

    @Test func testTheDeepestRungIsTodaysNarrowBar() {
        // A 250pt comparison pane shows the view switch as one pill, back, forward, scan and ⋯. If
        // this set grows, the bar's minimum width grows and the 250pt golden in
        // `PaneBarLadderTests` moves.
        let comparisonPane: [PaneBarItem] = [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles]
        let plan = PaneBarLayout.plan(arrangement: .default, available: comparisonPane, depth: .max)
        #expect(plan.visible == [.viewMode, .backForward, .scan])
        #expect(plan.compactsViewMode)
    }

    @Test func testPlanIsIdempotentPastMaxDepth() {
        // The header declares a fixed number of `ViewThatFits` rungs, so surplus ones must be
        // harmless duplicates, not ever emptier bars.
        let available = Self.allAvailable
        let maxDepth = PaneBarLayout.maxDepth(arrangement: .default, available: available)
        let atMax = PaneBarLayout.plan(arrangement: .default, available: available, depth: maxDepth)
        for beyond in [maxDepth + 1, maxDepth + 5, Int.max] {
            #expect(PaneBarLayout.plan(arrangement: .default, available: available, depth: beyond) == atMax)
        }
    }

    // MARK: What the host cannot offer, and what it doesn't know about yet

    @Test func testItemsTheHostCannotOfferAreNotDrawnAndNotInTheMenu() {
        // A comparison pane doesn't collapse individually, so it should leave no dead entry in ⋯.
        let railish: [PaneBarItem] = [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles]
        let plan = PaneBarLayout.plan(arrangement: .default, available: railish, depth: 0)
        #expect(!plan.visible.contains(.collapse))
        #expect(!plan.overflow.contains(.collapse))
    }

    /// A control you took off the bar is off the bar: ⋯ doesn't hand it back, or the customize
    /// sheet could only demote controls into a menu. The sheet's palette is where you get one back.
    @Test func testARemovedControlIsNotHandedBackInTheOverflow() {
        let arrangement = PaneBarArrangement([.flexibleSpace, .backForward, .scan])
        let plan = PaneBarLayout.plan(arrangement: arrangement, available: Self.allAvailable, depth: 0)
        #expect(plan.overflow.isEmpty,
                "⋯ offered \(plan.overflow) on a bar that is not folding anything — these were removed on purpose")
        // The bar itself is untouched by the change: what was placed is still drawn.
        #expect(plan.visible == [.flexibleSpace, .backForward, .scan])
        // …and every removed control is still recoverable, from the one place that should offer it.
        for item in [PaneBarItem.sort, .hiddenFiles, .newFolder] {
            #expect(PaneBarCustomizeSheet.palette.contains(item),
                    "\(item) can be removed from the bar and never put back")
        }
    }

    /// The cost of the same rule: a control shipped later is absent from every stored arrangement
    /// and doesn't land in ⋯ either. Only `PaneBarMigration` puts it on the bar. `delete`, which
    /// declines a migration step, stands in for the next new control, on a bar saved before it.
    @Test func testAControlAddedInALaterReleaseLandsNowhereWithoutAMigration() {
        let savedBeforeDeleteExisted = PaneBarArrangement(
            encoded: "flexibleSpace,viewMode,backForward,scan,sort,hiddenFiles")
        let plan = PaneBarLayout.plan(arrangement: savedBeforeDeleteExisted,
                                      available: Self.allAvailable, depth: 0)
        #expect(!plan.visible.contains(.delete), "a new control rearranged a bar the user had chosen")
        #expect(!plan.overflow.contains(.delete),
                "a new control still falls back into ⋯ — the fallback that hid Search is back")
    }

    /// ⋯ lists the folded controls in the bar's own order, so it reads the way the bar did even
    /// though the ladder sheds right to left.
    @Test func testTheOverflowListsFoldedControlsInBarOrder() {
        let arrangement = PaneBarArrangement([.flexibleSpace, .viewMode, .backForward, .scan,
                                              .sort, .hiddenFiles, .newFolder])
        let plan = PaneBarLayout.plan(arrangement: arrangement, available: Self.allAvailable, depth: 2)
        #expect(plan.overflow == [.hiddenFiles, .newFolder],
                "⋯ listed \(plan.overflow) — the two right-most sheddable controls, in bar order")
    }

    // MARK: Icon size

    @Test func testIconSizeIsACeilingNotAPin() {
        #expect(PaneBarIconSize.regular.ceiling == .small)
        #expect(PaneBarIconSize.small.ceiling == .mini)
        #expect(PaneBarIconSize(rawValue: "nonsense") == nil,
                "an unreadable stored value must fall back at the call site, not decode to something")
    }
}
