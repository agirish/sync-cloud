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
        // The Tidy rail has no Columns mode, so no preview to toggle; a comparison pane doesn't
        // collapse individually. Neither should leave a dead entry in ⋯.
        let railish: [PaneBarItem] = [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles]
        let plan = PaneBarLayout.plan(arrangement: .default, available: railish, depth: 0)
        #expect(!plan.visible.contains(.preview))
        #expect(!plan.overflow.contains(.preview))
        #expect(!plan.visible.contains(.collapse))
        #expect(!plan.overflow.contains(.collapse))
    }

    @Test func testARemovedControlStaysReachableInTheOverflow() {
        let arrangement = PaneBarArrangement([.flexibleSpace, .backForward, .scan])
        let plan = PaneBarLayout.plan(arrangement: arrangement, available: Self.allAvailable, depth: 0)
        #expect(plan.overflow.contains(.sort))
        #expect(plan.overflow.contains(.hiddenFiles))
        #expect(plan.overflow.contains(.newFolder))
    }

    @Test func testTheOverflowListsRemovedControlsInCanonicalOrder() {
        // These become menu items. `available` is assembled by each host in whatever order its
        // optional callbacks happen to be checked in, and passing that order through produced a menu
        // reading Back/Forward, Sort, Hidden Files, View — an order nobody can learn, and one that
        // would reshuffle itself the day a host gains another optional callback.
        let shuffled: [PaneBarItem] = [.hiddenFiles, .preview, .backForward, .viewMode, .sort, .newFolder, .scan]
        let plan = PaneBarLayout.plan(arrangement: PaneBarArrangement([.flexibleSpace, .scan]),
                                      available: shuffled, depth: 0)
        let canonical = PaneBarItem.allCases.filter { shuffled.contains($0) && $0 != .scan }
        #expect(plan.overflow == canonical, "the overflow menu follows the host's order, not the bar's")
    }

    @Test func testAControlAddedInALaterReleaseLandsInTheOverflowNotOnTheBar() {
        // The decided rule, and it falls out of the model: a stored arrangement predates the new
        // control, so the control is absent, so it arrives in ⋯ rather than rearranging a bar
        // somebody chose. `preview` stands in for "the next one we add" — an arrangement saved
        // before it existed.
        let savedBeforePreviewExisted = PaneBarArrangement(
            encoded: "flexibleSpace,viewMode,backForward,scan,sort,hiddenFiles")
        let plan = PaneBarLayout.plan(arrangement: savedBeforePreviewExisted,
                                      available: Self.allAvailable, depth: 0)
        #expect(!plan.visible.contains(.preview), "a new control rearranged a bar the user had chosen")
        #expect(plan.overflow.contains(.preview), "a new control went missing instead of landing in ⋯")
    }

    // MARK: Icon size

    @Test func testIconSizeIsACeilingNotAPin() {
        #expect(PaneBarIconSize.regular.ceiling == .small)
        #expect(PaneBarIconSize.small.ceiling == .mini)
        #expect(PaneBarIconSize(rawValue: "nonsense") == nil,
                "an unreadable stored value must fall back at the call site, not decode to something")
    }
}
