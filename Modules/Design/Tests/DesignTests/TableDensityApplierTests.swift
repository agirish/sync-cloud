import AppKit
import Testing
@testable import Design

/// Pins the AppKit contract of `TableDensityApplierView` (the worker beneath
/// `listDensity(_:)`) against bare `NSTableView`s — no SwiftUI mounting needed thanks to the
/// internal `apply(to:)` seam:
///
/// - compact pins auto-heights off / rowHeight / spacing 0 and captures the originals,
/// - re-applying is idempotent,
/// - nil (comfortable) restores all three originals in place and clears the capture,
/// - single-column tables (SwiftUI `List`s, i.e. the file panes) are refused outright,
/// - a table-identity change resets the stale capture instead of writing it onto the
///   new table.
@MainActor
@Suite struct TableDensityApplierTests {

    /// A fresh table the way SwiftUI's `Table` configures one before we touch it:
    /// automatic row heights on, a system-ish row height, and non-zero intercell spacing.
    private func makeTable(columns: Int = 2,
                           rowHeight: CGFloat = 24,
                           spacing: NSSize = NSSize(width: 3, height: 2)) -> NSTableView {
        let table = NSTableView()
        for index in 0..<columns {
            table.addTableColumn(NSTableColumn(identifier: .init("column\(index)")))
        }
        table.usesAutomaticRowHeights = true
        table.rowHeight = rowHeight
        table.intercellSpacing = spacing
        return table
    }

    @Test func compactPinsAFreshMultiColumnTableAndCapturesOriginals() {
        let applier = TableDensityApplierView()
        applier.desiredRowHeight = 20
        let table = makeTable()

        applier.apply(to: table)

        #expect(table.usesAutomaticRowHeights == false)
        #expect(table.rowHeight == 20)
        #expect(table.intercellSpacing.height == 0)
        // Horizontal spacing is left alone — only the vertical gap is density.
        #expect(table.intercellSpacing.width == 3)
        #expect(applier.original?.rowHeight == 24)
        #expect(applier.original?.spacing == NSSize(width: 3, height: 2))
        #expect(applier.original?.automaticHeights == true)
    }

    @Test func reapplyingCompactIsIdempotent() {
        let applier = TableDensityApplierView()
        applier.desiredRowHeight = 20
        let table = makeTable()

        applier.apply(to: table)
        applier.apply(to: table)

        // The capture still holds the FIRST apply's originals — a second pass must not
        // re-capture the already-pinned values (that would poison the restore).
        #expect(applier.original?.rowHeight == 24)
        #expect(applier.original?.spacing == NSSize(width: 3, height: 2))
        #expect(applier.original?.automaticHeights == true)
        #expect(table.rowHeight == 20)
        #expect(table.intercellSpacing.height == 0)
    }

    @Test func nilDesiredHeightRestoresOriginalsInPlaceAndClearsTheCapture() {
        let applier = TableDensityApplierView()
        applier.desiredRowHeight = 20
        let table = makeTable()
        applier.apply(to: table)

        applier.desiredRowHeight = nil
        applier.apply(to: table)

        #expect(table.usesAutomaticRowHeights == true)
        #expect(table.rowHeight == 24)
        #expect(table.intercellSpacing == NSSize(width: 3, height: 2))
        #expect(applier.original == nil)

        // A following compact re-apply re-captures the restored values.
        applier.desiredRowHeight = 18
        applier.apply(to: table)
        #expect(table.rowHeight == 18)
        #expect(applier.original?.rowHeight == 24)
        #expect(applier.original?.automaticHeights == true)
    }

    @Test func singleColumnTableIsRefused() {
        // A single-column NSTableView near the modifier is a SwiftUI `List` (the file
        // panes) — the applier must never touch it, pinned or not.
        let applier = TableDensityApplierView()
        applier.desiredRowHeight = 20
        let list = makeTable(columns: 1)

        applier.apply(to: list)

        #expect(list.usesAutomaticRowHeights == true)
        #expect(list.rowHeight == 24)
        #expect(list.intercellSpacing == NSSize(width: 3, height: 2))
        #expect(applier.original == nil)
    }

    @Test func tableIdentityChangeResetsTheStaleCapture() {
        let applier = TableDensityApplierView()
        applier.desiredRowHeight = 20
        let tableA = makeTable(rowHeight: 24)
        let tableB = makeTable(rowHeight: 30, spacing: NSSize(width: 5, height: 4))

        applier.apply(to: tableA)
        #expect(applier.original?.rowHeight == 24)

        applier.apply(to: tableB)

        // B gets its OWN capture — A's stale originals were reset, never written onto B.
        #expect(applier.original?.rowHeight == 30)
        #expect(applier.original?.spacing == NSSize(width: 5, height: 4))
        #expect(tableB.rowHeight == 20)
        #expect(tableB.intercellSpacing.height == 0)
        // Documented limitation: the previous table stays pinned once the applier moves on.
        // The multi-column discriminator + window-scoped cache make this unreachable for
        // the app's panes.
        #expect(tableA.rowHeight == 20)
        #expect(tableA.usesAutomaticRowHeights == false)
    }
}
