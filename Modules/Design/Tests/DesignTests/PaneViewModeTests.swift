import Testing
import SwiftUI
@testable import Design

/// `PaneViewMode` carries three decisions that are easy to regress silently: Columns is the
/// default, the two panes store independently, and the resize drag clamps rather than letting a
/// column shrink past the point where a row stops carrying its difference badge.
@Suite struct PaneViewModeTests {

    /// A throwaway defaults domain, so these never touch the user's real preferences — the app is
    /// routinely running while the tests are. `ScratchDefaults` rather than a bare
    /// `UserDefaults(suiteName:)`: it wipes domain *and* plist on deinit, which is what stopped
    /// these suites accumulating tens of thousands of files in `~/Library/Preferences`.
    private func defaults() -> ScratchDefaults {
        ScratchDefaults("PaneViewModeTests")
    }

    @Test func testColumnsIsTheDefault() {
        #expect(PaneViewMode.default == .columns)
        #expect(PaneViewMode.stored(isLeft: true, in: defaults()) == .columns)
        #expect(PaneViewMode.stored(isLeft: false, in: defaults()) == .columns)
    }

    /// Per-pane by decision: one side can be a deep tree while the other is flat.
    @Test func testEachPaneStoresItsOwnMode() {
        let d = defaults()
        d.set(PaneViewMode.tree.rawValue, forKey: PaneViewMode.defaultsKey(isLeft: true))

        #expect(PaneViewMode.stored(isLeft: true, in: d) == .tree)
        #expect(PaneViewMode.stored(isLeft: false, in: d) == .columns, "the sibling pane is unaffected")
        #expect(PaneViewMode.defaultsKey(isLeft: true) != PaneViewMode.defaultsKey(isLeft: false))
    }

    /// A value written by a newer build (or corrupted) must fall back rather than crash or render
    /// an empty pane.
    @Test func testUnrecognisedValueFallsBackToTheDefault() {
        let d = defaults()
        d.set("gallery", forKey: PaneViewMode.defaultsKey(isLeft: true))
        #expect(PaneViewMode.stored(isLeft: true, in: d) == .columns)
    }

    /// The single-source rail stores separately from both comparison panes. It shares the LEFT pane's
    /// underlying state (focus, selection, history, browse path), so reading its presentation from
    /// the left key would be the easy mistake — and would mean choosing Tree for a comparison
    /// silently un-stacked the rail, and vice versa.
    @Test func testTheRailStoresApartFromBothPanes() {
        #expect(PaneViewMode.railDefaultsKey != PaneViewMode.defaultsKey(isLeft: true))
        #expect(PaneViewMode.railDefaultsKey != PaneViewMode.defaultsKey(isLeft: false))

        let d = defaults()
        d.set(PaneViewMode.tree.rawValue, forKey: PaneViewMode.railDefaultsKey)
        #expect(PaneViewMode.stored(isLeft: true, in: d) == .columns, "the left pane is unaffected")
        #expect(PaneViewMode.stored(isLeft: false, in: d) == .columns, "the right pane is unaffected")

        // …and the reverse: a comparison pane's choice must not reach the rail's key.
        let e = defaults()
        e.set(PaneViewMode.tree.rawValue, forKey: PaneViewMode.defaultsKey(isLeft: true))
        #expect(e.string(forKey: PaneViewMode.railDefaultsKey) == nil)
    }

    // MARK: - Layout rules

    /// The clamp exists so a row never loses its difference badge; assert the boundary itself,
    /// not just that some clamping happens.
    @Test func testColumnWidthClampsToTheLegibleRange() {
        #expect(PaneViewMode.clampColumnWidth(10) == PaneViewMode.minimumColumnWidth)
        #expect(PaneViewMode.clampColumnWidth(9_999) == PaneViewMode.maximumColumnWidth)
        #expect(PaneViewMode.clampColumnWidth(210) == 210)
        #expect(PaneViewMode.minimumColumnWidth == 140)
        #expect(PaneViewMode.defaultColumnWidth == 210)
    }

    /// Push navigation starts where a second column stops fitting — pinned against the minimum
    /// width it is derived from, so changing one without the other is caught.
    @Test func testPushNavigationThresholdIsTwoMinimumColumns() {
        #expect(PaneViewMode.pushNavigationBelowWidth == PaneViewMode.minimumColumnWidth * 2)

        // The 250pt pane floor is below the threshold, so the narrowest pane always pushes.
        #expect(PaneViewMode.usesPushNavigation(paneWidth: 250))
        #expect(PaneViewMode.usesPushNavigation(paneWidth: 279))
        #expect(PaneViewMode.usesPushNavigation(paneWidth: 280) == false)
        #expect(PaneViewMode.usesPushNavigation(paneWidth: 660) == false)
    }

    /// The drag regression: translation is cumulative, so the anchor must stay the width the drag
    /// STARTED at. Walking a drag frame by frame is the only way to catch a moving anchor — a
    /// single call looks correct either way.
    @Test func testDragWidthTracksTranslationFromAFixedAnchor() {
        let anchor: CGFloat = 210
        #expect(PaneViewMode.draggedColumnWidth(anchor: anchor, translation: 10) == 220)
        #expect(PaneViewMode.draggedColumnWidth(anchor: anchor, translation: 20) == 230)
        #expect(PaneViewMode.draggedColumnWidth(anchor: anchor, translation: 30) == 240)
        // Dragging back past the start shrinks by the same amount it grew.
        #expect(PaneViewMode.draggedColumnWidth(anchor: anchor, translation: -10) == 200)
        #expect(PaneViewMode.draggedColumnWidth(anchor: anchor, translation: 0) == anchor)
        // Still clamped at both ends.
        #expect(PaneViewMode.draggedColumnWidth(anchor: anchor, translation: 9_999) == PaneViewMode.maximumColumnWidth)
        #expect(PaneViewMode.draggedColumnWidth(anchor: anchor, translation: -9_999) == PaneViewMode.minimumColumnWidth)
    }

    /// ⌘ and ⇧ clicks belong to the list, not to navigation — otherwise every multi-selection
    /// collapses to the row just clicked and the action bar can never act on more than one item.
    @Test func testOnlyPlainClicksNavigate() {
        #expect(PaneViewMode.clickNavigates(modifiers: []))
        #expect(PaneViewMode.clickNavigates(modifiers: [.option]))
        #expect(PaneViewMode.clickNavigates(modifiers: [.command]) == false)
        #expect(PaneViewMode.clickNavigates(modifiers: [.shift]) == false)
        #expect(PaneViewMode.clickNavigates(modifiers: [.command, .shift]) == false)
    }

    /// ⌃ is the secondary click, and it reaches a primary-button recognizer because macOS delivers
    /// it as a button-1 event carrying `.control`. It used to be admitted here, so control-clicking
    /// a column's empty space opened the context menu AND — in the same gesture — cleared both
    /// panes' selections and closed every column to the right of the one clicked in.
    @Test func testControlClickIsTheSecondaryClickAndNeverNavigates() {
        #expect(PaneViewMode.clickNavigates(modifiers: [.control]) == false)
        #expect(PaneViewMode.clickNavigates(modifiers: [.control, .option]) == false)
    }

    // MARK: - Column-width floor lift

    /// The repair: an install left pinned at the floor by the preview's old sizing rule comes back
    /// to the default.
    @Test func testAFlooredColumnWidthIsLiftedToTheDefault() {
        let d = defaults()
        d.set(Double(PaneViewMode.minimumColumnWidth), forKey: PaneViewMode.columnWidthDefaultsKey)
        PaneViewMode.liftColumnWidthOffTheFloor(d)
        #expect(d.double(forKey: PaneViewMode.columnWidthDefaultsKey) == Double(PaneViewMode.defaultColumnWidth))
    }

    /// Once only. Someone who genuinely wants the minimum and drags back to it must keep it — a
    /// repair that re-fires every launch is a preference the user cannot express.
    @Test func testTheLiftNeverFiresTwice() {
        let d = defaults()
        d.set(Double(PaneViewMode.minimumColumnWidth), forKey: PaneViewMode.columnWidthDefaultsKey)
        PaneViewMode.liftColumnWidthOffTheFloor(d)
        d.set(Double(PaneViewMode.minimumColumnWidth), forKey: PaneViewMode.columnWidthDefaultsKey)
        PaneViewMode.liftColumnWidthOffTheFloor(d)
        #expect(d.double(forKey: PaneViewMode.columnWidthDefaultsKey) == Double(PaneViewMode.minimumColumnWidth))
    }

    /// Only a width sitting exactly at the floor is touched. A deliberate 141 — or any other width a
    /// user chose — is left exactly as it is.
    @Test func testTheLiftLeavesEveryDeliberateWidthAlone() {
        let d = defaults()
        d.set(Double(PaneViewMode.minimumColumnWidth + 1), forKey: PaneViewMode.columnWidthDefaultsKey)
        PaneViewMode.liftColumnWidthOffTheFloor(d)
        #expect(d.double(forKey: PaneViewMode.columnWidthDefaultsKey) == Double(PaneViewMode.minimumColumnWidth + 1))
    }

    /// An install that never set a width has nothing to repair, and must not be given an explicit
    /// one — that would freeze today's default into a stored value for good.
    @Test func testTheLiftLeavesAnUnsetWidthUnset() {
        let d = defaults()
        PaneViewMode.liftColumnWidthOffTheFloor(d)
        #expect(d.object(forKey: PaneViewMode.columnWidthDefaultsKey) == nil)
    }

    // MARK: - Trailing deselect filler

    /// The load-bearing case. An overflowing stack must get a filler of exactly zero: the column
    /// stack's scroll behaviour was tuned across four commits (`63bb6cf` … `a89aa40`) against a
    /// stack that genuinely overflows, and padding its content in that state would move the very
    /// condition those fixes — and their mounted test — depend on.
    @Test func testAnOverflowingStackGetsNoFiller() {
        let width = PaneViewMode.trailingFillerWidth(
            paneWidth: 500, columnWidths: Array(repeating: 210, count: 3))
        #expect(width == 0)
    }

    /// Exactly-full is the boundary of the same rule, and the one an off-by-one would land on.
    @Test func testAnExactlyFullStackGetsNoFiller() {
        let width = PaneViewMode.trailingFillerWidth(
            paneWidth: 630, columnWidths: Array(repeating: 210, count: 3))
        #expect(width == 0)
    }

    /// Under-filled: the filler takes the slack that already existed and nothing more.
    @Test func testAnUnderFilledStackFillsTheRemainder() {
        let width = PaneViewMode.trailingFillerWidth(
            paneWidth: 900, columnWidths: Array(repeating: 210, count: 2))
        #expect(width == 480)
    }

    /// A resting pane's one column keeps its own width, so the slack after it — most of the pane —
    /// is the filler's. It used to span the pane and get none.
    @Test func testARestingColumnLeavesTheRestToTheFiller() {
        let width = PaneViewMode.trailingFillerWidth(
            paneWidth: 900, columnWidths: Array(repeating: 210, count: 1))
        #expect(width == 690)
    }

    /// Push mode renders exactly one column at any depth, framed to the whole viewport, so there is
    /// no slack to fill — the general rule, with no case of its own.
    @Test func testPushModeGetsNoFiller() {
        let paneWidth = PaneViewMode.pushNavigationBelowWidth - 1
        #expect(PaneViewMode.usesPushNavigation(paneWidth: paneWidth))
        let width = PaneViewMode.trailingFillerWidth(paneWidth: paneWidth, columnWidths: [paneWidth])
        #expect(width == 0)
    }

    @Test func testEveryModeHasDistinctChrome() {
        let symbols = Set(PaneViewMode.allCases.map(\.symbol))
        #expect(symbols.count == PaneViewMode.allCases.count)
        #expect(PaneViewMode.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.help.isEmpty })
    }

    /// The raw values are a wire format: three defaults keys store them. Every prior test here
    /// wrote `.tree.rawValue` and read it back — a round trip that passes across any rename while
    /// the rename silently restacks every user's panes. The literals are the pin.
    @Test func testRawValuesAreStableAndAnUnknownStoredValueFallsBack() {
        #expect(PaneViewMode.tree.rawValue == "tree")
        #expect(PaneViewMode.columns.rawValue == "columns")
        #expect(PaneViewMode.allCases == [.tree, .columns])

        // The documented fallback in `stored(isLeft:in:)`. The absent and foreign-word halves were
        // already pinned (`testColumnsIsTheDefault`, `testUnrecognisedValueFallsBackToTheDefault`);
        // the case-NEAR-MISS is what this adds — "Tree" for "tree" is the shape a hand-edited
        // plist or a case-renamed enum actually produces, and neither older test probes it.
        let defaults = ScratchDefaults("PaneViewModeRawValues")
        #expect(PaneViewMode.stored(isLeft: true, in: defaults) == .default)
        defaults.set("Tree", forKey: PaneViewMode.defaultsKey(isLeft: true))
        #expect(PaneViewMode.stored(isLeft: true, in: defaults) == .default,
                "a case-near-miss must fall back, not match")
        defaults.set("tree", forKey: PaneViewMode.defaultsKey(isLeft: true))
        #expect(PaneViewMode.stored(isLeft: true, in: defaults) == .tree)
    }
}
