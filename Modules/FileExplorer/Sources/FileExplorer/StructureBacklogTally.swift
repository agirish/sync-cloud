import Foundation
import Sync

/// What a structure backlog is *made of*, for the one line under its card on Organize's overview.
///
/// ## Why this exists
///
/// The card used to spend three lines on `scoped.prefix(3).map(\.headline)` — three findings off
/// the front of an unsorted list. On a real tree that produced this:
///
/// ```
/// Claude/Projects/Work/Reference/Hardware/1s-and-0s — remotion/node_modules — 127 folders, 4 schemes
/// Claude/Projects/Work/Reference/Hardware/1s-and-0s — remotion/node_modules/@types/eslint-scope — beside its container
/// Claude/Projects/Work/Reference/Hardware/1s-and-0s — remotion/node_modules/esbuild — two names for one thing
/// ```
///
/// Three lines, one subtree, sixty characters of shared prefix, and the whole of what they told
/// you was that the list is not empty — which the `53 findings` pill three inches away had already
/// said. A sample that is `prefix(3)` of an unsorted list is not a sample; it is whatever sorts
/// first.
///
/// **To File and Duplicates keep their rows and should**: `Invoice.pdf → Finance` and
/// `clip.mp4 — 2 copies` are short, distinct, and things you can act on without opening anything.
/// The difference is not the card, it is what the lens has to show — Restructure's rows are deep
/// paths that repeat their parents, and three of them cannot represent fifty-three.
///
/// **Renames already answered half of this**, which is the precedent rather than a new idea: it
/// summarised rather than sampling long before this type existed. It was putting that summary in
/// the detail slot too, though, where a monospaced font meant for filenames was setting a run of
/// prose; both arms carry their breakdown in the blurb now, and the slot is left to the two lenses
/// whose rows really are identifiers.
///
/// ## Why the words are here and not at the call site
///
/// They are ``RestructureLens/kindLabel(_:)``'s words, deliberately, exactly as
/// ``RenameBacklogTally`` takes `RenamePassLens.summary`'s. That label is the tag every finding
/// wears on its own card inside the lens, so a summary that named the same kinds differently would
/// read as a different measurement of a different thing — and `theBreakdownQuotesTheLensesOwnTags`
/// pins the two together so they cannot drift.
struct StructureBacklogTally {

    /// How many findings of each kind, kinds with none omitted.
    let counts: [FindingKind: Int]

    init(_ findings: [StructureFinding]) {
        counts = findings.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
    }

    /// The kinds present **and their counts**, the ones you can drive to zero first.
    ///
    /// Pairs rather than kinds alone, so ``breakdown`` cannot look a count up and find nothing:
    /// it read `counts[kind]?.formatted() ?? "0"`, and that `"0"` was a fallback for a state this
    /// very filter makes unrepresentable — a branch that can only ever be wrong if it is ever
    /// reached.
    ///
    /// Not biggest-first, which is what a summary of fifty-three otherwise wants to do. The
    /// distinction is ``FindingKind/carriesPlan``, which exists for this exact reason one surface
    /// up — *"a badge you cannot drive to zero is a badge people stop reading"* — and the same
    /// argument applies to a breakdown: leading with `31 Dead weight`, which reports and offers no
    /// plan, buries the fourteen findings that have a button behind the ones that do not.
    ///
    /// Declared order within each half, so the line does not reshuffle itself as a tree changes.
    var kinds: [(kind: FindingKind, count: Int)] {
        let present = FindingKind.allCases.compactMap { kind -> (kind: FindingKind, count: Int)? in
            guard let n = counts[kind], n > 0 else { return nil }
            return (kind, n)
        }
        return present.filter(\.kind.carriesPlan) + present.filter { !$0.kind.carriesPlan }
    }

    /// The line: `31 Shape · 14 Loose folder · 8 Dead weight`.
    ///
    /// Empty when there is nothing to break down, so the caller draws nothing rather than a
    /// dangling separator — the same contract `RenameBacklogTally.breakdown` has.
    ///
    /// **Uncapped, and that is a decision.** Ten kinds exist and a real tree shows two or three;
    /// a cap would need a rule for what "and 4 more" means to somebody deciding whether to open
    /// the lens, and there is no useful answer to that. The line wraps instead, which costs a
    /// second row on a narrow pane and never hides a kind.
    var breakdown: String {
        kinds.map { "\($0.count.formatted()) \(RestructureLens.kindLabel($0.kind))" }
            .joined(separator: " · ")
    }
}
