import Foundation
import Sync
import Testing
@testable import FileExplorer

/// What the rename backlog's header says it would do, and that it is the same sentence the rows
/// below it say.
///
/// The header counts FOLDERS on its chip — the unit the planner decides and the manager applies —
/// and nothing renames a folder, so the readout beside the chip is the only place the user is told
/// what is actually being renamed. These pin both halves: the arithmetic over many plans, and the
/// wording, which is shared with `RenamePassLens.summary` precisely so a header cannot summarise
/// the same plans in different words from the rows it sits above.
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
        // Each kind reads a DIFFERENT number, so a tally that summed the wrong field — or the same
        // field three times — cannot agree with all four at once.
        #expect(tally.named == 6)
        #expect(tally.reshuffled == 2)
        #expect(tally.padded == 7)
        #expect(tally.skipped == 3)
        // The headline is steps, and skips are NOT steps: a pass that declined to touch three files
        // did not rename them.
        #expect(tally.renames == 15)
    }

    @Test("An empty backlog tallies to nothing and breaks down to nothing")
    func emptyBacklog() {
        let tally = RenameBacklogTally([])
        #expect(tally.renames == 0)
        // Empty rather than a dangling separator or a lone "0 to pad" — the caller draws no run at
        // all, which is how a header with nothing to report says so.
        #expect(tally.breakdown.isEmpty)
    }

    @Test("The breakdown names the rare kinds before the bulk")
    func breakdownOrder() {
        let tally = RenameBacklogTally([plan(named: 42, reshuffled: 16, padded: 1_134, skips: 7)])
        // Not biggest-first. A reshuffle is the only thing this feature does that moves a file which
        // was already correct, so it must survive being read quickly rather than sitting behind
        // eleven hundred paddings.
        #expect(tally.breakdown == "42 to name · 16 to reshuffle · 1,134 to pad · 7 left alone")
    }

    @Test("A kind with nothing in it is absent, not zero")
    func zeroKindsAreOmitted() {
        // The backlog's ordinary shape. "0 to reshuffle" on the 126 folders where nothing moves is
        // how the word stops meaning anything on the one folder where something does.
        #expect(RenameBacklogTally([plan(padded: 9)]).breakdown == "9 to pad")
        #expect(RenameBacklogTally([plan(padded: 9, skips: 1)]).breakdown == "9 to pad · 1 left alone")
    }

    @Test("A folder's row and the header above it speak with one voice")
    func theRowDelegatesToTheTally() {
        // `RenamePassLens.summary` IS this type now. Asserted through the lens's own entry point so
        // the delegation is what is pinned, not just the arithmetic behind it: an implementation
        // re-inlined into the lens would pass every other test in this file.
        let p = plan(named: 1, reshuffled: 3, padded: 0)
        #expect(RenamePassLens.summary(p) == RenameBacklogTally([p]).breakdown)
        #expect(RenamePassLens.summary(p) == "1 to name · 3 to reshuffle")
    }

    @Test("A plan of nothing but skips still says something")
    func nothingToDoIsStillSaid() {
        // `claim` and `breakdown` diverge in exactly one place, and this is it: a row that rendered
        // the empty breakdown would read as a clean folder when in fact the pass looked and
        // declined. The header has no such problem — it draws nothing rather than a blank.
        let p = plan(skips: 2)
        #expect(RenameBacklogTally([p]).claim == "nothing to do · 2 left alone")
        #expect(RenameBacklogTally([p]).breakdown == "2 left alone")
        #expect(RenamePassLens.summary(p) == "nothing to do · 2 left alone")
    }

    @Test("Counts are grouped once they get big enough to need it")
    func countsAreGrouped() {
        // The backlog this was written for is four figures. "1134 to pad" beside a chip reading
        // "126 folders" invites the reader to compare two numbers written in different systems.
        #expect(RenameBacklogTally([plan(padded: 1_134)]).breakdown.contains("1,134"))
    }
}
