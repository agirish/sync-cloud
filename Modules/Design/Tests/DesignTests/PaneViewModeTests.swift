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

    // MARK: - Preview toggle

    /// **Browse's preview is not Compare's.** Turning the preview off to compare two providers —
    /// where it costs the columns doing the comparing half the room — must not take it away from
    /// Browse, where reading a file IS the task.
    ///
    /// The distinctness assertion is the load-bearing one, and it is not a tautology about two
    /// literals: `ContentView` declares both of its `@AppStorage` properties through this function,
    /// so if the two arms ever returned the same string the two properties would silently become one
    /// value again and the split would be gone with nothing else to notice.
    @Test func testBrowseStoresItsPreviewApartFromEverySurface() {
        #expect(PaneViewMode.previewColumnKey(isBrowse: true)
                != PaneViewMode.previewColumnKey(isBrowse: false))

        // Compare, the Organize rail and Storage deliberately share one answer — the two comparison
        // panes are read against each other, exactly as they share `columnWidthDefaultsKey`.
        #expect(PaneViewMode.previewColumnKey(isBrowse: false) == PaneViewMode.previewColumnDefaultsKey)
        #expect(PaneViewMode.previewColumnKey(isBrowse: true) == PaneViewMode.browsePreviewColumnDefaultsKey)

        // Both are a persistence format, so they are pinned as strings rather than only against each
        // other: renaming one silently resets everyone who had turned the preview off.
        #expect(PaneViewMode.previewColumnDefaultsKey == "paneColumnShowsPreview")
        #expect(PaneViewMode.browsePreviewColumnDefaultsKey == "paneColumnShowsPreviewBrowse")

        // Neither key is written by storing the other: Browse's stored "off" leaves Compare's key
        // absent, so Compare still opens at the default. Both directions, because a migration seeding
        // one from the other would pass the first half alone.
        let d = defaults()
        d.set(false, forKey: PaneViewMode.previewColumnKey(isBrowse: true))
        #expect(d.object(forKey: PaneViewMode.previewColumnKey(isBrowse: false)) == nil)

        let e = defaults()
        e.set(false, forKey: PaneViewMode.previewColumnKey(isBrowse: false))
        #expect(e.object(forKey: PaneViewMode.previewColumnKey(isBrowse: true)) == nil)
    }

    /// The toggle is offered only where flipping it does something: Columns mode. A switch wired to
    /// nothing is worse than no switch.
    @Test func testThePreviewToggleIsOfferedOnlyWhereAPreviewCanAppear() {
        #expect(PaneViewMode.showsPreviewToggle(mode: .columns))
        // Tree mode has no preview for a toggle to govern.
        #expect(PaneViewMode.showsPreviewToggle(mode: .tree) == false)
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
            paneWidth: 500, columnWidth: 210, columnCount: 3, isSingleColumn: false)
        #expect(width == 0)
    }

    /// Exactly-full is the boundary of the same rule, and the one an off-by-one would land on.
    @Test func testAnExactlyFullStackGetsNoFiller() {
        let width = PaneViewMode.trailingFillerWidth(
            paneWidth: 630, columnWidth: 210, columnCount: 3, isSingleColumn: false)
        #expect(width == 0)
    }

    /// Under-filled: the filler takes the slack that already existed and nothing more.
    @Test func testAnUnderFilledStackFillsTheRemainder() {
        let width = PaneViewMode.trailingFillerWidth(
            paneWidth: 900, columnWidth: 210, columnCount: 2, isSingleColumn: false)
        #expect(width == 480)
    }

    /// A resting pane frames its one column to the full pane width, so there is no slack to fill —
    /// asking `paneWidth - columnWidth` here would wrongly claim most of the pane.
    @Test func testASingleColumnGetsNoFiller() {
        let width = PaneViewMode.trailingFillerWidth(
            paneWidth: 900, columnWidth: 210, columnCount: 1, isSingleColumn: true)
        #expect(width == 0)
    }

    /// Push mode renders exactly one column at any depth, and it spans the pane — same rule,
    /// reached by the other door.
    @Test func testPushModeGetsNoFiller() {
        let paneWidth = PaneViewMode.pushNavigationBelowWidth - 1
        #expect(PaneViewMode.usesPushNavigation(paneWidth: paneWidth))
        let width = PaneViewMode.trailingFillerWidth(
            paneWidth: paneWidth, columnWidth: 210, columnCount: 1, isSingleColumn: true)
        #expect(width == 0)
    }

    // MARK: - Preview column

    /// The whole gate, at the width it turns on. A pane must fit one full column *beside* a minimum
    /// preview: one point under and the preview would start the stack scrolling sideways because a
    /// file was clicked, which is the resting-state contract Columns is built on.
    @Test func testThePreviewNeedsRoomForAFullColumnBesideIt() {
        let floorWidth = 210 + PaneViewMode.minimumPreviewColumnWidth
        #expect(PaneViewMode.showsPreviewColumn(
            paneWidth: floorWidth, columnWidth: 210, isEnabled: true, hasPreviewTarget: true))
        #expect(PaneViewMode.showsPreviewColumn(
            paneWidth: floorWidth - 1, columnWidth: 210, isEnabled: true, hasPreviewTarget: true) == false)
    }

    /// A wider column raises the bar by exactly its own growth — the test that catches a rule
    /// written against `defaultColumnWidth` instead of the pane's live column width.
    @Test func testTheGateTracksTheLiveColumnWidth() {
        let paneWidth = PaneViewMode.maximumColumnWidth + PaneViewMode.minimumPreviewColumnWidth
        #expect(PaneViewMode.showsPreviewColumn(
            paneWidth: paneWidth, columnWidth: PaneViewMode.maximumColumnWidth,
            isEnabled: true, hasPreviewTarget: true))
        #expect(PaneViewMode.showsPreviewColumn(
            paneWidth: paneWidth - 1, columnWidth: PaneViewMode.maximumColumnWidth,
            isEnabled: true, hasPreviewTarget: true) == false)
    }

    /// Both switches are real switches: no selected file, or the setting off, and there is no
    /// preview however wide the pane.
    @Test func testThePreviewNeedsBothATargetAndTheSetting() {
        #expect(PaneViewMode.showsPreviewColumn(
            paneWidth: 1200, columnWidth: 210, isEnabled: true, hasPreviewTarget: false) == false)
        #expect(PaneViewMode.showsPreviewColumn(
            paneWidth: 1200, columnWidth: 210, isEnabled: false, hasPreviewTarget: true) == false)
    }

    /// A pane in push mode shows one pushing column and has no room for a preview beside it. The
    /// width gate already subsumes this against today's constants; the assertion is here so that
    /// retuning any of the three can't quietly put a preview into a push-mode pane.
    @Test func testPushModeNeverShowsAPreview() {
        let paneWidth = PaneViewMode.pushNavigationBelowWidth - 1
        #expect(PaneViewMode.usesPushNavigation(paneWidth: paneWidth))
        #expect(PaneViewMode.showsPreviewColumn(
            paneWidth: paneWidth, columnWidth: PaneViewMode.minimumColumnWidth,
            isEnabled: true, hasPreviewTarget: true) == false)
    }

    /// The common case — one column of files and a preview — fills the pane exactly, so there is
    /// nothing to scroll. `990 - 210` is the arithmetic; the point is that it is the *whole*
    /// remainder, not a fixed width.
    /// The preview is pinned to the pane's trailing edge and gets exactly the width it was dragged
    /// to. Two earlier rules derived it from the columns instead, and both failed in use: as the last
    /// item inside the scrolling stack it grew off the right edge, and taken from the columns' slack
    /// it could only be enlarged by narrowing every column until the stack stopped scrolling.
    @Test func testThePreviewGetsExactlyTheWidthItWasDraggedTo() {
        #expect(PaneViewMode.previewPaneWidth(paneWidth: 1590, columnWidth: 290, preferred: 900) == 900)
        #expect(PaneViewMode.previewPaneWidth(paneWidth: 1590, columnWidth: 290, preferred: 420) == 420)
    }

    /// The point of pinning it: the width is independent of how many columns are open and how wide
    /// they are, so the columns keep their own width and keep scrolling beside it.
    @Test func testThePreviewsWidthIgnoresTheColumnsBesideIt() {
        let wideColumns = PaneViewMode.previewPaneWidth(paneWidth: 1590, columnWidth: 340, preferred: 900)
        let narrowColumns = PaneViewMode.previewPaneWidth(paneWidth: 1590, columnWidth: 140, preferred: 900)
        #expect(wideColumns == narrowColumns)
    }

    /// …capped so one full column always survives beside it. Otherwise a preview dragged wide would
    /// squeeze out the very column holding the file it describes.
    @Test func testThePreviewNeverSqueezesOutTheLastColumn() {
        let width = PaneViewMode.previewPaneWidth(paneWidth: 500, columnWidth: 210,
                                                  preferred: PaneViewMode.maximumPreviewColumnWidth)
        #expect(width == 290)
        #expect(width + 210 == 500)
    }

    @Test func testThePreviewWidthIsClampedToTheLegibleRange() {
        #expect(PaneViewMode.clampPreviewColumnWidth(10) == PaneViewMode.minimumPreviewColumnWidth)
        #expect(PaneViewMode.clampPreviewColumnWidth(5000) == PaneViewMode.maximumPreviewColumnWidth)
        #expect(PaneViewMode.minimumPreviewColumnWidth <= PaneViewMode.defaultPreviewColumnWidth)
        #expect(PaneViewMode.defaultPreviewColumnWidth <= PaneViewMode.maximumPreviewColumnWidth)
    }

    /// The preview's divider is on its LEADING edge and the preview is pinned to the trailing edge,
    /// so the drag translation is subtracted: dragging left widens it. This is the sign that made the
    /// in-stack version look broken, and the geometry that now makes it work.
    @Test func testDraggingThePreviewsDividerLeftWidensIt() {
        #expect(PaneViewMode.draggedPreviewColumnWidth(anchor: 420, translation: -60) == 480)
        #expect(PaneViewMode.draggedPreviewColumnWidth(anchor: 420, translation: 60) == 360)
    }

    /// Cumulative translation, fixed anchor — the discipline `draggedColumnWidth` needed, where
    /// folding the translation into the live width compounded a drag to the maximum immediately.
    @Test func testThePreviewDragTracksTranslationFromAFixedAnchor() {
        let steps = [-10, -20, -30].map {
            PaneViewMode.draggedPreviewColumnWidth(anchor: 420, translation: CGFloat($0))
        }
        #expect(steps == [430, 440, 450])
    }

    /// The filler measures the COLUMNS' area, which is the pane minus the pinned preview. The two
    /// can no longer claim the same points — the preview isn't in the scroll content at all — so the
    /// filler simply takes whatever slack the columns leave inside their own area.
    @Test func testTheFillerTakesTheSlackInsideTheColumnsOwnArea() {
        #expect(PaneViewMode.trailingFillerWidth(
            paneWidth: 690, columnWidth: 210, columnCount: 1, isSingleColumn: false) == 480)
        #expect(PaneViewMode.trailingFillerWidth(
            paneWidth: 690, columnWidth: 210, columnCount: 4, isSingleColumn: false) == 0)
    }

    @Test func testEveryModeHasDistinctChrome() {
        let symbols = Set(PaneViewMode.allCases.map(\.symbol))
        #expect(symbols.count == PaneViewMode.allCases.count)
        #expect(PaneViewMode.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.help.isEmpty })
    }
}
