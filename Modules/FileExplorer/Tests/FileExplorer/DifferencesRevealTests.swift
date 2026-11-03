import AppKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// Ask Claude's `differences` tool with `show: true` selects rows in Compare (TE261), and the table
/// scrolls to them (TE295). It used to only select, so rows below the fold looked unselected and
/// nothing seemed to happen.
///
/// The mounted cases read the backing `NSTableView`'s visible rows rather than anything drawn:
/// offscreen tables paint no cell text, but they do lay out and scroll. "The first selected row"
/// is the table's own lowest selected index, so the check does not lean on the rule it tests.
@MainActor
@Suite(.serialized, .oneMountedDifferencesTable) struct DifferencesRevealTests {

    // MARK: Which row

    /// Grouped, display order is section by section, and a sort can put a later section's row
    /// first in `sorted`. Here `sorted` leads with Beta's row, but Alpha's section comes first.
    @Test func groupedTablesRevealTheFirstRowOfTheFirstSectionHoldingOne() {
        let alphaBig = Self.row("Alpha/a-1.txt")
        let betaHuge = Self.row("Beta/b-1.txt")
        let alphaSmall = Self.row("Alpha/a-2.txt")
        let sorted = [alphaBig, betaHuge, alphaSmall]
        let sections = DifferenceGrouping.sections(sorted)
        let picked: Set<UUID> = [betaHuge.id, alphaSmall.id]
        #expect(DifferenceGrouping.firstShown(of: picked, sorted: sorted, sections: sections)?.id
                == alphaSmall.id)
        // Flat, it is the first selected row of `sorted`.
        #expect(DifferenceGrouping.firstShown(of: picked, sorted: sorted, sections: [])?.id
                == betaHuge.id)
        #expect(DifferenceGrouping.firstShown(of: [UUID()], sorted: sorted, sections: sections) == nil)
    }

    // MARK: The scroll

    /// On screen, with the filter changing under the request: the rows Claude picked are not in
    /// the table until `show`'s filter applies. Two rows, so a scroll to the second one fails.
    @Test func showScrollsToTheFirstSelectedRowAfterTheFilterApplies() async throws {
        let mounted = Self.mount(filter: .missingOnRight)
        defer { mounted.window.contentView = nil }
        let atTop = await LayoutPumpWait.pump(mounted.host, upTo: 15) {
            (mounted.table()?.numberOfRows ?? 0) > 40
        }
        try #require(atTop.held, "the table never filled")
        let table = try #require(mounted.table())
        let topRows = table.rows(in: table.visibleRect)

        mounted.session.show(.missingOnLeft, selecting: [mounted.ids["delta-30"]!, mounted.ids["charlie-25"]!])

        let shown = await Self.waitForFirstSelectedOnScreen(mounted)
        #expect(shown.held, "first selected row \(shown.row) never came into view")
        // It was a scroll: the row would not have been on the screen the table opened on.
        #expect(!NSLocationInRange(shown.row, topRows))
        #expect(shown.row > 20)
        // And to the middle, where the rows after it show too, not just onto the bottom edge.
        let visible = table.rows(in: table.visibleRect)
        let middle = Double(visible.location) + Double(visible.length - 1) / 2
        #expect(abs(Double(shown.row) - middle) <= 2, "row \(shown.row) in \(visible)")
    }

    /// Grouped, the scroll goes to the first selected row the table DRAWS, and a Size sort makes
    /// that a different row from the first one sorted. Delta's biggest file puts its section
    /// first, so Delta's selected row draws 40 rows above Charlie's, which sorts before it.
    @Test func groupedTablesScrollToTheFirstRowDrawnNotTheFirstSorted() async throws {
        let rows = ["Charlie", "Delta"].flatMap { folder in
            (1...40).map { index in
                Self.row("\(folder)/\(folder.lowercased())-\(String(format: "%02d", index)).txt", onlyRight: true,
                         size: ["delta-01": 1000, "charlie-01": 999, "delta-02": 998][
                             "\(folder.lowercased())-\(String(format: "%02d", index))"] ?? 10)
            }
        }
        let session = DifferencesSession()
        session.sortOrder = [KeyPathComparator(\FileDifference.displaySizeSort, order: .reverse)]
        let mounted = Self.mount(rows: rows, filter: .missingOnLeft, session: session)
        defer { mounted.window.contentView = nil }
        let filled = await LayoutPumpWait.pump(mounted.host, upTo: 15) {
            (mounted.table()?.numberOfRows ?? 0) == 82
        }
        try #require(filled.held, "the table never drew both sections")
        let table = try #require(mounted.table())
        table.scrollRowToVisible(table.numberOfRows - 1)
        try #require(!NSLocationInRange(2, table.rows(in: table.visibleRect)))

        mounted.session.show(.missingOnLeft, selecting: [mounted.ids["charlie-01"]!, mounted.ids["delta-02"]!])

        let shown = await Self.waitForFirstSelectedOnScreen(mounted)
        #expect(shown.row == 2, "Delta's header, delta-01, then the row asked for")
        #expect(shown.held, "first drawn selected row \(shown.row) never came into view")
    }

    /// `show` opens Compare, so the request usually lands before the table exists.
    @Test func aRequestMadeBeforeTheTableMountsStillScrolls() async {
        let session = DifferencesSession()
        let rows = Self.fixture()
        session.show(.missingOnLeft, selecting: [rows.first { $0.fileName == "delta-30.txt" }!.id])
        let mounted = Self.mount(rows: rows, session: session)
        defer { mounted.window.contentView = nil }

        let shown = await Self.waitForFirstSelectedOnScreen(mounted)
        #expect(shown.held, "first selected row \(shown.row) never came into view")
        #expect(shown.row > 20)
    }

    /// Collapsed to its bar, Compare has no table, and a request used to change nothing anyone
    /// could see. It opens the bar, and the table that mounts shows the rows selected and scrolled
    /// to. The collapsed table is confirmed absent first, so the pane opening is what drew it.
    ///
    /// The filter asked for is the one already showing, so the rows are current before the table
    /// exists and the reveal is due the moment it mounts — the case only `initial: true` answers.
    @Test func aRequestOpensComparesCollapsedBarAndScrolls() async throws {
        let pane = PaneCollapse(true)
        let mounted = Self.mount(filter: .missingOnLeft, collapse: pane)
        defer { mounted.window.contentView = nil }
        // Ample for the rows' pass, which takes milliseconds: they are built before the table is.
        _ = await LayoutPumpWait.pump(mounted.host, upTo: 1) { false }
        try #require(mounted.table() == nil, "a collapsed Compare still drew its table")

        mounted.session.show(.missingOnLeft, selecting: [mounted.ids["delta-30"]!])
        let shown = await Self.waitForFirstSelectedOnScreen(mounted)
        #expect(!pane.isCollapsed)
        #expect(shown.held, "first selected row \(shown.row) never came into view")
        #expect(shown.row > 20)
    }

    /// A review takes the list's place, and the host refuses `show` while one runs. A request
    /// that reaches the view anyway is dropped: when the review ends the pane goes back to its
    /// bar, as the review promised, and opening it shows nothing selected or scrolled to.
    @Test func aRequestDuringAReviewIsDropped() async throws {
        let pane = PaneCollapse(true)
        let rows = Self.fixture()
        let review = ReviewSessionStore()
        review.session = ReviewSession(queue: Array(rows.prefix(3)), isMove: false, pathRootName: nil)
        try #require(review.isReviewing)
        let mounted = Self.mount(rows: rows, filter: .missingOnLeft, collapse: pane, review: review)
        defer { mounted.window.contentView = nil }
        _ = await LayoutPumpWait.pump(mounted.host, upTo: 0.5) { false }

        mounted.session.show(.missingOnLeft, selecting: [mounted.ids["delta-30"]!])
        _ = await LayoutPumpWait.pump(mounted.host, upTo: 0.5) { false }
        #expect(pane.isCollapsed, "the request overwrote the preference the review is overriding")

        review.session = nil
        _ = await LayoutPumpWait.pump(mounted.host, upTo: 0.5) { false }
        #expect(mounted.table() == nil, "the pane did not go back to its bar")
        pane.isCollapsed = false
        let filled = await LayoutPumpWait.pump(mounted.host, upTo: 15) {
            (mounted.table()?.numberOfRows ?? 0) > 40
        }
        try #require(filled.held, "the reopened table never filled")
        _ = await LayoutPumpWait.pump(mounted.host, upTo: 0.6) { false }
        let table = try #require(mounted.table())
        #expect(table.selectedRowIndexes.isEmpty)
        #expect(NSLocationInRange(0, table.rows(in: table.visibleRect)))
    }

    /// A request is answered once. A republish of the rows after it — a bulk sync does one per
    /// file — must not drag the user back to it once they have scrolled away.
    @Test func aRevealIsSpentOnceAnswered() async throws {
        let mounted = Self.mount(filter: .all)
        defer { mounted.window.contentView = nil }
        mounted.session.show(.missingOnLeft, selecting: [mounted.ids["delta-30"]!])
        let shown = await Self.waitForFirstSelectedOnScreen(mounted)
        try #require(shown.held)
        // Past the reveal's retry, so the scroll home below is the last one.
        _ = await LayoutPumpWait.pump(mounted.host, upTo: 0.6) { false }

        let table = try #require(mounted.table())
        let clip = try #require(table.enclosingScrollView?.contentView)
        table.scroll(.zero)
        try #require(NSLocationInRange(0, table.rows(in: table.visibleRect)))
        mounted.manager.differences = mounted.manager.differences + [Self.row("Charlie/charlie-00.txt", onlyRight: true)]
        _ = await LayoutPumpWait.pump(mounted.host, upTo: 1) { false }

        #expect(clip.bounds.origin.y <= 0)
        #expect(!NSLocationInRange(shown.row, table.rows(in: table.visibleRect)))
    }

    // MARK: Fixture

    /// Four folders of forty. Alpha and Bravo are only on the left, Charlie and Delta only on the
    /// right; names sort folder by folder, so the sections come out Alpha → Delta.
    private static func fixture() -> [FileDifference] {
        [("Alpha", false), ("Bravo", false), ("Charlie", true), ("Delta", true)].flatMap { folder, right in
            (1...40).map { index in
                row("\(folder)/\(folder.lowercased())-\(String(format: "%02d", index)).txt", onlyRight: right)
            }
        }
    }

    private static func row(_ path: String, onlyRight: Bool = false, size: Int = 1024) -> FileDifference {
        FileDifference(relativePath: path,
                       leftItemPath: "/left/\(path)",
                       rightItemPath: "/right/\(path)",
                       type: onlyRight ? .missingOnLeft : .missingOnRight,
                       action: onlyRight ? .copyToLeft : .copyToRight,
                       description: "", leftFileSize: size, rightFileSize: size)
    }

    private struct Mounted {
        let window: NSWindow
        let host: NSView
        let manager: FileSyncManager
        let session: DifferencesSession
        /// Row ids by file name without its extension.
        let ids: [String: UUID]

        func table() -> NSTableView? { Self.find(in: host) }
        private static func find(in view: NSView) -> NSTableView? {
            if let found = view as? NSTableView { return found }
            for subview in view.subviews { if let found = find(in: subview) { return found } }
            return nil
        }
    }

    /// Compare's collapse, owned outside the view so a test can open the pane.
    private final class PaneCollapse: ObservableObject {
        @Published var isCollapsed: Bool
        init(_ isCollapsed: Bool) { self.isCollapsed = isCollapsed }
    }

    private struct CollapsibleCompare: View {
        @ObservedObject var pane: PaneCollapse
        let manager: FileSyncManager
        let session: DifferencesSession
        let reviewStore: ReviewSessionStore
        var body: some View {
            DifferencesView(syncManager: manager, reviewStore: reviewStore,
                            isCollapsed: $pane.isCollapsed, session: session)
        }
    }

    /// A 400pt-tall Compare: about a dozen rows show, so row 20 and below need a scroll.
    private static func mount(rows: [FileDifference] = fixture(), filter: DifferenceFilter? = nil,
                              session: DifferencesSession = DifferencesSession(),
                              collapse: PaneCollapse? = nil,
                              review: ReviewSessionStore = ReviewSessionStore()) -> Mounted {
        let store = ScratchDefaults("DifferencesRevealTests")
        store.set(true, forKey: "differencesGroupByFolder")
        if let filter { session.selectedFilter = filter }
        let manager = FileSyncManager()
        manager.differences = rows
        manager.hasScanned = true
        let compare = collapse.map {
            AnyView(CollapsibleCompare(pane: $0, manager: manager, session: session, reviewStore: review))
        } ?? AnyView(DifferencesView(syncManager: manager, reviewStore: review, session: session))
        let host = NSHostingView(rootView: AnyView(compare.defaultAppStorage(store)))
        // Held at its frame. By default the host sizes its window to the view, and Compare
        // collapsed to its bar is a header strip: reopened, the table came back with no height
        // and no visible rows, which read exactly like a reveal that never happened.
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let ids = Dictionary(uniqueKeysWithValues: rows.map {
            (($0.fileName as NSString).deletingPathExtension, $0.id)
        })
        return Mounted(window: window, host: host, manager: manager, session: session, ids: ids)
    }

    /// Waits for the table's lowest selected row to be among its visible rows.
    private static func waitForFirstSelectedOnScreen(_ mounted: Mounted) async -> (held: Bool, row: Int) {
        var row = -1
        let outcome = await LayoutPumpWait.pump(mounted.host, upTo: 15) {
            guard let table = mounted.table(), let first = table.selectedRowIndexes.first else { return false }
            row = first
            return NSLocationInRange(first, table.rows(in: table.visibleRect))
        }
        return (outcome.held, row)
    }
}
