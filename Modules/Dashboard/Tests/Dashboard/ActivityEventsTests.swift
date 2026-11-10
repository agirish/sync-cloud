import Foundation
import Testing
import Events
import FileExplorer
import Sync
@testable import Dashboard

/// Activity's Events: one row per run, however many files it touched, led by the message that
/// reported it; a message no run carries is a row of its own; the filters reach into runs.
@MainActor
@Suite struct ActivityEventsTests {

    private let at = Date(timeIntervalSince1970: 1_793_000_000)

    private func record(_ run: UUID, _ action: SyncAction, _ source: String, _ dest: String? = nil,
                        seconds: Double = 0, size: Int? = nil) -> SyncHistoryRecord {
        SyncHistoryRecord(runId: run, timestamp: at.addingTimeInterval(seconds), action: action, sourcePath: source,
                          destPath: dest, sizeBytes: size)
    }

    private func message(_ text: String, run: UUID? = nil, seconds: Double = 0) -> ActivityMessage {
        var message = ActivityMessage(date: at.addingTimeInterval(seconds), message: text, severity: .success)
        message.runId = run
        return message
    }

    private func build(records: [SyncHistoryRecord] = [], messages: [ActivityMessage] = [],
                       oneWay: [OneWaySyncHistoryEntry] = [], choice: ActivityEventsChoice = .all,
                       search: String = "", start: Date? = nil) -> [ActivityEvent] {
        ActivityEvents.build(records: records, messages: messages, oneWay: oneWay, changes: [], choice: choice,
                             search: search, start: start)
    }

    private func runs(_ events: [ActivityEvent]) -> [ActivityEventRun] {
        events.compactMap { if case .run(let run) = $0 { run } else { nil } }
    }

    // MARK: Runs

    /// A run of three copies is one row, its records newest first, led by the message that
    /// reported it; the message isn't a row of its own as well.
    @Test func aRunIsOneRowLedByItsMessage() throws {
        let run = UUID()
        let records = (0..<3).map { record(run, .copy, "/A/\($0).pdf", "/B/\($0).pdf", seconds: Double($0)) }
        let said = message("Copied 3 items to Dropbox", run: run, seconds: 3)
        let events = build(records: records, messages: [said])
        #expect(events.count == 1)
        let row = try #require(runs(events).first)
        #expect(row.message?.id == said.id)
        #expect(row.records.map(\.sourcePath) == ["/A/2.pdf", "/A/1.pdf", "/A/0.pdf"])
        #expect(row.total == 3)
        #expect(!row.isNarrowed)
        #expect(ActivityEventsView.recordsLabel(row) == "3 records")
    }

    /// A run no message reported — a pane's rename, an Ask Claude plan — still gets its row, with a
    /// sentence built from its records.
    @Test func aRunWithNoMessageBuildsItsOwnSentence() throws {
        let rename = UUID()
        let plan = UUID()
        let records = [
            record(rename, .move, "/Docs/Rentals/Lease draft.pdf", "/Docs/Rentals/Lease 2026.pdf", seconds: 60),
            record(plan, .newFolder, "/Docs/Bills"),
            record(plan, .move, "/Downloads/a.pdf", "/Docs/Bills/a.pdf", size: 1_000),
            record(plan, .move, "/Downloads/b.pdf", "/Docs/Bills/b.pdf", size: 2_000),
        ]
        let rows = runs(build(records: records))
        #expect(rows.map(\.id) == [rename, plan])
        #expect(rows[0].message == nil)
        #expect(rows[0].headline == "Renamed “Lease draft.pdf” to “Lease 2026.pdf”")
        #expect(rows[1].headline == "2 moves, 1 new folder")
        #expect(ActivityEventsView.recordsLabel(rows[0]) == "1 record")
    }

    /// One record's sentence says what it did, in the words its pill uses.
    @Test func oneRecordsSentenceSaysWhatItDid() {
        let run = UUID()
        #expect(ActivityEventRun.headline([record(run, .copy, "/A/x.pdf", "/B/x.pdf")]) == "Copied “x.pdf”")
        #expect(ActivityEventRun.headline([record(run, .move, "/A/x.pdf", "/B/Bills/x.pdf")]) == "Moved “x.pdf” to “Bills”")
        let trashed = SyncHistoryRecord(runId: run, action: .delete, sourcePath: "/A/x.pdf", reachedTrash: true)
        #expect(ActivityEventRun.headline([trashed]) == "Moved “x.pdf” to the Trash")
        let deleted = SyncHistoryRecord(runId: run, action: .delete, sourcePath: "/A/x.pdf", reachedTrash: false)
        #expect(ActivityEventRun.headline([deleted]) == "Deleted “x.pdf”")
        #expect(ActivityEventRun.headline([record(run, .matchDates, "/A/x.pdf", "/B/x.pdf")]) == "Matched the date of “x.pdf”")
        #expect(ActivityEventRun.headline([record(run, .newFolder, "/A/New")]) == "Made the folder “New”")
        #expect(ActivityEventRun.headline((0..<2).map {
            SyncHistoryRecord(runId: run, action: .delete, sourcePath: "/A/\($0)", reachedTrash: true)
        }) == "2 to the Trash")
    }

    /// A run's detail line names where it happened and how much it moved.
    @Test func aRunsDetailNamesItsFoldersAndSize() {
        let run = UUID()
        let copies = [record(run, .copy, "/Docs/Taxes/2025/a.pdf", "/Box/Taxes/2025/a.pdf", size: 1_000_000),
                      record(run, .copy, "/Docs/Taxes/2025/W-2/b.pdf", "/Box/Taxes/2025/W-2/b.pdf", size: 1_000_000)]
        let size = ByteCountFormatter.string(fromByteCount: 2_000_000, countStyle: .file)
        #expect(ActivityEventRun.detail(copies) == "/Docs/Taxes/2025 → /Box/Taxes/2025 · \(size)")
        let dates = [record(run, .matchDates, "/Pics/a.jpg", "/Pics/a.jpg")]
        #expect(ActivityEventRun.detail(dates) == "/Pics")
        #expect(ActivityEventRun.commonFolder(["/a/b/c", "/a/b", "/a/bc"]) == "/a")
    }

    /// A run Sync History's cap cut says its count is only what is kept.
    @Test func aCutRunSaysItsCountIsWhatIsKept() throws {
        let run = UUID()
        let records = (0..<3).map { record(run, .copy, "/A/\($0)", "/B/\($0)", seconds: Double($0)) }
        let row = try #require(runs(ActivityEvents.build(records: records, messages: [], oneWay: [], changes: [],
                                                         choice: .all, search: "", start: nil,
                                                         trimmedRuns: [run])).first)
        #expect(row.isCut)
        #expect(ActivityEventsView.recordsLabel(row) == "3 records kept")
    }

    /// Deletes with no way back are "deleted", never "to the Trash".
    @Test func permanentDeletesAreNotCalledTrash() {
        let run = UUID()
        let trashed = (0..<2).map { SyncHistoryRecord(runId: run, action: .delete, sourcePath: "/A/t\($0)", reachedTrash: true) }
        let gone = (0..<3).map { SyncHistoryRecord(runId: run, action: .delete, sourcePath: "/A/g\($0)", reachedTrash: false) }
        #expect(ActivityEventRun.headline(trashed + gone) == "2 to the Trash, 3 deleted")
    }

    /// A run across two volumes names no common folder rather than "/".
    @Test func aRunAcrossVolumesNamesNoRootFolder() {
        let run = UUID()
        let records = [record(run, .copy, "/Volumes/One/a.txt", "/Users/me/Box/a.txt"),
                       record(run, .copy, "/Users/me/Docs/b.txt", "/Users/me/Box/b.txt")]
        #expect(ActivityEventRun.detail(records) == "→ /Users/me/Box")
    }

    // MARK: Messages

    /// A message with no run is a row; so is one whose run left no records here (cleared, or
    /// trimmed), so nothing it said disappears.
    @Test func aMessageNoRunCarriesIsItsOwnRow() {
        let failed = message("Couldn’t move “Lease 2026.pdf”", seconds: 10)
        let orphan = message("Copied 3 items", run: UUID(), seconds: 5)
        let ids = build(messages: [failed, orphan]).map(\.id)
        #expect(ids == ["message-\(failed.id)", "message-\(orphan.id)"])
    }

    /// Messages alone: the rows no run carries. A run's message is its run's row, not one of these.
    @Test func theMessagesChoiceKeepsOnlyMessagesWithNoRun() {
        let run = UUID()
        let copy = record(run, .copy, "/A/x", "/B/x")
        let led = message("Copied “x”", run: run)
        let failed = message("Couldn’t copy “y”", seconds: 1)
        #expect(build(records: [copy], messages: [led, failed], choice: .messages).map(\.id) == ["message-\(failed.id)"])
        #expect(build(records: [copy], messages: [led, failed], choice: .action(.copy)).map(\.id) == ["run-\(run)"])
    }

    // MARK: Filters

    /// An action filter keeps every run with a match and lists only the matching records, while
    /// the row still counts them all: "1 of 3 records".
    @Test func anActionFilterNarrowsARunToItsMatches() throws {
        let run = UUID()
        let mixed = [record(run, .newFolder, "/D/Bills"), record(run, .move, "/In/a", "/D/Bills/a", seconds: 1),
                     record(run, .move, "/In/b", "/D/Bills/b", seconds: 2)]
        let other = UUID()
        let copies = [record(other, .copy, "/X/c", "/Y/c", seconds: 3)]
        let rows = runs(build(records: mixed + copies, choice: .action(.newFolder)))
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.records.map(\.action) == [.newFolder])
        #expect(row.isNarrowed)
        #expect(ActivityEventsView.recordsLabel(row) == "1 of 3 records")
    }

    /// A path search finds a run by its files; a search for a message's words finds its whole run.
    @Test func aSearchFindsARunByItsFilesOrItsMessage() throws {
        let run = UUID()
        let records = [record(run, .copy, "/Taxes/W-2.pdf", "/Box/W-2.pdf"), record(run, .copy, "/Taxes/1099.pdf", "/Box/1099.pdf")]
        let said = message("Copied 2 items to Dropbox", run: run, seconds: 1)
        let byPath = try #require(runs(build(records: records, messages: [said], search: "w-2")).first)
        #expect(byPath.records.map(\.sourcePath) == ["/Taxes/W-2.pdf"])
        let byWords = try #require(runs(build(records: records, messages: [said], search: "dropbox")).first)
        #expect(byWords.records.count == 2)
        #expect(!byWords.isNarrowed)
        #expect(build(records: records, messages: [said], search: "nothing like it").isEmpty)
    }

    /// The date range reaches every kind of row.
    @Test func theDateRangeReachesRunsAndMessages() {
        let run = UUID()
        let old = record(run, .copy, "/a", "/b", seconds: -7_200)
        let said = message("Couldn’t copy", seconds: -7_200)
        let recent = message("Saved 1 PDF", seconds: 0)
        let ids = build(records: [old], messages: [said, recent], start: at.addingTimeInterval(-3_600)).map(\.id)
        #expect(ids == ["message-\(recent.id)"])
    }

    // MARK: One-way sync

    /// A one-way sync is a row among the runs by time, and One-Way Sync shows them alone.
    @Test func aOneWaySyncIsARowByTime() {
        let run = UUID()
        let copy = record(run, .copy, "/a", "/b", seconds: 0)
        let entry = OneWaySyncHistoryEntry(firstRun: UUID(), startedAt: Int64(at.timeIntervalSince1970) + 60,
                                           steps: [OneWaySyncHistoryStep(step: OneWaySyncStep(action: .copy(from: "Notes/a.md", to: "Notes/a.md", needsDownload: false)), status: .confirmed)],
                                           held: [], finishedAt: Int64(at.timeIntervalSince1970) + 61)
        #expect(build(records: [copy], oneWay: [entry]).map(\.id) == ["oneway-\(entry.id)", "run-\(run)"])
        #expect(build(records: [copy], oneWay: [entry], choice: .oneWaySync).map(\.id) == ["oneway-\(entry.id)"])
        #expect(build(records: [copy], oneWay: [entry], search: "notes/a").map(\.id) == ["oneway-\(entry.id)"])
    }

    // MARK: Days

    /// Rows group by day, newest first, under Today, Yesterday, or the date.
    @Test func rowsGroupByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = at
        let today = message("Today’s", seconds: 0)
        let yesterday = message("Yesterday’s", seconds: -86_400)
        let earlier = message("Earlier", seconds: -5 * 86_400)
        let days = ActivityEvents.days(build(messages: [today, yesterday, earlier]), now: now, calendar: calendar)
        #expect(days.count == 3)
        #expect(days[0].title == "Today")
        #expect(days[1].title == "Yesterday")
        #expect(days[2].events.map(\.id) == ["message-\(earlier.id)"])
    }
}
