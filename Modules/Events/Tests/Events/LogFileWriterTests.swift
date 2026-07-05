import Testing
import Foundation
@testable import Events

/// Direct coverage for `LogFileWriter`, the persistent-handle disk writer behind `Logger`.
/// These exercise the two behaviors that have no other test: self-healing after the log file is
/// removed out from under the open handle (the C5 follow-up fix, 0269f24), and `clear()`
/// truncation. Each test writes to its own temp file so nothing touches `~/sync-cloud.log`.
@Suite struct LogFileWriterTests {

    /// Makes a unique temp path (the file itself is created by `LogFileWriter.init`).
    private func makeTempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogFileWriterTest-\(UUID().uuidString).log")
    }

    @Test func testLogFileRecreatedAfterExternalDeletion() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = LogFileWriter(url: url)

        writer.append("first line\n")
        writer.flush()
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Simulate the file being deleted/replaced externally while the app runs: the open handle
        // now points at an orphaned inode, so a naive write would be silently lost.
        try FileManager.default.removeItem(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        writer.append("second line\n")
        writer.flush()

        // The writer must have recreated the file and persisted the post-deletion line.
        #expect(FileManager.default.fileExists(atPath: url.path))
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("second line"))
        // The pre-deletion line lived in the discarded inode, so the fresh file starts clean.
        #expect(!contents.contains("first line"))
    }

    @Test func testClearTruncatesFile() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = LogFileWriter(url: url)

        writer.append("some log content\n")
        writer.flush()
        #expect(try String(contentsOf: url, encoding: .utf8).isEmpty == false)

        writer.clear()
        writer.flush()
        #expect(try String(contentsOf: url, encoding: .utf8).isEmpty)

        // The handle stays valid after clearing: subsequent appends still persist.
        writer.append("after clear\n")
        writer.flush()
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("after clear"))
    }
}
