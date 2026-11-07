import Foundation

/// Stepping ↑/↓ between the pages of a pair that actually differ.
///
/// The strip doesn't already know which pages differ: `pageStates` is filled one page at a time by
/// the raster refresh, which runs for the current page only. Stepping between the strip's dots
/// would only visit pages already looked at. So a step is a bounded search: walk on from the
/// current page, take a known verdict for free, compare where there is none, and stop at the
/// first page that differs.
///
/// At full compare resolution, never a thumbnail's: a downsampled comparison can prove two pages
/// differ but not that they match, since a one-pixel mark averages away. A dot is a claim somebody
/// checked, so "nothing further differs" must not come from thumbnails.
enum PageDifferenceStepper {

    /// How many pages one press will render before it stops looking.
    ///
    /// A press is a gesture, not a job: each page pair is tens of milliseconds at full resolution,
    /// so without a cap a long document would wedge the surface. Pages with a verdict cost nothing
    /// and aren't counted, so pressing again resumes: the budget bounds one press, not the search.
    static let renderBudget = 25

    /// Which verdicts a step stops at.
    ///
    /// `.changed` and `.oneSided` both do: a page only one side has is a difference worth landing
    /// on. `.unrenderable` doesn't, since nothing was compared there and stopping would present a
    /// failure as a finding. `.pending` is not a verdict at all.
    static func isDifference(_ state: PageDiffState) -> Bool {
        switch state {
        case .changed, .oneSided: return true
        case .same, .unrenderable, .pending: return false
        }
    }

    /// The pages to examine, in the order a press examines them.
    ///
    /// Every other page exactly once, wrapping, as the text stepper's ↑/↓ wrap from the last change
    /// to the first. The current page is excluded: landing where it started would read as a dead
    /// key on a two-page pair whose other page matches.
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
        /// `thenJumpTo` is a page known to differ that lies beyond them: the destination if none of
        /// the examined pages does. With page 1 uncompared and page 2 known changed, the next
        /// difference is 1 if 1 differs, else 2; forgetting the 2 would make the press do nothing.
        /// `nil` when the budget cut the walk short, since nothing is known beyond it.
        case examine([Int], thenJumpTo: Int?)
        /// Every page has a verdict and none of them differs, or there is nowhere to look.
        case nothingToFind
    }

    /// Known verdicts are used before anything is rendered, so stepping back through a walked
    /// document costs no render, and the search can't disagree with its own earlier verdicts.
    static func plan(from current: Int, direction: Int, stripLength: Int,
                     states: [Int: PageDiffState],
                     budget: Int = renderBudget) -> Plan {
        let order = searchOrder(from: current, direction: direction, stripLength: stripLength)
        guard !order.isEmpty else { return .nothingToFind }
        var toExamine: [Int] = []
        for page in order {
            guard let state = states[page], state != .pending else {
                // Out of budget: stop rather than look on for a fallback, since reaching a known
                // difference beyond here would skip pages nobody has examined.
                guard toExamine.count < budget else {
                    return .examine(toExamine, thenJumpTo: nil)
                }
                toExamine.append(page)
                continue
            }
            // A known difference wins outright only if nothing unexamined sits before it: the
            // reader asked for the next one. It is still the destination if none of those differ.
            if isDifference(state) {
                return toExamine.isEmpty ? .jump(to: page)
                                         : .examine(toExamine, thenJumpTo: page)
            }
        }
        return toExamine.isEmpty ? .nothingToFind : .examine(toExamine, thenJumpTo: nil)
    }

    /// What the strip says about how much of the document has been judged.
    ///
    /// "of N compared", never "of N pages": only visited and searched pages have verdicts, and a
    /// count against the document's length would claim all of it was checked. Silent until
    /// something has been compared, and when a one-page pair has no strip.
    static func caption(states: [Int: PageDiffState], stripLength: Int) -> String? {
        guard stripLength > 1 else { return nil }
        let resolved = states.values.filter { $0 != .pending }
        guard !resolved.isEmpty else { return nil }
        let differing = resolved.filter(isDifference).count
        return "\(differing) of \(resolved.count) compared differ"
    }
}
