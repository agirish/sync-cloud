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

    @Test func testEmptyStateDistinguishesNeverLoggedFromFilteredOut() {
        // Rows visible → no empty state, regardless of how they got there.
        #expect(LogEmptyState.classify(hasEntries: true, hasVisibleRows: true) == .none)
        // Entries exist but the filters hide them all → the "Clear Filters" dead end.
        #expect(LogEmptyState.classify(hasEntries: true, hasVisibleRows: false) == .noMatches)
        // Nothing logged this session → the explain-the-surface state.
        #expect(LogEmptyState.classify(hasEntries: false, hasVisibleRows: false) == .noActivity)
    }
}
