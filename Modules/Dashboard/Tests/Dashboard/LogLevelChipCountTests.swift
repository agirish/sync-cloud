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
}
