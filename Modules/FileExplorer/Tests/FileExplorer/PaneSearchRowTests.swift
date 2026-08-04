import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// What one row draws differently while a search is running.
@MainActor
@Suite struct PaneSearchRowTests {

    private static func results(_ query: String, otherPaths: Set<String>? = nil) -> PaneSearchResults {
        PaneSearchResults(side: .left, generation: 1, query: query,
                          tree: PaneSearchTreeRevealTests.tree(), otherPaths: otherPaths)
    }

    private func context(_ path: String, query: String = "tax", isExpanded: Bool = false,
                         otherPaths: Set<String>? = nil) -> PaneSearchRowContext {
        PaneSearchRowContext(results: Self.results(query, otherPaths: otherPaths),
                             path: path, isExpanded: isExpanded)
    }

    // MARK: - The count pill

    /// A closed folder with hits inside it says so — otherwise the tree hides the answer behind a
    /// row that looks exactly like the ones with nothing in them.
    @Test("A closed folder with matches inside shows its count")
    func aClosedFolderWithMatchesShowsACount() {
        let irs = context("/root/Documents/IRS")
        #expect(irs.containedMatchCount == 1)
        #expect(irs.showsContainedCount)
    }

    /// An OPEN folder's count says nothing its own rows are not already saying — and in Columns it
    /// would sit on the very folder you drilled through.
    @Test("An open folder does not repeat the count its rows already show")
    func anOpenFolderShowsNoCount() {
        #expect(!context("/root/Documents/IRS", isExpanded: true).showsContainedCount)
    }

    @Test("A folder with nothing matching inside shows no count, open or closed")
    func aFolderWithNoMatchesShowsNothing() {
        #expect(!context("/root/Movies").showsContainedCount)
        #expect(!context("/root/Movies", isExpanded: true).showsContainedCount)
    }

    // MARK: - Dimming

    @Test("A row off every path to an answer dims; matches and their ancestors do not")
    func dimmingFollowsTheResults() {
        #expect(context("/root/Movies").isDimmed)
        #expect(!context("/root/Documents").isDimmed)
        #expect(!context("/root/Documents/Finance/tax-notes.md").isDimmed)
    }

    /// The resting value has to be inert in every direction, because it is what every caller that
    /// knows nothing about search passes.
    @Test("With no search running a row draws exactly what it always drew")
    func theRestingContextIsInert() {
        #expect(PaneSearchRowContext.none.match == nil)
        #expect(!PaneSearchRowContext.none.isDimmed)
        #expect(!PaneSearchRowContext.none.showsContainedCount)
        #expect(PaneSearchRowContext.none.side == nil)
    }

    // MARK: - The side annotation

    /// The two panes must not both say “left only”. The label names THIS pane, so it has to come
    /// from the side rather than from the sentence.
    @Test("A one-sided hit names the pane it is on")
    func theOneSidedLabelNamesItsOwnSide() {
        #expect(PaneSearchAnnotation.onlyHereLabel(isLeft: true) == "left only")
        #expect(PaneSearchAnnotation.onlyHereLabel(isLeft: false) == "right only")
    }

    @Test("The annotation is only produced where there is a second tree")
    func theRailAnnotatesNothing() {
        // No `otherPaths` — the single-source rail.
        #expect(context("/root/Documents/Finance/tax-notes.md").side == nil)
        // With one, the hit is annotated.
        let compared = context("/root/Documents/Finance/tax-notes.md",
                               otherPaths: ["Documents/Finance/tax-notes.md"])
        #expect(compared.side == .bothSides)
    }

    // MARK: - The emphasized name

    /// The clamp, exercised: the range and the string reach this view from different places — the
    /// results computed against the tree that was published when the query ran, the row rendered
    /// from the tree published since — so one republish between them hands it a range past the end.
    /// Without the bounds check `display[..<match.lowerBound]` traps and takes the process with it,
    /// which is why this test renders rather than asserting a return value.
    @Test("A stale match range past the end of the name renders instead of trapping")
    func aStaleMatchRangeIsClamped() {
        for match in [40..<45, -3..<2, 2..<2, 0..<3] {
            let host = NSHostingView(rootView:
                PaneSearchName(name: "notes.md", match: match, font: .body))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0, "the name should still lay out for \(match)")
        }
    }

    /// The emphasis is drawn on the MARKED form (“Swimming ” → “Swimming␣”), and the offsets have to
    /// survive that substitution — `NameDisplay.visibleName` replaces one character with one, so
    /// they do. A fold that changed the length here would silently bold the wrong run.
    @Test("A name whose affix whitespace is marked keeps the same character count")
    func theMarkedNameIsTheSameLength() {
        #expect(Array(NameDisplay.visibleName("Swimming ")).count == Array("Swimming ").count)
        #expect(Array(NameDisplay.visibleName("  a  ")).count == Array("  a  ").count)
    }
}
