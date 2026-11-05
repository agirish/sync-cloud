import Testing
import Foundation
@testable import Events

/// `LogEntry.parse`, the inverse of `formattedString` that lets the Activity Log rebuild earlier
/// sessions from `~/sync-cloud.log`. Pure (no `Logger.shared`), so not serialized with the logger
/// suite.
@Suite struct LogEntryParseTests {

    @Test func testRoundTripsEveryLevel() {
        // parse(format(x)) must re-render the identical canonical line for every level.
        for level in LogLevel.allCases {
            let line = LogEntry(timestamp: Date(timeIntervalSince1970: 1_234_567.89),
                                level: level, message: "hello \(level.rawValue)").formattedString
            let parsed = LogEntry.parse(line)
            #expect(parsed?.formattedString == line)
            #expect(parsed?.level == level)
            #expect(parsed?.message == "hello \(level.rawValue)")
        }
    }

    @Test func testPreservesTimestampToMillisecond() {
        let original = LogEntry(timestamp: Date(timeIntervalSince1970: 1_700_000_000.123),
                                level: .info, message: "ts check")
        let parsed = LogEntry.parse(original.formattedString)
        // Same canonical rendering ⇒ same timestamp at the log's millisecond precision.
        #expect(parsed?.formattedString == original.formattedString)
    }

    @Test func testMessageEmbeddingBracketMarkersLandsWhollyInMessage() {
        // A crafted filename that embeds the "] [" / "] " markers must not forge a second entry:
        // only the leading (real) markers are consumed, the rest stays in the message.
        let nasty = "renamed [2020-01-01 00:00:00.000] [ERROR] fake → safe"
        let line = LogEntry(level: .info, message: nasty).formattedString
        let parsed = LogEntry.parse(line)
        #expect(parsed?.level == .info)
        #expect(parsed?.message == nasty)
    }

    @Test func testWarningLocationTailSurvives() {
        // warning/error append " | Location: …"; the whole message (tail included) round-trips.
        let line = "[2026-07-13 22:13:31.286] [WARN] renaming failed | Location: File.swift:42 / doThing()"
        let parsed = LogEntry.parse(line)
        #expect(parsed?.level == .warning)
        #expect(parsed?.message == "renaming failed | Location: File.swift:42 / doThing()")
        #expect(parsed?.messageLocation == "File.swift:42 / doThing()")
    }

    @Test func testEmptyMessageParses() {
        let line = LogEntry(level: .debug, message: "").formattedString
        let parsed = LogEntry.parse(line)
        #expect(parsed?.level == .debug)
        #expect(parsed?.message == "")
    }

    @Test func testHostileLocaleTimestampIsNotMisdated() {
        // Non-ASCII digits, as an ar-locale formatter would emit. ICU may map them while
        // parsing, so the line may parse, but only ever to the correct Gregorian local date:
        // the pinned locale and calendar keep the user's calendar out of parsing.
        let parsed = LogEntry.parse("[٢٠٢٦-٠٧-١٣ ٢٢:١٣:٣١.٠٠٠] [INFO] hostile digits")
        var expected = DateComponents()
        expected.year = 2026; expected.month = 7; expected.day = 13
        expected.hour = 22; expected.minute = 13; expected.second = 31
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let expectedDate = gregorian.date(from: expected)
        #expect(parsed == nil || parsed?.timestamp == expectedDate)
    }

    @Test func testCanonicalTimestampParsesAsGregorianLocalTime() {
        // The digits are a Gregorian date in local time, whatever the machine's locale or
        // calendar.
        let parsed = LogEntry.parse("[2026-07-13 22:13:31.000] [INFO] pinned date")
        var expected = DateComponents()
        expected.year = 2026; expected.month = 7; expected.day = 13
        expected.hour = 22; expected.minute = 13; expected.second = 31
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        #expect(parsed?.timestamp == gregorian.date(from: expected))
    }

    @Test func testMalformedLinesReturnNil() {
        #expect(LogEntry.parse("") == nil)
        #expect(LogEntry.parse("just some text") == nil)
        #expect(LogEntry.parse("[not a timestamp] [INFO] hi") == nil)   // bad timestamp
        #expect(LogEntry.parse("[2026-07-13 22:13:31.286] [NOPE] hi") == nil)  // unknown level
        #expect(LogEntry.parse("[2026-07-13 22:13:31.286] no level bracket") == nil)
    }
}
