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

    /// Removes the log and its trim-lock sidecar.
    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + ".lock")
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

    @Test func testAppendsLandInCurrentFileAfterExternalAtomicReplacement() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = LogFileWriter(url: url)
        writer.append("first line\n")
        writer.flush()

        // Atomic rewrite = write-temp-then-rename: the path stays present the whole time but
        // points at a NEW inode, exactly what another process's tail-trim does to a shared log
        // (the app and CLI both trim ~/sync-cloud.log). A fileExists-only check cannot see this,
        // so the open handle would keep writing into the orphaned old inode.
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
            try? FileManager.default.removeItem(at: url)
        }

        try "history line\n".write(to: url, atomically: true, encoding: .utf8)
        // Make the file unwritable so `FileHandle(forWritingTo:)` fails and the writer must use
        // its fallback (an atomic replace only needs directory write permission, so it succeeds).
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        let writer = LogFileWriter(url: url)
        writer.append("new line\n")
        writer.flush()

        // The fallback must append, not clobber: one transient handle failure previously replaced
        // the entire log history with the single new line.
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.hasPrefix("history line"))
        #expect(contents.contains("new line"))
    }

    /// An oversized existing log is tail-trimmed at init: the newest lines survive, the result
    /// starts at a line boundary, and the writer keeps appending normally afterwards.
    @Test func testInitTailTrimsOversizedLogKeepingNewestLines() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let history = (0..<500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try history.write(to: url, atomically: true, encoding: .utf8)

        let writer = LogFileWriter(url: url, maxFileSize: 1024)
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
        defer { try? FileManager.default.removeItem(at: url) }

        let history = "keep me\nand me\n"
        try history.write(to: url, atomically: true, encoding: .utf8)

        let writer = LogFileWriter(url: url, maxFileSize: 1024)
        writer.flush()

        #expect(try String(contentsOf: url, encoding: .utf8) == history)
    }

    /// The size cap must hold DURING a session, not just at the next launch: a long run of
    /// appends (repeated scans) periodically re-trims, so the file stays bounded near the cap
    /// instead of growing without limit until restart.
    @Test func testMidSessionAppendsKeepFileBounded() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let maxFileSize = 1024
        let writer = LogFileWriter(url: url, maxFileSize: maxFileSize)

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

    /// A leftover sidecar lock file (e.g. from a crashed process) must not block trims: flock
    /// state dies with the holder's descriptor, so a stale FILE alone carries no lock, and the
    /// trim proceeds normally through the guarded path.
    @Test func testStaleTrimLockFileDoesNotBlockTrimming() throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        try Data().write(to: URL(fileURLWithPath: url.path + ".lock"))  // stale sidecar
        let history = (0..<500).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try history.write(to: url, atomically: true, encoding: .utf8)

        let writer = LogFileWriter(url: url, maxFileSize: 1024)
        writer.flush()

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.utf8.count <= 512)
        #expect(contents.hasSuffix("line 499\n"))
    }

    /// Concurrent writers on the same log (the app + CLI scenario, here two in-process writers
    /// with separate descriptors — flock contends across file descriptions the same way) must
    /// both finish their guarded trims without deadlock and leave a bounded, line-aligned file.
    @Test func testConcurrentWritersTrimWithoutDeadlock() throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let maxFileSize = 1024
        let a = LogFileWriter(url: url, maxFileSize: maxFileSize)
        let b = LogFileWriter(url: url, maxFileSize: maxFileSize)
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

    /// The `clear()` counterpart of `testAppendsLandInCurrentFileAfterExternalAtomicReplacement`.
    ///
    /// `clear()` used to truncate through the open handle with no staleness check, unlike
    /// `append()`. After the CLI atomically rewrites the shared `~/sync-cloud.log` (tail-trim =
    /// write-temp-then-rename, so the path stays put and the inode changes), that truncate emptied
    /// an orphaned inode nothing points at: "Clear Log" looked like a no-op and the Settings size
    /// readout kept reporting a full file the user had just cleared.
    @Test func testClearEmptiesTheCurrentFileAfterExternalAtomicReplacement() throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let writer = LogFileWriter(url: url)
        writer.append("first line\n")
        writer.flush()

        try Data("externally trimmed\n".utf8).write(to: url, options: .atomic)

        writer.clear()
        writer.flush()

        // What matters is the file actually on disk — that is what the Settings readout stats and
        // what the next reader of the log sees.
        #expect(try String(contentsOf: url, encoding: .utf8).isEmpty)

        // And the reopened handle must still be the live one: appends after the clear land in the
        // same file rather than resurrecting the orphan.
        writer.append("after clear\n")
        writer.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == "after clear\n")
    }
}
