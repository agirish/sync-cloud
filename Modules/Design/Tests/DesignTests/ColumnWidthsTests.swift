import Testing
import CoreGraphics
@testable import Design

/// Columns sized one at a time — the rules under the Readability setting "Column widths", ⌥, and the
/// stored per-position widths. Pure, so every case is a line.
@Suite struct ColumnWidthsTests {

    /// ⌥ always does the other one, in either setting — the one rule the drag and the double-click
    /// both ask, so it is pinned as a truth table rather than as two behaviours.
    @Test func optionAlwaysDoesTheOther() {
        #expect(ColumnResizeMode.eachColumn.resizesAll(optionHeld: false) == false)
        #expect(ColumnResizeMode.eachColumn.resizesAll(optionHeld: true) == true)
        #expect(ColumnResizeMode.allColumns.resizesAll(optionHeld: false) == true)
        #expect(ColumnResizeMode.allColumns.resizesAll(optionHeld: true) == false)
        #expect(ColumnResizeMode.default == .eachColumn, "one column at a time is the change asked for")
    }

    /// A drag on one column moves that column and nothing else — the base width and every other
    /// column's own width are untouched.
    @Test func aDragMovesOnlyItsColumn() {
        let before = ColumnWidthOverrides(widths: [0: 250])
        let after = PaneViewMode.resizedColumnWidths(base: 210, overrides: before, depth: 2, to: 420, all: false)
        #expect(after.base == 210)
        #expect(after.overrides.widths == [0: 250, 2: 420])
        #expect(after.overrides.width(atDepth: 1, base: after.base) == 210, "an unsized column moved")
    }

    /// A column sized to exactly the base is not kept as sized on its own: it IS the base. An entry
    /// saying so would make a gesture that changed nothing — a fit that lands on the shared width —
    /// look like a change, and fire the width drivers for it.
    @Test func aColumnSizedToTheBaseIsNotKeptAsSized() {
        let sized = ColumnWidthOverrides(widths: [2: 300])
        let back = PaneViewMode.resizedColumnWidths(base: 210, overrides: sized, depth: 2, to: 210, all: false)
        #expect(back.overrides.widths.isEmpty, "a column dragged back to the base kept an entry")
        let untouched = PaneViewMode.resizedColumnWidths(base: 210, overrides: .init(), depth: 1, to: 210, all: false)
        #expect(untouched.overrides == ColumnWidthOverrides(), "a no-op gesture wrote an entry")
    }

    /// "All columns together" is exactly the single shared width that shipped before: one width for
    /// every column, and every column that was sized on its own released to it.
    @Test func allTogetherIsOneWidthForEveryColumn() {
        let before = ColumnWidthOverrides(widths: [0: 250, 3: 500])
        let after = PaneViewMode.resizedColumnWidths(base: 210, overrides: before, depth: 1, to: 300, all: true)
        #expect(after.base == 300)
        #expect(after.overrides.widths.isEmpty)
        for depth in 0..<5 { #expect(after.overrides.width(atDepth: depth, base: after.base) == 300) }
    }

    /// Widths are clamped when they are written and again when they are read, so neither a runaway
    /// drag nor a hand-edited default can produce a column outside the legible range.
    @Test func widthsAreClampedOnWriteAndOnRead() {
        let written = PaneViewMode.resizedColumnWidths(base: 210, overrides: .init(), depth: 0, to: 9_999, all: false)
        #expect(written.overrides.widths[0] == PaneViewMode.maximumColumnWidth)
        let edited = ColumnWidthOverrides(rawValue: "0=5;1=99999")!
        #expect(edited.width(atDepth: 0, base: 210) == PaneViewMode.minimumColumnWidth)
        #expect(edited.width(atDepth: 1, base: 210) == PaneViewMode.maximumColumnWidth)
    }

    /// The storage form round-trips, and an entry it cannot read is skipped rather than failing the
    /// whole set — one bad pair must not throw away every column someone sized.
    @Test func overridesSurviveTheirStorageForm() throws {
        let widths = ColumnWidthOverrides(widths: [3: 300, 0: 250.5])
        let decoded = try #require(ColumnWidthOverrides(rawValue: widths.rawValue))
        #expect(decoded == widths)
        let damaged = try #require(ColumnWidthOverrides(rawValue: "0=250;x=3;2=;4=nan;-1=300;5=280"))
        #expect(damaged.widths == [0: 250, 5: 280])
        #expect(ColumnWidthOverrides(rawValue: "")?.widths.isEmpty == true)
    }

    /// The dead space past the last column is the viewport minus the columns' REAL widths.
    @Test func theFillerSumsTheRealWidths() {
        #expect(PaneViewMode.trailingFillerWidth(paneWidth: 1000, columnWidths: [300, 200], isSingleColumn: false) == 500)
        #expect(PaneViewMode.trailingFillerWidth(paneWidth: 400, columnWidths: [300, 200], isSingleColumn: false) == 0)
        #expect(PaneViewMode.trailingFillerWidth(paneWidth: 1000, columnWidths: [300], isSingleColumn: true) == 0)
    }
}
