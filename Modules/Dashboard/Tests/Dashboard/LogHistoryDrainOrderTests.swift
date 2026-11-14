import Testing
import Foundation
import Events
@testable import Dashboard

/// Pins the order of a history load's two steps: drain the log writer's queue, then read the file.
/// Clear Logs truncates on the writer's background serial queue, and the next load holds a valid
/// token (the guard covers only loads in flight at the clear), so a read that overtook the truncate
/// would bring back the deleted rows. The test supplies the pending write as `drainWriter`, so the
/// order is observable without racing a real queue.
/// Mutation that must fail it: deleting the `drainWriter()` call, or moving it after the read.
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

        // The control: without a drain the same read sees the history line, so the empty result
        // below comes from the drain alone.
        #expect(LogHistoryLoader.loadOlderThanDrainingWriter(boundary, fileURL: url) {}.loadedEntries?.count == 1)

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
}
