import Testing
import Foundation
@testable import Events

/// `LogFileWriter`, the persistent-handle disk writer behind `Logger`: healing after the file is
/// removed or replaced under the open handle, the fallback append, size trims, and `clear()`. Each
/// test writes its own temp file, never `~/sync-cloud.log`.
@Suite struct LogFileWriterTests {

    /// Makes a unique temp path (the file itself is created by `LogFileWriter.init`).
    private func makeTempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogFileWriterTest-\(UUID().uuidString).log")
    }

    @Test func testLogFileRecreatedAfterExternalDeletion() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let writer = LogFileWriter(url: url)
        defer { writer.flush() }

        writer.append("first line\n")
        writer.flush()
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Delete the file under the writer: the open handle now points at an orphaned inode, so
        // a naive write would be lost.
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

    @Test func testAppendsLandInCurrentFileAfterExternalAtomicReplacement() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let writer = LogFileWriter(url: url)
        defer { writer.flush() }
        writer.append("first line\n")
        writer.flush()

        // An atomic rewrite keeps the path but swaps the inode, as the other process's trim of
        // the shared log does. A fileExists check can't see it, so the handle would keep writing
        // into the orphaned inode.
        try Data("externally trimmed\n".utf8).write(to: url, options: .atomic)

        writer.append("second line\n")
        writer.flush()

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("externally trimmed"))
        #expect(contents.contains("second line"))
    }

    @Test func testFallbackAppendPreservesExistingLogHistory() throws {
        let url = makeTempURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            removeLogFiles(at: url)
        }

        try "history line\n".write(to: url, atomically: true, encoding: .utf8)
        // Make the file unwritable so the writer can't open its handle and must use the fallback,
        // whose atomic replace needs only directory permission.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        let writer = LogFileWriter(url: url)
        defer { writer.flush() }
        writer.append("new line\n")
        writer.flush()

        // The fallback must append, not replace the whole history with the one new line.
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.hasPrefix("history line"))
        #expect(contents.contains("new line"))
    }

    /// An oversized existing log is tail-trimmed at init: the newest lines survive, the result
    /// starts at a line boundary, and the writer keeps appending normally afterwards.
    @Test func testInitTailTrimsOversizedLogKeepingNewestLines() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let history = (0..<500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try history.write(to: url, atomically: true, encoding: .utf8)

        let writer = LogFileWriter(url: url, maxFileSize: 1024)
        defer { writer.flush() }
        writer.flush()

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.utf8.count <= 512)
        #expect(contents.hasSuffix("line 499\n"))          // newest end intact
        #expect(!contents.contains("line 0\n"))            // oldest lines gone
        #expect(contents.hasPrefix("line "))               // starts at a line boundary

        writer.append("after trim\n")
        writer.flush()
        #expect(try String(contentsOf: url, encoding: .utf8).hasSuffix("after trim\n"))
    }

    /// A file under the cap is left byte-for-byte untouched at init.
    @Test func testInitLeavesLogUnderCapUntouched() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let history = "keep me\nand me\n"
        try history.write(to: url, atomically: true, encoding: .utf8)

        let writer = LogFileWriter(url: url, maxFileSize: 1024)
        defer { writer.flush() }
        writer.flush()

        #expect(try String(contentsOf: url, encoding: .utf8) == history)
    }

    /// The size cap holds during a session, not just at the next launch: a long run of appends
    /// re-trims periodically, so the file stays near the cap.
    @Test func testMidSessionAppendsKeepFileBounded() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let maxFileSize = 1024
        let writer = LogFileWriter(url: url, maxFileSize: maxFileSize)
        defer { writer.flush() }

        // Write far more than the cap in one session (~20 KB against a 1 KB cap).
        var lastLine = ""
        for i in 0..<500 {
            lastLine = "session line \(i)\n"
            writer.append(lastLine)
        }
        writer.flush()

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? .max
        // Between checks the file can drift past the cap by up to one check interval
        // (maxFileSize / 2) plus a line, but never anywhere near the ~20 KB written.
        #expect(size <= maxFileSize + maxFileSize / 2 + 64)

        // Trimming swaps the inode; appends after a trim must still land in the live file.
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.hasSuffix(lastLine))
        #expect(contents.hasPrefix("session line ")) // still starts at a line boundary
    }

    /// A leftover lock file (say, from a crashed process) must not block trims: a flock dies with
    /// its holder's descriptor, so a stale file alone carries no lock.
    @Test func testStaleTrimLockFileDoesNotBlockTrimming() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        try Data().write(to: URL(fileURLWithPath: url.path + ".lock"))  // stale sidecar
        let history = (0..<500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try history.write(to: url, atomically: true, encoding: .utf8)

        let writer = LogFileWriter(url: url, maxFileSize: 1024)
        defer { writer.flush() }
        writer.flush()

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.utf8.count <= 512)
        #expect(contents.hasSuffix("line 499\n"))
    }

    /// Two writers on one log, standing in for the app and the CLI (flock contends across
    /// descriptors in one process the same way), finish their guarded trims without deadlock and
    /// leave a bounded file.
    @Test func testConcurrentWritersTrimWithoutDeadlock() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let maxFileSize = 1024
        let a = LogFileWriter(url: url, maxFileSize: maxFileSize)
        defer { a.flush() }
        let b = LogFileWriter(url: url, maxFileSize: maxFileSize)
        defer { b.flush() }
        for i in 0..<300 {
            a.append("writer-a line \(i)\n")
            b.append("writer-b line \(i)\n")
        }
        a.flush()
        b.flush()

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? .max
        // Bounded near the cap (same slack as the single-writer bound, doubled for two
        // writers' independent check intervals), nowhere near the ~12 KB written.
        #expect(size <= 2 * (maxFileSize + maxFileSize / 2) + 64)
    }

    @Test func testClearTruncatesFile() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let writer = LogFileWriter(url: url)
        defer { writer.flush() }

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

    /// Pins an accepted side effect: `clear()` runs `reopenHandleIfStale()` first (see the test
    /// below), which recreates a missing file, so clearing a deleted log leaves an empty file.
    /// Harmless; see `LogFileWriter.clear()`. `SyncHistoryStore.clear()` shares it.
    @Test func testClearRecreatesADeletedLogAsAnEmptyFile() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let writer = LogFileWriter(url: url)
        defer { writer.flush() }
        writer.append("first line\n")
        writer.flush()

        try FileManager.default.removeItem(at: url)
        writer.clear()
        writer.flush()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: url, encoding: .utf8).isEmpty)

        // The point of reopening: later lines land in the live file, not the orphaned inode.
        writer.append("after clear\n")
        writer.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == "after clear\n")
    }

    /// The `clear()` counterpart of `testAppendsLandInCurrentFileAfterExternalAtomicReplacement`.
    /// After the CLI's atomic trim swaps the inode, a clear must empty the file on disk, not the
    /// orphaned inode, or Clear Log looks like a no-op. Fails if `clear()` skips the staleness check.
    @Test func testClearEmptiesTheCurrentFileAfterExternalAtomicReplacement() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let writer = LogFileWriter(url: url)
        defer { writer.flush() }
        writer.append("first line\n")
        writer.flush()

        try Data("externally trimmed\n".utf8).write(to: url, options: .atomic)

        writer.clear()
        writer.flush()

        // The file on disk is what Settings stats and the next reader sees.
        #expect(try String(contentsOf: url, encoding: .utf8).isEmpty)

        // And the reopened handle is the live one: later appends land in the same file.
        writer.append("after clear\n")
        writer.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == "after clear\n")
    }
}
