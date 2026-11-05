import Foundation
import Testing
@testable import Dashboard
import Events

/// Sync History's time column and the zone it reads in.
///
/// `SyncHistoryRow` stamps every row through one shared `DateFormatter`, and one whose `timeZone`
/// is never set keeps the zone it first formatted in. Sync History is a window left open, so after
/// a flight or a Date & Time change its rows would read in the old zone for the rest of the session.
///
/// Driven through the accessor, not by moving `NSTimeZone.default`, which is process-wide and would
/// race every other suite (as in `OrganizeRenderMemoTests.theStampFormattersFollowTheSystemZone`).
/// The rule itself is tested on `Design.ZoneRefreshedFormatter`; these assert the column routes
/// through it.
@MainActor
@Suite(.serialized) struct SyncHistoryRowTimeZoneTests {

    /// 2026-06-01 12:00:00 UTC, frozen so the expectation is arithmetic, not a second reading of
    /// the clock.
    private static let instant = Date(timeIntervalSince1970: 1_780_315_200)

    /// A zone that is not this machine's, so the tests' mutation is a real move wherever they run.
    private static func elsewhere() throws -> TimeZone {
        try #require([TimeZone(identifier: "Asia/Kolkata"), TimeZone(identifier: "America/Los_Angeles")]
            .compactMap { $0 }.first { $0 != TimeZone.current })
    }

    /// What the column should read, computed independently: a fresh formatter with the same format
    /// and pins on the system zone, so it can't inherit the staleness under test.
    private static func expected(_ date: Date) -> String {
        let control = DateFormatter()
        control.locale = Locale(identifier: "en_US_POSIX")
        control.calendar = Calendar(identifier: .gregorian)
        control.timeZone = .current
        control.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return control.string(from: date)
    }

    /// The shared formatter is put back on the system zone before it is handed back. Mutated out
    /// from under the accessor, a formatter that captured its zone would answer with the stale one.
    @Test func theSyncHistoryStampFollowsTheSystemZone() throws {
        let away = try Self.elsewhere()
        SyncHistoryRow.timeFormatter.stageZoneForTesting(away)
        _ = SyncHistoryRow.timeFormatter.string(from: Self.instant)

        #expect(SyncHistoryRow.timeFormatter.zone == TimeZone.current,
                "a cached formatter must be put back on the system zone before it is used")
    }

    /// The call-site half: the string the row draws. Catches `timeString` using the cached
    /// formatter directly, bypassing the accessor the test above checks.
    @Test func theRowsStampIsRenderedInTheSystemZone() throws {
        let away = try Self.elsewhere()
        let stale = { () -> String in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = away
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.string(from: Self.instant)
        }()
        // A positive control on the fixture itself: if these two agreed, the assertion below
        // would pass without the refresh ever running.
        #expect(stale != Self.expected(Self.instant),
                "the fixture zone and the system zone render this instant identically — pick another")

        SyncHistoryRow.timeFormatter.stageZoneForTesting(away)

        #expect(SyncHistoryRow.timeString(Self.instant) == Self.expected(Self.instant),
                "the row drew its stamp in a zone the system has left")
    }

    /// A date match's row says the date it replaced, in the column's own format, and a record with
    /// none says nothing. The row's wiring is read at source level: the comfortable layout draws it.
    @Test func aDateMatchRowSaysTheDateItReplaced() throws {
        let previous = Date(timeIntervalSince1970: 1_600_000_000)
        let match = SyncHistoryRecord(runId: UUID(), action: .matchDates, sourcePath: "/l/a.txt",
                                      destPath: "/r/a.txt", previousModificationDate: previous)
        #expect(SyncHistoryRow.previousDateText(match) == "was " + SyncHistoryRow.timeString(previous))
        #expect(SyncHistoryRow.previousDateText(SyncHistoryRecord(runId: UUID(), action: .copy, sourcePath: "/l/a.txt")) == nil)

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Dashboard/SyncHistoryView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8), "cannot read SyncHistoryView.swift")
        #expect(source.contains("if let previous = Self.previousDateText(record) {"), "the row no longer draws the previous date")
    }
}
