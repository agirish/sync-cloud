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

    // MARK: The footer's "No earlier activity" note vs. the empty state

    @Test func testFooterStaysQuietWhenTheEmptyStateAlreadySaysNoEarlierActivity() {
        // The double-render: an empty session over an empty loaded history put
        // "…the log holds nothing from earlier sessions" (the empty state) directly above
        // "No earlier activity in the log" (the footer). Exactly one of them may speak.
        #expect(LogEmptyState.footerNotesNoEarlierActivity(historyIsEmpty: true, emptyState: .noEarlierActivity) == false)
    }

    @Test func testFooterStillSpeaksWhenTheEmptyStateIsSayingSomethingElse() {
        // A session that DID log something renders no empty state at all (.none) — the footer note
        // is then the only word on the subject and must survive. Same for a filtered-out session
        // (.noMatches), whose empty state talks about filters, not about earlier sessions.
        #expect(LogEmptyState.footerNotesNoEarlierActivity(historyIsEmpty: true, emptyState: .none))
        #expect(LogEmptyState.footerNotesNoEarlierActivity(historyIsEmpty: true, emptyState: .noMatches))
    }

    @Test func testFooterNeverNotesAnythingWhenHistoryIsNotEmpty() {
        // Loaded history with rows in it is never "no earlier activity", whatever the empty state
        // says (it can be .noMatches when the filter hides every one of those rows).
        #expect(LogEmptyState.footerNotesNoEarlierActivity(historyIsEmpty: false, emptyState: .noMatches) == false)
        #expect(LogEmptyState.footerNotesNoEarlierActivity(historyIsEmpty: false, emptyState: .none) == false)
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

    // MARK: A failed READ is not an empty history

    /// A scratch file path in the temp directory, removed by the caller's `defer`.
    private func scratchLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("log-read-outcome-\(UUID().uuidString).log")
    }

    @Test func testAnUnreadableLogFileIsReportedAsUnreadableNotAsEmptyHistory() throws {
        // The log is appended to by a second process as well as this one, so a crash mid-write can
        // leave bytes that aren't valid UTF-8 (0xFF is not a legal lead byte anywhere in UTF-8).
        // Collapsing that into `[]` told the user "No earlier activity in the log" permanently and
        // falsely, with nothing recorded anywhere.
        let url = scratchLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0xFF, 0xFE, 0xFF, 0x0A]).write(to: url)

        let outcome = LogHistoryLoader.loadOlderThan(Date(), fileURL: url)
        guard case .unreadable(let reason) = outcome else {
            Issue.record("expected .unreadable, got \(outcome)")
            return
        }
        // The reason is what the caller puts in the log line, so it must not be blank.
        #expect(!reason.isEmpty)
        // And the shortcut accessor refuses to hand back an empty array for it.
        #expect(outcome.loadedEntries == nil)
    }

    @Test func testAReadableLogFileIsLoadedEvenWhenItParsesToNothing() throws {
        // The other half of the distinction: a file that reads fine but holds nothing older is
        // `.loaded([])` — a real answer the footer is entitled to state.
        let url = scratchLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "not a log line\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(LogHistoryLoader.loadOlderThan(Date(), fileURL: url).loadedEntries?.isEmpty == true)
    }

    @Test func testAMissingLogFileIsNothingOlderRatherThanAFailure() {
        // No file yet is a true "nothing older", not a torn write — reporting it as unreadable
        // would put an error note under a first launch that has simply never written the file.
        let url = scratchLogURL()   // deliberately never created
        #expect(LogHistoryLoader.loadOlderThan(Date(), fileURL: url).loadedEntries?.isEmpty == true)
    }

    @Test func testAGoodFileStillLoadsItsHistory() throws {
        // The control: the read path itself still works, so the two tests above are asserting the
        // failure/empty distinction and not a loader that returns nothing for everything.
        let url = scratchLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let line = LogEntry(timestamp: base, level: .warning, message: "earlier session").formattedString
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

        let outcome = LogHistoryLoader.loadOlderThan(base.addingTimeInterval(60), fileURL: url)
        #expect(outcome.loadedEntries?.map(\.message) == ["earlier session"])
    }

    // MARK: The window's derived contents

    /// The composition the `body` used to perform inline, now a value (`LogViewerContents`) so the
    /// pieces are derived from ONE history state instead of five independent reads of it. The chip
    /// counts have their own suite; these pin the rest of what moved, so the extraction is provably
    /// behavior-preserving.
    ///
    /// `@MainActor` because `LogViewerContents` reaches `LogViewer.thresholdCounts`, a static on a
    /// SwiftUI `View`.
    @MainActor
    @Suite struct ContentsTests {
        private let now = Date(timeIntervalSince1970: 1_780_000_000)

        private func entry(_ level: LogLevel, _ message: String) -> LogEntry {
            LogEntry(timestamp: Date(timeIntervalSince1970: 1_780_000_000), level: level, message: message)
        }

        private func contents(session: [LogEntry] = [],
                              history: LogHistoryState = .notLoaded,
                              level: LogLevel? = nil,
                              search: String = "",
                              pageSize: Int = 25) -> LogViewerContents {
            LogViewerContents(session: session, history: history, minimumLevel: level,
                              search: search, pageSize: pageSize, now: now)
        }

        @Test func sessionRowsAreFilteredAndNewestFirst() {
            let session = [entry(.debug, "first"), entry(.error, "second"), entry(.warning, "third")]
            let rows = contents(session: session, level: .warning).sessionRows
            #expect(rows.map(\.message) == ["third", "second"])
        }

        @Test func onlyTheRevealedPageOfHistoryIsVisibleAndTheRemainderIsOffered() {
            let history = (0..<30).map { entry(.info, "h\($0)") }
            let shown = contents(history: .loaded(entries: history, revealed: 25))
            #expect(shown.visibleHistory.count == 25)
            #expect(shown.visibleHistory.first?.message == "h0")
            // The LAST page offers the true remainder, not another full page — the footer button
            // used to promise 25 and hand over 5.
            #expect(shown.nextReveal == 5)
            #expect(contents(history: .loaded(entries: history, revealed: 30)).nextReveal == 0)
        }

        @Test func theHistoryPageIsCutFromTheFilteredMatchesNotTheRawEntries() {
            // `revealed` caps the FILTERED matches, so narrowing the filter re-pages from the top
            // rather than revealing a window into an unfiltered list.
            let history = [entry(.info, "quiet"), entry(.error, "boom"), entry(.error, "bang")]
            let shown = contents(history: .loaded(entries: history, revealed: 2), level: .error)
            #expect(shown.visibleHistory.map(\.message) == ["boom", "bang"])
            #expect(shown.nextReveal == 0)
        }

        @Test func theEmptyStateNamesWhichDeadEndTheWindowIsIn() {
            // Nothing logged, history never asked for.
            #expect(contents().emptyState == .noActivity)
            // Loaded, and the log holds nothing older.
            #expect(contents(history: .loaded(entries: [], revealed: 25)).emptyState == .noEarlierActivity)
            // Entries exist but the filter hides them all.
            #expect(contents(session: [entry(.debug, "d")], level: .error).emptyState == .noMatches)
            // Rows on screen: no empty state at all.
            #expect(contents(session: [entry(.error, "e")]).emptyState == .none)
            // Revealed history alone is enough to count as "rows on screen".
            #expect(contents(history: .loaded(entries: [entry(.error, "e")], revealed: 25)).emptyState == .none)
        }

        @Test func aFailedReadIsNotAnEmptyHistory() {
            // `.failed` must not read as "loaded, and there is nothing older" — the footer says
            // different things, and the empty state is one of them.
            #expect(contents(history: .failed).emptyState == .noActivity)
            #expect(contents(history: .failed).visibleHistory.isEmpty)
        }
    }
}
