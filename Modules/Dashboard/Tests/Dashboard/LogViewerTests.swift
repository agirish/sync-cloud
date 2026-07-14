import Testing
import Foundation
import Events
@testable import Dashboard

/// Coverage for LogEntryFilter.apply — the level filter, case-insensitive search, and newest-first
/// ordering that back the Activity Log. Extracted from the view body so it is testable without @State.
@Suite struct LogViewerTests {

    private let entries: [LogEntry] = [
        LogEntry(level: .info, message: "Started up"),
        LogEntry(level: .debug, message: "Walking tree"),
        LogEntry(level: .error, message: "Disk FULL"),
        LogEntry(level: .warning, message: "Low space"),
        LogEntry(level: .info, message: "Loaded tree"),
    ]

    @Test func testNilLevelReturnsAllNewestFirst() {
        let result = LogEntryFilter.apply(entries, minimumLevel: nil, search: "")
        // All entries, reversed (newest at the top).
        #expect(result.map(\.message) == ["Loaded tree", "Low space", "Disk FULL", "Walking tree", "Started up"])
    }

    @Test func testThresholdKeepsLevelAndAbove() {
        // "Warnings & above" keeps warnings AND errors — the whole reason the filter is a
        // threshold, not exact-match. Debug and info drop out.
        let result = LogEntryFilter.apply(entries, minimumLevel: .warning, search: "")
        #expect(result.map(\.message) == ["Low space", "Disk FULL"])
        #expect(result.allSatisfy { $0.level.severity >= LogLevel.warning.severity })
    }

    @Test func testInfoThresholdHidesOnlyDebug() {
        // "Info & above" hides debug but keeps info/warning/error.
        let result = LogEntryFilter.apply(entries, minimumLevel: .info, search: "")
        #expect(result.map(\.message) == ["Loaded tree", "Low space", "Disk FULL", "Started up"])
        #expect(!result.contains { $0.level == .debug })
    }

    @Test func testErrorThresholdKeepsOnlyErrors() {
        let result = LogEntryFilter.apply(entries, minimumLevel: .error, search: "")
        #expect(result.map(\.message) == ["Disk FULL"])
    }

    @Test func testSearchIsCaseInsensitiveSubstring() {
        // "full" matches "Disk FULL" regardless of case.
        let result = LogEntryFilter.apply(entries, minimumLevel: nil, search: "full")
        #expect(result.map(\.message) == ["Disk FULL"])
    }

    @Test func testLevelAndSearchCombine() {
        // Threshold .info excludes the debug entry, and "tree" narrows to one info entry.
        let result = LogEntryFilter.apply(entries, minimumLevel: .info, search: "TREE")
        #expect(result.map(\.message) == ["Loaded tree"])
    }

    @Test func testNoMatchReturnsEmpty() {
        let result = LogEntryFilter.apply(entries, minimumLevel: nil, search: "no such text")
        #expect(result.isEmpty)
    }

    @Test func testSearchMatchesMessageTextNotLevelName() {
        // "ERROR" appears as a level tag in the UI but not in any message body, so the
        // search field — which filters message text only — must not match the error entry.
        let result = LogEntryFilter.apply(entries, minimumLevel: nil, search: "ERROR")
        #expect(result.isEmpty)
    }

    @Test func testEmptyInputStaysEmpty() {
        let result = LogEntryFilter.apply([], minimumLevel: .error, search: "anything")
        #expect(result.isEmpty)
    }

    // MARK: Empty-state classification

    @Test func testEmptyStateVisibleRowsWinRegardlessOfSource() {
        // Any visible rows (session or history) → no empty state.
        #expect(LogEmptyState.classify(hasVisibleRows: true, hasRawEntries: true, historyLoaded: false) == .none)
        #expect(LogEmptyState.classify(hasVisibleRows: true, hasRawEntries: false, historyLoaded: true) == .none)
    }

    @Test func testEmptyStateFilteredOutIsNoMatches() {
        // Raw entries exist (this session and/or loaded history) but the filters hide them all.
        #expect(LogEmptyState.classify(hasVisibleRows: false, hasRawEntries: true, historyLoaded: false) == .noMatches)
        #expect(LogEmptyState.classify(hasVisibleRows: false, hasRawEntries: true, historyLoaded: true) == .noMatches)
    }

    @Test func testEmptyStateQuietSessionOffersHistory() {
        // Nothing this session and history not loaded yet → the explain-and-offer-history state.
        #expect(LogEmptyState.classify(hasVisibleRows: false, hasRawEntries: false, historyLoaded: false) == .noActivity)
    }

    @Test func testEmptyStateHistoryLoadedButEmptyIsNoEarlierActivity() {
        // History was loaded and the log holds nothing older → the honest end state, not "load it".
        #expect(LogEmptyState.classify(hasVisibleRows: false, hasRawEntries: false, historyLoaded: true) == .noEarlierActivity)
    }

    // MARK: History loading (parse + boundary + order)

    /// Builds a canonical log-file text (oldest-first, as on disk) from (secondsAgo, level, message)
    /// tuples relative to a fixed base instant, so the boundary math is deterministic.
    private func logText(_ lines: [(offset: TimeInterval, level: LogLevel, message: String)], base: Date) -> String {
        lines.map { LogEntry(timestamp: base.addingTimeInterval($0.offset), level: $0.level, message: $0.message).formattedString }
            .joined(separator: "\n")
    }

    @Test func testHistoryLoaderReturnsOnlyOlderThanBoundaryNewestFirst() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let sessionStart = base.addingTimeInterval(100)
        let text = logText([
            (0,   .info,    "old one"),      // older than session
            (50,  .warning, "old two"),      // older than session
            (100, .info,    "session start"),// == boundary → excluded (strictly older only)
            (150, .info,    "this session"), // newer → excluded
        ], base: base)
        let history = LogHistoryLoader.parseOlderThan(sessionStart, text: text)
        // Only the two pre-session entries, newest-first.
        #expect(history.map(\.message) == ["old two", "old one"])
    }

    @Test func testHistoryLoaderSkipsMalformedLinesAndBlanks() {
        let base = Date(timeIntervalSince1970: 2_000_000)
        let sessionStart = base.addingTimeInterval(1000)
        let good = LogEntry(timestamp: base, level: .info, message: "real entry").formattedString
        let text = "\n\(good)\nnot a log line\n[garbage without level] hi\n"
        let history = LogHistoryLoader.parseOlderThan(sessionStart, text: text)
        #expect(history.map(\.message) == ["real entry"])
    }

    @Test func testHistoryLoaderEmptyWhenNothingOlder() {
        let base = Date(timeIntervalSince1970: 3_000_000)
        // Boundary before every line → no history.
        let text = logText([(10, .info, "a"), (20, .info, "b")], base: base)
        #expect(LogHistoryLoader.parseOlderThan(base, text: text).isEmpty)
    }
}
