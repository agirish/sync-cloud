import AppKit
import Testing
@testable import FileExplorer

/// The gate that makes clicking a pane's empty space safe: `acceptsClick` decides whether the
/// deselect recognizer engages at all, and a refusal means the click reaches the list's own mouse
/// handling completely untouched.
///
/// This is the one predicate the whole feature rests on. Four separate bugs in this pane
/// (`aa9d407`, `94554e9`, `743d8bd`, `8b85cf4`) came from two things both claiming one click, so
/// the case that matters most here is the *negative* one — a click on a row must be invisible to
/// this.
@MainActor
@Suite struct PaneBackgroundDeselectTests {

    /// Feeds the table real rows so `row(at:)` resolves against a real height cache rather than an
    /// empty one, where every point would read as -1 and every assertion below would pass
    /// vacuously.
    private final class Source: NSObject, NSTableViewDataSource {
        let rows: Int
        init(rows: Int) { self.rows = rows }
        func numberOfRows(in tableView: NSTableView) -> Int { rows }
    }

    private var source: Source?

    /// A table with 200pt of deliberate empty area *below* its last row — the shape a pane list
    /// actually has when its rows do not fill the viewport, and the case this whole file is about.
    ///
    /// Row positions are read back from the table rather than computed here. A row's pitch is
    /// `rowHeight` plus `intercellSpacing`, and assuming otherwise put points that look like they
    /// are over row 4 into the empty area below it — the first draft of these tests failed for
    /// exactly that reason, which is a fair warning about hand-computed table geometry.
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

    /// The fixture is only meaningful if the table really resolves rows — assert that before
    /// leaning on the refusals below.
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

    /// Every row and both its edges, not just a convenient midpoint — an off-by-one at a row
    /// boundary would leave one sliver of one row deselecting instead of selecting, which is
    /// precisely the shape of the intermittent dead click this pane has been chasing.
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

    /// The first pixel past the last row already counts — the gap between "the list ends" and "the
    /// click deselects" should be nothing.
    @Test mutating func testTheBoundaryBelowTheLastRowIsAccepted() {
        let table = table(rows: 5)
        #expect(accepts(CGPoint(x: 100, y: belowLastRow(table, rows: 5) + 0.5), table))
    }

    /// An empty folder's column is all empty area, which is the one place a deselect is most
    /// obviously right and where a row-based gate could accidentally refuse everything.
    @Test mutating func testAnEmptyTableIsAllEmptyArea() {
        let table = table(rows: 0)
        #expect(accepts(CGPoint(x: 100, y: 10), table))
    }

    // MARK: Modifiers

    /// ⌘ and ⇧ are the list's own extend and range-select. Deselecting when one of them misses a row
    /// by a pixel would collapse the multi-selection being built — the same flattening `dba5cd3`
    /// fixed on the row path, arriving by a different door.
    @Test mutating func testCommandClickOnEmptyAreaIsRefused() {
        let table = table(rows: 5)
        #expect(accepts(CGPoint(x: 100, y: belowLastRow(table, rows: 5) + 150), table, .command) == false)
    }

    @Test mutating func testShiftClickOnEmptyAreaIsRefused() {
        let table = table(rows: 5)
        #expect(accepts(CGPoint(x: 100, y: belowLastRow(table, rows: 5) + 150), table, .shift) == false)
    }

    /// A modifier that means nothing to selection must not disable the gesture — ⌥ is the pane's
    /// mirror modifier and is held routinely while navigating.
    @Test mutating func testOptionClickOnEmptyAreaStillDeselects() {
        let table = table(rows: 5)
        #expect(accepts(CGPoint(x: 100, y: belowLastRow(table, rows: 5) + 150), table, .option))
    }
}
