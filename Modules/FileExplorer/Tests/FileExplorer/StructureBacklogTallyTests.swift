import Foundation
import Sync
import Testing
@testable import FileExplorer

/// What Restructure's card says its backlog is made of — and that it says it in the same words the
/// lens uses on the findings themselves.
///
/// ## What this replaced
///
/// `scoped.prefix(3).map(\.headline)`: three findings off the front of an unsorted list, drawn as
/// three monospaced lines. On the reference tree that was one `node_modules` subtree three times
/// over, sixty characters of shared prefix apiece, and the only thing it established was that the
/// list is not empty — which the `53 findings` pill beside it had already established. A sample
/// that is `prefix(3)` of an unsorted list is not a sample; it is whatever sorts first.
@Suite struct StructureBacklogTallyTests {

    private func finding(_ kind: FindingKind, _ n: Int) -> [StructureFinding] {
        (0..<n).map { StructureFinding(kind: kind, family: "F\(kind.rawValue)\($0)") }
    }

    @Test func itCountsEachKind() {
        let tally = StructureBacklogTally(finding(.shape, 3) + finding(.echoName, 2))
        #expect(tally.counts[.shape] == 3)
        #expect(tally.counts[.echoName] == 2)
        #expect(tally.counts[.deadWeight] == nil, "a kind with none is absent, not zero")
    }

    /// **The kinds you can drive to zero come first.**
    ///
    /// Not biggest-first, which is what a summary of fifty-three otherwise wants to do.
    /// `FindingKind.carriesPlan` exists one surface up for this exact reason — *a badge you cannot
    /// drive to zero is a badge people stop reading* — and leading a breakdown with `31 Dead
    /// weight`, which reports and offers no plan, buries the findings that have a button.
    @Test func actionableKindsLeadTheLine() {
        // Dead weight is much the largest and carries no plan; Echo is small and does.
        let tally = StructureBacklogTally(finding(.deadWeight, 40) + finding(.echoName, 2))
        #expect(tally.kinds == [.echoName, .deadWeight])
        #expect(tally.breakdown.hasPrefix("2 "), "the breakdown led with the kind nothing can fix")
    }

    /// Declared order within each half, so the line does not reshuffle as a tree changes under it.
    @Test func theOrderIsStableWithinEachHalf() {
        let all = FindingKind.allCases.flatMap { finding($0, 1) }
        #expect(StructureBacklogTally(all).kinds
                == FindingKind.allCases.filter(\.carriesPlan)
                    + FindingKind.allCases.filter { !$0.carriesPlan })
        // Same set, different arrival order, same line.
        #expect(StructureBacklogTally(all.reversed()).breakdown
                == StructureBacklogTally(all).breakdown)
    }

    /// **The words are the lens's own.**
    ///
    /// `RestructureLens.kindLabel` is the tag every finding wears on its card inside the lens, so a
    /// summary naming the same kinds differently would read as a different measurement of a
    /// different thing. The same rule `RenameBacklogTally` follows against `RenamePassLens.summary`,
    /// and the same reason: two vocabularies for one fact is how they drift.
    @Test func theBreakdownQuotesTheLensesOwnTags() {
        for kind in FindingKind.allCases {
            let line = StructureBacklogTally(finding(kind, 4)).breakdown
            #expect(line == "4 \(RestructureLens.kindLabel(kind))",
                    "\(kind.rawValue) is summarised as \(line)")
        }
    }

    @Test func aFullLineReadsAsOneRun() {
        let tally = StructureBacklogTally(finding(.shape, 31) + finding(.looseBesideContainer, 14)
                                          + finding(.deadWeight, 8))
        #expect(tally.breakdown == "31 Shape · 14 Loose folder · 8 Dead weight")
    }

    /// Empty rather than a dangling separator, so the caller can append it or not without asking.
    @Test func nothingToBreakDownSaysNothing() {
        #expect(StructureBacklogTally([]).breakdown.isEmpty)
        #expect(StructureBacklogTally([]).kinds.isEmpty)
    }

    /// Thousands separate, like every other count on this screen.
    @Test func countsAreFormatted() {
        #expect(StructureBacklogTally(finding(.shape, 1_200)).breakdown
                == "\(1_200.formatted()) Shape")
    }
}
