import Foundation
import Testing
@testable import Dashboard
import Events

/// Sync History's time column and the zone it reads in.
///
/// `SyncHistoryRow` stamped every row through one `DateFormatter` built once for the process, and
/// a `DateFormatter` whose `timeZone` is never set captures the system zone the first time it
/// formats and keeps it. Sync History is a window someone leaves open, so after a flight or a
/// Date & Time change every row in it went on reading in the old zone for the rest of the
/// session, silently.
///
/// Driven through the accessor rather than by moving `NSTimeZone.default`, which is process-wide
/// and would race every other suite in the run — the same rule
/// `OrganizeRenderMemoTests.theStampFormattersFollowTheSystemZone` follows for
/// `RestructureLens.formatter(_:)`, which is this defect two modules over.
@MainActor
@Suite(.serialized) struct SyncHistoryRowTimeZoneTests {

    /// 2026-06-01 12:00:00 UTC — a frozen instant, so the expectation is arithmetic and not a
    /// second reading of the same clock.
    private static let instant = Date(timeIntervalSince1970: 1_780_315_200)

    /// A zone that is definitely not this machine's, so the mutation the tests perform is a real
    /// move and not a no-op wherever the suite happens to run.
    private static func elsewhere() throws -> TimeZone {
        try #require([TimeZone(identifier: "Asia/Kolkata"), TimeZone(identifier: "America/Los_Angeles")]
            .compactMap { $0 }.first { $0 != TimeZone.current })
    }

    /// What the column should read, computed independently of the thing under test: a fresh
    /// formatter, same format, same pins, on the system zone. Fresh, so it cannot inherit the
    /// staleness this suite exists to catch.
    private static func expected(_ date: Date) -> String {
        let control = DateFormatter()
        control.locale = Locale(identifier: "en_US_POSIX")
        control.calendar = Calendar(identifier: .gregorian)
        control.timeZone = .current
        control.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return control.string(from: date)
    }

    /// **The shared formatter is put back on the system zone before it is handed back.**
    ///
    /// Mutate it out from under the accessor and ask again: a formatter that captured its zone
    /// answers with the stale one, which is the bug exactly.
    @Test func theSyncHistoryStampFollowsTheSystemZone() throws {
        let away = try Self.elsewhere()
        SyncHistoryRow.timeFormatter().timeZone = away

        #expect(SyncHistoryRow.timeFormatter().timeZone == TimeZone.current,
                "a cached formatter must be put back on the system zone before it is used")
    }

    /// **The call-site half.** The test above is about a formatter; this one is about the string
    /// the row actually draws, and it is the one that would catch `timeString` going back to the
    /// cached formatter directly — an accessor nothing routes through is exactly the shape a rule
    /// extracted for testability decays into.
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

        SyncHistoryRow.timeFormatter().timeZone = away

        #expect(SyncHistoryRow.timeString(Self.instant) == Self.expected(Self.instant),
                "the row drew its stamp in a zone the system has left")
    }
}
