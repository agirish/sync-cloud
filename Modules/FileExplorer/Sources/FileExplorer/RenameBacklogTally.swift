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

    /// The header's shorter form of ``breakdown``: the same words, fewer of them.
    ///
    /// ## Why the header needs its own string at all
    ///
    /// ``breakdown`` is pinned equal to `RenamePassLens.summary` — the header and the folder rows
    /// say the same thing in the same vocabulary, deliberately, and that is not a constraint to
    /// work around. But the two have very different room. A folder row owns a full line; the header
    /// shares a 22pt row with a readout, a divider and two buttons, and measured on the Renames
    /// lens `7 to name · 6 to reshuffle · 628 to pad · 2 left alone` is **268.5pt** — the single
    /// widest tenant of that row, and rigid (`.fixedSize()`) despite being subordinate to the
    /// headline it explains. This is 190.5pt for the same backlog.
    ///
    /// ## What it drops, and why each is safe
    ///
    /// - **The skips.** `breakdown` appends "N left alone" to a run that the header prefixes with
    ///   the *rename* total — and a skipped file is not among those renames. `641 renames · … ·
    ///   2 left alone` breaks its own total down into parts, one of which is not part of it. The
    ///   folder rows keep it (``claim``), where it sits under a folder's own name and is not
    ///   itemising anything.
    /// - **The separate spelling of the two rare kinds.** `to name` and `to reshuffle` collapse to
    ///   one clause when both are present, because at header scale the useful distinction is
    ///   routine-versus-not, and the split is one row below. **Only when both are present** — with
    ///   one of them the header names it exactly, which is both narrower and more precise than a
    ///   disjunction offering a kind that has no members.
    ///
    /// It does **not** invent vocabulary. Every word here is a word the folder rows use, which is
    /// the rule ``breakdown``'s doc states and the reason this is not "N to review".
    ///
    /// Rare and consequential first, bulk last — ``stepParts``' order, for ``stepParts``' reason.
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
        // **The one case where the skips ARE the breakdown.** Dropping them is right while there
        // are renames to itemise — they are not among that total. With no renames at all the
        // header reads "0 renames" and the skips are the only thing that explains the zero, so
        // withholding them here would answer a question with silence. `breakdown` never had to
        // make this distinction because it never dropped them.
        if parts.isEmpty && skipped > 0 { parts.append("\(skipped.formatted()) left alone") }
        return parts.joined(separator: " · ")
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
