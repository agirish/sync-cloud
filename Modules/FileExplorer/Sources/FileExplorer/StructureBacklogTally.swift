import Foundation
import Sync

/// What a structure backlog is made of, for the one line under its card on Organize's overview.
///
/// A summary, not sample rows: Restructure's findings are deep paths that repeat their parents,
/// so a few of them say little beyond "not empty". To File and Duplicates keep sample rows, which
/// are short and actionable; Renames summarises in its blurb, as this does.
///
/// The words are ``RestructureLens/kindLabel(_:)``'s, the tag each finding wears inside the lens,
/// as ``RenameBacklogTally`` uses `RenamePassLens.summary`'s. `theBreakdownQuotesTheLensesOwnTags`
/// keeps the two from drifting.
struct StructureBacklogTally {

    /// How many findings of each kind, kinds with none omitted.
    let counts: [FindingKind: Int]

    init(_ findings: [StructureFinding]) {
        counts = findings.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
    }

    /// The kinds present with their counts, those you can drive to zero first. Pairs, so
    /// ``breakdown`` never looks up a missing count.
    ///
    /// Ordered by ``FindingKind/carriesPlan``, not size: leading with a kind that offers no plan
    /// would bury the findings that have a button. Declared order within each half, so the line
    /// doesn't reshuffle as the tree changes.
    var kinds: [(kind: FindingKind, count: Int)] {
        let present = FindingKind.allCases.compactMap { kind -> (kind: FindingKind, count: Int)? in
            guard let n = counts[kind], n > 0 else { return nil }
            return (kind, n)
        }
        return present.filter(\.kind.carriesPlan) + present.filter { !$0.kind.carriesPlan }
    }

    /// The line: `31 Shape · 14 Loose folder · 8 Dead weight`. Empty when there is nothing to
    /// break down, so the caller draws no dangling separator, as with
    /// `RenameBacklogTally.breakdown`.
    ///
    /// Uncapped: a real tree shows two or three kinds, and "and 4 more" would tell nobody whether
    /// to open the lens. It wraps instead and never hides a kind.
    var breakdown: String {
        kinds.map { "\($0.count.formatted()) \(RestructureLens.kindLabel($0.kind))" }
            .joined(separator: " · ")
    }
}
