import AppKit
import Testing
@testable import FileExplorer

/// The gate that makes clicking a pane's empty space safe: `acceptsClick` decides whether the
/// deselect recognizer engages, and a refusal leaves the click to the list. The case that matters
/// most is the negative one: a click on a row must be invisible to this.
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

    /// A table with 200pt of empty area below its last row. Row positions are read back from the
    /// table, not computed: a row's pitch includes `intercellSpacing`.
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

    /// A click on a row is refused, at every row and both its edges: an off-by-one at a boundary
    /// would leave a sliver that deselects instead of selecting.
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

    /// A click `below` points under the last row with `modifiers` held. The first pixel past the last
    /// row counts; ⌘ and ⇧ (extend, range-select) refuse, while ⌥, the mirror modifier, does not.
    @Test(arguments: [
        (150, [], true), (0.5, [], true),
        (150, .command, false), (150, .shift, false), (150, .option, true),
    ] as [(CGFloat, NSEvent.ModifierFlags, Bool)])
    mutating func testAClickBelowTheLastRow(below: CGFloat, modifiers: NSEvent.ModifierFlags, accepted: Bool) {
        let table = table(rows: 5)
        #expect(accepts(CGPoint(x: 100, y: belowLastRow(table, rows: 5) + below), table, modifiers) == accepted,
                "\(below)pt below with modifiers \(modifiers.rawValue)")
    }

    /// An empty folder's column is all empty area: where a deselect is most obviously right, and
    /// where a row-based gate could accidentally refuse everything.
    @Test mutating func testAnEmptyTableIsAllEmptyArea() {
        let table = table(rows: 0)
        #expect(accepts(CGPoint(x: 100, y: 10), table))
    }
}
