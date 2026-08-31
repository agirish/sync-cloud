import Testing
@testable import SyncCloud

/// **Which chords a layout is allowed to offer** — the question `ContentLayout` answers for every
/// pane-scoped shortcut, and the one member of it that had no test at all.
@Suite struct ContentLayoutRuleTests {

    /// `drawsAPaneList` is what ⇧⌘N and ⇧⌘P consult before offering themselves. It gates a naming
    /// row that opens *inside* a pane's file list and a preview column that lives beside one, so
    /// the arrangements that draw neither must answer no.
    ///
    /// **Six cases, listed by hand rather than derived**, because the point is the per-case verdict:
    /// a derived list would only restate the switch. `.editorCollapsed` is the one that answers no,
    /// and the mutation it stops is a one-word edit — `case .editorCollapsed: return true` puts an
    /// invisible pane into a naming state the user cannot dismiss, which is the bug this member was
    /// introduced to fix.
    @Test func onlyTheCollapsedEditorDrawsNoPaneList() {
        let expected: [(ContentView.ContentLayout, Bool)] = [
            (.compareSplit, true),
            (.singleExpanded, true),
            (.singleCollapsed, true),
            (.browseFull, true),
            (.editorExpanded, true),
            (.editorCollapsed, false),
        ]
        for (layout, draws) in expected {
            #expect(layout.drawsAPaneList == draws,
                    "\(layout) says drawsAPaneList == \(layout.drawsAPaneList)")
        }
        // The control: an answer of "all" or "none" would satisfy a loop that only checked one side.
        #expect(expected.contains { $0.1 } && expected.contains { !$0.1 })
    }

    /// The sibling member, and the reason both are asked of the LAYOUT rather than the workspace:
    /// the collapse rung belongs to arrangements that HAVE a spine to collapse to, which is not the
    /// same set as the ones that currently draw a list.
    ///
    /// The two answers differ on exactly one case — `.editorExpanded` draws a list AND can collapse
    /// — and that difference is the whole reason there are two members instead of one.
    @Test func theTwoLayoutQuestionsAreNotTheSameQuestion() {
        let expected: [(ContentView.ContentLayout, Bool)] = [
            (.compareSplit, false),
            (.singleExpanded, true),
            (.singleCollapsed, true),
            (.browseFull, false),
            (.editorExpanded, true),
            (.editorCollapsed, true),
        ]
        for (layout, collapsible) in expected {
            #expect(layout.hasCollapsibleRail == collapsible,
                    "\(layout) says hasCollapsibleRail == \(layout.hasCollapsibleRail)")
        }
        let differ = expected.filter { $0.0.drawsAPaneList != $0.0.hasCollapsibleRail }
        #expect(!differ.isEmpty,
                "the two members agree on every case — one of them is redundant, or this table is wrong")
    }
}
