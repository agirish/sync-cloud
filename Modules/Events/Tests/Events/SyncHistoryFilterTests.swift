import Testing
import Foundation
@testable import Events

/// Coverage for `SyncHistoryFilter`: the action gate, path search, date-range bounds, and
/// newest-first ordering — the pure logic behind the Sync History window's controls.
@Suite struct SyncHistoryFilterTests {

    private func record(
        action: SyncAction,
        source: String,
        dest: String? = nil,
        at seconds: TimeInterval
    ) -> SyncHistoryRecord {
        SyncHistoryRecord(
            runId: UUID(),
            timestamp: Date(timeIntervalSince1970: seconds),
            action: action,
            sourcePath: source,
            destPath: dest
        )
    }

    /// Records in ascending time order (as the store appends them).
    private var fixture: [SyncHistoryRecord] {
        [
            record(action: .copy, source: "/photos/beach.jpg", dest: "/backup/beach.jpg", at: 100),
            record(action: .move, source: "/docs/report.pdf", dest: "/archive/report.pdf", at: 200),
            record(action: .delete, source: "/tmp/scratch.txt", at: 300),
            record(action: .copy, source: "/photos/sunset.jpg", dest: "/backup/sunset.jpg", at: 400),
        ]
    }

    @Test func testNoFiltersReturnsAllNewestFirst() {
        let result = SyncHistoryFilter.apply(fixture, action: nil, search: "")
        #expect(result.count == 4)
        // Newest (t=400) first, oldest (t=100) last.
        #expect(result.map { $0.timestamp.timeIntervalSince1970 } == [400, 300, 200, 100])
    }

    @Test func testActionFilterKeepsOnlyThatAction() {
        let copies = SyncHistoryFilter.apply(fixture, action: .copy, search: "")
        #expect(copies.count == 2)
        #expect(copies.allSatisfy { $0.action == .copy })
        // Still newest-first.
        #expect(copies.first?.sourcePath == "/photos/sunset.jpg")

        let deletes = SyncHistoryFilter.apply(fixture, action: .delete, search: "")
        #expect(deletes.map(\.sourcePath) == ["/tmp/scratch.txt"])
    }

    @Test func testSearchMatchesSourceAndDestCaseInsensitively() {
        // Matches source path.
        let photos = SyncHistoryFilter.apply(fixture, action: nil, search: "PHOTOS")
        #expect(photos.count == 2)
        #expect(photos.allSatisfy { $0.sourcePath.contains("/photos/") })

        // Matches destination path (only the moved record lands in /archive).
        let archive = SyncHistoryFilter.apply(fixture, action: nil, search: "archive")
        #expect(archive.map(\.sourcePath) == ["/docs/report.pdf"])

        // A whitespace-only needle is treated as empty (matches everything).
        #expect(SyncHistoryFilter.apply(fixture, action: nil, search: "   ").count == 4)
    }

    @Test func testDateRangeBoundsAreInclusive() {
        let start = Date(timeIntervalSince1970: 200)
        let end = Date(timeIntervalSince1970: 300)
        let inRange = SyncHistoryFilter.apply(fixture, action: nil, search: "", start: start, end: end)
        // t=200 and t=300 both included; t=100 and t=400 excluded.
        #expect(inRange.map { $0.timestamp.timeIntervalSince1970 } == [300, 200])

        // Only a lower bound.
        let fromT300 = SyncHistoryFilter.apply(fixture, action: nil, search: "", start: Date(timeIntervalSince1970: 300))
        #expect(fromT300.map { $0.timestamp.timeIntervalSince1970 } == [400, 300])

        // Only an upper bound.
        let untilT200 = SyncHistoryFilter.apply(fixture, action: nil, search: "", end: Date(timeIntervalSince1970: 200))
        #expect(untilT200.map { $0.timestamp.timeIntervalSince1970 } == [200, 100])
    }

    @Test func testCombinedFiltersCompose() {
        // Copies whose path mentions "sunset", after t=300 — just the last record.
        let result = SyncHistoryFilter.apply(
            fixture, action: .copy, search: "sunset", start: Date(timeIntervalSince1970: 350))
        #expect(result.map(\.sourcePath) == ["/photos/sunset.jpg"])
    }
}
