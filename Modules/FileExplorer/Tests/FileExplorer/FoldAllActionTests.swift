import Testing
@testable import FileExplorer

/// Pins the master disclosure's rules. The control is one button standing in for two menu items,
/// so the interesting cases are the ones the items never face: a partly-folded table, and a table
/// with no sections at all.
@Suite struct FoldAllActionTests {

    // MARK: What a click does

    @Test func anExpandedTableOffersCollapse() {
        #expect(FoldAllAction.next(collapsedOnScreen: 0, sectionCount: 4) == .collapse)
    }

    @Test func aFullyCollapsedTableOffersExpand() {
        #expect(FoldAllAction.next(collapsedOnScreen: 4, sectionCount: 4) == .expand)
    }

    /// The rule the single-button shape exists to answer, and the one a majority-flip would get
    /// backwards. Mixed is what you get after collapsing everything and opening one folder, so the
    /// way back out is closing it again — at ANY ratio, including one lone expanded section.
    @Test func anyExpandedSectionOffersCollapse() {
        for collapsed in 0..<4 {
            #expect(FoldAllAction.next(collapsedOnScreen: collapsed, sectionCount: 4) == .collapse,
                    "\(collapsed) of 4 collapsed should still offer Collapse")
        }
    }

    /// Not "all collapsed" — there is nothing to expand. Unreachable while `isOffered` gates the
    /// control, and pinned so a future caller can't be handed a surprising `.expand`.
    @Test func anUnsectionedTableOffersCollapseRatherThanExpand() {
        #expect(FoldAllAction.next(collapsedOnScreen: 0, sectionCount: 0) == .collapse)
    }

    /// `collapsedOnScreen` is counted from the visible sections, but nothing stops a stale count
    /// arriving one render early. Saturating rather than trapping keeps that a cosmetic glitch.
    @Test func aCountAboveTheSectionTotalStillResolves() {
        #expect(FoldAllAction.next(collapsedOnScreen: 9, sectionCount: 4) == .expand)
    }

    // MARK: When it is offered at all

    @Test func anUnsectionedTableIsOfferedNoControl() {
        // Empty covers both "Group by folder is off" and "isWorthGrouping declined it".
        #expect(!FoldAllAction.isOffered(sectionCount: 0, compaction: .full))
    }

    @Test func aSectionedTableIsOfferedTheControlAtFullWidth() {
        #expect(FoldAllAction.isOffered(sectionCount: 1, compaction: .full))
    }

    /// It survives every rung down to the one where the filter beside it drops to a bare funnel,
    /// and yields there rather than pairing two anonymous glyphs.
    @Test func itYieldsFromTheRungThatMakesTheFilterAGlyph() {
        for compaction in HeaderCompaction.allCases {
            let offered = FoldAllAction.isOffered(sectionCount: 3, compaction: compaction)
            #expect(offered == (compaction < .glyphFilter),
                    "\(compaction) should \(compaction < .glyphFilter ? "offer" : "withhold") the toggle")
        }
        // Spelled out, so the boundary is pinned by name and not only by the loop's own predicate.
        #expect(FoldAllAction.isOffered(sectionCount: 3, compaction: .shortReverse))
        #expect(!FoldAllAction.isOffered(sectionCount: 3, compaction: .glyphFilter))
        #expect(!FoldAllAction.isOffered(sectionCount: 3, compaction: .shortPrimary))
    }

    // MARK: How it presents

    /// Three controls in this row collapse something — the section triangles, the pane's show/hide
    /// chevron, and this. The other two are chevrons; this one must not become a third.
    @Test func theGlyphsAreNotChevrons() {
        #expect(!FoldAllAction.collapse.systemImage.contains("chevron"))
        #expect(!FoldAllAction.expand.systemImage.contains("chevron"))
        #expect(FoldAllAction.collapse.systemImage != FoldAllAction.expand.systemImage)
    }

    /// The label names the click, not the current state, and says "folders" so it can never be
    /// read as the pane toggle's "Hide the differences list".
    @Test func theTitleNamesTheActionAndItsSubject() {
        #expect(FoldAllAction.collapse.title == "Collapse all folders")
        #expect(FoldAllAction.expand.title == "Expand all folders")
    }
}
