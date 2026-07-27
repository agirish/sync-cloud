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

    @Test func testVisibleColumnCountNeverDropsBelowOne() {
        #expect(PaneViewMode.visibleColumnCount(paneWidth: 660, columnWidth: 210) == 3)
        #expect(PaneViewMode.visibleColumnCount(paneWidth: 420, columnWidth: 210) == 2)
        // Narrower than one column, and a degenerate width, still yield a column to draw.
        #expect(PaneViewMode.visibleColumnCount(paneWidth: 100, columnWidth: 210) == 1)
        #expect(PaneViewMode.visibleColumnCount(paneWidth: 660, columnWidth: 0) == 1)
    }

    @Test func testEveryModeHasDistinctChrome() {
        let symbols = Set(PaneViewMode.allCases.map(\.symbol))
        #expect(symbols.count == PaneViewMode.allCases.count)
        #expect(PaneViewMode.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.help.isEmpty })
    }
}
