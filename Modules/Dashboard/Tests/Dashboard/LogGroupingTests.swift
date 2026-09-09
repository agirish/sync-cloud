import Testing
import Foundation
import Events
@testable import Dashboard

/// Coverage for LogGrouping — the operation-run folding and day bucketing that back the Activity
/// Log's grouped view. Pure, so it's tested without a View or @State.
@Suite struct LogGroupingTests {

    /// A UTC Gregorian calendar so `startOfDay` boundaries are deterministic regardless of the host
    /// machine's timezone.
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// Compact fingerprint of a fold result so assertions read clearly.
    private func shape(_ items: [LogGrouping.Item]) -> [String] {
        items.map {
            switch $0 {
            case .entry(let e): return "entry:\(e.message)"
            case .group(let g): return "group:\(g.kind.rawValue):\(g.count)"
            }
        }
    }

    // MARK: Kind classification

    @Test func testClassifyKnownPrefixes() {
        #expect(LogGrouping.Kind.classify("Synced file: Reports/q3.pdf") == .synced)
        #expect(LogGrouping.Kind.classify("Filing: filed “notes.md” → Documents") == .filed)
        #expect(LogGrouping.Kind.classify("Scan completed: found 7 differences.") == nil)
        #expect(LogGrouping.Kind.classify("Copied 12 item(s) in bulk") == nil)
    }

    // MARK: Fold

    @Test func testFoldCollapsesConsecutiveRun() {
        let entries = [
            LogEntry(level: .info, message: "Synced file: a"),
            LogEntry(level: .info, message: "Synced file: b"),
            LogEntry(level: .info, message: "Synced file: c"),
        ]
        let items = LogGrouping.fold(entries)
        #expect(shape(items) == ["group:synced:3"])
        if case .group(let g) = items[0] {
            #expect(g.title == "Synced 3 files")
            #expect(g.children.map(\.message) == ["Synced file: a", "Synced file: b", "Synced file: c"])
            #expect(g.id == entries[0].id.uuidString) // stable id = first child
        } else {
            Issue.record("expected a group")
        }
    }

    @Test func testLoneMatchingLineStaysAnEntry() {
        // A run of 1 is nothing to collapse — it renders as a normal row.
        let items = LogGrouping.fold([LogEntry(level: .info, message: "Synced file: only-one")])
        #expect(shape(items) == ["entry:Synced file: only-one"])
    }

    @Test func testFoldLeavesNonMatchingLinesAndSeparatesKinds() {
        let entries = [
            LogEntry(level: .info, message: "Scan completed"),
            LogEntry(level: .info, message: "Synced file: a"),
            LogEntry(level: .info, message: "Synced file: b"),
            LogEntry(level: .info, message: "Filing: filed x"),   // different kind → breaks the run
            LogEntry(level: .info, message: "Filing: filed y"),
            LogEntry(level: .warning, message: "Low space"),
        ]
        #expect(shape(LogGrouping.fold(entries)) ==
                ["entry:Scan completed", "group:synced:2", "group:filed:2", "entry:Low space"])
    }

    @Test func testAdjacentDifferentKindsDoNotMerge() {
        // One synced + one filed, adjacent: each run is length 1, so neither folds.
        let entries = [
            LogEntry(level: .info, message: "Synced file: a"),
            LogEntry(level: .info, message: "Filing: filed b"),
        ]
        #expect(shape(LogGrouping.fold(entries)) == ["entry:Synced file: a", "entry:Filing: filed b"])
    }

    @Test func testGroupInheritsHighestSeverity() {
        // A failure buried in a run tints the collapsed header, so it isn't hidden.
        let entries = [
            LogEntry(level: .info, message: "Synced file: a"),
            LogEntry(level: .error, message: "Synced file: b"),
            LogEntry(level: .info, message: "Synced file: c"),
        ]
        let items = LogGrouping.fold(entries)
        guard case .group(let g) = items[0] else { Issue.record("expected a group"); return }
        #expect(g.level == .error)
    }

    // MARK: Day bucketing

    @Test func testByDaySplitsIntoOrderedSections() {
        let now = at(2026, 7, 14, 12)
        // Newest-first, spanning today and yesterday.
        let entries = [
            LogEntry(timestamp: at(2026, 7, 14, 10), level: .info, message: "Loaded tree"),
            LogEntry(timestamp: at(2026, 7, 14, 9), level: .info, message: "Started up"),
            LogEntry(timestamp: at(2026, 7, 13, 20), level: .warning, message: "Low space"),
        ]
        let sections = LogGrouping.byDay(entries, now: now, calendar: utc)
        #expect(sections.map(\.header) == ["Today", "Yesterday"])
        #expect(shape(sections[0].items) == ["entry:Loaded tree", "entry:Started up"])
        #expect(shape(sections[1].items) == ["entry:Low space"])
    }

    @Test func testByDayFoldsWithinEachDaySeparately() {
        let now = at(2026, 7, 14, 12)
        // A synced run that straddles a day boundary must fold once per day, not across the split.
        let entries = [
            LogEntry(timestamp: at(2026, 7, 14, 10), level: .info, message: "Synced file: a"),
            LogEntry(timestamp: at(2026, 7, 14, 9), level: .info, message: "Synced file: b"),
            LogEntry(timestamp: at(2026, 7, 13, 23), level: .info, message: "Synced file: c"),
            LogEntry(timestamp: at(2026, 7, 13, 22), level: .info, message: "Synced file: d"),
        ]
        let sections = LogGrouping.byDay(entries, now: now, calendar: utc)
        #expect(sections.map(\.header) == ["Today", "Yesterday"])
        #expect(shape(sections[0].items) == ["group:synced:2"])
        #expect(shape(sections[1].items) == ["group:synced:2"])
    }

    @Test func testOlderDayGetsADatedHeaderNotTodayOrYesterday() {
        let now = at(2026, 7, 14, 12)
        let entries = [LogEntry(timestamp: at(2026, 7, 1, 8), level: .info, message: "old")]
        let header = LogGrouping.byDay(entries, now: now, calendar: utc)[0].header
        #expect(header != "Today")
        #expect(header != "Yesterday")
        #expect(!header.isEmpty)
        // The date itself, which the three assertions above never looked at — and that is how a
        // header a full day out went unnoticed. `1` is the day this bucket is for in UTC.
        #expect(header.contains("1"), "the dated header does not name the day it labels")
    }

    /// **A dated header names the day its bucket is for, in the bucket's own zone.**
    ///
    /// `byDay` takes the bucket boundary from the calendar it is handed, but the two header
    /// formatters used to be shared `DateFormatter`s that captured the system zone at first use and
    /// never looked again. So the boundary moved with the machine and the rendering did not: entries
    /// bucketed at midnight in one zone were drawn under a date belonging to another — a full day
    /// out, and only ever on sections two days old and older, because `Today`/`Yesterday` compare
    /// against the same fresh calendar and were always right.
    ///
    /// **The assertion has to pin the rendered date, not merely show two zones differing.** The
    /// first version of this test compared a UTC bucket's header with a Kolkata one and asserted
    /// they were not equal — which passes under the bug too, because the two buckets are different
    /// instants and render differently in any single zone. It caught nothing; the mutation that
    /// puts the formatter back on the system zone went green through it.
    ///
    /// The two zones are the extremes of the real offset range (+14 and −12), and that is what makes
    /// this independent of the machine it runs on. Rendering midnight-in-Z under the system zone C
    /// names the wrong day whenever `offset(C) < offset(Z)`: at Z = +14 that is every C but +14
    /// itself, and Z = −12 covers the remaining C in +12…+14. One of the two always fails under the
    /// bug, wherever this runs.
    @Test func testADatedHeaderIsRenderedInItsBucketsOwnZone() throws {
        let instant = at(2026, 7, 1, 20)
        let now = at(2026, 7, 14, 12)
        let entries = [LogEntry(timestamp: instant, level: .info, message: "old")]

        for offsetHours in [14, -12] {
            var bucket = Calendar(identifier: .gregorian)
            bucket.timeZone = try #require(TimeZone(secondsFromGMT: offsetHours * 3600))
            let section = LogGrouping.byDay(entries, now: now, calendar: bucket)[0]

            // The expectation, built independently: a fresh formatter, same template, on the
            // bucket's own zone. Fresh, so it cannot inherit the staleness under test.
            let control = DateFormatter()
            control.timeZone = bucket.timeZone
            control.setLocalizedDateFormatFromTemplate("EEEEMMMd")
            let day = bucket.startOfDay(for: instant)

            #expect(section.header == control.string(from: day),
                    "the header names a day belonging to some zone other than its bucket's")
            #expect(section.id == Self.isoDay(day, in: bucket.timeZone))
        }
    }

    /// `yyyy-MM-dd` for a section id, computed independently of the code under test.
    private static func isoDay(_ day: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }

    @Test func testEmptyInputYieldsNoSections() {
        #expect(LogGrouping.byDay([], now: at(2026, 7, 14, 12), calendar: utc).isEmpty)
    }
}
