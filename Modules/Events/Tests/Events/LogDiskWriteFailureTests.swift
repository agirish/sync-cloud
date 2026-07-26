import Testing
import Foundation
@testable import Events

/// Pins the ONE signal the logging stack emits when the disk log stops accepting writes.
///
/// Every write in `LogFileWriter` used to be a `try?`: on a full or unmounted volume the Activity
/// Log kept scrolling from memory while `~/sync-cloud.log` silently stopped growing, and nothing
/// anywhere recorded that the history the user would later go looking for was no longer being
/// written. The fix cannot be "log the failure" in the ordinary sense — that hands the report back
/// to the writer that just failed — so it is a one-shot: the first failure, once, in memory.
///
/// Both halves are pinned here: that the writer reports (exactly once, and never on success), and
/// that `Logger` turns that report into an in-memory warning entry.
@Suite struct LogDiskWriteFailureTests {

    /// Collects the writer's callbacks, which arrive on the writer's own background queue.
    private final class FailureCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func record(_ reason: String) {
            lock.lock()
            storage.append(reason)
            lock.unlock()
        }

        var reasons: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// A path inside a directory that does not exist, so BOTH write paths fail: the handle can't be
    /// opened (nothing to open) and the fallback's atomic write has no directory to write into.
    /// The unwritable-file trick used elsewhere in these tests isn't enough — an atomic replace
    /// only needs directory permission, so the fallback would succeed.
    private func makeUnwritableURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-dir-\(UUID().uuidString)")
            .appendingPathComponent("app.log")
    }

    @Test func testAFailedDiskWriteIsReportedOnceNotPerLine() {
        let url = makeUnwritableURL()
        let collector = FailureCollector()
        let writer = LogFileWriter(url: url, onWriteFailure: { collector.record($0) })

        writer.append("first\n")
        writer.append("second\n")
        writer.append("third\n")
        writer.flush()

        // The control: the writes really did fail, so the assertions below are about the signal
        // and not about a file that quietly succeeded.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Exactly one — three failing lines must not cost three reports (nor, on a volume that
        // stays full, one per line for the rest of the session).
        #expect(collector.reasons.count == 1)
        #expect(collector.reasons.first?.isEmpty == false)
    }

    @Test func testAHealthyWriterNeverReportsAFailure() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogWriteOK-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let collector = FailureCollector()
        let writer = LogFileWriter(url: url, onWriteFailure: { collector.record($0) })
        writer.append("a line\n")
        writer.flush()

        #expect(try String(contentsOf: url, encoding: .utf8) == "a line\n")
        #expect(collector.reasons.isEmpty)
    }

    /// The trim writes the surviving tail back atomically; that write can fail for exactly the same
    /// reasons an append can, and it is the one that would leave the file oversized forever.
    @Test func testAFailedTailTrimIsReportedThroughTheSameSignal() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogTrimFail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("app.log")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        // An oversized log, then a read-only DIRECTORY: the trim's atomic write (write-temp,
        // rename) needs to create a file in it, so it fails while the file itself stays readable.
        try (0..<500).map { "line \($0)" }.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let collector = FailureCollector()
        let writer = LogFileWriter(url: url, maxFileSize: 1024, onWriteFailure: { collector.record($0) })
        writer.flush()

        // The file is untouched (still oversized) — proof the trim really failed — and the failure
        // left a signal instead of vanishing into a `try?`.
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        #expect((size ?? 0) > 1024)
        #expect(collector.reasons.count == 1)
    }

    /// The product-level half: a `Logger` whose file cannot be written must say so in the entries
    /// the Activity Log renders — once — and must not have tried to write that notice to the same
    /// broken file.
    @MainActor
    @Test func testLoggerRecordsOneInMemoryWarningWhenTheLogFileCannotBeWritten() async throws {
        let url = makeUnwritableURL()
        let logger = Logger(logFileURL: url)

        await logger.info("one").value
        await logger.info("two").value
        logger.flushToDisk()   // the writes (and their failure report) have now happened

        func notices() -> [LogEntry] {
            logger.entries.filter { $0.level == .warning && $0.message.contains("could not be written") }
        }

        // The notice is enqueued from the writer's background queue, so it reaches `entries` on a
        // later main-actor hop than the awaited info lines.
        var waits = 0
        while notices().isEmpty && waits < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waits += 1
        }
        #expect(notices().count == 1)
        #expect(notices().first?.message.contains(url.lastPathComponent) == true)

        // Drain once more, then confirm the count is still one: further failing lines must not add
        // further notices.
        await logger.info("three").value
        logger.flushToDisk()
        await logger.info("four").value
        #expect(notices().count == 1)
        // The info lines themselves still reached memory — the log is degraded, not disabled.
        #expect(logger.entries.contains { $0.message == "four" })
    }
}
