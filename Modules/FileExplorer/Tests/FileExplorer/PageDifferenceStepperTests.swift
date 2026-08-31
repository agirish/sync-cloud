import Foundation
import Testing
@testable import FileExplorer

/// ↑/↓ between the pages of a pair that differ.
///
/// **The rule the whole suite is built around: the strip does not already know.** `pageStates` is
/// filled by the raster refresh, which runs for the current page alone, so a fresh pair knows
/// nothing and a stepper written against "the dots the strip has" would jump between the pages
/// already looked at — the opposite of the question. Every plan below is therefore checked for
/// what it EXAMINES, not just where it lands.
@Suite struct PageDifferenceStepperTests {

    // MARK: Order

    @Test func aStepForwardWalksTheFollowingPagesAndWraps() {
        #expect(PageDifferenceStepper.searchOrder(from: 2, direction: 1, stripLength: 5)
                == [3, 4, 0, 1])
    }

    @Test func aStepBackWalksThePrecedingPagesAndWraps() {
        #expect(PageDifferenceStepper.searchOrder(from: 2, direction: -1, stripLength: 5)
                == [1, 0, 4, 3])
    }

    /// The current page is never in the order: a step that could land where it started would read
    /// as a dead key on a two-page pair whose other page matches.
    @Test(arguments: [1, -1]) func theCurrentPageIsNeverExamined(direction: Int) {
        let order = PageDifferenceStepper.searchOrder(from: 3, direction: direction,
                                                      stripLength: 7)
        #expect(!order.contains(3))
        #expect(Set(order).count == 6, "every other page exactly once")
    }

    @Test func aOnePageStripHasNowhereToStep() {
        #expect(PageDifferenceStepper.searchOrder(from: 0, direction: 1, stripLength: 1).isEmpty)
    }

    // MARK: What counts as a difference

    /// `.unrenderable` must not stop a step: nothing was compared there, so landing on it would
    /// present a failure as a finding.
    @Test func onlyRealFindingsStopAStep() {
        #expect(PageDifferenceStepper.isDifference(.changed(fraction: 0.01)))
        #expect(PageDifferenceStepper.isDifference(.oneSided))
        #expect(!PageDifferenceStepper.isDifference(.same))
        #expect(!PageDifferenceStepper.isDifference(.unrenderable))
        #expect(!PageDifferenceStepper.isDifference(.pending))
    }

    // MARK: Planning

    /// Known verdicts are consumed before anything is rendered — a reader who has walked a
    /// document and comes back to step through it pays for no renders at all.
    @Test func aKnownDifferingPageIsJumpedToWithoutRendering() {
        let states: [Int: PageDiffState] = [1: .same, 2: .changed(fraction: 0.2)]
        #expect(PageDifferenceStepper.plan(from: 0, direction: 1, stripLength: 4, states: states)
                == .jump(to: 2))
    }

    /// **The ordering rule that makes the answer the NEXT difference rather than any difference.**
    /// Page 1 has never been compared and page 2 is known to differ; jumping to 2 would skip over
    /// a page that might differ too, answering a question the reader did not ask.
    @Test func anUncomparedPageBeforeAKnownOneIsExaminedFirst() {
        let states: [Int: PageDiffState] = [2: .changed(fraction: 0.2)]
        // Not [1, 3]: page 2 is a guaranteed stop, so page 3 is beyond the answer either way —
        // and page 2 is carried as the destination for the case where page 1 turns out to match.
        #expect(PageDifferenceStepper.plan(from: 0, direction: 1, stripLength: 4, states: states)
                == .examine([1], thenJumpTo: 2))
    }

    @Test func afreshPairExaminesEveryOtherPageInOrder() {
        #expect(PageDifferenceStepper.plan(from: 0, direction: 1, stripLength: 4, states: [:])
                == .examine([1, 2, 3], thenJumpTo: nil))
    }

    /// Pending is not a verdict — a page mid-render must still be examined, or a search launched
    /// while one was in flight would skip it for ever.
    @Test func aPendingStateIsTreatedAsUnknown() {
        #expect(PageDifferenceStepper.plan(from: 0, direction: 1, stripLength: 3,
                                           states: [1: .pending])
                == .examine([1, 2], thenJumpTo: nil))
    }

    @Test func everyPageJudgedAndNoneDifferingFindsNothing() {
        let states: [Int: PageDiffState] = [0: .same, 1: .same, 2: .same, 3: .unrenderable]
        #expect(PageDifferenceStepper.plan(from: 0, direction: 1, stripLength: 4, states: states)
                == .nothingToFind)
    }

    @Test func aOnePageStripFindsNothing() {
        #expect(PageDifferenceStepper.plan(from: 0, direction: 1, stripLength: 1, states: [:])
                == .nothingToFind)
    }

    /// **A press is a gesture, not a job.** One press renders at most `renderBudget` pages, so a
    /// 300-page document pauses rather than wedging.
    @Test func onePressExaminesNoMoreThanItsBudget() {
        guard case .examine(let pages, let fallback) = PageDifferenceStepper.plan(
            from: 0, direction: 1, stripLength: 500, states: [:]) else {
            Issue.record("expected a search")
            return
        }
        #expect(pages.count == PageDifferenceStepper.renderBudget)
        #expect(pages == Array(1...PageDifferenceStepper.renderBudget))
        #expect(fallback == nil, "nothing is known beyond a truncated walk")
    }

    /// The budget bounds one press, not the search: pages that already have a verdict cost nothing
    /// and are not counted against it, so a second press resumes rather than re-treading.
    @Test func alreadyJudgedPagesDoNotSpendTheBudget() {
        var states: [Int: PageDiffState] = [:]
        for page in 1...50 { states[page] = .same }
        guard case .examine(let pages, _) = PageDifferenceStepper.plan(
            from: 0, direction: 1, stripLength: 500, states: states) else {
            Issue.record("expected a search")
            return
        }
        #expect(pages.first == 51, "the search resumed past what was already judged")
        #expect(pages.count == PageDifferenceStepper.renderBudget)
    }

    // MARK: The caption

    /// **"of N compared", never "of N pages"**: only visited and searched pages have verdicts, and
    /// a count phrased against the document's length would claim the whole of it was checked.
    @Test func theCaptionCountsWhatWasComparedRatherThanTheDocument() {
        let states: [Int: PageDiffState] = [0: .same, 1: .changed(fraction: 0.1), 2: .pending]
        #expect(PageDifferenceStepper.caption(states: states, stripLength: 40)
                == "1 of 2 compared differ")
    }

    @Test func theCaptionIsSilentBeforeAnythingHasBeenCompared() {
        #expect(PageDifferenceStepper.caption(states: [:], stripLength: 40) == nil)
        #expect(PageDifferenceStepper.caption(states: [0: .pending], stripLength: 40) == nil)
    }

    @Test func aOnePageStripHasNoCaption() {
        #expect(PageDifferenceStepper.caption(states: [0: .same], stripLength: 1) == nil)
    }
}

// MARK: - The fallback destination
//
// The case that made `thenJumpTo` exist: a plan that examined the uncompared pages before a known
// difference and then forgot the known one ended the press on a key that did nothing.
extension PageDifferenceStepperTests {

    /// Examining page 1 first is right; **dropping page 2 is not.** If page 1 matches, page 2 is
    /// still the next difference, and the press has to land there.
    @Test func aKnownDifferenceBeyondTheExaminedPagesIsCarriedAsTheDestination() {
        let plan = PageDifferenceStepper.plan(from: 0, direction: 1, stripLength: 6,
                                              states: [3: .changed(fraction: 0.3)])
        #expect(plan == .examine([1, 2], thenJumpTo: 3))
    }

    /// And it is dropped where it should be: past the budget nothing is known about what lies
    /// beyond, so carrying a destination would be skipping pages nobody examined.
    @Test func atruncatedWalkCarriesNoDestination() {
        var states: [Int: PageDiffState] = [:]
        states[PageDifferenceStepper.renderBudget + 5] = .changed(fraction: 0.3)
        let plan = PageDifferenceStepper.plan(from: 0, direction: 1, stripLength: 500,
                                              states: states)
        #expect(plan == .examine(Array(1...PageDifferenceStepper.renderBudget), thenJumpTo: nil))
    }
}
