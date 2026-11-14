import Testing
import Foundation
@testable import Events

/// The signal when the disk log stops accepting writes: on a full or unmounted volume the
/// Activity Log keeps scrolling from memory while `~/sync-cloud.log` stops growing. Logging it the
/// ordinary way would hand it back to the failed writer, so the writer reports once per failure
/// run and `Logger` turns that into an in-memory warning entry.
@Suite struct LogDiskWriteFailureTests {

    /// A path in a directory that doesn't exist, so both write paths fail: no handle can open, and
    /// the fallback's atomic write has no directory. An unwritable file isn't enough, since an
    /// atomic replace needs only directory permission.
    private func makeUnwritableURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-dir-\(UUID().uuidString)")
            .appendingPathComponent("app.log")
    }

    @Test func testAFailedDiskWriteIsReportedOnceNotPerLine() {
        let url = makeUnwritableURL()
        let collector = FailureSpy()
        let writer = LogFileWriter(url: url, onWriteFailure: { collector.append($0) })

        writer.append("first\n")
        writer.append("second\n")
        writer.append("third\n")
        writer.flush()

        // The control: the writes really did fail, so the assertions below test the signal.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Exactly one: three failing lines must not cost three reports.
        #expect(collector.lines.count == 1)
        #expect(collector.lines.first?.isEmpty == false)
    }

    @Test func testAHealthyWriterNeverReportsAFailure() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogWriteOK-\(UUID().uuidString).log")
        defer { removeLogFiles(at: url) }

        let collector = FailureSpy()
        let writer = LogFileWriter(url: url, onWriteFailure: { collector.append($0) })
        defer { writer.flush() }
        writer.append("a line\n")
        writer.flush()

        #expect(try String(contentsOf: url, encoding: .utf8) == "a line\n")
        #expect(collector.lines.isEmpty)
    }

    /// The trim's atomic write of the surviving tail can fail for the same reasons an append can,
    /// and would leave the file oversized for good.
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

        let collector = FailureSpy()
        let writer = LogFileWriter(url: url, maxFileSize: 1024, onWriteFailure: { collector.append($0) })
        defer { writer.flush() }
        writer.flush()

        // Still oversized, proof the trim really failed, and the failure was reported.
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        #expect((size ?? 0) > 1024)
        #expect(collector.lines.count == 1)
    }

    // MARK: The latch re-arms

    /// A directory a test creates and removes to switch the writer's disk on and off. Removing it
    /// orphans the open handle and denies the fallback's atomic write, so every write fails;
    /// recreating it lets the writer heal on its next append.
    private func makeSwitchableLogURL() -> (directory: URL, log: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogRearm-\(UUID().uuidString)")
        return (directory, directory.appendingPathComponent("app.log"))
    }

    @Test func testTheFailureReportRearmsOnceWritingRecovers() throws {
        let (directory, url) = makeSwitchableLogURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let failures = FailureSpy()
        let recoveries = FailureSpy()
        let writer = LogFileWriter(url: url,
                                   onWriteFailure: { failures.append($0) },
                                   onWriteRecovered: { recoveries.append("recovered") })
        defer { writer.flush() }

        // Broken: no directory, so neither the handle nor the fallback can write.
        writer.append("lost\n")
        writer.flush()
        #expect(failures.lines.count == 1)
        #expect(recoveries.lines.isEmpty)

        // Healed.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writer.append("kept\n")
        writer.flush()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("kept"))
        #expect(recoveries.lines.count == 1)

        // Broken again: this second failure must be reported too, since the first notice lives in
        // memory only and may be gone by now. Fails if the latch never re-arms.
        try FileManager.default.removeItem(at: directory)
        writer.append("lost again\n")
        writer.flush()
        #expect(failures.lines.count == 2)

        // Still rate-limited within a failure run.
        writer.append("lost too\n")
        writer.append("and again\n")
        writer.flush()
        #expect(failures.lines.count == 2)
        #expect(recoveries.lines.count == 1)
    }

    @Test func testClearRearmsTheFailureReportWithoutClaimingARecovery() throws {
        let (directory, url) = makeSwitchableLogURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let failures = FailureSpy()
        let recoveries = FailureSpy()
        let writer = LogFileWriter(url: url,
                                   onWriteFailure: { failures.append($0) },
                                   onWriteRecovered: { recoveries.append("recovered") })
        defer { writer.flush() }
        writer.append("healthy\n")
        writer.flush()

        // Break it, take the one report, then heal it and clear, which in the app also deletes
        // the in-memory notice.
        try FileManager.default.removeItem(at: directory)
        writer.append("lost\n")
        writer.flush()
        #expect(failures.lines.count == 1)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writer.clear()
        writer.flush()
        // A successful truncate doesn't prove lines will land, and the notice a recovery would
        // pair with is gone, so the clear re-arms silently.
        #expect(recoveries.lines.isEmpty)

        // Break it again: the re-armed report must fire, or the window could never again say the
        // log isn't being written.
        try FileManager.default.removeItem(at: directory)
        writer.append("lost after clear\n")
        writer.flush()
        #expect(failures.lines.count == 2)
    }

    @Test func testAFailedClearIsReportedThroughTheSameSignal() {
        // `clear()`'s fallback runs when the handle can't be opened, so something is already
        // wrong with the file. A clear that silently fails leaves the history on disk while the
        // window says it is gone. Fails if the fallback's error is swallowed.
        let url = makeUnwritableURL()
        let failures = FailureSpy()
        let writer = LogFileWriter(url: url, onWriteFailure: { failures.append($0) })

        writer.clear()
        writer.flush()

        #expect(!FileManager.default.fileExists(atPath: url.path))   // the clear really did fail
        #expect(failures.lines.count == 1)
        #expect(failures.lines.first?.isEmpty == false)
    }

    /// The product-level half: a `Logger` whose file can't be written says so once in the entries
    /// the Activity Log renders.
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
        #expect(await LayoutPumpWait.poll(upTo: 2) { notices().count == 1 }.held)
        #expect(notices().first?.message.contains(url.lastPathComponent) == true)

        // Drain once more, then confirm the count is still one: further failing lines must not add
        // further notices.
        await logger.info("three").value
        logger.flushToDisk()
        await logger.info("four").value
        #expect(notices().count == 1)
        // The info lines still reached memory: the log is degraded, not disabled.
        #expect(logger.entries.contains { $0.message == "four" })
    }

    /// The product-level half of the re-arm: a log that breaks, recovers and breaks again says so
    /// all three times, since the notices live in memory only and the first may be evicted or
    /// cleared by then.
    @MainActor
    @Test func testTheLoggerNoticesTheLogBreakingAgainAfterItRecovers() async throws {
        let (directory, url) = makeSwitchableLogURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = Logger(logFileURL: url)
        defer { logger.flushToDisk() }

        func notices() -> [LogEntry] {
            logger.entries.filter { $0.level == .warning && $0.message.contains("could not be written") }
        }
        func recoveries() -> [LogEntry] {
            logger.entries.filter { $0.level == .info && $0.message.contains("is being written again") }
        }
        // The notices arrive a main-actor hop behind the awaited lines, so each count is polled.
        await logger.info("while broken").value
        logger.flushToDisk()
        #expect(await LayoutPumpWait.poll(upTo: 2) { notices().count == 1 }.held)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await logger.info("after the volume came back").value
        logger.flushToDisk()
        #expect(await LayoutPumpWait.poll(upTo: 2) { recoveries().count == 1 }.held)

        try FileManager.default.removeItem(at: directory)
        await logger.info("broken again").value
        logger.flushToDisk()
        #expect(await LayoutPumpWait.poll(upTo: 2) { notices().count == 2 }.held)

        // And the rate limit still holds inside the second run.
        await logger.info("still broken").value
        logger.flushToDisk()
        await logger.info("and still").value
        #expect(notices().count == 2)
        #expect(recoveries().count == 1)
    }
}
