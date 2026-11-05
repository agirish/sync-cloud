import Foundation
import Testing
@testable import Events

/// The zone `~/sync-cloud.log`'s timestamps are written and read in.
///
/// A shared `DateFormatter` with no `timeZone` keeps the zone it first formatted in, so after a
/// zone change every later line would carry the wrong wall clock, permanently. The same formatter
/// parses history back for the Activity Log, so writing and reading must both refresh, or every
/// older-history row would shift. Both halves are covered.
///
/// Driven through `stageZoneForTesting`, not by moving the process-wide `NSTimeZone.default`,
/// which would race other suites (as `OrganizeRenderMemoTests.theStampFormattersFollowTheSystemZone`
/// does for `RestructureLens`). See `LogTimestampFormatter`.
@Suite(.serialized) struct LogTimestampZoneTests {

    /// 2026-06-01 12:00:00.000 UTC — whole seconds, so a round-tripped timestamp compares exactly
    /// at the log's millisecond precision.
    private static let instant = Date(timeIntervalSince1970: 1_780_315_200)

    /// A zone that isn't this machine's, so staging it is a real move wherever the suite runs.
    private static func elsewhere() throws -> TimeZone {
        try #require([TimeZone(identifier: "Asia/Kolkata"), TimeZone(identifier: "America/Los_Angeles")]
            .compactMap { $0 }.first { $0 != TimeZone.current })
    }

    /// What a line's timestamp should read, from a fresh formatter with the same format and pins on
    /// `zone`, so it can't inherit the staleness this suite catches.
    private static func stamp(_ date: Date, in zone: TimeZone) -> String {
        let control = DateFormatter()
        control.locale = Locale(identifier: "en_US_POSIX")
        control.calendar = Calendar(identifier: .gregorian)
        control.timeZone = zone
        control.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return control.string(from: date)
    }

    /// The write half: with the formatter staged on a stale zone, a line must carry the wall clock
    /// of the zone the machine is in now.
    @Test func aLineIsWrittenInTheZoneTheSystemIsInNow() throws {
        let away = try Self.elsewhere()
        // Positive control: if these agreed, the assertion below would pass without the refresh.
        #expect(Self.stamp(Self.instant, in: away) != Self.stamp(Self.instant, in: .current),
                "the staged zone and the system zone render this instant identically — pick another")

        LogEntry.timestampFormatter.stageZoneForTesting(away)
        let line = LogEntry(timestamp: Self.instant, level: .info, message: "zone check").formattedString

        #expect(line == "[\(Self.stamp(Self.instant, in: .current))] [INFO] zone check",
                "the log line carries the wall clock of a zone the machine has left")
        #expect(LogEntry.timestampFormatter.zone == TimeZone.current)
    }

    /// The read half: a line written on the system zone reads back on it, even from a reader
    /// staged elsewhere. Fails if only `formattedString` refreshes the zone.
    @Test func aLineReadsBackOnTheSameZoneItWasWrittenOn() throws {
        let away = try Self.elsewhere()
        let line = LogEntry(timestamp: Self.instant, level: .warning, message: "round trip").formattedString

        LogEntry.timestampFormatter.stageZoneForTesting(away)
        let parsed = try #require(LogEntry.parse(line))

        #expect(parsed.timestamp == Self.instant,
                "the line parsed at an instant the zone it was written in does not agree with")
        #expect(parsed.formattedString == line)
    }

    /// Both halves together, the invariant the Activity Log depends on: a line's text survives a
    /// parse and re-render unchanged. Both stagings are stale, so both refreshes must fire.
    @Test func aLinesTextSurvivesTheRoundTripWhateverZoneTheFormatterWokeUpIn() throws {
        let away = try Self.elsewhere()
        LogEntry.timestampFormatter.stageZoneForTesting(away)
        let line = LogEntry(timestamp: Self.instant, level: .error, message: "text identity").formattedString

        LogEntry.timestampFormatter.stageZoneForTesting(away)
        let reRendered = try #require(LogEntry.parse(line)).formattedString

        #expect(reRendered == line)
        #expect(line.hasPrefix("[\(Self.stamp(Self.instant, in: .current))]"))
    }
}
