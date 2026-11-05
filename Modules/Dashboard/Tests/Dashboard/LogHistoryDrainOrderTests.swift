import Testing
import Foundation
import Events
@testable import Dashboard

/// Pins the order of a history load's two steps: drain the log writer's queue, then read the file.
///
/// Clear Logs truncates the log on the writer's background serial queue, so the truncate can still
/// be pending when the next click starts a history load. That load holds a valid token (the guard
/// only covers loads in flight at the clear), so a read that overtakes the truncate would bring
/// back the deleted rows for the window's lifetime.
///
/// The test supplies the pending write as `drainWriter`, so the order is observable without racing
/// a real queue. Deleting the `drainWriter()` call, or moving it after the read, must fail.
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
        // `loadedEntries`, not a bare count, so a read failure can't pass as the post-clear empty.
        #expect(parsed.loadedEntries?.isEmpty == true, "a load after Clear Logs must not resurrect the cleared rows")
    }

    @Test func testTheSameReadWithoutDrainingWouldSeeTheStaleRows() throws {
        // The control: the pre-clear file parses to a non-empty history, so the empty result above
        // comes from the drain alone.
        let url = try makeLogFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let withoutDraining = LogHistoryLoader.loadOlderThanDrainingWriter(boundary, fileURL: url) {}
        #expect(withoutDraining.loadedEntries?.count == 1)
    }
}
