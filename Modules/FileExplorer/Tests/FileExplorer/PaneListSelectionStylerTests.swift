import AppKit
import Testing
@testable import FileExplorer

/// The pane list's selection styling: the table search that turns the system highlight off, and the
/// active/inactive wash that replaced the emphasized selection AppKit used to draw.
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
    /// backs. Measured identical to the point on a mounted pane.
    private func anchor(at frame: CGRect) -> NSView { NSView(frame: frame) }

    // MARK: Table search

    @Test func testFindsTheListItIsAnchoredOver() {
        let frame = CGRect(x: 0, y: 0, width: 210, height: 520)
        let (scroll, table) = list(at: frame)
        let anchor = anchor(at: frame)
        _ = nest([scroll, anchor])
        #expect(PaneListResolver.table(matching: anchor) === table)
    }

    /// A table with no columns yet (SwiftUI mid-mount) still counts — the pane list is single-column
    /// by construction, and refusing it here would leave the gray highlight on until a relayout.
    @Test func testZeroColumnTableCounts() {
        let frame = CGRect(x: 0, y: 0, width: 210, height: 520)
        let (scroll, table) = list(at: frame, columns: 0)
        let anchor = anchor(at: frame)
        _ = nest([scroll, anchor])
        #expect(PaneListResolver.table(matching: anchor) === table)
    }

    /// A multi-column table is a `Table` (the differences list), NOT a pane list. Styling it would
    /// strip the selection highlight from the wrong view entirely.
    @Test func testMultiColumnTableIsIgnored() {
        let frame = CGRect(x: 0, y: 0, width: 210, height: 520)
        let (scroll, _) = list(at: frame, columns: 3)
        let anchor = anchor(at: frame)
        _ = nest([scroll, anchor])
        #expect(PaneListResolver.table(matching: anchor) == nil)
    }

    /// **The case the old walk got wrong.** Three columns are siblings under one `HStack`, so the
    /// first ancestor holding any table holds all three — the subtree-counting walk refused, and
    /// every column but the first kept the OS selection highlight. The frame resolves it: each
    /// anchor sits over exactly one column.
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

    /// The two comparison panes are never in the same place, so the frame separates them — which is
    /// what the old ambiguity refusal was protecting against, now handled rather than declined.
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
    /// than toss a coin between panes — the same discipline the old walk applied to an ambiguous
    /// subtree.
    @Test func testTwoListsInTheSamePlaceAreRefused() {
        let frame = CGRect(x: 0, y: 0, width: 210, height: 520)
        let a = list(at: frame)
        let b = list(at: frame)
        let anchor = anchor(at: frame)
        _ = nest([a.scroll, b.scroll, anchor])
        #expect(PaneListResolver.table(matching: anchor) == nil)
    }

    /// An anchor SwiftUI has not sized yet resolves to nothing rather than matching whatever
    /// happens to sit at the origin — the caller retries once it has a frame.
    @Test func testAnUnlaidOutAnchorResolvesToNothing() {
        let frame = CGRect(x: 0, y: 0, width: 210, height: 520)
        let (scroll, _) = list(at: frame)
        let anchor = anchor(at: .zero)
        _ = nest([scroll, anchor])
        #expect(PaneListResolver.table(matching: anchor) == nil)
    }

    /// A list nowhere near the anchor is not this anchor's list, however alone it is in the
    /// hierarchy — otherwise a single stale table would be adopted by any anchor that asked.
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

    /// The search climbs ancestors, so an anchor mounted deeper than the list still reaches it —
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

    /// The active pane's selection must read stronger than the inactive one's — that gap is the
    /// only remaining cue for which pane the action bar's Delete will act on, now that the system
    /// highlight is off and the window is pinned to `controlActiveState == .active`.
    @Test func testActiveWashIsStrongerThanInactive() {
        #expect(PaneSelectionWash.opacity(isActivePane: true) > PaneSelectionWash.opacity(isActivePane: false))
        #expect(PaneSelectionWash.opacity(isActivePane: true) == PaneSelectionWash.active)
        #expect(PaneSelectionWash.opacity(isActivePane: false) == PaneSelectionWash.inactive)
    }

    /// Both ends stay usable: the inactive wash must still be visible (not effectively transparent,
    /// which would read as "nothing is selected there"), and the active one must not be so opaque
    /// that it swallows the row's own text.
    @Test func testBothWashesStayInTheLegibleBand() {
        #expect(PaneSelectionWash.inactive >= 0.06)
        #expect(PaneSelectionWash.active <= 0.35)
        // A gap too small to perceive would defeat the point of having two.
        #expect(PaneSelectionWash.active - PaneSelectionWash.inactive >= 0.08)
    }
}
