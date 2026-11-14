import AppKit
import Testing
@testable import FileExplorer

/// The pane list's selection styling: the table search that turns the system highlight off, and the
/// active/inactive wash drawn in place of AppKit's emphasized selection.
@MainActor
@Suite struct PaneListSelectionStylerTests {

    /// A list: a table inside a scroll view, framed where the pane would put it. The scroll view's
    /// frame is what the resolver matches, since the table inside it scrolls.
    private func list(at frame: CGRect, columns: Int = 1) -> (scroll: NSScrollView, table: NSTableView) {
        let table = NSTableView()
        for i in 0..<columns { table.addTableColumn(NSTableColumn(identifier: .init("c\(i)"))) }
        let scroll = NSScrollView(frame: frame)
        scroll.documentView = table
        return (scroll, table)
    }

    /// A container holding the given views, sized to contain them.
    private func nest(_ views: [NSView], frame: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 600)) -> NSView {
        let root = NSView(frame: frame)
        views.forEach { root.addSubview($0) }
        return root
    }

    /// An anchor is what a `.background` is: a view laid out to exactly the frame of the list it
    /// backs (identical to the point on a mounted pane).
    private func anchor(at frame: CGRect) -> NSView { NSView(frame: frame) }

    // MARK: Table search

    /// A list is found by the anchor laid over it. A table with no columns yet (mid-mount) still
    /// counts; a multi-column one is the differences `Table`, not a pane list.
    @Test(arguments: [(1, true), (0, true), (3, false)])
    func testTheListIsFoundByColumnCount(columns: Int, isPaneList: Bool) {
        let frame = CGRect(x: 0, y: 0, width: 210, height: 520)
        let (scroll, table) = list(at: frame, columns: columns)
        let anchor = anchor(at: frame)
        _ = nest([scroll, anchor])
        if isPaneList {
            #expect(PaneListResolver.table(matching: anchor) === table)
        } else {
            #expect(PaneListResolver.table(matching: anchor) == nil)
        }
    }

    /// Sibling columns under one `HStack` share their first table-holding ancestor; the frame tells
    /// them apart, as each anchor sits over exactly one column.
    @Test func testSiblingColumnsEachResolveToTheirOwnList() {
        var lists: [(scroll: NSScrollView, table: NSTableView)] = []
        var anchors: [NSView] = []
        for column in 0..<3 {
            let frame = CGRect(x: CGFloat(column) * 210, y: 0, width: 210, height: 520)
            lists.append(list(at: frame))
            anchors.append(anchor(at: frame))
        }
        _ = nest(lists.map(\.scroll) + anchors)
        for column in 0..<3 {
            #expect(PaneListResolver.table(matching: anchors[column]) === lists[column].table,
                    "column \(column) should resolve to its own list")
        }
    }

    /// The two comparison panes are never in the same place, so the frame separates them.
    @Test func testTheOtherPanesListIsNotPickedUp() {
        let mineFrame = CGRect(x: 0, y: 0, width: 400, height: 520)
        let theirsFrame = CGRect(x: 500, y: 0, width: 400, height: 520)
        let mine = list(at: mineFrame)
        let theirs = list(at: theirsFrame)
        let anchor = anchor(at: mineFrame)
        _ = nest([mine.scroll, theirs.scroll, anchor])
        #expect(PaneListResolver.table(matching: anchor) === mine.table)
    }

    /// Two lists in the same place mean the frame has stopped identifying anything. Refuse rather
    /// than toss a coin between panes.
    @Test func testTwoListsInTheSamePlaceAreRefused() {
        let frame = CGRect(x: 0, y: 0, width: 210, height: 520)
        let a = list(at: frame)
        let b = list(at: frame)
        let anchor = anchor(at: frame)
        _ = nest([a.scroll, b.scroll, anchor])
        #expect(PaneListResolver.table(matching: anchor) == nil)
    }

    /// The differences table's styler inverts the column filter: the multi-column `Table`, never a
    /// pane list.
    @Test(arguments: [(4, true), (1, false)])
    func testMultiColumnModeResolvesOnlyTheDifferencesTable(columns: Int, resolves: Bool) {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 300)
        let (scroll, table) = list(at: frame, columns: columns)
        let anchor = anchor(at: frame)
        _ = nest([scroll, anchor])
        let found = PaneListResolver.table(matching: anchor, multiColumn: true)
        #expect(resolves ? found === table : found == nil, "\(columns) column(s): resolved \(String(describing: found))")
    }

    /// An anchor SwiftUI hasn't sized yet resolves to nothing rather than matching whatever sits at
    /// the origin; the caller retries once it has a frame.
    @Test func testAnUnlaidOutAnchorResolvesToNothing() {
        let frame = CGRect(x: 0, y: 0, width: 210, height: 520)
        let (scroll, _) = list(at: frame)
        let anchor = anchor(at: .zero)
        _ = nest([scroll, anchor])
        #expect(PaneListResolver.table(matching: anchor) == nil)
    }

    /// A list nowhere near the anchor is not its list, however alone it is in the hierarchy.
    @Test func testANonOverlappingListIsNotAdopted() {
        let (scroll, _) = list(at: CGRect(x: 0, y: 0, width: 210, height: 520))
        let anchor = anchor(at: CGRect(x: 600, y: 0, width: 210, height: 520))
        _ = nest([scroll, anchor])
        #expect(PaneListResolver.table(matching: anchor) == nil)
    }

    @Test func testNoTableAnywhereReturnsNil() {
        let anchor = anchor(at: CGRect(x: 0, y: 0, width: 210, height: 520))
        _ = nest([NSView(frame: .zero), anchor])
        #expect(PaneListResolver.table(matching: anchor) == nil)
    }

    /// The search climbs ancestors, so an anchor mounted deeper than the list still reaches it,
    /// within the bounded number of levels.
    @Test func testSearchClimbsAncestorsWithinItsBudget() {
        let frame = CGRect(x: 0, y: 0, width: 210, height: 520)
        let (scroll, table) = list(at: frame)
        let anchor = anchor(at: frame)
        var chain: NSView = nest([anchor])
        for _ in 0..<3 { chain = nest([chain]) }
        _ = nest([scroll, chain])
        #expect(PaneListResolver.table(matching: anchor) === table)
    }

    /// `matches` is the cheap re-validation run on every layout pass; it must agree with the search.
    @Test func testMatchesAgreesWithTheSearch() {
        let frame = CGRect(x: 0, y: 0, width: 210, height: 520)
        let (scroll, table) = list(at: frame)
        let anchor = anchor(at: frame)
        _ = nest([scroll, anchor])
        let target = anchor.convert(anchor.bounds, to: nil)
        #expect(PaneListResolver.matches(table, target: target))
        #expect(PaneListResolver.matches(table, target: CGRect(x: 600, y: 0, width: 210, height: 520)) == false)
        #expect(PaneListResolver.matches(table, target: .zero) == false)
    }

    // MARK: Selection wash

    /// The active pane's selection reads stronger than the inactive one's: the only cue for which
    /// pane the action bar's Delete will act on.
    @Test func testActiveWashIsStrongerThanInactive() {
        #expect(PaneSelectionWash.opacity(isActivePane: true) > PaneSelectionWash.opacity(isActivePane: false))
        #expect(PaneSelectionWash.opacity(isActivePane: true) == PaneSelectionWash.active)
        #expect(PaneSelectionWash.opacity(isActivePane: false) == PaneSelectionWash.inactive)
    }

    /// Both washes stay usable: the inactive one visible, the active one not so opaque it swallows
    /// the row's text.
    @Test func testBothWashesStayInTheLegibleBand() {
        #expect(PaneSelectionWash.inactive >= 0.06)
        #expect(PaneSelectionWash.active <= 0.35)
        // A gap too small to perceive would defeat the point of having two.
        #expect(PaneSelectionWash.active - PaneSelectionWash.inactive >= 0.08)
    }
}
