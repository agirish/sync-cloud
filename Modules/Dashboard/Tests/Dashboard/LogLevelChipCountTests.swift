import Testing
import Foundation
import Events
@testable import Dashboard

/// Pins that the severity chips count the same set their threshold filters. `selectedLevel`
/// filters the session rows and any revealed history, so counting the session alone would show
/// "Errors 0" above a screenful of history error rows, just when someone reveals history in a
/// quiet session.
@MainActor
@Suite struct LogLevelChipCountTests {

    private func entry(_ level: LogLevel, _ message: String = "m") -> LogEntry {
        LogEntry(timestamp: Date(timeIntervalSince1970: 1_780_000_000), level: level, message: message)
    }

    /// The tally is keyed by `LogLevel?` (nil is the "All" total), so a bare `.error` subscript is
    /// ambiguous against Optional's own members; this keeps the assertions readable.
    private func tally(_ counts: [LogLevel?: Int], _ level: LogLevel?) -> Int? { counts[level] }

    @Test func sessionAndHistoryAreSummedPerThreshold() {
        let counts = LogViewer.thresholdCounts(
            session: [entry(.debug), entry(.info), entry(.error)],
            history: [entry(.warning), entry(.error)])

        #expect(tally(counts, nil) == 5)                 // All
        #expect(tally(counts, .info) == 4)               // info + warning + 2 errors
        #expect(tally(counts, .warning) == 3)            // warning + 2 errors
        #expect(tally(counts, .error) == 2)
    }

    @Test func everyThresholdKeyIsPresentEvenAtZero() {
        // The chip row reads `levelCounts[option.level] ?? 0` for all four options; a missing key
        // would silently render 0, so the tally must emit each one.
        let counts = LogViewer.thresholdCounts(session: [entry(.debug)], history: [])
        #expect(tally(counts, nil) == 1)
        #expect(tally(counts, .info) == 0)
        #expect(tally(counts, .warning) == 0)
        #expect(tally(counts, .error) == 0)
    }

    // MARK: What the window actually counts

    // Everything above pins the arithmetic, given a session and a history array. These pin which
    // entries the window hands the tally: `LogViewerContents` takes the history state and feeds
    // the same value to both the counts and the rows, so the two can't diverge.

    private func contents(session: [LogEntry],
                          history: LogHistoryState,
                          level: LogLevel? = nil,
                          search: String = "") -> LogViewerContents {
        LogViewerContents(session: session, history: history, minimumLevel: level, search: search,
                          pageSize: 25, now: Date(timeIntervalSince1970: 1_780_000_000))
    }

    @Test func theCountsAndTheVisibleRowsDescribeTheSameHistory() {
        // The invariant: what the chips count is what the list shows the threshold over. Both
        // come from the one `history` argument, so they can't drift apart without the rows visibly
        // emptying too.
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
        // The three non-loaded states hold no entries; none may inflate the counts, and `.failed`
        // must not pass for a loaded history.
        let session = [entry(.error)]
        for state in [LogHistoryState.notLoaded, .loading(token: UUID()), .failed] {
            let counts = contents(session: session, history: state).levelCounts
            #expect(tally(counts, nil) == 1)
            #expect(tally(counts, .error) == 1)
        }
    }

    @Test func revealingMorePagesDoesNotChangeTheCounts() {
        // Same set, three reveal positions: the tally must not move as the user pages into it.
        let entries = (0..<40).map { entry(.error, "e\($0)") }
        let counts = [0, 25, 40].map {
            tally(contents(session: [], history: .loaded(entries: entries, revealed: $0)).levelCounts, .error)
        }
        #expect(counts == [40, 40, 40])
    }

    @Test func theSearchAndLevelFiltersNeverNarrowTheCounts() {
        // The chips report the window's contents, not the current filter's result, or the number on
        // a chip would already be the number after clicking it.
        let state = LogHistoryState.loaded(entries: [entry(.error, "boom"), entry(.info, "quiet")], revealed: 25)
        let filtered = contents(session: [], history: state, level: .error, search: "boom")
        #expect(tally(filtered.levelCounts, nil) == 2)
        #expect(filtered.visibleHistory.count == 1)   // the list, unlike the chips, does narrow
    }
}
