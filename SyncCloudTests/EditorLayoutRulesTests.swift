import Testing
import Foundation
@testable import SyncCloud

/// Which chords a layout may offer: the question `ContentLayout` answers for every pane-scoped
/// shortcut.
@Suite struct ContentLayoutRuleTests {

    /// `drawsAPaneList` is what ⇧⌘N and ⇧⌘P consult before offering themselves. It gates a naming
    /// row that opens *inside* a pane's file list and a preview column that lives beside one, so
    /// the arrangements that draw neither must answer no.
    ///
    /// Six cases, listed by hand rather than derived, because the point is the per-case verdict: a
    /// derived list would only restate the switch. Fails on `case .editorCollapsed: return true`,
    /// which would put an invisible pane into a naming state the user can't dismiss.
    @Test func aCollapsedRailDrawsNoPaneListWhicheverWorkspaceItBelongsTo() {
        let expected: [(ContentView.ContentLayout, Bool)] = [
            (.compareSplit, true),
            (.singleExpanded, true),
            // Collapsed is collapsed: a lens rail folded to its spine is as absent as the editor's,
            // so ⇧⌘N must not open a naming row in a pane nobody can see.
            (.singleCollapsed, false),
            (.browseFull, true),
            (.editorExpanded, true),
            (.editorCollapsed, false),
        ]
        for (layout, draws) in expected {
            #expect(layout.drawsAPaneList == draws,
                    "\(layout) says drawsAPaneList == \(layout.drawsAPaneList)")
        }
    }

    /// The sibling member, and why both are asked of the layout rather than the workspace: the
    /// collapse rung belongs to arrangements that have a spine to collapse to, which is not the
    /// same set as those that draw a list. That difference is why there are two members.
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
    }

    /// The launch refresh's completion must be tried before the bootstrap guard returns.
    ///
    /// `refreshAction` does nothing when a pane names a source `enabledProviders` hasn't published
    /// yet, which is ordinary at launch (the ids are restored before discovery finishes). The
    /// source's arrival finishes the load, in `onChange(of: settings.enabledProviders)`, which
    /// returns early while the bootstrap guard is up. That guard is up for exactly the window the
    /// pending flag is set in, so completing the refresh below it would never run, stranding the
    /// flag and leaving the pane on whatever tree it had.
    ///
    /// `PaneProviderChange` keeps the same rule one handler over: consume before you test the
    /// guard. A source scan because `ContentView` is a `View` with `@State` that nothing can
    /// instantiate, with a positive control so a scan that stops finding the handler fails.
    @Test func theLaunchRefreshIsCompletedBeforeTheBootstrapGuardReturns() throws {
        let source = try macAppFile("ContentView.swift")
        // The handler's own closure (``declarationBody(of:in:sourceLocation:)`` matches its
        // braces), not a fixed window that a longer handler outgrows and a shorter one overruns.
        let body = CodeText(try declarationBody(of: ".onChange(of: settings.enabledProviders) {", in: source))
        let completes = try #require(body.range(of: "launchRefreshPending, refreshAction()"),
                                     "the launch refresh is never completed when its sources arrive")
        let guardsOut = try #require(body.range(of: "guard !isBootstrappingProviders else { return }"),
                                     "the bootstrap guard is gone — this scan is reading the wrong handler")
        #expect(completes.upperBound < guardsOut.lowerBound,
                "the pending launch refresh is completed BELOW the bootstrap guard, which returns first — so it never runs")
        // And the bootstrap actually arms it, or there is nothing for the above to complete.
        #expect(source.contains("launchRefreshPending = !refreshAction()"),
                "the bootstrap no longer records a launch refresh that could not start")
    }
}
