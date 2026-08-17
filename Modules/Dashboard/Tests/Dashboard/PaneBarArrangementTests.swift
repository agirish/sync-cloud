import SwiftUI
import Testing
@testable import Dashboard

/// The pane bar's model: what is on the bar, in what order, and what a narrow pane gives up first.
///
/// The view tests measure the rendered result; these pin the arithmetic behind it, because the
/// arrangement is *persisted* — a rule that changes here silently rewrites bars people arranged on a
/// previous build.
@Suite struct PaneBarArrangementTests {

    /// Every item a Compare pane in Columns mode can offer.
    private static let allAvailable: [PaneBarItem] =
        [.viewMode, .collapse, .backForward, .scan, .newFolder, .sort, .hiddenFiles, .preview,
         .search, .delete]

    // MARK: Persistence

    @Test func testTheDefaultIsTodaysBar() {
        // The load-bearing one. An untouched install must render exactly what it rendered before the
        // bar became arrangeable: a flexible space (what used to be the trailing-edge Spacer) and
        // then the nine controls in their historical order — followed by Search, and now by Delete
        // ahead of it, since the shedding order runs right-to-left and Search is the one control
        // here with a keyboard equivalent on every surface.
        //
        // Restated literally rather than read off `PaneBarArrangement.default`, deliberately: this is
        // the assertion that makes changing the shipped bar a decision someone has to write down.
        // Delete arriving here is that decision — a header only draws it if the host passes a
        // delete handler, which no test fixture and no non-app caller does.
        #expect(PaneBarArrangement.default.items == [
            .flexibleSpace, .viewMode, .collapse, .backForward, .scan, .newFolder, .sort, .hiddenFiles,
            .preview, .delete, .search
        ])
    }

    @Test func testEncodingRoundTrips() {
        let arrangement = PaneBarArrangement([.backForward, .scan, .flexibleSpace, .sort])
        #expect(PaneBarArrangement(encoded: arrangement.encoded) == arrangement)
    }

    @Test func testUnknownTokensAreDroppedNotRejected() {
        // A bar arranged on a newer build, opened on an older one: the item it doesn't know about
        // disappears, the rest survives. Resetting to the default here would throw away an
        // arrangement over one unrecognized word.
        let parsed = PaneBarArrangement(encoded: "backForward,teleport,scan,sort")
        #expect(parsed.items == [.backForward, .scan, .sort])
    }

    @Test func testEmptyStringIsAnEmptyBarNotTheDefault() {
        // Removing everything is a legitimate arrangement, and must not spring back to the default —
        // only `scan` returns, because it is not removable.
        #expect(PaneBarArrangement(encoded: "").items == [.scan])
    }

    @Test func testDuplicateControlsCollapseButSpacersRepeat() {
        let parsed = PaneBarArrangement(encoded: "sort,space,sort,space,flexibleSpace,scan")
        #expect(parsed.items == [.sort, .space, .space, .flexibleSpace, .scan])
    }

    @Test func testScanIsRestoredWhenAStoredArrangementLacksIt() {
        // Not reachable through the sheet — this is the hand-edited-plist case. A pane that cannot be
        // scanned is broken rather than customized.
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
        // The rule that replaces the old hard-coded "sort and hidden files first". Here the user put
        // Sort last, so Sort is what a cramped pane gives up first — the arrangement IS the priority
        // list, and nobody had to be told that.
        let arrangement = PaneBarArrangement([.flexibleSpace, .backForward, .scan, .hiddenFiles, .sort])
        let plan = PaneBarLayout.plan(arrangement: arrangement, available: Self.allAvailable, depth: 1)
        #expect(plan.visible == [.flexibleSpace, .backForward, .scan, .hiddenFiles])
        // Folded items lead the menu, ahead of the ones that were never on the bar — what just
        // disappeared should be the first thing you find when you go looking for it.
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
        // What a 250pt comparison pane showed before this change: the view switch as one pill, back,
        // forward, scan, and ⋯. If this set grows, the bar's minimum width grows with it, the
        // provider capsule gets less room, and the 250pt snapshots move.
        let comparisonPane: [PaneBarItem] = [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles, .preview]
        let plan = PaneBarLayout.plan(arrangement: .default, available: comparisonPane, depth: .max)
        #expect(plan.visible == [.flexibleSpace, .viewMode, .backForward, .scan])
        #expect(plan.compactsViewMode)
    }

    @Test func testPlanIsIdempotentPastMaxDepth() {
        // The header declares a fixed number of `ViewThatFits` rungs, so the surplus ones have to be
        // harmless duplicates rather than progressively emptier bars.
        let available = Self.allAvailable
        let maxDepth = PaneBarLayout.maxDepth(arrangement: .default, available: available)
        let atMax = PaneBarLayout.plan(arrangement: .default, available: available, depth: maxDepth)
        for beyond in [maxDepth + 1, maxDepth + 5, Int.max] {
            #expect(PaneBarLayout.plan(arrangement: .default, available: available, depth: beyond) == atMax)
        }
    }

    // MARK: What the host cannot offer, and what it doesn't know about yet

    @Test func testItemsTheHostCannotOfferAreNotDrawnAndNotInTheMenu() {
        // The single-source rail has no Columns mode, so no preview to toggle; a comparison pane doesn't
        // collapse individually. Neither should leave a dead entry in ⋯.
        let railish: [PaneBarItem] = [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles]
        let plan = PaneBarLayout.plan(arrangement: .default, available: railish, depth: 0)
        #expect(!plan.visible.contains(.preview))
        #expect(!plan.overflow.contains(.preview))
        #expect(!plan.visible.contains(.collapse))
        #expect(!plan.overflow.contains(.collapse))
    }

    /// **A control you took off the bar is off the bar.** ⋯ used to append every available control
    /// the arrangement did not place, on the principle that a removal should cost a pill and never
    /// an ability — which meant the customize sheet could not actually remove anything, only demote
    /// it into a menu. Removing is now removing; the sheet's palette is where you get one back.
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

    /// The other half of the same rule, and the one with a cost worth restating: a control that
    /// ships in a later release is absent from every stored arrangement, and no longer lands in ⋯ as
    /// a consolation. `PaneBarMigration` is what puts it on the bar — this test is what fails if
    /// anyone assumes the old fallback is still there. `preview` stands in for "the next one we
    /// add", as an arrangement saved before it existed.
    @Test func testAControlAddedInALaterReleaseLandsNowhereWithoutAMigration() {
        let savedBeforePreviewExisted = PaneBarArrangement(
            encoded: "flexibleSpace,viewMode,backForward,scan,sort,hiddenFiles")
        let plan = PaneBarLayout.plan(arrangement: savedBeforePreviewExisted,
                                      available: Self.allAvailable, depth: 0)
        #expect(!plan.visible.contains(.preview), "a new control rearranged a bar the user had chosen")
        #expect(!plan.overflow.contains(.preview),
                "a new control still falls back into ⋯ — the fallback that hid Search is back")
    }

    /// Folding still fills ⋯, in the bar's own order: it is the *shed* items, and the ladder sheds
    /// right to left, so what comes back reads the way the bar did.
    @Test func testTheOverflowListsFoldedControlsInBarOrder() {
        let arrangement = PaneBarArrangement([.flexibleSpace, .viewMode, .backForward, .scan,
                                              .sort, .hiddenFiles, .preview])
        let plan = PaneBarLayout.plan(arrangement: arrangement, available: Self.allAvailable, depth: 2)
        #expect(plan.overflow == [.hiddenFiles, .preview],
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
