import Testing
import Foundation
import Events
@testable import Dashboard

/// Coverage for LogEntryFilter.apply: the level filter, case-insensitive search and newest-first
/// ordering behind the Activity Log. Outside the view body, so it is testable without @State.
@Suite struct LogViewerTests {

    private let entries: [LogEntry] = [
        LogEntry(level: .info, message: "Started up"),
        LogEntry(level: .debug, message: "Walking tree"),
        LogEntry(level: .error, message: "Disk FULL"),
        LogEntry(level: .warning, message: "Low space"),
        LogEntry(level: .info, message: "Loaded tree"),
    ]

    /// The level filter is a threshold, not an exact match, and keeps newest first: no level keeps
    /// all, reversed; "Warnings & above" keeps warnings and errors; "Info & above" hides only
    /// debug; errors keeps errors.
    @Test(arguments: [
        (nil, ["Loaded tree", "Low space", "Disk FULL", "Walking tree", "Started up"]),
        (.warning, ["Low space", "Disk FULL"]),
        (.info, ["Loaded tree", "Low space", "Disk FULL", "Started up"]),
        (.error, ["Disk FULL"]),
    ] as [(LogLevel?, [String])])
    func testTheLevelIsAThresholdAndKeepsNewestFirst(level: LogLevel?, messages: [String]) {
        let result = LogEntryFilter.apply(entries, minimumLevel: level, search: "")
        #expect(result.map(\.message) == messages)
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

    @Test func testSearchMatchesMessageTextNotLevelName() {
        // "ERROR" appears as a level tag in the UI but in no message body, so the search field,
        // which filters message text only, must not match the error entry.
        let result = LogEntryFilter.apply(entries, minimumLevel: nil, search: "ERROR")
        #expect(result.isEmpty)
    }

    // MARK: Empty-state classification

    /// One argument per situation, each with the rows (visible rows, raw entries, history loaded,
    /// history read failed → empty state) that pin it.
    @Test(arguments: [
        // Any visible rows (session or history): no empty state.
        [(true, true, false, false, LogEmptyState.none), (true, false, true, false, .none)],
        // Raw entries exist (this session and/or loaded history) but the filters hide them all.
        [(false, true, false, false, .noMatches), (false, true, true, false, .noMatches)],
        // Nothing this session and history not loaded yet: the explain-and-offer-history state.
        [(false, false, false, false, .noActivity)],
        // History loaded and the log holds nothing older: the honest end state, not "load it".
        [(false, false, true, false, .noEarlierActivity)],
        // A failed read is not `.noActivity`, whose message offers "Show older history" to load
        // earlier sessions; above the footer's "Couldn't read the log file" that would make two
        // opposite claims about the same file.
        [(false, false, false, true, .historyUnavailable)],
        // A retry that succeeded leaves the state loaded; the earlier failure must not still decide
        // the wording. (`LogHistoryState` can't be both, but classify takes two Bools.)
        [(false, false, true, true, .noEarlierActivity)],
        // The failure only reaches the empty state when there is nothing else to show: a session
        // that logged something renders rows, and the footer's note is then the only word on it.
        [(true, true, false, true, .none), (false, true, false, true, .noMatches)],
    ] as [[(Bool, Bool, Bool, Bool, LogEmptyState)]])
    func testTheEmptyStateClassification(_ rows: [(Bool, Bool, Bool, Bool, LogEmptyState)]) {
        for (visible, raw, loaded, failed, expected) in rows {
            #expect(LogEmptyState.classify(hasVisibleRows: visible, hasRawEntries: raw, historyLoaded: loaded,
                                           historyReadFailed: failed) == expected)
        }
    }

    // MARK: The footer's "No earlier activity" note vs. the empty state

    /// The "No earlier activity" note, by (history is empty, empty state → the footer notes it).
    @Test(arguments: [
        // An empty session over an empty loaded history: the empty state's "…the log holds nothing
        // from earlier sessions" and the footer's "No earlier activity in the log" say the same
        // thing, so only one may speak.
        [(true, LogEmptyState.noEarlierActivity, false)],
        // A session that logged something renders no empty state (.none), so the footer note is
        // the only word on the subject and must survive. Same for a filtered-out session
        // (.noMatches), whose empty state talks about filters, not earlier sessions.
        [(true, .none, true), (true, .noMatches, true)],
        // Loaded history with rows in it is never "no earlier activity", whatever the empty state
        // says (it can be .noMatches when the filter hides every one of those rows).
        [(false, .noMatches, false), (false, .none, false)],
    ] as [[(Bool, LogEmptyState, Bool)]])
    func testTheFooterNotesNoEarlierActivityOnlyWhereNothingElseSaysSo(_ rows: [(Bool, LogEmptyState, Bool)]) {
        for (historyIsEmpty, emptyState, expected) in rows {
            #expect(LogEmptyState.footerNotesNoEarlierActivity(historyIsEmpty: historyIsEmpty,
                                                                emptyState: emptyState) == expected)
        }
    }

    /// The unreadable-log note, by (empty state → the footer notes it).
    @Test(arguments: [
        // Same yield rule as the "No earlier activity" note, for the failed read: the empty state
        // states it more fully and higher up, so the footer keeps only its retry button.
        [(LogEmptyState.historyUnavailable, false)],
        // A session that logged something renders no empty state, so this note is the only word on
        // why earlier history is missing; a filtered-out session's empty state talks about
        // filters, not the file.
        [(.none, true), (.noMatches, true), (.noActivity, true)],
    ] as [[(LogEmptyState, Bool)]])
    func testTheFooterNotesAnUnreadableLogOnlyWhereTheEmptyStateDoesNot(_ rows: [(LogEmptyState, Bool)]) {
        for (emptyState, expected) in rows {
            #expect(LogEmptyState.footerNotesUnreadableHistory(emptyState: emptyState) == expected)
        }
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

    // MARK: A failed READ is not an empty history

    /// A scratch file path in the temp directory, removed by the caller's `defer`.
    private func scratchLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("log-read-outcome-\(UUID().uuidString).log")
    }

    /// A torn byte costs that byte, not the history around it. A second process appends to the log
    /// too, so a crash mid-write can leave invalid UTF-8 (0xFF is never a legal lead byte), which
    /// `String(contentsOf:)` would throw on, losing every good line. The lines either side must
    /// survive.
    @Test func testATornByteDoesNotCostTheHistoryAroundIt() throws {
        let url = scratchLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let before = LogEntry(timestamp: base, level: .warning, message: "before the tear")
        let after = LogEntry(timestamp: base.addingTimeInterval(1), level: .info, message: "after the tear")

        var bytes = Data((before.formattedString + "\n").utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, 0xFF, 0x0A])   // the torn write, on its own line
        bytes.append(Data((after.formattedString + "\n").utf8))
        try bytes.write(to: url)

        let outcome = LogHistoryLoader.loadOlderThan(base.addingTimeInterval(60), fileURL: url)
        // Newest-first, this loader's documented order, as the window shows it.
        #expect(outcome.loadedEntries?.map(\.message) == ["after the tear", "before the tear"],
                """
                the good lines did not survive a torn one: \(String(describing: outcome)) — one \
                unreadable byte is again costing the whole history
                """)
    }

    /// Asserted on bytes: a character cut short comes back marked, not silently gone.
    /// `String(decoding:as:)` repairs; `String(data:encoding:)` returns a clean string with the tail
    /// dropped, which no assertion on the surrounding text could catch.
    @Test func testTheRepairMarksACutShortCharacterRatherThanDroppingIt() {
        let whole = "page 3 — café"
        let cut = Data(whole.utf8).dropLast()            // the final "é" loses its second byte

        let repaired = LogHistoryLoader.repairingUTF8(cut)
        #expect(repaired == "page 3 — caf\u{FFFD}",
                """
                a cut-short character came back as \(repaired.debugDescription) — if that is the \
                text minus its tail, the truncation is invisible
                """)
        #expect(LogHistoryLoader.repairingUTF8(Data(whole.utf8)) == whole,
                "the control: intact bytes must pass through untouched")
    }

    /// The positive control for the case above: a file that genuinely can't be read still reports
    /// `.unreadable`. A directory at the path stages that without permission games.
    @Test func testAFileThatCannotBeReadAtAllIsStillUnreadable() throws {
        let url = scratchLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

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
        // The other half: a file that reads fine but holds nothing older is `.loaded([])`, a real
        // answer the footer may state.
        let url = scratchLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "not a log line\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(LogHistoryLoader.loadOlderThan(Date(), fileURL: url).loadedEntries?.isEmpty == true)
    }

    @Test func testAMissingLogFileIsNothingOlderRatherThanAFailure() {
        // No file yet is a true "nothing older", not a failure; calling it unreadable would put an
        // error note under a first launch that has never written the file.
        let url = scratchLogURL()   // deliberately never created
        #expect(LogHistoryLoader.loadOlderThan(Date(), fileURL: url).loadedEntries?.isEmpty == true)
    }

    // MARK: The window's derived contents

    /// `LogViewerContents`, the window's derived contents, all taken from one history state. The
    /// chip counts have their own suite; these pin the rows, paging and empty state.
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
            // The last page offers the true remainder, not another full page.
            #expect(shown.nextReveal == 5)
            #expect(contents(history: .loaded(entries: history, revealed: 30)).nextReveal == 0)
        }

        @Test func theHistoryPageIsCutFromTheFilteredMatchesNotTheRawEntries() {
            // `revealed` caps the filtered matches, so narrowing the filter re-pages from the top
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
            // `.failed` reads neither as "nothing older" nor as `.noActivity`, whose message offers
            // "Show older history" right above a footer saying the file couldn't be read. The
            // empty state names the failure, and the footer's duplicate note yields to it.
            #expect(contents(history: .failed).emptyState == .historyUnavailable)
            #expect(contents(history: .failed).visibleHistory.isEmpty)
        }

        @Test func aFailedReadUnderAChattySessionLeavesTheFooterToSpeak() {
            // With rows on screen there is no empty state to carry the failure, so the footer's
            // note must survive: the yield above must not silence it everywhere.
            let shown = contents(session: [entry(.info, "did something")], history: .failed)
            #expect(shown.emptyState == .none)
            #expect(LogEmptyState.footerNotesUnreadableHistory(emptyState: shown.emptyState))
        }

        /// Show in Log on a message from an earlier session whose minutes the log no longer holds:
        /// with the history read, the list says the log doesn't reach them, not that it is empty.
        @Test func minutesTheLogNoLongerHoldsAreSaidToBeGone() {
            let span = now.addingTimeInterval(-90 * 86_400)...now.addingTimeInterval(-90 * 86_400 + 300)
            let older = LogEntry(timestamp: now.addingTimeInterval(-3_600), level: .info, message: "later line")
            let shown = LogViewerContents(session: [], history: .loaded(entries: [older], revealed: 25),
                                          minimumLevel: nil, search: "", pageSize: 25, span: span, now: now)
            #expect(shown.emptyState == .spanNotInLog)
        }
    }

    // MARK: Show in Log on an earlier session's message

    /// Show in Log's minutes from before this launch are only in the earlier sessions' log, so the
    /// Log reads it as it opens; minutes from this session, or a log already read, need nothing.
    @Test func minutesFromAnEarlierSessionReadTheEarlierLog() {
        let launch = Date(timeIntervalSince1970: 1_780_000_000)
        let earlier = launch.addingTimeInterval(-86_400)...launch.addingTimeInterval(-86_100)
        let now = launch.addingTimeInterval(60)...launch.addingTimeInterval(120)
        #expect(LogViewer.spanNeedsHistory(earlier, sessionStart: launch, history: .notLoaded))
        #expect(!LogViewer.spanNeedsHistory(now, sessionStart: launch, history: .notLoaded))
        #expect(!LogViewer.spanNeedsHistory(nil, sessionStart: launch, history: .notLoaded))
        #expect(!LogViewer.spanNeedsHistory(earlier, sessionStart: launch, history: .loaded(entries: [], revealed: 25)))
        #expect(!LogViewer.spanNeedsHistory(earlier, sessionStart: launch, history: .loading(token: UUID())))
    }

    /// …and the view asks as it opens and whenever Show in Log narrows it again.
    @Test func theLogAsksForTheEarlierLogWhenItOpensOnOldMinutes() throws {
        let viewer = try DashboardSource.read("LogViewer.swift", codeOnly: true)
        #expect(viewer.contains(".onAppear { loadHistoryIfTheSpanNeedsIt() }"))
        #expect(viewer.contains(".onChange(of: span) { _, _ in loadHistoryIfTheSpanNeedsIt() }"))
        #expect(viewer.contains("if Self.spanNeedsHistory(span, sessionStart: logger.sessionStart, history: history) { loadHistory() }"))
    }

    // MARK: Isolation

    /// `LogViewerContents` is a pure value with a nonisolated `init`, constructible off the main
    /// actor. **Trap:** a `View`'s statics are main-actor isolated, and reaching one off-actor
    /// compiles with only a warning and SIGTRAPs at runtime, so a regression crashes the test host
    /// rather than failing. Not `@MainActor` on purpose: a main-actor test would hop the detached
    /// work back to the main actor and hide it.
    @Test func theDerivedContentsCanBeBuiltOffTheMainActor() async {
        let session = [LogEntry(level: .error, message: "boom")]
        let history = LogHistoryState.loaded(
            entries: [LogEntry(level: .warning, message: "earlier")], revealed: 25)

        let total = await Task.detached {
            LogViewerContents(session: session, history: history, minimumLevel: nil,
                              search: "", pageSize: 25).levelCounts[nil] ?? -1
        }.value

        // The value is real, not just non-crashing: one session error plus one history warning.
        #expect(total == 2)
    }
}
