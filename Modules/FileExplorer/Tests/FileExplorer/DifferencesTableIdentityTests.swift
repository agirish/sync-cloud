import AppKit
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
/// Two things this harness learned the hard way, both worth keeping:
/// - The tests are `async` and wait with `Task.sleep`, never by spinning `RunLoop.run`. The rows
///   arrive from a `.task(id:)` hop on the MainActor, and a synchronous runloop spin from a
///   `@MainActor` test starves the very task it is waiting for — the table sits at zero rows
///   until the timeout and every assertion downstream reads as a product failure.
/// - The window is never ordered in. `.task` fires without it, and this machine's owner drives
///   the real app while these run.
///
/// `.serialized`, and it drives `UserDefaults.standard` (what `@AppStorage` reads): the grouping
/// preference is process-global, so two of these in flight would fight over it. That is the test
/// process's own defaults domain, never the shipping app's.
///
/// `.serialized` alone was not enough once a second suite arrived — it orders cases within a suite
/// while swift-testing runs suites in parallel, so `FoldAllToggleBindingTests` and this one read
/// each other's preference and both failed. `.exclusiveGroupingPreference` is the gate that fixes
/// it; see that trait for the full account.
@MainActor
@Suite(.serialized, .exclusiveGroupingPreference) struct DifferencesTableIdentityTests {

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
    private func mount(grouped: Bool,
                       rows: [FileDifference]? = nil) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        UserDefaults.standard.set(grouped, forKey: "differencesGroupByFolder")
        let manager = FileSyncManager()
        manager.differences = rows ?? differences()
        manager.hasScanned = true

        let view = DifferencesView(syncManager: manager, reviewStore: ReviewSessionStore())
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 600)

        // A real (never ordered-in) window: an NSTableView only lays its columns out inside one.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    // MARK: Waiting + hierarchy helpers

    /// Waits until `condition` holds, and REPORTS whether it did.
    ///
    /// Every caller must assert on the return value. The rows arrive asynchronously, so a test
    /// that waited a while and then asserted would pass vacuously the day the rows stopped
    /// arriving — there would be nothing on screen to contradict it.
    private func wait(for condition: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
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

    // MARK: Tests

    /// The load-bearing one. Drag a column to a width nothing would choose on its own, flip the
    /// grouping preference, and the width is still there — on the same table view.
    @Test func widthSurvivesTheGroupingToggle() async throws {
        let (host, window) = mount(grouped: false)
        defer { window.contentView = nil }

        #expect(await wait(for: { (self.tableView(in: host)?.numberOfRows ?? 0) > 0 }),
                "flat table never produced rows — every later assertion would be vacuous")
        let table = try #require(tableView(in: host))
        let flatRows = table.numberOfRows
        let column = try #require(sizeColumn(of: table))

        // 213pt: not the ideal (90), not the min (70), not a round number the layout might land on
        // by coincidence. If this value survives, it survived because the column did.
        let dragged: CGFloat = 213
        #expect(dragged != Self.sizeColumnIdeal, "a dragged width equal to the ideal proves nothing")
        column.width = dragged
        host.layoutSubtreeIfNeeded()
        #expect(abs(column.width - dragged) < 0.5, "the fixture could not set the width it measures")

        UserDefaults.standard.set(true, forKey: "differencesGroupByFolder")
        #expect(await wait(for: { (self.tableView(in: host)?.numberOfRows ?? 0) != flatRows }),
                "grouping toggle never took effect — the toggle under test did not happen")

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
        let (host, window) = mount(grouped: false, rows: many)
        defer { window.contentView = nil }

        #expect(await wait(for: { (self.tableView(in: host)?.numberOfRows ?? 0) > 0 }),
                "flat table never produced rows")
        let table = try #require(tableView(in: host))
        let scroller = try #require(scrollView(in: host))
        let flatRows = table.numberOfRows
        #expect(flatRows == 120, "expected 120 fixture rows, drew \(flatRows)")

        let offset: CGFloat = 400
        scroller.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroller.reflectScrolledClipView(scroller.contentView)
        host.layoutSubtreeIfNeeded()
        let scrolledTo = scroller.contentView.bounds.origin.y
        #expect(scrolledTo > 100, "the fixture could not scroll (landed at \(scrolledTo)) — nothing to preserve")

        UserDefaults.standard.set(true, forKey: "differencesGroupByFolder")
        #expect(await wait(for: { (self.tableView(in: host)?.numberOfRows ?? 0) != flatRows }),
                "grouping toggle never took effect")

        let after = try #require(scrollView(in: host))
        #expect(after === scroller, "the toggle swapped the NSScrollView — the Table was rebuilt")
        let afterOffset = after.contentView.bounds.origin.y
        #expect(afterOffset > 100, "list snapped back to \(afterOffset) — scroll position was lost")
    }

    /// Guards the fixture, not the product: the toggle must actually change what is drawn, or the
    /// identity assertion above would prove nothing more than that an untouched table keeps its
    /// columns. Grouped adds one header row per folder, so the row count must rise.
    @Test func togglingGroupingChangesTheRowShape() async throws {
        let (host, window) = mount(grouped: false)
        defer { window.contentView = nil }

        #expect(await wait(for: { (self.tableView(in: host)?.numberOfRows ?? 0) > 0 }))
        let flatRows = try #require(tableView(in: host)).numberOfRows
        #expect(flatRows == 12, "expected the 12 fixture rows, drew \(flatRows)")

        UserDefaults.standard.set(true, forKey: "differencesGroupByFolder")
        let grew = await wait(for: { (self.tableView(in: host)?.numberOfRows ?? 0) > flatRows })
        let groupedRows = tableView(in: host)?.numberOfRows ?? -1
        #expect(grew, "grouped drew \(groupedRows) rows vs flat \(flatRows) — fixture is not clearing isWorthGrouping")
    }

    /// Both row shapes must reach the same selection binding. `contextMenu(forSelectionType:)` and
    /// the ⌘←/⌘→ copy shortcut hang off that binding, and the review flagged them as "under
    /// suspicion of not binding through" the enclosing `Group` the two Tables sat in. That Group
    /// is gone — the modifiers now attach to the Table itself — and this keeps both shapes honest.
    @Test func bothRowShapesAcceptSelection() async throws {
        for grouped in [false, true] {
            let (host, window) = mount(grouped: grouped)
            defer { window.contentView = nil }

            #expect(await wait(for: { (self.tableView(in: host)?.numberOfRows ?? 0) > 0 }),
                    "grouped=\(grouped) produced no rows")
            let table = try #require(tableView(in: host))
            #expect(table.selectionHighlightStyle != .none, "grouped=\(grouped): table is not selectable")

            // Row 0 is a section header in the grouped shape, so reach past it for a data row.
            let target = grouped ? 1 : 0
            table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            #expect(await wait(for: { table.selectedRowIndexes.contains(target) }, timeout: 2),
                    "grouped=\(grouped): row \(target) would not select")
        }
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
            let (host, window) = mount(grouped: grouped)
            defer { window.contentView = nil }

            #expect(await wait(for: { (self.tableView(in: host)?.numberOfRows ?? 0) > 0 }),
                    "grouped=\(grouped) produced no rows")
            seen.append(try #require(tableView(in: host)).tableColumns.map(\.title))
        }
        #expect(seen[0] == ["Name", "Change", "Size", "Copy to"], "flat columns were \(seen[0])")
        #expect(seen[0] == seen[1], "grouped drew \(seen[1]), flat drew \(seen[0])")
    }
}
