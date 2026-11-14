import Foundation
import Sync
import Testing
@testable import FileExplorer

/// What the rename backlog's header says it would do, in the same words as the rows below it.
///
/// The header's chip counts folders (the unit the planner decides and the manager applies), and
/// nothing renames a folder, so the readout beside it is the only place the user learns what gets
/// renamed. These pin the arithmetic over many plans and the wording, which is shared with
/// `RenamePassLens.summary` so the header can't summarise the same plans differently.
@Suite struct RenameBacklogTallyTests {

    private func plan(named: Int = 0, reshuffled: Int = 0, padded: Int = 0, skips: Int = 0,
                      id: String = "/T") -> RenamePlan {
        var steps: [RenameStep] = []
        func step(_ i: Int, _ kind: RenameStep.Kind) -> RenameStep {
            RenameStep(currentPath: "\(id)/\(kind.rawValue)\(i).pdf",
                       currentName: "\(kind.rawValue)\(i).pdf", proposedName: "0\(i). Jan 2021.pdf",
                       kind: kind, cohort: kind == .renumbered ? 1 : 0, reason: "")
        }
        for i in 0..<named { steps.append(step(i, .placed)) }
        for i in 0..<reshuffled { steps.append(step(i, .renumbered)) }
        for i in 0..<padded { steps.append(step(i, .tidied)) }
        return RenamePlan(folderPath: id, relativePath: id, scheme: .position, steps: steps,
                          skips: (0..<skips).map { RenameSkip(path: "\(id)/s\($0)",
                                                              fileName: "s\($0)", reason: "") })
    }

    @Test("The tally sums every kind across every plan")
    func sumsAcrossPlans() {
        let tally = RenameBacklogTally([
            plan(named: 1, reshuffled: 2, padded: 3, skips: 1, id: "/A"),
            plan(named: 0, reshuffled: 0, padded: 4, skips: 0, id: "/B"),
            plan(named: 5, reshuffled: 0, padded: 0, skips: 2, id: "/C"),
        ])
        // Each kind reads a different number, so a tally that summed the wrong field, or one field
        // three times, can't agree with all four.
        #expect(tally.named == 6)
        #expect(tally.reshuffled == 2)
        #expect(tally.padded == 7)
        #expect(tally.skipped == 3)
        // The headline counts steps, and skips are not steps: a declined file isn't renamed.
        #expect(tally.renames == 15)
    }

    @Test("An empty backlog tallies to nothing and breaks down to nothing")
    func emptyBacklog() {
        let tally = RenameBacklogTally([])
        #expect(tally.renames == 0)
        // Empty, not a dangling separator or "0 to pad": the caller then draws nothing.
        #expect(tally.breakdown.isEmpty)
    }

    @Test("The breakdown names the rare kinds before the bulk")
    func breakdownOrder() {
        let tally = RenameBacklogTally([plan(named: 42, reshuffled: 16, padded: 1_134, skips: 7)])
        // Not biggest-first: a reshuffle is the only change that moves a file already correct, so
        // it must not sit behind a thousand paddings. Grouped, as the folder counts beside it are.
        #expect(tally.breakdown == "42 to name · 16 to reshuffle · 1,134 to pad · 7 left alone")
    }

    @Test("A kind with nothing in it is absent, not zero")
    func zeroKindsAreOmitted() {
        // The backlog's ordinary shape. "0 to reshuffle" on every folder where nothing moves would
        // make the word mean nothing on the one where something does.
        #expect(RenameBacklogTally([plan(padded: 9)]).breakdown == "9 to pad")
        #expect(RenameBacklogTally([plan(padded: 9, skips: 1)]).breakdown == "9 to pad · 1 left alone")
    }

    @Test("A folder's row and the header above it speak with one voice")
    func theRowDelegatesToTheTally() {
        // `RenamePassLens.summary` delegates to this type. Asserted through the lens's entry point
        // so the delegation is pinned: a copy re-inlined into the lens would pass every other test.
        let p = plan(named: 1, reshuffled: 3, padded: 0)
        #expect(RenamePassLens.summary(p) == RenameBacklogTally([p]).breakdown)
        #expect(RenamePassLens.summary(p) == "1 to name · 3 to reshuffle")
    }

    @Test("A plan of nothing but skips still says something")
    func nothingToDoIsStillSaid() {
        // The one place `claim` and `breakdown` diverge: a row showing the empty breakdown would
        // read as a clean folder when the pass looked and declined. The header draws nothing.
        let p = plan(skips: 2)
        #expect(RenameBacklogTally([p]).claim == "nothing to do · 2 left alone")
        #expect(RenameBacklogTally([p]).breakdown == "2 left alone")
        #expect(RenamePassLens.summary(p) == "nothing to do · 2 left alone")
    }

    // MARK: headerBreakdown — the header's shorter form of the same words

    @Test("The header collects the two rare kinds and drops the skips")
    func theHeaderBreakdownIsShorterInTheSameWords() {
        let p = plan(named: 7, reshuffled: 6, padded: 628, skips: 2)
        let tally = RenameBacklogTally([p])
        // The folder rows' string, pinned equal to `RenamePassLens.summary`, is unchanged.
        #expect(tally.breakdown == "7 to name · 6 to reshuffle · 628 to pad · 2 left alone")
        // Rare and consequential first, bulk last (`stepParts`' order), so the few worth a second
        // look aren't buried behind the bulk.
        #expect(tally.headerBreakdown == "13 to name or reshuffle · 628 to pad")
        // The point: narrower (190.5pt against 268.5 in the header's 11pt monospaced-digit face).
        #expect(tally.headerBreakdown.count < tally.breakdown.count)
    }

    @Test("With one rare kind the header names it exactly")
    func theHeaderBreakdownDoesNotOfferAKindWithNoMembers() {
        // A disjunction is honest only when both sides have members: "7 to name or reshuffle"
        // with no reshuffles sends you looking for a kind that isn't there, and is wider.
        #expect(RenameBacklogTally([plan(named: 7, padded: 628)]).headerBreakdown
                == "7 to name · 628 to pad")
        #expect(RenameBacklogTally([plan(reshuffled: 6, padded: 628)]).headerBreakdown
                == "6 to reshuffle · 628 to pad")
        #expect(RenameBacklogTally([plan(padded: 9)]).headerBreakdown == "9 to pad")
    }

    @Test("Skips are dropped only while there are renames to itemise")
    func theHeaderBreakdownKeepsSkipsWhenTheyAreTheWholeStory() {
        // Dropped beside a rename total they aren't part of: `641 renames · … · 2 left alone`
        // would list a part that isn't in the total.
        #expect(RenameBacklogTally([plan(padded: 9, skips: 3)]).headerBreakdown == "9 to pad")
        // With no renames the header reads "0 renames", and the skips are what explain the zero.
        let onlySkips = RenameBacklogTally([plan(skips: 2)])
        #expect(onlySkips.renames == 0)
        #expect(onlySkips.headerBreakdown == "2 left alone")
        // Nothing at all still says nothing, so the caller draws no dangling separator.
        #expect(RenameBacklogTally([plan()]).headerBreakdown.isEmpty)
    }

    @Test("The header's numbers are grouped like the rows'")
    func theHeaderBreakdownGroupsItsThousands() {
        #expect(RenameBacklogTally([plan(padded: 1_134)]).headerBreakdown.contains("1,134"))
        #expect(RenameBacklogTally([plan(named: 1_200, reshuffled: 300)]).headerBreakdown
                .contains("1,500 to name or reshuffle"))
    }
}
