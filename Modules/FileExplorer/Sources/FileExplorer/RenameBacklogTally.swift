import Foundation
import Sync

/// What a rename backlog would actually do, counted **in files**, for the summary row above it.
///
/// ## Why this exists
///
/// The backlog's chip counts *folders*, because a folder is the unit the planner decides and the
/// unit the manager applies — a plan's steps are chosen against each other, so half of one is not a
/// smaller version of the same change, and a chip reading "1,240 to rename" beside a list of 126
/// rows would be counting something you cannot point at.
///
/// But nothing renames a folder. The first question "126 folders to rename" invites is *what is
/// being renamed* — and the honest answer, files, was reachable only by clicking through. So the
/// chip keeps the number that matches its list and this says what that number costs, one zone to
/// the right: `1,240 renames · 1,180 to pad · 44 to name · 16 to reshuffle · 6 left alone`.
///
/// ## Why the words are here and not at the call site
///
/// They are `RenamePassLens.summary`'s words, deliberately — the per-folder row already says
/// "to pad", "to name", "to reshuffle" and "left alone", and a header that summarised the same
/// plans in different vocabulary would read as a different measurement of a different thing. Pure
/// and static, so the arithmetic is testable without mounting anything.
struct RenameBacklogTally: Equatable {
    /// Every rename the listed plans propose. The headline: this is what "apply all" would do.
    let renames: Int
    /// Steps that only respell a name already in the grammar — `4. Apr 2021.pdf` →
    /// `04. Apr 2021.pdf`. Almost always the bulk of a backlog, and the one kind that changes
    /// nothing about where a file sits.
    let padded: Int
    /// Steps giving a raw name a slot it did not have — `9829custbill07182023.pdf` →
    /// `07. Jul 2023.pdf`.
    let named: Int
    /// Steps whose slot moved to make room for one of the above. Called out separately because it
    /// is the only kind here that touches a file that was already correct.
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

    /// The three step kinds, in the order a folder's own row names them.
    ///
    /// **Rare and consequential first, bulk last** — not biggest first, which is what a header
    /// summarising 126 folders otherwise wants to do. A reshuffle is the only thing this feature
    /// does that moves a file which was already correct, so it has to survive being read quickly;
    /// leading with `1,134 to pad` would bury the sixteen renames that are worth a second look
    /// behind the eleven hundred that are not.
    private var stepParts: [String] {
        var parts: [String] = []
        if named > 0 { parts.append("\(named.formatted()) to name") }
        if reshuffled > 0 { parts.append("\(reshuffled.formatted()) to reshuffle") }
        if padded > 0 { parts.append("\(padded.formatted()) to pad") }
        return parts
    }

    /// The kinds behind the headline, as one quiet run of prose — `42 to name · 16 to reshuffle ·
    /// 1,134 to pad · 7 left alone`.
    ///
    /// **One string, not four more badges.** Drawn as separate `SummaryRun`s each kind took a glyph
    /// and a bolded number, which gave a *breakdown of one total* the same weight as the total and
    /// put five numbers on a row whose whole job is to be read at a glance. A breakdown reads as a
    /// breakdown when it is subordinate.
    ///
    /// Empty when there is nothing to break down, so the caller draws nothing rather than a
    /// dangling separator. ``claim`` is the never-silent form.
    var breakdown: String {
        (stepParts + (skipped > 0 ? ["\(skipped.formatted()) left alone"] : []))
            .joined(separator: " · ")
    }

    /// One folder's own claim, under its name in the backlog list.
    ///
    /// ``breakdown``, except that it always says something: a plan of nothing but skips reads as a
    /// clean folder otherwise, when in fact the pass looked and declined. This is why the header and
    /// the rows can share an implementation at all — same words, same order, same separator, one
    /// place to change them.
    var claim: String {
        var s = stepParts.isEmpty ? "nothing to do" : stepParts.joined(separator: " · ")
        if skipped > 0 { s += " · \(skipped.formatted()) left alone" }
        return s
    }
}
