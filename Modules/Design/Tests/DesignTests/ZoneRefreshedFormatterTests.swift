import Foundation
import Testing
@testable import Design

/// The one rule eleven date columns now share: the system zone is re-checked on every use, never
/// captured.
///
/// Driven through `stageZoneForTesting` rather than by moving `NSTimeZone.default`, which is
/// process-wide and would race every other suite in the run.
@Suite(.serialized) struct ZoneRefreshedFormatterTests {

    /// 2026-06-01 12:00:00.000 UTC — whole seconds, so a round-tripped stamp compares exactly.
    private static let instant = Date(timeIntervalSince1970: 1_780_315_200)

    private static func elsewhere() throws -> TimeZone {
        try #require([TimeZone(identifier: "Asia/Kolkata"), TimeZone(identifier: "America/Los_Angeles")]
            .compactMap { $0 }.first { $0 != TimeZone.current })
    }

    /// The expectation, computed independently of the type under test: a fresh formatter, same
    /// format, same pins, on `zone`. Fresh, so it cannot inherit the staleness being tested for.
    private static func control(_ format: String, _ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = format
        return f
    }

    /// **The refresh itself.** Stage the stale state the bug leaves behind, then format: the result
    /// must be the system zone's reading, and the formatter must have been put back.
    @Test func aStagedZoneIsRefreshedAwayBeforeTheNextUse() throws {
        let away = try Self.elsewhere()
        let subject = ZoneRefreshedFormatter.fixed("yyyy-MM-dd HH:mm:ss")
        // Positive control: if these agreed the assertion below would pass without a refresh.
        #expect(Self.control("yyyy-MM-dd HH:mm:ss", away).string(from: Self.instant)
                != Self.control("yyyy-MM-dd HH:mm:ss", .current).string(from: Self.instant),
                "the staged zone and the system zone render this instant identically — pick another")

        subject.stageZoneForTesting(away)

        #expect(subject.string(from: Self.instant)
                == Self.control("yyyy-MM-dd HH:mm:ss", .current).string(from: Self.instant))
        #expect(subject.zone == TimeZone.current)
    }

    /// **An explicitly named zone survives the refresh** — the seam snapshot references use so they
    /// stop baking in the recording machine's zone.
    @Test func anExplicitZoneIsHonouredRatherThanOverwritten() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let subject = ZoneRefreshedFormatter.fixed("HH:mm:ss.SSS")

        #expect(subject.string(from: Self.instant, in: utc) == "12:00:00.000")
        #expect(subject.string(from: Self.instant, in: kolkata) == "17:30:00.000")
        #expect(subject.zone == kolkata)
    }

    /// **Reading and writing share a zone**, which is what any round trip depends on. Both sides are
    /// staged stale, so both refreshes have to fire for the text to survive.
    @Test func aStampReadsBackOnTheZoneItWasWrittenOn() throws {
        let away = try Self.elsewhere()
        let subject = ZoneRefreshedFormatter.fixed("yyyy-MM-dd HH:mm:ss")

        subject.stageZoneForTesting(away)
        let text = subject.string(from: Self.instant)
        subject.stageZoneForTesting(away)
        let parsed = try #require(subject.date(from: text))

        #expect(parsed == Self.instant)
    }

    /// **`fixed` pins the calendar as well as the locale.** The zone is this type's subject, but the
    /// pins are why callers can use it for text that round-trips, and a fixed-format formatter that
    /// quietly followed the system calendar would render Gregorian dates as 2569 or 1448.
    @Test func fixedPinsLocaleAndCalendarAgainstTheSystemRegion() throws {
        let subject = ZoneRefreshedFormatter.fixed("yyyy-MM-dd")
        let buddhist = Calendar(identifier: .buddhist)
        // The premise: this instant really does render differently under another calendar, so the
        // assertion below is about the pin and not about the date being calendar-agnostic.
        let unpinned = DateFormatter()
        unpinned.calendar = buddhist
        unpinned.locale = Locale(identifier: "en_US_POSIX")
        unpinned.timeZone = .current
        unpinned.dateFormat = "yyyy-MM-dd"
        #expect(unpinned.string(from: Self.instant).hasPrefix("2026") == false,
                "the Buddhist calendar rendered a Gregorian year — the premise of this test is gone")

        #expect(subject.string(from: Self.instant).hasPrefix("2026"))
    }

    /// **The localized cases still refresh.** `localized` and `template` build their format from the
    /// reader's region rather than a literal, and the refresh has to reach them the same way — a
    /// styled Modified column is exactly where this defect was found seven more times.
    @Test func theLocalizedAndTemplateCasesRefreshToo() throws {
        let away = try Self.elsewhere()
        for subject in [ZoneRefreshedFormatter.localized(date: .medium, time: .short),
                        ZoneRefreshedFormatter.template("EEEEMMMd")] {
            subject.stageZoneForTesting(away)
            _ = subject.string(from: Self.instant)
            #expect(subject.zone == TimeZone.current)
        }
    }

    /// **Concurrent use does not race.** Most callers are main-actor `View`s, but `DetailsSidebar`
    /// reads its formatter off the main actor by design, which is the whole reason the zone check
    /// and the format are taken under one lock rather than left as a bare compare-and-assign.
    @Test func manyThreadsMayFormatAtOnce() async throws {
        let subject = ZoneRefreshedFormatter.fixed("yyyy-MM-dd HH:mm:ss")
        let expected = Self.control("yyyy-MM-dd HH:mm:ss", .current).string(from: Self.instant)
        let instant = Self.instant

        let readings = await withTaskGroup(of: String.self) { group in
            for _ in 0..<200 { group.addTask { subject.string(from: instant) } }
            var seen: Set<String> = []
            for await reading in group { seen.insert(reading) }
            return seen
        }

        #expect(readings == [expected],
                "concurrent formatting produced more than one answer for one instant")
    }
}
