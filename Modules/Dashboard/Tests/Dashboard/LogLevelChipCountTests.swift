import Testing
import Foundation
import Events
@testable import Dashboard

/// Pins that the severity chips count the same set their threshold filters.
///
/// The chips set `selectedLevel`, which filters the session rows AND any revealed history — but the
/// counts were tallied from `logger.entries` alone. A quiet session under a raised threshold is
/// exactly when someone reveals history, so the failure showed up in the worst place: an
/// "Errors 0" chip sitting directly above a screenful of history error rows.
/// `@MainActor` because `thresholdCounts` is a static on `LogViewer`, and SwiftUI's `View`
/// conformance isolates the whole type — calling it off the main actor traps at runtime rather
/// than failing to compile.
@MainActor
@Suite struct LogLevelChipCountTests {

    private func entry(_ level: LogLevel, _ message: String = "m") -> LogEntry {
        LogEntry(timestamp: Date(timeIntervalSince1970: 1_780_000_000), level: level, message: message)
    }

    /// The tally is keyed by `LogLevel?` (nil is the "All" total), so a bare `.error` subscript is
    /// ambiguous against Optional's own members — this keeps the assertions readable.
    private func tally(_ counts: [LogLevel?: Int], _ level: LogLevel?) -> Int? { counts[level] }

    @Test func historyEntriesCountTowardTheChips() {
        // The reported case: nothing in this session, three errors in the log's history.
        let counts = LogViewer.thresholdCounts(
            session: [],
            history: [entry(.error), entry(.error), entry(.error, "boom")])

        #expect(tally(counts, .error) == 3)
        #expect(tally(counts, nil) == 3)
    }

    @Test func sessionAndHistoryAreSummedPerThreshold() {
        let counts = LogViewer.thresholdCounts(
            session: [entry(.debug), entry(.info), entry(.error)],
            history: [entry(.warning), entry(.error)])

        #expect(tally(counts, nil) == 5)                 // All
        #expect(tally(counts, .info) == 4)               // info + warning + 2 errors
        #expect(tally(counts, .warning) == 3)            // warning + 2 errors
        #expect(tally(counts, .error) == 2)
    }

    @Test func anUnloadedHistoryLeavesTheCountsExactlyAsTheyWere() {
        // The pre-existing behaviour, unchanged: before "Show older history" is clicked the window
        // holds only the session, so that is all the chips may claim.
        let session = [entry(.debug), entry(.warning), entry(.error)]
        let counts = LogViewer.thresholdCounts(session: session, history: [])

        #expect(tally(counts, nil) == 3)
        #expect(tally(counts, .info) == 2)
        #expect(tally(counts, .warning) == 2)
        #expect(tally(counts, .error) == 1)
    }

    @Test func aLoadedButEmptyHistoryChangesNothing() {
        // "Loaded, and the log holds nothing older" must read the same as "not loaded" here — the
        // distinction matters to the footer's message, not to a tally.
        let session = [entry(.info), entry(.error)]
        #expect(tally(LogViewer.thresholdCounts(session: session, history: []), nil) == 2)
    }

    @Test func everyThresholdKeyIsPresentEvenAtZero() {
        // The chip row reads `levelCounts[option.level] ?? 0` for all four options; a missing key
        // would silently render 0 rather than fail, so pin that the tally emits each one.
        let counts = LogViewer.thresholdCounts(session: [entry(.debug)], history: [])
        #expect(tally(counts, nil) == 1)
        #expect(tally(counts, .info) == 0)
        #expect(tally(counts, .warning) == 0)
        #expect(tally(counts, .error) == 0)
    }

    @Test func theCountIsIndependentOfHowMuchHistoryIsRevealed() {
        // "Show more" reveals further into the SAME filtered set, so the tally must describe what
        // the window holds, not the scroll position — a count that grew as you paged would be
        // describing the latter.
        let history = (0..<40).map { entry(.error, "e\($0)") }
        let counts = LogViewer.thresholdCounts(session: [], history: history)
        #expect(tally(counts, .error) == 40)
    }

    // MARK: What the window actually counts

    // Everything above pins the ARITHMETIC, given a session and a history array. None of it could
    // see the decision that produced the bug: which entries the window hands the tally. That choice
    // used to live in one line of the View body, where `history: []` restored the bug with every
    // test still green. It now lives in `LogViewerContents`, which takes the history STATE and
    // feeds the same value to both the counts and the rows — so these tests can reach it, and the
    // old one-line revert no longer type-checks.

    private func contents(session: [LogEntry],
                          history: LogHistoryState,
                          level: LogLevel? = nil,
                          search: String = "") -> LogViewerContents {
        LogViewerContents(session: session, history: history, minimumLevel: level, search: search,
                          pageSize: 25, now: Date(timeIntervalSince1970: 1_780_000_000))
    }

    @Test func loadedHistoryIsWhatTheChipsCount() {
        // The reported bug, at the layer that decides it: the window holds three history errors
        // and a quiet session, so the Errors chip must read 3 — not 0.
        let state = LogHistoryState.loaded(entries: [entry(.error), entry(.error), entry(.error)], revealed: 25)
        let counts = contents(session: [], history: state).levelCounts

        #expect(tally(counts, .error) == 3)
        #expect(tally(counts, nil) == 3)
    }

    @Test func theCountsAndTheVisibleRowsDescribeTheSameHistory() {
        // The invariant, stated directly: whatever the chips count is what the list shows the
        // threshold over. Both come from the one `history` argument, so they cannot drift apart
        // without the rows visibly emptying too.
        let loaded = LogHistoryState.loaded(entries: [entry(.error), entry(.warning)], revealed: 25)
        let shown = contents(session: [entry(.info)], history: loaded)
        #expect(tally(shown.levelCounts, nil) == 3)
        #expect(shown.visibleHistory.count == 2)

        // And with no history loaded, both sides drop to the session alone.
        let sessionOnly = contents(session: [entry(.info)], history: .notLoaded)
        #expect(tally(sessionOnly.levelCounts, nil) == 1)
        #expect(sessionOnly.visibleHistory.isEmpty)
    }

    @Test func onlyALoadedHistoryContributesToTheCounts() {
        // The three non-loaded states hold no entries, each for its own reason; none of them may
        // inflate — or, for `.failed`, be mistaken for — a loaded history.
        let session = [entry(.error)]
        for state in [LogHistoryState.notLoaded, .loading(token: UUID()), .failed] {
            let counts = contents(session: session, history: state).levelCounts
            #expect(tally(counts, nil) == 1)
            #expect(tally(counts, .error) == 1)
        }
    }

    @Test func revealingMorePagesDoesNotChangeTheCounts() {
        // Same set, three reveal positions: the chips describe what the window holds, so the tally
        // must not move as the user pages into it.
        let entries = (0..<40).map { entry(.error, "e\($0)") }
        let counts = [0, 25, 40].map {
            tally(contents(session: [], history: .loaded(entries: entries, revealed: $0)).levelCounts, .error)
        }
        #expect(counts == [40, 40, 40])
    }

    @Test func theSearchAndLevelFiltersNeverNarrowTheCounts() {
        // The chips report the window's contents, not the current filter's result — otherwise the
        // number on the chip you are about to click would already be the number after clicking it.
        let state = LogHistoryState.loaded(entries: [entry(.error, "boom"), entry(.info, "quiet")], revealed: 25)
        let filtered = contents(session: [], history: state, level: .error, search: "boom")
        #expect(tally(filtered.levelCounts, nil) == 2)
        #expect(filtered.visibleHistory.count == 1)   // the list, unlike the chips, does narrow
    }
}
