import Testing
import Foundation
import Events
@testable import Dashboard

/// Characterization tests for the Activity Log's history state machine, each rule read off
/// `LogViewer`'s call sites:
///   - A load won't start while one is in flight or history is already loaded.
///   - A completion applies only if its token is current, and reveals the first page.
///   - Clear Logs resets everything at once and invalidates in-flight loads.
///   - A level or search change resets the page size; "Show more" grows it.
///   - `nil` history offers the reload button; empty history says "no earlier activity".
@Suite struct LogHistoryStateTests {

    private func entry(_ message: String) -> LogEntry {
        LogEntry(timestamp: Date(timeIntervalSince1970: 1_780_000_000), level: .info, message: message)
    }

    private let pageSize = 25

    // MARK: The load guard (was: `guard !isLoadingHistory, loadedHistory == nil`)

    @Test func aFreshStateCanStartALoad() {
        var state = LogHistoryState.notLoaded
        let token = state.beginLoading()
        #expect(token != nil)
        #expect(state.isLoading)
        #expect(!state.isLoaded)
        #expect(state.entries == nil)
    }

    @Test func aSecondLoadCannotStartWhileOneIsInFlight() {
        var state = LogHistoryState.notLoaded
        _ = state.beginLoading()
        // Stops the button double-firing: the claim itself fails, so a caller can't forget to
        // check.
        let second = state.beginLoading()
        #expect(second == nil)
    }

    @Test func loadingDoesNotRestartOnceHistoryIsLoaded() {
        var state = LogHistoryState.notLoaded
        let token = state.beginLoading()!
        state.finishLoading([entry("old")], token: token, pageSize: pageSize)
        let again = state.beginLoading()
        #expect(again == nil)
    }

    // MARK: Completion (was: the generation guard + `historyLimit = pageSize`)

    @Test func aCompletedLoadRevealsTheFirstPage() {
        var state = LogHistoryState.notLoaded
        let token = state.beginLoading()!
        let applied = state.finishLoading([entry("a"), entry("b")], token: token, pageSize: pageSize)
        #expect(applied)
        #expect(state.entries?.count == 2)
        #expect(state.revealed == pageSize)
        #expect(state.isLoaded)
        #expect(!state.isLoading)
    }

    @Test func anEmptyParseStillCountsAsLoaded() {
        // The footer depends on this: nil offers "Show older history", empty says "No earlier
        // activity in the log". Collapsing them would leave a button re-reading a file known to
        // hold nothing.
        var state = LogHistoryState.notLoaded
        let token = state.beginLoading()!
        state.finishLoading([], token: token, pageSize: pageSize)
        #expect(state.isLoaded)
        #expect(state.entries?.isEmpty == true)
    }

    @Test func aLoadThatFinishesAfterAClearIsDiscarded() {
        // The central rule: a read parsed from the pre-clear file must not bring back deleted rows,
        // nor make `entries` non-nil again, which would hide the reload button for the window's
        // lifetime.
        var state = LogHistoryState.notLoaded
        let token = state.beginLoading()!
        state.reset()   // Clear Logs arrives while the read is in flight

        let applied = state.finishLoading([entry("deleted")], token: token, pageSize: pageSize)
        #expect(applied == false)
        #expect(state.entries == nil)
        #expect(!state.isLoaded)
        // And the reload button is available again.
        let retry = state.beginLoading()
        #expect(retry != nil)
    }

    @Test func aSupersededLoadCannotOverwriteANewerOne() {
        // Clear, then a second load: the first read's completion must lose, because its token is
        // no longer current.
        var state = LogHistoryState.notLoaded
        let stale = state.beginLoading()!
        state.reset()
        let fresh = state.beginLoading()!
        #expect(stale != fresh)

        let staleApplied = state.finishLoading([entry("stale")], token: stale, pageSize: pageSize)
        #expect(staleApplied == false)
        let freshApplied = state.finishLoading([entry("fresh")], token: fresh, pageSize: pageSize)
        #expect(freshApplied)
        #expect(state.entries?.map(\.message) == ["fresh"])
    }

    // MARK: Paging (was: `historyLimit`)

    @Test func showMoreRevealsAnotherPage() {
        var state = LogHistoryState.notLoaded
        let token = state.beginLoading()!
        state.finishLoading([entry("a")], token: token, pageSize: pageSize)
        state.revealMore(by: pageSize)
        #expect(state.revealed == pageSize * 2)
    }

    @Test func aFilterChangeCollapsesBackToTheFirstPage() {
        // A new level or search is a fresh view of history, so the list must not stay expanded to
        // hundreds of now-filtered rows.
        var state = LogHistoryState.notLoaded
        let token = state.beginLoading()!
        state.finishLoading([entry("a")], token: token, pageSize: pageSize)
        state.revealMore(by: pageSize)
        state.revealMore(by: pageSize)

        state.resetRevealed(to: pageSize)
        #expect(state.revealed == pageSize)
        // …without disturbing what was parsed.
        #expect(state.entries?.count == 1)
    }

    @Test func pagingIsInertWhileNotLoaded() {
        // Paging calls do nothing before a load, and `revealed` stays 0, so a `prefix` against it
        // yields nothing.
        var state = LogHistoryState.notLoaded
        state.revealMore(by: pageSize)
        state.resetRevealed(to: pageSize)
        #expect(state.revealed == 0)
        #expect(!state.isLoaded)

        _ = state.beginLoading()
        state.revealMore(by: pageSize)
        #expect(state.revealed == 0)
        #expect(state.isLoading)   // and paging did not knock it out of `.loading`
    }

    // MARK: Reset (was: the four-variable Clear Logs handler)

    @Test func resetForgetsEverythingAtOnce() {
        // A partial reset would leave deleted rows on screen and the reload button gone. One case
        // assignment can't be partial.
        var state = LogHistoryState.notLoaded
        let token = state.beginLoading()!
        state.finishLoading([entry("a"), entry("b")], token: token, pageSize: pageSize)
        state.revealMore(by: pageSize)

        state.reset()

        #expect(state.entries == nil)
        #expect(state.revealed == 0)
        #expect(!state.isLoading)
        #expect(!state.isLoaded)
    }

    @Test func resetWhileIdleIsHarmless() {
        // Clear Logs can arrive with no history ever loaded (the common case).
        var state = LogHistoryState.notLoaded
        state.reset()
        #expect(!state.isLoaded)
        let token = state.beginLoading()
        #expect(token != nil)
    }

    // MARK: A failed read (was: indistinguishable from an empty one)

    @Test func aFailedReadIsNeitherLoadedNorEmptyHistory() {
        // A read failure must not look like "loaded, and there is nothing older".
        var state = LogHistoryState.notLoaded
        let token = state.beginLoading()!
        let applied = state.failLoading(token: token)
        #expect(applied)
        #expect(state.readFailed)
        #expect(!state.isLoaded)
        #expect(!state.isLoading)
        #expect(state.entries == nil)
    }

    @Test func aFailedReadCanBeRetried() {
        // An unreadable log is usually a torn write the next read gets past; refusing the retry
        // (as `.loaded` does, by design) would leave the window on the error for its lifetime.
        var state = LogHistoryState.notLoaded
        let first = state.beginLoading()!
        state.failLoading(token: first)

        let retry = state.beginLoading()
        #expect(retry != nil)
        #expect(state.isLoading)
        #expect(!state.readFailed)   // the retry supersedes the failure

        state.finishLoading([entry("recovered")], token: retry!, pageSize: pageSize)
        #expect(state.entries?.map(\.message) == ["recovered"])
    }

    @Test func aFailureFromASupersededReadIsDiscarded() {
        // The same token guard as `finishLoading`: a failure arriving after Clear Logs must not
        // knock the reset state into `.failed` for a read nobody is awaiting.
        var state = LogHistoryState.notLoaded
        let token = state.beginLoading()!
        state.reset()

        let applied = state.failLoading(token: token)
        #expect(applied == false)
        #expect(!state.readFailed)
        #expect(state.beginLoading() != nil)
    }

    @Test func successAndFailureAreMutuallyExclusive() {
        var loaded = LogHistoryState.notLoaded
        let token = loaded.beginLoading()!
        loaded.finishLoading([], token: token, pageSize: pageSize)
        // An empty load is loaded, not failed: the footer's wording rests on it.
        #expect(loaded.isLoaded && !loaded.readFailed)
    }

    // MARK: The "Show N more" count

    @Test func theRevealCountIsAFullPageWhileMoreThanAPageIsHidden() {
        #expect(LogHistoryState.nextRevealCount(matchCount: 100, revealed: 25, pageSize: 25) == 25)
        #expect(LogHistoryState.nextRevealCount(matchCount: 51, revealed: 25, pageSize: 25) == 25)
    }

    @Test func theRevealCountIsTheREMAINDEROnTheLastPage() {
        // The last page offers the remainder, not a full page: promising 25 and producing 5 would
        // mislead.
        #expect(LogHistoryState.nextRevealCount(matchCount: 30, revealed: 25, pageSize: 25) == 5)
        #expect(LogHistoryState.nextRevealCount(matchCount: 26, revealed: 25, pageSize: 25) == 1)
    }

    @Test func theRevealCountIsZeroWhenNothingIsHidden() {
        // Zero also swaps the button for the "you're at the start of the log" note, so it must
        // never go negative when `revealed` passes the match count, as it does when a filter
        // narrows the matches after a few "Show more" taps.
        #expect(LogHistoryState.nextRevealCount(matchCount: 25, revealed: 25, pageSize: 25) == 0)
        #expect(LogHistoryState.nextRevealCount(matchCount: 3, revealed: 75, pageSize: 25) == 0)
        #expect(LogHistoryState.nextRevealCount(matchCount: 0, revealed: 25, pageSize: 25) == 0)
    }

    // MARK: The combinations that are now unrepresentable

    @Test func loadingAndLoadedAreMutuallyExclusive() {
        // Every state answers exactly one of the two questions, so no consumer has to decide which
        // wins.
        var loading = LogHistoryState.notLoaded
        _ = loading.beginLoading()
        #expect(loading.isLoading && !loading.isLoaded)

        var loaded = LogHistoryState.notLoaded
        let token = loaded.beginLoading()!
        loaded.finishLoading([entry("a")], token: token, pageSize: pageSize)
        #expect(loaded.isLoaded && !loaded.isLoading)

        let idle = LogHistoryState.notLoaded
        #expect(!idle.isLoading && !idle.isLoaded)
    }
}
