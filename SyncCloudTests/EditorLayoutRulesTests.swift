import Testing
import Foundation
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
    @Test func aCollapsedRailDrawsNoPaneListWhicheverWorkspaceItBelongsTo() {
        let expected: [(ContentView.ContentLayout, Bool)] = [
            (.compareSplit, true),
            (.singleExpanded, true),
            // Collapsed is collapsed: a lens rail folded to its spine is as absent as the editor's.
            // This said `true` while the member was editor-only, which left ⇧⌘N opening a naming
            // row in a pane nobody could see — the very bug it was introduced to fix, in the
            // workspace that had it first.
            (.singleCollapsed, false),
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

    /// **The launch refresh's completion must be tried BEFORE the bootstrap guard returns.**
    ///
    /// `refreshAction` does nothing when a pane names a source `enabledProviders` has not published
    /// yet, which at launch is ordinary — the ids are restored from defaults before discovery
    /// finishes. The load is then finished by the arrival of that source, and the arrival handler is
    /// `onChange(of: settings.enabledProviders)`, which returns early while the bootstrap guard is
    /// up. That guard is up for exactly the window the pending flag is set in, so completing the
    /// refresh below it would never run — the flag would be set, stranded, and the pane would keep
    /// whatever tree it happened to have.
    ///
    /// `PaneProviderChange` records the same lesson one handler over, in the same words: consume
    /// before you test the guard, or the write that armed it is lost. A source scan because
    /// `ContentView` is a `View` with `@State` and nothing can instantiate it — with a positive
    /// control, so a scan that stops finding the handler fails instead of passing empty.
    @Test func theLaunchRefreshIsCompletedBeforeTheBootstrapGuardReturns() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read ContentView.swift — this scan would be vacuous")
        let handler = try #require(source.range(of: ".onChange(of: settings.enabledProviders) {"),
                                   "the provider-arrival handler is gone or renamed")
        let body = String(source[handler.upperBound...].prefix(1600))
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
