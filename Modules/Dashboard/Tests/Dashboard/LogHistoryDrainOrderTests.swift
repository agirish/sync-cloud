import Testing
import Foundation
import Events
@testable import Dashboard

/// Pins the ORDER of the two steps a history load performs: drain the log writer's queue, then read
/// the file.
///
/// Clear Logs truncates the on-disk log from the writer's own background-qos serial queue, so the
/// truncate can still be pending when the user's next click starts a history load. That load holds a
/// perfectly valid token — the token guard only defends loads already in flight AT the clear — so a
/// read that overtakes the truncate resurrects the rows the user just deleted, as `.loaded` history
/// that stays for the window's lifetime.
///
/// The pending write is supplied by the test as `drainWriter` itself, which makes the ordering
/// observable without racing a real queue: if the read runs first it sees the pre-clear bytes, and
/// if the drain runs first it sees the truncated file. Both directions are asserted below, so
/// deleting the `drainWriter()` call — or moving it after the read — fails deterministically.
@Suite struct LogHistoryDrainOrderTests {

    private let boundary = Date(timeIntervalSince1970: 1_780_000_000)

    /// A log file holding one pre-boundary (history) line.
    private func makeLogFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drain-order-\(UUID().uuidString).log")
        let older = boundary.addingTimeInterval(-3600)
        let line = LogEntry(timestamp: older, level: .error, message: "Copy failed").formattedString
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func testHistoryReadHappensAfterThePendingClearIsDrained() throws {
        let url = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // Sanity: the file really does hold a history line before anything drains.
        #expect(LogHistoryLoader.loadOlderThan(boundary, fileURL: url).loadedEntries?.count == 1)

        // `drainWriter` stands in for the enqueued Clear Logs truncate landing.
        var drained = false
        let parsed = LogHistoryLoader.loadOlderThanDrainingWriter(boundary, fileURL: url) {
            drained = true
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }

        #expect(drained, "the writer barrier must be run, not skipped")
        // `loadedEntries` — not a bare count — so a READ FAILURE can never masquerade as the
        // post-clear empty this test is asserting.
        #expect(parsed.loadedEntries?.isEmpty == true, "a load after Clear Logs must not resurrect the cleared rows")
    }

    @Test func testTheSameReadWithoutDrainingWouldSeeTheStaleRows() throws {
        // The control that gives the test above its teeth: the pre-clear file genuinely parses to a
        // non-empty history, so `parsed.isEmpty` there is caused by the drain and nothing else.
        let url = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let withoutDraining = LogHistoryLoader.loadOlderThanDrainingWriter(boundary, fileURL: url) {}
        #expect(withoutDraining.loadedEntries?.count == 1)
    }
}
