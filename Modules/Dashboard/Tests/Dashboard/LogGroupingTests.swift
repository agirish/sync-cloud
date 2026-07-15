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
    }

    @Test func testEmptyInputYieldsNoSections() {
        #expect(LogGrouping.byDay([], now: at(2026, 7, 14, 12), calendar: utc).isEmpty)
    }
}
