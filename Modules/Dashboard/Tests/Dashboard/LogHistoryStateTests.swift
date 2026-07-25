import Testing
import Foundation
import Events
@testable import Dashboard

/// Characterization tests for the Activity Log's history state machine.
///
/// Written against the behaviour of the FOUR `@State` variables this type replaced
/// (`loadedHistory` / `historyLimit` / `isLoadingHistory` / `historyLoadGeneration`), each rule read
/// off the call sites in `LogViewer` before the migration — so a passing suite means the new shape
/// preserves the old behaviour, not merely that it is self-consistent.
///
/// The old rules, and where they lived:
///   - `loadHistory()` refused to start when a read was in flight OR history was already loaded.
///   - A completion applied only if its captured generation still matched, and reset the page.
///   - The Clear Logs notification bumped the generation and reset all three other vars together.
///   - A level/search change reset the page size; "Show more" grew it.
///   - `nil` history offered the reload button; EMPTY history said "no earlier activity".
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
        // The old `isLoadingHistory` flag existed to stop the button double-firing; now the
        // claim itself fails, so a caller cannot forget to check.
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
        // The distinction the footer depends on: nil offers "Show older history", empty says
        // "No earlier activity in the log". Collapsing them would strand the user on a button
        // that re-reads a file known to hold nothing.
        var state = LogHistoryState.notLoaded
        let token = state.beginLoading()!
        state.finishLoading([], token: token, pageSize: pageSize)
        #expect(state.isLoaded)
        #expect(state.entries?.isEmpty == true)
    }

    @Test func aLoadThatFinishesAfterAClearIsDiscarded() {
        // THE rule this machinery exists for. A read parsed from the PRE-clear file must not
        // resurrect deleted rows — and must not make `entries` non-nil again, which would hide the
        // reload button for the window's lifetime.
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
        // Clear, then a second load: the FIRST read's completion must lose. Under the old counter
        // this worked because the generation had moved; the token carries the same guarantee
        // without a counter to keep in step.
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
        // A new level/search is a fresh view of history, so the list must not stay expanded to
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
        // The old code assigned `historyLimit` unconditionally on a filter change, which was
        // harmless only because a completion overwrote it. Here those calls simply do nothing,
        // and `revealed` stays 0 so a `prefix` against it yields nothing.
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
        // The shipped bug was a PARTIAL version of this: Clear Logs reset some of the four and
        // left `loadedHistory` populated, so deleted rows stayed on screen and the reload button
        // never returned. One case assignment cannot be partial.
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

    // MARK: The combinations that are now unrepresentable

    @Test func loadingAndLoadedAreMutuallyExclusive() {
        // The pairing the four booleans-and-optionals could express and this cannot: every state
        // answers exactly one of the two questions, so no consumer has to decide which wins.
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
