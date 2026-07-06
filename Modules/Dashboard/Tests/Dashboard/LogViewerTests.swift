import Testing
import Foundation
import Events
@testable import Dashboard

/// Coverage for LogEntryFilter.apply — the level filter, case-insensitive search, and newest-first
/// ordering that back the Activity Log. Extracted from the view body so it is testable without @State.
@Suite struct LogViewerTests {

    private let entries: [LogEntry] = [
        LogEntry(level: .info, message: "Started up"),
        LogEntry(level: .error, message: "Disk FULL"),
        LogEntry(level: .info, message: "Loaded tree"),
    ]

    @Test func testNilLevelReturnsAllNewestFirst() {
        let result = LogEntryFilter.apply(entries, level: nil, search: "")
        // All entries, reversed (newest at the top).
        #expect(result.map(\.message) == ["Loaded tree", "Disk FULL", "Started up"])
    }

    @Test func testLevelFilterKeepsOnlyMatchingLevel() {
        let result = LogEntryFilter.apply(entries, level: .info, search: "")
        #expect(result.map(\.message) == ["Loaded tree", "Started up"])
        #expect(result.allSatisfy { $0.level == .info })
    }

    @Test func testSearchIsCaseInsensitiveSubstring() {
        // "full" matches "Disk FULL" regardless of case.
        let result = LogEntryFilter.apply(entries, level: nil, search: "full")
        #expect(result.map(\.message) == ["Disk FULL"])
    }

    @Test func testLevelAndSearchCombine() {
        // Level .info excludes the error, and "tree" narrows to one info entry.
        let result = LogEntryFilter.apply(entries, level: .info, search: "TREE")
        #expect(result.map(\.message) == ["Loaded tree"])
    }

    @Test func testNoMatchReturnsEmpty() {
        let result = LogEntryFilter.apply(entries, level: nil, search: "no such text")
        #expect(result.isEmpty)
    }

    @Test func testSearchMatchesMessageTextNotLevelName() {
        // "ERROR" appears as a level tag in the UI but not in any message body, so the
        // search field — which filters message text only — must not match the error entry.
        let result = LogEntryFilter.apply(entries, level: nil, search: "ERROR")
        #expect(result.isEmpty)
    }

    @Test func testEmptyInputStaysEmpty() {
        let result = LogEntryFilter.apply([], level: .error, search: "anything")
        #expect(result.isEmpty)
    }
}
