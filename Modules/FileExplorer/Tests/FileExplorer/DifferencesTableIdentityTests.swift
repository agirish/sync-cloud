import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// Pins the ONE property that made `standardTableSection` collapse its two Tables into one: the
/// differences table must keep its AppKit identity across a "Group by folder" toggle.
///
/// Why this is measured against a real `NSTableView` rather than asserted about the SwiftUI tree:
/// the thing at stake — a dragged column width — lives in `NSTableColumn.width`, and SwiftUI
/// exposes no way to ask "is this the same Table you had before?". The observable consequence IS
/// the test. When this was two Tables behind an `if` (a collection initializer for the flat form,
/// a rows-builder initializer for the sectioned one) the toggle swapped one view identity for
/// another, AppKit tore the old table view down, and every width the user had dragged reset.
///
/// Mutation-tested by restoring that two-Table form: `widthSurvivesTheGroupingToggle` fails on
/// `the toggle swapped the NSTableView`, and `togglingGroupingChangesTheRowShape` still passes —
/// i.e. the suite fails for the identity reason it exists for, not because the toggle broke.
///
/// Three things this harness learned the hard way, all worth keeping:
/// - The tests are `async` and wait with `Task.sleep`, never by spinning `RunLoop.run`. The rows
///   arrive from a `.task(id:)` hop on the MainActor, and a synchronous runloop spin from a
///   `@MainActor` test starves the very task it is waiting for — the table sits at zero rows
///   until the timeout and every assertion downstream reads as a product failure.
/// - The window is never ordered in. `.task` fires without it, and this machine's owner drives
///   the real app while these run.
/// - Mount waits target the EXACT settled row count, never `rows > 0`. Row materialization is
///   async, so a wait that latches the first non-empty count certifies whatever shape happened
///   to render first — under six CPU loaders that was ~4-in-10 full-suite failures on
///   2026-07-28, "flat" mounts drawing 15 and 140 rows.
///
/// Every mount reads its preferences from its own `ScratchDefaults` suite via
/// `.defaultAppStorage`, never from `UserDefaults.standard`. The standard domain made the
/// grouping key process-global state, and no discipline over it survived contact with SwiftUI:
/// suite-level serialization (`.exclusiveGroupingPreference`, now deleted) still lost to
/// `@AppStorage`'s process-wide storage location for the (store, key) pair, which outlives every
/// view that used it and can re-attach to a fresh view WITHOUT re-reading the defaults — a
/// loaded run showed a mount rendering grouped for 15 straight seconds while the plist said
/// flat, healed only by the NEXT test's writes. A scratch store sidesteps the cache entirely:
/// the location is created by this mount's first render, reads a value this test seeded, and no
/// other suite can touch it. `.serialized` orders the cases here; `.oneMountedDifferencesTable`
/// keeps this suite's mounts — the priciest main-actor jobs in the target — from stacking on
/// top of the other mounting suites' and starving everyone else's runloop-hop deadlines (that
/// trait has the numbers).
@MainActor
@Suite(.serialized, .oneMountedDifferencesTable) struct DifferencesTableIdentityTests {

    /// The Size column's declared ideal, from `standardTableSection`. The dragged width asserted
    /// below must not be this, or "the width survived" and "the column was rebuilt and re-derived
    /// its ideal" would look identical.
    private static let sizeColumnIdeal: CGFloat = 90

    // MARK: Fixture

    /// Three folders of four rows each. Comfortably clears `isWorthGrouping` (sections must
    /// average >= 3 rows), so the grouped form really does draw sections and the toggle really
    /// does change the row shape — a fixture that silently failed that gate would make the
    /// identity assertion vacuous, which is why `togglingGroupingChangesTheRowShape` checks it.
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

    /// Mounts the real `DifferencesView` — not a lookalike. A harness that rebuilt "a Table shaped
    /// like the production one" would keep passing after the production one regressed.
    ///
    /// The view reads its preferences from a fresh `ScratchDefaults` suite (see the suite doc),
    /// seeded BEFORE the view exists so the storage location `@AppStorage` creates on first
    /// render is born holding this test's value — there is no window in which a stale or foreign
    /// value can be latched. Mid-test toggles write to the returned `store`, whose location has
    /// been live and observing since that first render.
    private func mount(grouped: Bool,
                       rows: [FileDifference]? = nil,
                       manager externalManager: FileSyncManager? = nil,
                       reviewStore: ReviewSessionStore = ReviewSessionStore())
        -> (host: NSHostingView<AnyView>, window: NSWindow, store: UserDefaults) {
        let store = ScratchDefaults("DifferencesTableIdentityTests")
        store.set(grouped, forKey: "differencesGroupByFolder")
        // An external manager arrives with its state already scanned in (the path-anchor tests
        // need `lastScanRootNames` captured by the production publish, not poked); the default
        // one gets the fixture rows directly.
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

    /// Waits until `condition` holds, and REPORTS whether it did.
    ///
    /// Every caller must assert on the return value. The rows arrive asynchronously, so a test
    /// that waited a while and then asserted would pass vacuously the day the rows stopped
    /// arriving — there would be nothing on screen to contradict it.
    ///
    /// Pumps `host` rather than merely sleeping, and is bounded by `LayoutPumpWait`'s pass floor
    /// as well as by its deadline — see `settle` below for why seconds are the wrong unit.
    private func wait(_ host: NSView, for condition: () -> Bool,
                      timeout: TimeInterval = 5) async -> (held: Bool, pumps: Int) {
        await LayoutPumpWait.pump(host, upTo: timeout, until: condition)
    }

    /// Waits for the table to settle at EXACTLY `expected` rows, and reports the last count seen.
    ///
    /// `rows > 0` is not a settle signal here: the rows and the grouping toggle both land
    /// asynchronously, so a wait that latches the first non-empty count certifies whatever shape
    /// happened to render first rather than the one under test. The count is returned rather
    /// than asserted so each caller's failure message can name the mount it was measuring; on
    /// timeout that is the count actually on screen, not a nil — the same shape as
    /// `SectionRowHeightTests.rowHeights`.
    ///
    /// **Bounded by `LayoutPumpWait`'s pass floor, not by the deadline alone, and it reports the
    /// passes.** The 15s deadline was sized for a machine under deliberate CPU load, on the
    /// assumption that a loaded machine needs more seconds. It needs more main-actor TURNS, and a
    /// congested full-package run delivers fewer of them per second — this suite gave up at 0 rows
    /// twice in seven runs on 2026-08-04, alongside newly landed mounted-view suites, which is
    /// mechanism 2 with nothing else in it. The pass count is the diagnosis: giving up after the
    /// floor's 50 means starved, after a thousand means genuinely disproved, and elapsed time
    /// cannot tell those apart because both spend the whole deadline.
    /// See `docs/flaky-tests.md`, mechanism 2.
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

    /// The scroll view the table actually scrolls in — its own enclosing one, not the first
    /// `NSScrollView` in the hierarchy, which could be some other scroller entirely.
    private func scrollView(in view: NSView) -> NSScrollView? {
        tableView(in: view)?.enclosingScrollView
    }

    /// Found by title, not by index — an index would silently start measuring a different column
    /// if one were ever inserted before it.
    private func sizeColumn(of table: NSTableView) -> NSTableColumn? {
        table.tableColumns.first { $0.title == "Size" || $0.headerCell.stringValue == "Size" }
    }

    // MARK: Path-anchor helpers

    /// A manager whose `lastScanRootNames` was captured by the PRODUCTION publish path: two real
    /// temp folders, scanned through the public API. Poking the internal tuple would test a state
    /// no production code can reach; a scan of `Home` vs `Home` is the state the anchor exists for.
    /// The left folder holds one root-level file, so the diff is a single row whose Path cell is
    /// exactly the case that used to render as nothing.
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
        let l = CloudProvider(id: "l", displayName: "Left", imageName: "folder", path: left.path, type: .iCloud)
        let r = CloudProvider(id: "r", displayName: "Right", imageName: "folder", path: right.path, type: .iCloud)
        await manager.scanDirectories(left: l, leftPath: left.path, right: r, rightPath: right.path)
        return (manager, base)
    }

    /// The single root-level fixture row the anchor tests render without a scan — the same shape
    /// `scannedManager`'s diff produces, so the two mounts differ ONLY in the anchor.
    private func rootLevelRow() -> FileDifference {
        FileDifference(relativePath: "loose.pdf",
                       leftItemPath: "/left/loose.pdf", rightItemPath: "/right/loose.pdf",
                       type: .missingOnRight, action: .copyToRight,
                       description: "Missing on right", leftFileSize: 1)
    }

    /// The Path cell of `row`, rendered to PNG bytes. Pixels, not view introspection: a SwiftUI
    /// cell exposes no readable text from AppKit, and what the user sees IS the paint.
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

    /// The load-bearing one. Drag a column to a width nothing would choose on its own, flip the
    /// grouping preference, and the width is still there — on the same table view.
    @Test func widthSurvivesTheGroupingToggle() async throws {
        let (host, window, store) = mount(grouped: false)
        defer { window.contentView = nil }

        let flat = await settle(host, atRows: 12)
        #expect(flat.rows == 12,
                "flat table settled at \(flat.rows) row(s) after \(flat.pumps) passes, not the 12 fixture rows — every later assertion would be vacuous")
        let table = try #require(tableView(in: host))
        let column = try #require(sizeColumn(of: table))

        // 213pt: not the ideal (90), not the min (70), not a round number the layout might land on
        // by coincidence. If this value survives, it survived because the column did.
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

    /// The other half of what a torn-down Table costs: scroll position.
    ///
    /// The claim here is deliberately weaker than the column one, because the strong version is
    /// false by construction — grouping inserts a header row per folder, so the row under a given
    /// offset genuinely moves and demanding an unchanged offset would be demanding the wrong
    /// thing. What must not happen is the list SNAPPING BACK TO THE TOP, which is what a rebuilt
    /// table does and what the user actually loses. So: same scroll view, still scrolled.
    @Test func scrollPositionSurvivesTheGroupingToggle() async throws {
        // 20 folders × 6 rows: enough content to scroll a 600pt viewport several times over, so
        // the offset below is nowhere near the clamp at the bottom of a short list.
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

    /// Guards the fixture, not the product: the toggle must actually change what is drawn, or the
    /// identity assertion above would prove nothing more than that an untouched table keeps its
    /// columns. Grouped adds one header row per folder, so the row count must rise.
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

    /// Both row shapes must reach the same selection binding. `contextMenu(forSelectionType:)` and
    /// the ⌘←/⌘→ copy shortcut hang off that binding, and the review flagged them as "under
    /// suspicion of not binding through" the enclosing `Group` the two Tables sat in. That Group
    /// is gone — the modifiers now attach to the Table itself — and this keeps both shapes honest.
    ///
    /// Selectability used to be pinned by `selectionHighlightStyle != .none`. That is now the
    /// WRONG sign: `DifferencesTableSelectionStyler` deliberately sets `.none` (the OS highlight
    /// is replaced by the accent wash, as in the panes), and `.none` only suppresses AppKit's
    /// selection DRAWING — the selection itself, asserted below by the row actually selecting,
    /// is untouched. Waiting for `.none` first also proves the styler resolved this table.
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

    /// The selected row wears the panes' accent wash — hue and strength — and sheds it on
    /// deselection. This is the user-visible half of what replacing the OS highlight bought:
    /// `.none` alone would leave selection INVISIBLE, which no count of green selection-binding
    /// assertions could distinguish from styled (see the memory of asserting the container, not
    /// the outcome — the wash view's presence and color are the outcome here).
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

    /// The seam every pure test stops short of: DifferencesView must actually FEED the captured
    /// scan-root anchor into the Path cells. `pathColumnText` is tested pure, the cell is
    /// snapshot-tested with an anchor passed BY THE TEST, and the manager's capture is pinned in
    /// Sync — but severing `rootName: pathRootName` at the call site left all of them green
    /// (measured before this test existed). So: one mount whose anchor came through a real scan
    /// ("Home"), one with no scan (fallback "Top level"), and the rendered Path cell must differ.
    /// Self-detecting against a blind harness: if offscreen cell rendering ever produced nothing,
    /// both PNGs would be equal blanks and the test would FAIL, not pass vacuously.
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

    /// The review table's anchor must be the SESSION's frozen one, not the live scan's. The
    /// queue is a snapshot (it doubles as a receipt), so a mid-review rescan of different
    /// folders must not relabel the frozen rows — here the live anchor is nil in BOTH mounts,
    /// and only the session's differs, so any difference in the rendered cell can have come
    /// from the frozen anchor alone. Also pins the review table's five columns.
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

    /// The anchor policy itself: equal root names anchor, differing ones must NOT — either name
    /// would misname the other side. Driven through real scans so the gate is exercised against
    /// state the production publish actually creates.
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

    /// The four columns are declared once now, so both shapes must show the same four in the same
    /// order. They used to be duplicated verbatim across the two branches with nothing pinning
    /// them identical.
    ///
    /// Scope, stated honestly: this pins column TITLES and order, which is all an NSTableView will
    /// tell you from outside. It would not have caught the drift the duplication actually produced
    /// — the Name column passing `grouped: true` in one branch and defaulting in the other, a
    /// difference in cell CONTENT. That one is now unrepresentable rather than tested: there is a
    /// single Name column reading a single `grouped` binding, so there is no second place to
    /// disagree. `DifferenceGroupingTests.testPathWithinSection…` covers what the flag then does.
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
