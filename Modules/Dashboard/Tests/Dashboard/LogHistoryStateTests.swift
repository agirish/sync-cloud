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
        #expect(!state.readFailed, "an empty load is loaded, not failed")
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

    // MARK: The "Show N more" count

    /// A full page while more than a page is hidden; the remainder on the last page (promising 25
    /// and producing 5 would mislead); zero when nothing is hidden. Zero swaps the button for the
    /// "start of the log" note, so it must never go negative when `revealed` passes the match count,
    /// as it does when a filter narrows the matches after a few "Show more" taps.
    @Test(arguments: [(100, 25, 25), (51, 25, 25), (30, 25, 5), (26, 25, 1), (25, 25, 0), (3, 75, 0), (0, 25, 0)])
    func theRevealCountIsWhatTheNextTapShows(matchCount: Int, revealed: Int, expected: Int) {
        #expect(LogHistoryState.nextRevealCount(matchCount: matchCount, revealed: revealed, pageSize: 25) == expected)
    }
}
