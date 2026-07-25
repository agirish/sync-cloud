import AppKit
import Testing
@testable import FileExplorer

/// The pane list's selection styling: the table search that turns the system highlight off, and the
/// active/inactive wash that replaced the emphasized selection AppKit used to draw.
@MainActor
@Suite struct PaneListSelectionStylerTests {

    private typealias Styler = PaneListSelectionStyler.StylerView

    private func table(columns: Int) -> NSTableView {
        let t = NSTableView()
        for i in 0..<columns { t.addTableColumn(NSTableColumn(identifier: .init("c\(i)"))) }
        return t
    }

    private func nest(_ views: [NSView]) -> NSView {
        let root = NSView()
        views.forEach { root.addSubview($0) }
        return root
    }

    // MARK: Table search

    @Test func testFindsTheSingleColumnTableInASubtree() {
        let t = table(columns: 1)
        let root = nest([nest([t])])
        #expect(Styler.findTableView(from: root) === t)
    }

    /// A table with no columns yet (SwiftUI mid-mount) still counts — the pane list is single-column
    /// by construction, and refusing it here would leave the gray highlight on until a relayout.
    @Test func testZeroColumnTableCounts() {
        let t = table(columns: 0)
        #expect(Styler.findTableView(from: nest([t])) === t)
    }

    /// A multi-column table is a `Table` (the differences list), NOT a pane list. Styling it would
    /// strip the selection highlight from the wrong view entirely.
    @Test func testMultiColumnTableIsIgnored() {
        #expect(Styler.findTableView(from: nest([table(columns: 3)])) == nil)
    }

    /// The refusal rule, and the reason it exists: with both panes under one ancestor the walk must
    /// return nil rather than guess — guessing styles the OTHER pane's list.
    @Test func testAmbiguityIsRefusedNotGuessed() {
        let root = nest([nest([table(columns: 1)]), nest([table(columns: 1)])])
        #expect(Styler.findTableView(from: root) == nil)
    }

    /// Ambiguity higher up doesn't matter as long as a lower level resolves: starting from the
    /// pane's own container finds that pane's table even though their shared parent holds two.
    @Test func testLowerLevelResolvesEvenWhenTheParentIsAmbiguous() {
        let mine = table(columns: 1)
        let myBranch = nest([mine])
        _ = nest([myBranch, nest([table(columns: 1)])])
        #expect(Styler.findTableView(from: myBranch) === mine)
    }

    @Test func testNoTableAnywhereReturnsNil() {
        #expect(Styler.findTableView(from: nest([NSView(), nest([NSView()])])) == nil)
        #expect(Styler.findTableView(from: nil) == nil)
    }

    /// The walk climbs ancestors, so a styler mounted as a sibling *below* the list still reaches
    /// it — but only within the bounded number of levels.
    @Test func testWalkClimbsAncestorsWithinItsBudget() {
        let t = table(columns: 1)
        var chain: NSView = nest([t])
        for _ in 0..<3 { chain = nest([chain]) }
        let deep = NSView()
        chain.addSubview(deep)
        #expect(Styler.findTableView(from: deep.superview) === t)
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
