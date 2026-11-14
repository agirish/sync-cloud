import AppKit
import Testing
@testable import Design

/// Pins the AppKit contract of `TableDensityApplierView` (beneath `listDensity(_:)`) through the
/// `apply(to:)` seam: compact pins auto-heights off, rowHeight and spacing 0 and captures the
/// originals; nil restores them; single-column tables are refused; a new table resets the capture.
///
/// The mounted tests host the applier beside an `NSScrollView`-wrapped table in an offscreen
/// window, the shape SwiftUI mounts, and drive the find path (`layout()` → resolve → apply).
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

        // The capture still holds the first apply's originals: re-capturing the pinned values
        // would poison the restore.
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
        // A single-column NSTableView near the modifier is a SwiftUI `List` (the file panes),
        // which the applier must never touch.
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

        // B gets its own capture: A's stale originals are reset, never written onto B.
        #expect(applier.original?.rowHeight == 30)
        #expect(applier.original?.spacing == NSSize(width: 5, height: 4))
        #expect(tableB.rowHeight == 20)
        #expect(tableB.intercellSpacing.height == 0)
        // Known limitation: the previous table stays pinned once the applier moves on. The
        // multi-column check and window-scoped cache keep the app's panes out of reach of it.
        #expect(tableA.rowHeight == 20)
        #expect(tableA.usesAutomaticRowHeights == false)
    }

    // MARK: - Mounted hierarchy (the FIND path)

    /// An offscreen borderless window hosting the shape SwiftUI mounts: one `NSScrollView` per
    /// table plus the applier as a background sibling. Never ordered in, so no activation needed.
    private func mount(tables: [NSTableView],
                       applier: TableDensityApplierView) -> (window: NSWindow, container: NSView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        for table in tables {
            let scroll = NSScrollView(frame: container.bounds)
            scroll.documentView = table
            container.addSubview(scroll)
        }
        container.addSubview(applier)
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        return (window, container)
    }

    @Test func finderLocatesTheTableThroughAMountedHierarchy() {
        let applier = TableDensityApplierView()
        applier.desiredRowHeight = 20
        let table = makeTable()
        let mounted = mount(tables: [table], applier: applier)
        defer { mounted.window.contentView = nil }

        applier.layout()

        #expect(table.usesAutomaticRowHeights == false)
        #expect(table.rowHeight == 20)
        #expect(table.intercellSpacing.height == 0)
        #expect(applier.original?.rowHeight == 24)
        #expect(applier.original?.automaticHeights == true)
    }

    @Test func twoMultiColumnTablesInTheSameSubtreeAreRefused() {
        // An animated branch swap can leave outgoing and incoming tables alive under one
        // ancestor. Guessing by traversal order could capture the dying table's pinned values as
        // originals, so the finder refuses and leaves both untouched until one goes.
        let applier = TableDensityApplierView()
        applier.desiredRowHeight = 20
        let tableA = makeTable()
        let tableB = makeTable(rowHeight: 30)
        let mounted = mount(tables: [tableA, tableB], applier: applier)
        defer { mounted.window.contentView = nil }

        applier.layout()

        #expect(applier.resolveTableView() == nil)
        #expect(tableA.usesAutomaticRowHeights == true)
        #expect(tableA.rowHeight == 24)
        #expect(tableA.intercellSpacing.height == 2)
        #expect(tableB.usesAutomaticRowHeights == true)
        #expect(tableB.rowHeight == 30)
        #expect(applier.original == nil)
    }

    @Test func singleColumnTableAloneIsRefusedByTheFinder() {
        // The find-path twin of `singleColumnTableIsRefused`: a lone SwiftUI `List` must not even
        // be resolved.
        let applier = TableDensityApplierView()
        applier.desiredRowHeight = 20
        let list = makeTable(columns: 1)
        let mounted = mount(tables: [list], applier: applier)
        defer { mounted.window.contentView = nil }

        applier.layout()

        #expect(applier.resolveTableView() == nil)
        #expect(list.usesAutomaticRowHeights == true)
        #expect(list.rowHeight == 24)
        #expect(applier.original == nil)
    }

    @Test func detachedApplierDoesNothingEvenWithAFindableTable() {
        // No window: the nil-window guard refuses. Without it the stale-cache check
        // (`cached.window === window`) passes on nil === nil and a detached hierarchy is pinned.
        let applier = TableDensityApplierView()
        applier.desiredRowHeight = 20
        let table = makeTable()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let scroll = NSScrollView(frame: container.bounds)
        scroll.documentView = table
        container.addSubview(scroll)
        container.addSubview(applier)

        applier.layout()

        #expect(applier.resolveTableView() == nil)
        #expect(table.usesAutomaticRowHeights == true)
        #expect(table.rowHeight == 24)
        #expect(applier.original == nil)
    }

    @Test func movingToAnotherWindowNeverWritesTheFirstCaptureOntoTheNewTable() {
        let applier = TableDensityApplierView()
        applier.desiredRowHeight = 20
        let tableA = makeTable(rowHeight: 24)
        let mountedA = mount(tables: [tableA], applier: applier)
        defer { mountedA.window.contentView = nil }

        applier.layout()
        #expect(applier.original?.rowHeight == 24)

        // Rehome the applier into a second window with a different table: resolve must re-find,
        // and the identity change must reset A's capture rather than restore it onto B.
        applier.removeFromSuperview()
        let tableB = makeTable(rowHeight: 30, spacing: NSSize(width: 5, height: 4))
        let mountedB = mount(tables: [tableB], applier: applier)
        defer { mountedB.window.contentView = nil }

        applier.layout()

        #expect(applier.original?.rowHeight == 30)
        #expect(applier.original?.spacing == NSSize(width: 5, height: 4))
        #expect(tableB.rowHeight == 20)
        #expect(tableB.intercellSpacing.height == 0)
    }

    @Test func spacingDriftIsRePinnedOnTheNextLayoutPass() {
        // A SwiftUI re-tile can reset intercellSpacing alone; the next layout pass must re-pin it
        // without re-capturing, so the original still holds the first apply's values.
        let applier = TableDensityApplierView()
        applier.desiredRowHeight = 20
        let table = makeTable()
        let mounted = mount(tables: [table], applier: applier)
        defer { mounted.window.contentView = nil }

        applier.layout()
        #expect(table.intercellSpacing.height == 0)

        table.intercellSpacing = NSSize(width: 3, height: 2)
        applier.layout()

        #expect(table.intercellSpacing.height == 0)
        #expect(table.rowHeight == 20)
        #expect(applier.original?.spacing == NSSize(width: 3, height: 2))
    }
}
