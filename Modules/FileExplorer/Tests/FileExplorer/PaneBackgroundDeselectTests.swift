import AppKit
import Testing
@testable import FileExplorer

/// The gate that makes clicking a pane's empty space safe: `acceptsClick` decides whether the
/// deselect recognizer engages at all, and a refusal leaves the click to the list's own mouse
/// handling, untouched.
///
/// The predicate the whole feature rests on. Two things claiming one click is how this pane breaks,
/// so the case that matters most is the negative one: a click on a row must be invisible to this.
@MainActor
@Suite struct PaneBackgroundDeselectTests {

    /// Feeds the table real rows so `row(at:)` resolves against a real height cache. With an empty
    /// one every point reads as -1 and every assertion below would pass vacuously.
    private final class Source: NSObject, NSTableViewDataSource {
        let rows: Int
        init(rows: Int) { self.rows = rows }
        func numberOfRows(in tableView: NSTableView) -> Int { rows }
    }

    private var source: Source?

    /// A table with 200pt of empty area below its last row: the shape a pane list has when its rows
    /// don't fill the viewport, and the case this file is about.
    ///
    /// Row positions are read back from the table, not computed. A row's pitch is `rowHeight` plus
    /// `intercellSpacing`, and hand-computed points meant for row 4 can land in the empty area
    /// below.
    private mutating func table(rows: Int) -> NSTableView {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.rowHeight = 20
        let source = Source(rows: rows)
        self.source = source          // the table's dataSource is weak
        table.dataSource = source
        table.reloadData()
        if rows > 0 {
            table.setFrameSize(NSSize(width: 200, height: table.rect(ofRow: rows - 1).maxY + 200))
        }
        return table
    }

    /// First empty y below the last row.
    private func belowLastRow(_ table: NSTableView, rows: Int) -> CGFloat {
        table.rect(ofRow: rows - 1).maxY
    }

    private func accepts(_ point: CGPoint, _ table: NSTableView, _ modifiers: NSEvent.ModifierFlags = []) -> Bool {
        PaneBackgroundDeselect.acceptsClick(modifiers: modifiers, pointInTable: point, table: table)
    }

    /// The fixture is only meaningful if the table really resolves rows; asserted before the
    /// refusals below lean on it.
    @Test mutating func testTheFixtureResolvesRealRows() {
        let table = table(rows: 5)
        #expect(table.numberOfRows == 5)
        #expect(table.row(at: CGPoint(x: 100, y: table.rect(ofRow: 2).midY)) == 2)
        // And it really does have empty area below them, or every acceptance below is vacuous.
        #expect(table.bounds.maxY > belowLastRow(table, rows: 5))
    }

    // MARK: The refusals

    @Test mutating func testAClickOnARowIsRefused() {
        let table = table(rows: 5)
        #expect(accepts(CGPoint(x: 100, y: table.rect(ofRow: 2).midY), table) == false)
    }

    /// Every row and both its edges, not just a midpoint: an off-by-one at a row boundary would
    /// leave a sliver of a row deselecting instead of selecting, an intermittent dead click.
    @Test mutating func testNoPointOverAnyRowIsAccepted() {
        let table = table(rows: 5)
        for row in 0..<5 {
            let rect = table.rect(ofRow: row)
            for y in [rect.minY + 0.5, rect.midY, rect.maxY - 0.5] {
                #expect(accepts(CGPoint(x: 100, y: y), table) == false,
                        "row \(row) at y=\(y) must reach the list, not this")
            }
        }
    }

    // MARK: The acceptance

    @Test mutating func testAClickBelowTheLastRowIsAccepted() {
        let table = table(rows: 5)
        #expect(accepts(CGPoint(x: 100, y: belowLastRow(table, rows: 5) + 150), table))
    }

    /// The first pixel past the last row already counts: there should be no gap between "the list
    /// ends" and "the click deselects".
    @Test mutating func testTheBoundaryBelowTheLastRowIsAccepted() {
        let table = table(rows: 5)
        #expect(accepts(CGPoint(x: 100, y: belowLastRow(table, rows: 5) + 0.5), table))
    }

    /// An empty folder's column is all empty area: where a deselect is most obviously right, and
    /// where a row-based gate could accidentally refuse everything.
    @Test mutating func testAnEmptyTableIsAllEmptyArea() {
        let table = table(rows: 0)
        #expect(accepts(CGPoint(x: 100, y: 10), table))
    }

    // MARK: Modifiers

    /// ⌘ and ⇧ are the list's own extend and range-select. Deselecting when one of them misses a
    /// row by a pixel would collapse the multi-selection being built.
    @Test mutating func testCommandClickOnEmptyAreaIsRefused() {
        let table = table(rows: 5)
        #expect(accepts(CGPoint(x: 100, y: belowLastRow(table, rows: 5) + 150), table, .command) == false)
    }

    @Test mutating func testShiftClickOnEmptyAreaIsRefused() {
        let table = table(rows: 5)
        #expect(accepts(CGPoint(x: 100, y: belowLastRow(table, rows: 5) + 150), table, .shift) == false)
    }

    /// A modifier that means nothing to selection must not disable the gesture: ⌥ is the pane's
    /// mirror modifier, held routinely while navigating.
    @Test mutating func testOptionClickOnEmptyAreaStillDeselects() {
        let table = table(rows: 5)
        #expect(accepts(CGPoint(x: 100, y: belowLastRow(table, rows: 5) + 150), table, .option))
    }
}
