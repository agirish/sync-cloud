import Foundation

/// Stepping ↑/↓ between the pages of a pair that actually differ.
///
/// **The strip does not already know which pages differ, and that is the whole shape of this
/// type.** `pageStates` is filled one page at a time by the raster refresh, which runs for the
/// CURRENT page only — so a fresh pair knows nothing, and a strip of ten pages the reader has
/// visited twice knows two things. A stepper written against "the dots the strip has" would jump
/// between the pages already looked at, which is the opposite of the question.
///
/// So the step is a bounded SEARCH: walk forward from where the reader is, take the verdict for
/// free where one exists, compare where one does not, and stop at the first page that differs.
///
/// **At full compare resolution, not at a thumbnail's.** `PagePairRaster` carried a second, much
/// smaller long edge for a cheap sweep of the whole document; this is why that sweep was never the
/// answer, and why the constant is now gone. A downsampled comparison can prove that two pages
/// DIFFER, but it cannot prove they are the same — a one-pixel mark averages away below the
/// tolerance. This surface's rule is that a dot is a claim somebody checked, which is why a pending
/// page gets no dot at all; a search reporting "nothing further differs" from thumbnails would be
/// making exactly the claim the strip refuses to make with a grey dot.
enum PageDifferenceStepper {

    /// How many pages one press will render before it stops looking.
    ///
    /// **A press is a gesture, not a job.** At full compare resolution a page pair is a render on
    /// each side plus a buffer pass — tens of milliseconds — so this is the difference between a
    /// noticeable pause and a wedged surface on a 300-page document. Pages that already have a
    /// verdict cost nothing and are not counted against it, so pressing again resumes rather than
    /// re-treading: the budget bounds one press, not the search.
    static let renderBudget = 25

    /// Which verdicts a step stops at.
    ///
    /// `.changed` and `.oneSided` both do — a page only one side has is a difference a reader
    /// stepping through differences wants to land on, even though the strip's length note has
    /// already said the counts disagree. `.unrenderable` does not: nothing was compared there, so
    /// stopping would present a failure as a finding. `.pending` is not a verdict at all.
    static func isDifference(_ state: PageDiffState) -> Bool {
        switch state {
        case .changed, .oneSided: return true
        case .same, .unrenderable, .pending: return false
        }
    }

    /// The pages to examine, in the order a press examines them.
    ///
    /// Every other page exactly once, wrapping — the grammar the text stepper already set, where
    /// ↑/↓ move between changes rather than between lines and the last one leads back to the
    /// first. The current page is excluded: a step that could land where it started would read as
    /// a dead key on a two-page pair whose other page matches.
    static func searchOrder(from current: Int, direction: Int, stripLength: Int) -> [Int] {
        guard stripLength > 1, direction != 0 else { return [] }
        let step = direction > 0 ? 1 : -1
        return (1..<stripLength).map { offset in
            let raw = (current + step * offset) % stripLength
            return raw < 0 ? raw + stripLength : raw
        }
    }

    /// What a press should do, given what is already known.
    enum Plan: Equatable {
        /// A page already known to differ — jump straight there, rendering nothing.
        case jump(to: Int)
        /// Examine these, in order, and stop at the first that differs. Never longer than
        /// ``renderBudget``.
        ///
        /// `thenJumpTo` is a page already known to differ that lies BEYOND them — the destination
        /// if none of the examined pages does. It exists because the search walks past known
        /// verdicts for free: with page 1 uncompared and page 2 known changed, the answer to "next
        /// difference" is 1 if 1 differs and 2 otherwise, and a plan that forgot the 2 would end
        /// the press on a key that did nothing. `nil` when the budget cut the walk short, since
        /// nothing is then known about what lies beyond it.
        case examine([Int], thenJumpTo: Int?)
        /// Every page has a verdict and none of them differs, or there is nowhere to look.
        case nothingToFind
    }

    /// **Known verdicts are consumed before anything is rendered.** A reader who has walked a
    /// document and comes back to step through it should not pay for a single render, and a search
    /// that re-compared pages it had already judged would also be free to disagree with itself.
    static func plan(from current: Int, direction: Int, stripLength: Int,
                     states: [Int: PageDiffState],
                     budget: Int = renderBudget) -> Plan {
        let order = searchOrder(from: current, direction: direction, stripLength: stripLength)
        guard !order.isEmpty else { return .nothingToFind }
        var toExamine: [Int] = []
        for page in order {
            guard let state = states[page], state != .pending else {
                // Out of budget: stop walking rather than keep looking for a fallback, because a
                // known difference found beyond here would be reached by skipping pages nobody
                // has examined — which answers a different question.
                guard toExamine.count < budget else {
                    return .examine(toExamine, thenJumpTo: nil)
                }
                toExamine.append(page)
                continue
            }
            // A known difference wins outright ONLY if nothing unexamined sits before it: the
            // reader asked for the NEXT one, and skipping over an uncompared page to reach a
            // known one further on would answer a different question. It is still the destination
            // if none of those pages turns out to differ.
            if isDifference(state) {
                return toExamine.isEmpty ? .jump(to: page)
                                         : .examine(toExamine, thenJumpTo: page)
            }
        }
        return toExamine.isEmpty ? .nothingToFind : .examine(toExamine, thenJumpTo: nil)
    }

    /// What the strip says about how much of the document has been judged.
    ///
    /// **"of N compared", never "of N pages".** Only visited and searched pages have verdicts, so
    /// a count phrased against the document's length would claim the whole of it had been checked
    /// — the same over-claim the strip refuses when it withholds a dot from a pending page.
    /// Silent until something has been compared, and silent when a one-page pair has no strip.
    static func caption(states: [Int: PageDiffState], stripLength: Int) -> String? {
        guard stripLength > 1 else { return nil }
        let resolved = states.values.filter { $0 != .pending }
        guard !resolved.isEmpty else { return nil }
        let differing = resolved.filter(isDifference).count
        return "\(differing) of \(resolved.count) compared differ"
    }
}
