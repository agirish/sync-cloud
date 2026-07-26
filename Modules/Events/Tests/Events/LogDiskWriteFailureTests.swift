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

    // MARK: The latch re-arms

    /// A directory that a test creates and removes to switch the writer's disk on and off. Removing
    /// the directory orphans the open handle AND denies the fallback's atomic write, so every write
    /// path fails; recreating it lets the writer self-heal on its next append.
    private func makeSwitchableLogURL() -> (directory: URL, log: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogRearm-\(UUID().uuidString)")
        return (directory, directory.appendingPathComponent("app.log"))
    }

    @Test func testTheFailureReportRearmsOnceWritingRecovers() throws {
        let (directory, url) = makeSwitchableLogURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let failures = FailureCollector()
        let recoveries = FailureCollector()
        let writer = LogFileWriter(url: url,
                                   onWriteFailure: { failures.record($0) },
                                   onWriteRecovered: { recoveries.record("recovered") })

        // Broken: no directory, so neither the handle nor the fallback can write.
        writer.append("lost\n")
        writer.flush()
        #expect(failures.reasons.count == 1)
        #expect(recoveries.reasons.isEmpty)

        // Healed.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writer.append("kept\n")
        writer.flush()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("kept"))
        #expect(recoveries.reasons.count == 1)

        // Broken again. THE regression: under a never-resetting one-shot this second failure was
        // silent — and the first notice is in memory only, so by then the 1000-entry cap or a Clear
        // Logs may well have taken it, leaving nothing anywhere saying the log stopped growing.
        try FileManager.default.removeItem(at: directory)
        writer.append("lost again\n")
        writer.flush()
        #expect(failures.reasons.count == 2)

        // Still rate-limited WITHIN a failure run: the whole point of the latch survives.
        writer.append("lost too\n")
        writer.append("and again\n")
        writer.flush()
        #expect(failures.reasons.count == 2)
        #expect(recoveries.reasons.count == 1)
    }

    @Test func testClearRearmsTheFailureReportWithoutClaimingARecovery() throws {
        let (directory, url) = makeSwitchableLogURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let failures = FailureCollector()
        let recoveries = FailureCollector()
        let writer = LogFileWriter(url: url,
                                   onWriteFailure: { failures.record($0) },
                                   onWriteRecovered: { recoveries.record("recovered") })
        writer.append("healthy\n")
        writer.flush()

        // Break it, take the one report, then heal it and CLEAR — the app's Clear Logs, which
        // deletes the in-memory notice along with everything else in the window.
        try FileManager.default.removeItem(at: directory)
        writer.append("lost\n")
        writer.flush()
        #expect(failures.reasons.count == 1)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writer.clear()
        writer.flush()
        // A successful truncate is not evidence the lines will land, and the notice a recovery
        // would pair with has just been deleted — so the clear re-arms silently.
        #expect(recoveries.reasons.isEmpty)

        // Break it again: the report the clear re-armed must fire, or the window can never say
        // again that the log it is showing is no longer being written.
        try FileManager.default.removeItem(at: directory)
        writer.append("lost after clear\n")
        writer.flush()
        #expect(failures.reasons.count == 2)
    }

    @Test func testAFailedClearIsReportedThroughTheSameSignal() {
        // `clear()`'s fallback was the one write in the writer still swallowed by a bare `try?` —
        // on the path taken precisely when the handle cannot be opened, i.e. when something is
        // already wrong with the file. A Clear Logs that silently didn't clear leaves the user's
        // history on disk while the window says it is gone.
        let url = makeUnwritableURL()
        let failures = FailureCollector()
        let writer = LogFileWriter(url: url, onWriteFailure: { failures.record($0) })

        writer.clear()
        writer.flush()

        #expect(!FileManager.default.fileExists(atPath: url.path))   // the clear really did fail
        #expect(failures.reasons.count == 1)
        #expect(failures.reasons.first?.isEmpty == false)
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

    /// The product-level half of the re-arm: a log that breaks, recovers and breaks again must say
    /// so all three times, because the notices live in memory ONLY and the first one may well be
    /// gone by then — evicted by the 1000-entry cap, or deleted by Clear Logs.
    @MainActor
    @Test func testTheLoggerNoticesTheLogBreakingAgainAfterItRecovers() async throws {
        let (directory, url) = makeSwitchableLogURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = Logger(logFileURL: url)

        func notices() -> [LogEntry] {
            logger.entries.filter { $0.level == .warning && $0.message.contains("could not be written") }
        }
        func recoveries() -> [LogEntry] {
            logger.entries.filter { $0.level == .info && $0.message.contains("is being written again") }
        }
        /// The notices arrive from the writer's background queue, a main-actor hop behind the
        /// awaited log lines, so every assertion waits for its expected count rather than reading
        /// once and racing.
        func wait(for condition: @MainActor () -> Bool) async throws -> Bool {
            var waits = 0
            while !condition() && waits < 200 {
                try await Task.sleep(nanoseconds: 10_000_000)
                waits += 1
            }
            return condition()
        }

        await logger.info("while broken").value
        logger.flushToDisk()
        #expect(try await wait { notices().count == 1 })

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await logger.info("after the volume came back").value
        logger.flushToDisk()
        #expect(try await wait { recoveries().count == 1 })

        try FileManager.default.removeItem(at: directory)
        await logger.info("broken again").value
        logger.flushToDisk()
        #expect(try await wait { notices().count == 2 })

        // And the rate limit still holds inside the second run.
        await logger.info("still broken").value
        logger.flushToDisk()
        await logger.info("and still").value
        #expect(notices().count == 2)
        #expect(recoveries().count == 1)
    }
}
