import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The differences table keeps its AppKit identity across a "Group by folder" toggle, so a dragged
/// column width and the scroll position survive it. Measured on the real `NSTableView`, because
/// SwiftUI can't be asked whether a Table is the one it had before. Splitting it back into two
/// Tables behind an `if` must fail `widthSurvivesTheGroupingToggle` on "the toggle swapped the
/// NSTableView" while `togglingGroupingChangesTheRowShape` still passes.
///
/// Harness traps:
/// - Wait asynchronously, never by spinning `RunLoop.run`: the rows arrive from a `.task(id:)` hop
///   on the main actor, and a synchronous spin from a `@MainActor` test starves that task.
/// - The window is never ordered in: `.task` fires without it, and the owner uses the real app
///   while these run.
/// - Waits target the exact settled row count, never `rows > 0`: rows materialize asynchronously,
///   so the first non-empty count can be whichever shape rendered first.
///
/// Each mount reads its preferences from its own `ScratchDefaults` suite via `.defaultAppStorage`,
/// never `UserDefaults.standard`. `@AppStorage` keeps a process-wide storage location per
/// (store, key) that outlives its views and can re-attach to a fresh view without re-reading the
/// defaults, so a shared key can render grouped while the plist says flat. `.serialized` orders the
/// cases; `.oneMountedDifferencesTable` keeps these mounts, the priciest main-actor jobs in the
/// target, from stacking on other mounting suites' and starving their deadlines.
@MainActor
@Suite(.serialized, .oneMountedDifferencesTable) struct DifferencesTableIdentityTests {

    /// The Size column's declared ideal, from `DifferencesView.differencesTable`. The dragged width
    /// must differ from it, or a rebuilt column re-deriving its ideal would look like a survivor.
    private static let sizeColumnIdeal: CGFloat = 90

    // MARK: Fixture

    /// Three folders of four rows each, which clears `isWorthGrouping` (sections must average
    /// >= 3 rows), so the toggle really changes the row shape. `togglingGroupingChangesTheRowShape`
    /// checks that, since a fixture failing the gate would make the identity assertion vacuous.
    private func differences(folders: [String] = ["Documents", "Photos", "Projects"],
                             perFolder: Int = 4) -> [FileDifference] {
        folders.flatMap { folder in
            (1...perFolder).map { index in
                FileDifference(
                    relativePath: "\(folder)/file-\(index).txt",
                    leftItemPath: "/left/\(folder)/file-\(index).txt",
                    rightItemPath: "/right/\(folder)/file-\(index).txt",
                    type: .missingOnRight,
                    action: .copyToRight,
                    description: "Only on the left",
                    leftFileSize: 1024 * index)
            }
        }
    }

    /// Mounts the real `DifferencesView`, not a lookalike that would keep passing after the real
    /// one regressed. Its fresh `ScratchDefaults` suite is seeded before the view exists, so the
    /// `@AppStorage` location born on first render holds this test's value. Mid-test toggles write
    /// to the returned `store`, which that location has observed since.
    private func mount(grouped: Bool,
                       rows: [FileDifference]? = nil,
                       manager externalManager: FileSyncManager? = nil,
                       reviewStore: ReviewSessionStore = ReviewSessionStore())
        -> (host: NSHostingView<AnyView>, window: NSWindow, store: UserDefaults) {
        let store = ScratchDefaults("DifferencesTableIdentityTests")
        store.set(grouped, forKey: "differencesGroupByFolder")
        // An external manager arrives already scanned (the path-anchor tests need
        // `lastScanRootNames` from the real publish); the default one gets the fixture rows.
        let manager: FileSyncManager
        if let externalManager {
            manager = externalManager
        } else {
            manager = FileSyncManager()
            manager.differences = rows ?? differences()
            manager.hasScanned = true
        }

        let view = DifferencesView(syncManager: manager, reviewStore: reviewStore)
            .defaultAppStorage(store)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 600)

        // A real (never ordered-in) window: an NSTableView only lays its columns out inside one.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window, store)
    }

    // MARK: Waiting + hierarchy helpers

    /// Waits until `condition` holds and reports whether it did; every caller must assert on the
    /// result, or a test would pass vacuously once the rows stopped arriving. Pumps `host`, bounded
    /// by `LayoutPumpWait`'s pass floor as well as its deadline (see `settle`).
    private func wait(_ host: NSView, for condition: () -> Bool,
                      timeout: TimeInterval = 5) async -> (held: Bool, pumps: Int) {
        await LayoutPumpWait.pump(host, upTo: timeout, until: condition)
    }

    /// Waits for the table to settle at exactly `expected` rows and reports the last count seen.
    /// `rows > 0` is no signal: rows and the grouping toggle land asynchronously, so the first
    /// non-empty count may be the wrong shape. Returned, not asserted, so each caller's message
    /// names its mount; on timeout it is the count on screen, as in `SectionRowHeightTests`.
    ///
    /// Bounded by `LayoutPumpWait`'s pass floor, not the deadline alone, and it reports the passes:
    /// a loaded machine needs more main-actor turns, not more seconds. Giving up after the floor's
    /// 50 passes means starved; after a thousand, genuinely disproved. See "Fixed pumps and fixed
    /// sleeps" in `docs/flaky-tests.md`.
    private func settle(_ host: NSView, atRows expected: Int,
                        timeout: TimeInterval = 15) async -> (rows: Int, pumps: Int) {
        var last = 0
        let outcome = await LayoutPumpWait.pump(host, upTo: timeout) {
            last = tableView(in: host)?.numberOfRows ?? 0
            return last == expected
        }
        return (last, outcome.pumps)
    }

    private func tableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = tableView(in: subview) { return found }
        }
        return nil
    }

    /// The table's own enclosing scroll view, not the first `NSScrollView` in the hierarchy.
    private func scrollView(in view: NSView) -> NSScrollView? {
        tableView(in: view)?.enclosingScrollView
    }

    /// Found by title, not index, so a column inserted before it can't swap what is measured.
    private func sizeColumn(of table: NSTableView) -> NSTableColumn? {
        table.tableColumns.first { $0.title == "Size" || $0.headerCell.stringValue == "Size" }
    }

    // MARK: Path-anchor helpers

    /// A manager whose `lastScanRootNames` came from a real scan of two temp folders, not a poked
    /// tuple no real code could produce. The left folder holds one root-level file, so the diff is
    /// a single row whose Path cell relies on the anchor.
    private func scannedManager(leftFolder: String, rightFolder: String) async throws
        -> (manager: FileSyncManager, cleanup: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DiffPathAnchor-\(UUID().uuidString)")
        let left = base.appendingPathComponent(leftFolder)
        let right = base.appendingPathComponent("other").appendingPathComponent(rightFolder)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: left.appendingPathComponent("loose.pdf"))
        let manager = FileSyncManager()
        let l = CloudProvider(id: "l", displayName: "Left", imageName: "folder", rootPath: left.path, type: .iCloud)
        let r = CloudProvider(id: "r", displayName: "Right", imageName: "folder", rootPath: right.path, type: .iCloud)
        await manager.scanDirectories(left: l, leftPath: left.path, right: r, rightPath: right.path)
        return (manager, base)
    }

    /// The root-level row the anchor tests render without a scan: the same shape `scannedManager`
    /// produces, so the two mounts differ only in the anchor.
    private func rootLevelRow() -> FileDifference {
        FileDifference(relativePath: "loose.pdf",
                       leftItemPath: "/left/loose.pdf", rightItemPath: "/right/loose.pdf",
                       type: .missingOnRight, action: .copyToRight,
                       description: "Missing on right", leftFileSize: 1)
    }

    /// The Path cell of `row`, rendered to PNG bytes: a SwiftUI cell exposes no readable text to
    /// AppKit, so the paint is what's compared.
    private func pathCellPNG(in host: NSView, row: Int) throws -> Data {
        let table = try #require(tableView(in: host))
        let column = try #require(table.tableColumns.firstIndex { $0.title == "Path" },
                                  "no Path column — titles were \(table.tableColumns.map(\.title))")
        let cell = try #require(table.view(atColumn: column, row: row, makeIfNecessary: true))
        let rep = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    // MARK: Tests

    /// A column dragged to a width nothing would choose keeps it across the grouping toggle, on
    /// the same table view.
    @Test(.machinePinned(.layoutMetrics)) func widthSurvivesTheGroupingToggle() async throws {
        let (host, window, store) = mount(grouped: false)
        defer { window.contentView = nil }

        let flat = await settle(host, atRows: 12)
        #expect(flat.rows == 12,
                "flat table settled at \(flat.rows) row(s) after \(flat.pumps) passes, not the 12 fixture rows — every later assertion would be vacuous")
        let table = try #require(tableView(in: host))
        let column = try #require(sizeColumn(of: table))

        // 213pt: not the ideal (90), the min (70), or a round number layout might land on by
        // chance, so if it survives, the column did.
        let dragged: CGFloat = 213
        #expect(dragged != Self.sizeColumnIdeal, "a dragged width equal to the ideal proves nothing")
        column.width = dragged
        host.layoutSubtreeIfNeeded()
        #expect(abs(column.width - dragged) < 0.5, "the fixture could not set the width it measures")

        store.set(true, forKey: "differencesGroupByFolder")
        let grouped = await settle(host, atRows: 15)
        #expect(grouped.rows == 15,
                "grouping toggle never took effect — settled at \(grouped.rows) row(s) after \(grouped.pumps) passes, not the 15 sectioned rows (12 + 3 headers)")

        let after = try #require(tableView(in: host))
        #expect(after === table, "the toggle swapped the NSTableView — the Table was rebuilt")
        let afterColumn = try #require(sizeColumn(of: after))
        #expect(abs(afterColumn.width - dragged) < 0.5,
                "dragged width became \(afterColumn.width) — the Table lost its identity")
    }

    /// The scroll position survives the toggle: same scroll view, still scrolled. Weaker than the
    /// column check on purpose, since grouping inserts header rows and the offset legitimately
    /// moves; what must not happen is the snap back to the top a rebuilt table does.
    @Test func scrollPositionSurvivesTheGroupingToggle() async throws {
        // 20 folders × 6 rows scrolls a 600pt viewport several times over, so the offset is far
        // from the bottom clamp.
        let many = differences(folders: (1...20).map { "Folder\($0)" }, perFolder: 6)
        let (host, window, store) = mount(grouped: false, rows: many)
        defer { window.contentView = nil }

        let flat = await settle(host, atRows: 120)
        #expect(flat.rows == 120, "expected 120 fixture rows, settled at \(flat.rows) after \(flat.pumps) passes")
        let scroller = try #require(scrollView(in: host))

        let offset: CGFloat = 400
        scroller.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroller.reflectScrolledClipView(scroller.contentView)
        host.layoutSubtreeIfNeeded()
        let scrolledTo = scroller.contentView.bounds.origin.y
        #expect(scrolledTo > 100, "the fixture could not scroll (landed at \(scrolledTo)) — nothing to preserve")

        store.set(true, forKey: "differencesGroupByFolder")
        let grouped = await settle(host, atRows: 140)
        #expect(grouped.rows == 140,
                "grouping toggle never took effect — settled at \(grouped.rows) row(s) after \(grouped.pumps) passes, not the 140 sectioned rows (120 + 20 headers)")

        let after = try #require(scrollView(in: host))
        #expect(after === scroller, "the toggle swapped the NSScrollView — the Table was rebuilt")
        let afterOffset = after.contentView.bounds.origin.y
        #expect(afterOffset > 100, "list snapped back to \(afterOffset) — scroll position was lost")
    }

    /// Guards the fixture: the toggle must change what is drawn (a header row per folder), or the
    /// identity checks would only show that an untouched table keeps its columns.
    @Test func togglingGroupingChangesTheRowShape() async throws {
        let (host, window, store) = mount(grouped: false)
        defer { window.contentView = nil }

        let flat = await settle(host, atRows: 12)
        #expect(flat.rows == 12, "expected the 12 fixture rows, settled at \(flat.rows) after \(flat.pumps) passes")

        store.set(true, forKey: "differencesGroupByFolder")
        let grouped = await settle(host, atRows: 15)
        #expect(grouped.rows > flat.rows,
                "grouped settled at \(grouped.rows) rows vs flat \(flat.rows) — fixture is not clearing isWorthGrouping")
    }

    /// Both row shapes accept selection, which the context menu and the copy shortcuts act on.
    ///
    /// `selectionHighlightStyle` is `.none` on purpose: `DifferencesTableSelectionStyler` replaces
    /// the OS highlight with the accent wash, and `.none` suppresses only AppKit's drawing, not the
    /// selection. Waiting for `.none` first shows the styler reached this table.
    @Test func bothRowShapesAcceptSelection() async throws {
        for grouped in [false, true] {
            let (host, window, _) = mount(grouped: grouped)
            defer { window.contentView = nil }

            let expected = grouped ? 15 : 12
            let settled = await settle(host, atRows: expected)
            #expect(settled.rows == expected,
                    "grouped=\(grouped) settled at \(settled.rows) row(s) after \(settled.pumps) passes, expected \(expected)")
            let table = try #require(tableView(in: host))
            let styled = await wait(host, for: { table.selectionHighlightStyle == .none })
            #expect(styled.held,
                    "grouped=\(grouped): the wash styler never reached the table after \(styled.pumps) passes")

            // Row 0 is a section header in the grouped shape, so reach past it for a data row.
            let target = grouped ? 1 : 0
            table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            let selected = await wait(host, for: { table.selectedRowIndexes.contains(target) }, timeout: 2)
            #expect(selected.held,
                    "grouped=\(grouped): row \(target) would not select after \(selected.pumps) passes")
        }
    }

    /// The selected row wears the panes' accent wash, hue and strength, and sheds it on
    /// deselection. `.none` without the wash would leave selection invisible, which no
    /// selection-binding check could tell apart, so the wash view's presence and color are checked.
    @Test func selectedRowsWearTheAccentWash() async throws {
        let (host, window, _) = mount(grouped: false)
        defer { window.contentView = nil }

        let settled = await settle(host, atRows: 12)
        #expect(settled.rows == 12,
                "settled at \(settled.rows) row(s) after \(settled.pumps) passes, not the 12 fixture rows")
        let table = try #require(tableView(in: host))
        let styled = await wait(host, for: { table.selectionHighlightStyle == .none })
        #expect(styled.held, "the wash styler never reached the table after \(styled.pumps) passes")

        func wash(row: Int) -> SelectionWashView? {
            table.rowView(atRow: row, makeIfNecessary: false)?
                .subviews.compactMap { $0 as? SelectionWashView }.first
        }

        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        let washed = await wait(host, for: { wash(row: 2) != nil }, timeout: 5)
        #expect(washed.held, "no wash appeared on the selected row after \(washed.pumps) passes")
        #expect(wash(row: 3) == nil, "an unselected row is wearing the selection wash")

        // The exact wash the panes draw: the app accent (blue — the scratch store carries no hue
        // override) at the active pane strength. Compared component-wise in sRGB because both
        // sides are dynamic colors.
        let painted = try #require(wash(row: 2)?.color.usingColorSpace(.sRGB))
        let expected = try #require(NSColor(LiquidGlassHue.blue.accentColor)
            .withAlphaComponent(PaneSelectionWash.active).usingColorSpace(.sRGB))
        for (name, a, b) in [("red", painted.redComponent, expected.redComponent),
                             ("green", painted.greenComponent, expected.greenComponent),
                             ("blue", painted.blueComponent, expected.blueComponent),
                             ("alpha", painted.alphaComponent, expected.alphaComponent)] {
            #expect(abs(a - b) < 0.02, "wash \(name) is \(a), the panes' wash is \(b)")
        }

        // Deselection must take the wash with it, or every visited row stays painted.
        table.selectRowIndexes(IndexSet(), byExtendingSelection: false)
        let cleared = await wait(host, for: { wash(row: 2) == nil }, timeout: 5)
        #expect(cleared.held, "the wash outlived its selection after \(cleared.pumps) passes")
    }

    /// `DifferencesView` feeds the scanned root anchor into the Path cells: the seam the pure
    /// `pathColumnText`, cell snapshot and Sync capture tests all miss. Dropping
    /// `rootName: pathRootName` at the call site must fail this. One mount anchored by a real scan
    /// ("Home"), one with none ("Top level"); the cells must differ, so blank renders would fail.
    @Test func pathCellsRenderTheScannedRootAnchor() async throws {
        let scanned = try await scannedManager(leftFolder: "Home", rightFolder: "Home")
        defer { try? FileManager.default.removeItem(at: scanned.cleanup) }
        #expect(scanned.manager.differences.count == 1,
                "the real scan found \(scanned.manager.differences.count) difference(s), not the 1 fixture file")

        let (hostA, windowA, _) = mount(grouped: false, manager: scanned.manager)
        defer { windowA.contentView = nil }
        let settledA = await settle(hostA, atRows: 1)
        #expect(settledA.rows == 1, "anchored mount settled at \(settledA.rows) after \(settledA.pumps) passes")
        let anchored = try pathCellPNG(in: hostA, row: 0)

        let (hostB, windowB, _) = mount(grouped: false, rows: [rootLevelRow()])
        defer { windowB.contentView = nil }
        let settledB = await settle(hostB, atRows: 1)
        #expect(settledB.rows == 1, "fallback mount settled at \(settledB.rows) after \(settledB.pumps) passes")
        let fallback = try pathCellPNG(in: hostB, row: 0)

        #expect(anchored != fallback,
                "the Path cell rendered identically with and without a scanned root anchor — the view is not feeding lastScanRootNames into the cells")
    }

    /// The review table uses the session's frozen anchor, not the live scan's: the queue is a
    /// snapshot (it doubles as a receipt), so a mid-review rescan must not relabel it. The live
    /// anchor is nil in both mounts, so only the frozen one can make the cells differ. Also pins
    /// the review table's five columns.
    @Test func reviewTableRendersItsFrozenPathAnchor() async throws {
        var pngs: [Data] = []
        for anchor in ["Home", nil] {
            let row = rootLevelRow()
            let reviewStore = ReviewSessionStore()
            reviewStore.session = try #require(
                ReviewSession(queue: [row], isMove: false, pathRootName: anchor))
            // The manager holds NO differences and NO scan: review renders from the frozen queue.
            let manager = FileSyncManager()
            manager.hasScanned = true
            let (host, window, _) = mount(grouped: false, manager: manager, reviewStore: reviewStore)
            defer { window.contentView = nil }
            let settled = await settle(host, atRows: 1)
            #expect(settled.rows == 1,
                    "review mount (anchor \(anchor ?? "nil")) settled at \(settled.rows) after \(settled.pumps) passes")
            let table = try #require(tableView(in: host))
            #expect(table.tableColumns.map(\.title) == ["Name", "Change", "Path", "Size", "Status"],
                    "review columns were \(table.tableColumns.map(\.title))")
            pngs.append(try pathCellPNG(in: host, row: 0))
        }
        #expect(pngs[0] != pngs[1],
                "the review Path cell ignored the session's frozen anchor — with the live anchor nil in both mounts, only session.pathRootName could make these differ")
    }

    /// Equal root names anchor; differing ones don't, since either name would misname the other
    /// side. Driven through real scans, so the gate sees state the real publish creates.
    @Test func pathRootNameAnchorsOnlyMatchingRoots() async throws {
        let matching = try await scannedManager(leftFolder: "Home", rightFolder: "Home")
        defer { try? FileManager.default.removeItem(at: matching.cleanup) }
        #expect(DifferencesView(syncManager: matching.manager, reviewStore: ReviewSessionStore())
            .pathRootName == "Home")

        let differing = try await scannedManager(leftFolder: "Home", rightFolder: "Backup")
        defer { try? FileManager.default.removeItem(at: differing.cleanup) }
        #expect(DifferencesView(syncManager: differing.manager, reviewStore: ReviewSessionStore())
            .pathRootName == nil,
                "Home vs Backup anchored anyway — the equality gate is not being consulted")
    }

    /// Both shapes show the same four columns in the same order. This pins titles and order only,
    /// all an NSTableView tells from outside; cell content can't drift between shapes because the
    /// columns are declared once.
    @Test func bothRowShapesDrawTheSameColumns() async throws {
        var seen: [[String]] = []
        for grouped in [false, true] {
            let (host, window, _) = mount(grouped: grouped)
            defer { window.contentView = nil }

            let expected = grouped ? 15 : 12
            let settled = await settle(host, atRows: expected)
            #expect(settled.rows == expected,
                    "grouped=\(grouped) settled at \(settled.rows) row(s) after \(settled.pumps) passes, expected \(expected)")
            seen.append(try #require(tableView(in: host)).tableColumns.map(\.title))
        }
        #expect(seen[0] == ["Name", "Change", "Path", "Size"], "flat columns were \(seen[0])")
        #expect(seen[0] == seen[1], "grouped drew \(seen[1]), flat drew \(seen[0])")
    }
}
