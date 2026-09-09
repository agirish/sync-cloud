import Foundation
import Testing
@testable import Events

/// The zone `~/sync-cloud.log`'s timestamps are written and read in.
///
/// `LogEntry` stamped every line through one `DateFormatter` built once for the process, and a
/// `DateFormatter` whose `timeZone` is never set captures the system zone the first time it formats
/// and keeps it. After a Date & Time change or a flight, every line written for the rest of the
/// session carried the wall clock of a place the machine had left — and the file outlives the
/// session, so nothing ever corrects it.
///
/// The pairing is the half that is easy to lose: the same formatter also PARSES history lines back
/// out of the file, and the Activity Log renders what it parses. Parse-then-render is the identity
/// on the file's text only while the reader and the writer are on the same zone, so a fix that
/// refreshed one side and not the other would shift every older-history row. Both sides are
/// covered below.
///
/// Driven through `stageZoneForTesting` rather than by moving `NSTimeZone.default`, which is
/// process-wide and would race every other suite in the run — the same rule
/// `OrganizeRenderMemoTests.theStampFormattersFollowTheSystemZone` follows for `RestructureLens`.
///
/// The UI columns share `Design.ZoneRefreshedFormatter`; this one deliberately does not, because
/// Events is a leaf module that must not depend on Design — see `LogTimestampFormatter`.
@Suite(.serialized) struct LogTimestampZoneTests {

    /// 2026-06-01 12:00:00.000 UTC — whole seconds, so a round-tripped timestamp compares exactly
    /// at the log's millisecond precision.
    private static let instant = Date(timeIntervalSince1970: 1_780_315_200)

    /// A zone that is definitely not this machine's, so staging it is a real move and not a no-op
    /// wherever the suite happens to run.
    private static func elsewhere() throws -> TimeZone {
        try #require([TimeZone(identifier: "Asia/Kolkata"), TimeZone(identifier: "America/Los_Angeles")]
            .compactMap { $0 }.first { $0 != TimeZone.current })
    }

    /// What a line's timestamp should read, computed independently of the thing under test: a
    /// fresh formatter, same format, same pins, on `zone`. Fresh, so it cannot inherit the
    /// staleness this suite exists to catch.
    private static func stamp(_ date: Date, in zone: TimeZone) -> String {
        let control = DateFormatter()
        control.locale = Locale(identifier: "en_US_POSIX")
        control.calendar = Calendar(identifier: .gregorian)
        control.timeZone = zone
        control.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return control.string(from: date)
    }

    /// **The write half.** Stage the stale state the bug leaves behind, then write a line: it must
    /// carry the wall clock of the zone the machine is in now, not the one the formatter woke up
    /// in.
    @Test func aLineIsWrittenInTheZoneTheSystemIsInNow() throws {
        let away = try Self.elsewhere()
        // Positive control on the fixture: if these agreed, the assertion below would pass without
        // the refresh ever running.
        #expect(Self.stamp(Self.instant, in: away) != Self.stamp(Self.instant, in: .current),
                "the staged zone and the system zone render this instant identically — pick another")

        LogEntry.timestampFormatter.stageZoneForTesting(away)
        let line = LogEntry(timestamp: Self.instant, level: .info, message: "zone check").formattedString

        #expect(line == "[\(Self.stamp(Self.instant, in: .current))] [INFO] zone check",
                "the log line carries the wall clock of a zone the machine has left")
        #expect(LogEntry.timestampFormatter.zone == TimeZone.current)
    }

    /// **The read half, and the pairing.** A line written on the system zone must read back on the
    /// system zone — so a reader that woke up elsewhere is put right before it parses. This is the
    /// test that would catch the refresh being applied to `formattedString` alone, which is the
    /// shape that shifts every older-history row in the Activity Log.
    @Test func aLineReadsBackOnTheSameZoneItWasWrittenOn() throws {
        let away = try Self.elsewhere()
        let line = LogEntry(timestamp: Self.instant, level: .warning, message: "round trip").formattedString

        LogEntry.timestampFormatter.stageZoneForTesting(away)
        let parsed = try #require(LogEntry.parse(line))

        #expect(parsed.timestamp == Self.instant,
                "the line parsed at an instant the zone it was written in does not agree with")
        #expect(parsed.formattedString == line)
    }

    /// The two halves together, which is the invariant the Activity Log actually depends on:
    /// whatever zone the process woke up in, a line's text survives a parse and a re-render
    /// unchanged. Both stagings are on the stale zone, so both refreshes have to fire.
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
