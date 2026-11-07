import Foundation
import Sync

/// What a rename backlog would actually do, counted in files, for the summary row above it.
///
/// The backlog's chip counts folders, the unit the planner decides and the manager applies, so it
/// matches the list beside it. But nothing renames a folder: this says what that number costs in
/// files, e.g. `1,240 renames · 44 to name · 16 to reshuffle · 1,180 to pad · 6 left alone`.
///
/// The words are `RenamePassLens.summary`'s, so the header and the folder rows read as one
/// measurement. Pure, so the arithmetic is testable without mounting anything.
struct RenameBacklogTally: Equatable {
    /// Every rename the listed plans propose. The headline: this is what "apply all" would do.
    let renames: Int
    /// Steps that only respell a name already in the grammar (`4. Apr 2021.pdf` →
    /// `04. Apr 2021.pdf`). Usually the bulk of a backlog; they don't change where a file sits.
    let padded: Int
    /// Steps giving a raw name a slot it did not have (`9829custbill07182023.pdf` →
    /// `07. Jul 2023.pdf`).
    let named: Int
    /// Steps whose slot moved to make room for one of the above: the only kind that touches a file
    /// that was already correct.
    let reshuffled: Int
    /// Files the pass deliberately declined to rename.
    let skipped: Int

    init(_ plans: [RenamePlan]) {
        renames = plans.reduce(0) { $0 + $1.steps.count }
        padded = plans.reduce(0) { $0 + $1.tidied }
        named = plans.reduce(0) { $0 + $1.placed }
        reshuffled = plans.reduce(0) { $0 + $1.renumbered }
        skipped = plans.reduce(0) { $0 + $1.skips.count }
    }

    /// The three step kinds, in the order a folder's own row names them: rare and consequential
    /// first, bulk last, not biggest first. Leading with `1,134 to pad` would bury the few renames
    /// worth a second look.
    private var stepParts: [String] {
        var parts: [String] = []
        if named > 0 { parts.append("\(named.formatted()) to name") }
        if reshuffled > 0 { parts.append("\(reshuffled.formatted()) to reshuffle") }
        if padded > 0 { parts.append("\(padded.formatted()) to pad") }
        return parts
    }

    /// The kinds behind the headline, as one quiet run of prose: `42 to name · 16 to reshuffle ·
    /// 1,134 to pad · 7 left alone`. One string, not more badges, so the breakdown stays
    /// subordinate to its total.
    ///
    /// Empty when there is nothing to break down, so the caller draws no dangling separator.
    /// ``claim`` is the never-silent form.
    var breakdown: String {
        (stepParts + (skipped > 0 ? ["\(skipped.formatted()) left alone"] : []))
            .joined(separator: " · ")
    }

    /// The header's shorter form of ``breakdown``: the same words, fewer of them. The header
    /// shares a 22pt row with a readout, a divider and two buttons, where the full breakdown is the
    /// widest and a rigid tenant.
    ///
    /// - It drops the skips: the header prefixes the rename total, and a skipped file is not among
    ///   those renames. The folder rows keep them (``claim``).
    /// - With both rare kinds present it folds them into one "to name or reshuffle" clause; with
    ///   one, it names that one exactly.
    ///
    /// Every word is one the folder rows use, so this is not "N to review". Order as ``stepParts``.
    var headerBreakdown: String {
        var parts: [String] = []
        let consequential = named + reshuffled
        if named > 0 && reshuffled > 0 {
            parts.append("\(consequential.formatted()) to name or reshuffle")
        } else if named > 0 {
            parts.append("\(named.formatted()) to name")
        } else if reshuffled > 0 {
            parts.append("\(reshuffled.formatted()) to reshuffle")
        }
        if padded > 0 { parts.append("\(padded.formatted()) to pad") }
        // With no renames the header reads "0 renames", and the skips are the only thing that
        // explains the zero, so they come back.
        if parts.isEmpty && skipped > 0 { parts.append("\(skipped.formatted()) left alone") }
        return parts.joined(separator: " · ")
    }

    /// One folder's own claim, under its name in the backlog list. ``breakdown``, except that it
    /// always says something: a plan of nothing but skips would otherwise read as a clean folder,
    /// when the pass looked and declined. Same words, order and separator as the header.
    var claim: String {
        var s = stepParts.isEmpty ? "nothing to do" : stepParts.joined(separator: " · ")
        if skipped > 0 { s += " · \(skipped.formatted()) left alone" }
        return s
    }
}
