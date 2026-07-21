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
///
/// The mounted-hierarchy tests below go further: they host a real (offscreen, borderless)
/// `NSWindow` with the applier as a sibling of an `NSScrollView`-wrapped table — the shape
/// SwiftUI actually mounts — and drive the FIND path (`layout()` → resolve → apply), pinning
/// the finder's single-table requirement, the ambiguity refusal, the nil-window guard and
/// the cross-window cache invalidation.
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

    // MARK: - Mounted hierarchy (the FIND path)

    /// An offscreen borderless window hosting the shape SwiftUI mounts: a container whose
    /// subviews are one `NSScrollView` per table (documentView = the table) plus the applier
    /// as a background sibling. Never ordered in — no app activation needed.
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
        // The transient an animated branch swap can produce: outgoing and incoming Table
        // both alive under the same ancestor. Guessing by traversal order could capture the
        // dying table's pinned values as "originals" — the finder must refuse instead and
        // leave BOTH tables untouched until the coexistence ends.
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
        // The FIND-path twin of `singleColumnTableIsRefused`: a lone SwiftUI `List` in the
        // subtree must not even be resolved, let alone pinned.
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
        // No window: the nil-window guard must refuse outright. Without it the stale-cache
        // check (`cached.window === window`) would vacuously pass on nil === nil, and a
        // detached hierarchy would still get pinned.
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

        // Rehome the applier into a second window with a different table. The cached first
        // table is no longer in the applier's window, so resolve must re-find — and the
        // identity change must reset A's capture instead of restoring it onto B.
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
        // The guard's spacing leg, proven live through the mounted path: a SwiftUI re-tile
        // can reset intercellSpacing alone, and the next layout pass must re-pin it without
        // re-capturing (the original must still hold the FIRST apply's values).
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
