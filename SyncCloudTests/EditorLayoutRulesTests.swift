import Testing
import Foundation
@testable import SyncCloud

/// Which chords a layout may offer: the question `ContentLayout` answers for every pane-scoped
/// shortcut.
@Suite struct ContentLayoutRuleTests {
    /// ⇧⌘N and ⇧⌘P consult `drawsAPaneList`, so a layout that draws no pane list must answer no.
    /// Fails on `case .editorCollapsed: return true`, which would put an invisible pane into a
    /// naming state the user can't dismiss.
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

    /// `hasCollapsibleRail` is a different set from `drawsAPaneList`: it covers the layouts with a
    /// spine to collapse to.
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

    /// The launch refresh's completion is tried before the bootstrap guard returns. At launch a
    /// pane can name a source `enabledProviders` hasn't published yet, so `refreshAction` does
    /// nothing and its arrival must finish the load. The guard is up for exactly that window, so a
    /// completion below it never runs and the pane keeps its old tree. (`PaneProviderChange` keeps
    /// the same rule: consume before you test the guard.)
    @Test func theLaunchRefreshIsCompletedBeforeTheBootstrapGuardReturns() throws {
        let source = try macAppFile("ContentView.swift")
        // The handler's own closure, matched by its braces rather than a fixed window.
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
