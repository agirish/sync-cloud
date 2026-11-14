import Testing
import Foundation
@testable import Events

/// `SyncHistoryStore`: JSON-lines persistence and reload, run scoping, `lastRunId`, the in-memory
/// cap, `clear()` emptying memory and disk, and announcing dropped records. Every test uses its own
/// temp file, never the real `~/sync-cloud-history.jsonl`.
@MainActor
@Suite struct SyncHistoryStoreTests {

    private func makeTempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncHistoryStoreTest-\(UUID().uuidString).jsonl")
    }

    private func record(runId: UUID, action: SyncAction = .copy, source: String = "/src/a.txt") -> SyncHistoryRecord {
        SyncHistoryRecord(runId: runId, action: action, sourcePath: source, destPath: "/dst/a.txt", sizeBytes: 10)
    }

    @Test func testAppendPersistsAndReloadsFromDisk() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let runId = UUID()
        let store = SyncHistoryStore(fileURL: url)
        defer { store.flushToDisk() }
        store.append(record(runId: runId, source: "/src/one.txt"))
        store.appendBatch([
            record(runId: runId, action: .move, source: "/src/two.txt"),
            record(runId: runId, action: .delete, source: "/src/three.txt"),
        ])
        #expect(store.records.count == 3)
        store.flushToDisk()

        // A fresh store over the same file reloads every record, in order.
        let reloaded = SyncHistoryStore(fileURL: url)
        defer { reloaded.flushToDisk() }
        #expect(reloaded.records.count == 3)
        #expect(reloaded.records.map(\.sourcePath) == ["/src/one.txt", "/src/two.txt", "/src/three.txt"])
        #expect(reloaded.records.map(\.action) == [.copy, .move, .delete])
        #expect(reloaded.records[0].sizeBytes == 10)
    }

    @Test func testRecordsForRunFiltersByRunId() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let runA = UUID()
        let runB = UUID()
        let store = SyncHistoryStore(fileURL: url)
        defer { store.flushToDisk() }
        store.appendBatch([record(runId: runA, source: "/a1"), record(runId: runA, source: "/a2")])
        store.appendBatch([record(runId: runB, source: "/b1")])

        #expect(store.recordsForRun(runA).map(\.sourcePath) == ["/a1", "/a2"])
        #expect(store.recordsForRun(runB).map(\.sourcePath) == ["/b1"])
        #expect(store.recordsForRun(UUID()).isEmpty)
    }

    @Test func testLastRunIdTracksMostRecentRecord() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let store = SyncHistoryStore(fileURL: url)
        defer { store.flushToDisk() }
        #expect(store.lastRunId == nil)

        let runA = UUID()
        store.appendBatch([record(runId: runA)])
        #expect(store.lastRunId == runA)

        let runB = UUID()
        store.appendBatch([record(runId: runB)])
        #expect(store.lastRunId == runB)
    }

    /// A run the cap cuts is named, so Activity's Events says its count is only what is kept; a run
    /// it leaves whole is not, and a clear forgets them.
    @Test func theCapNamesTheRunsItCut() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }
        let store = SyncHistoryStore(fileURL: url)
        defer { store.flushToDisk() }
        let cut = UUID()
        let whole = UUID()
        store.appendBatch((0..<4_999).map { record(runId: cut, source: "/src/a-\($0).txt") })
        store.appendBatch((0..<2).map { record(runId: whole, source: "/src/b-\($0).txt") })
        #expect(store.records.count == 5000)
        #expect(store.records.first?.sourcePath == "/src/a-1.txt")
        #expect(store.records.last?.sourcePath == "/src/b-1.txt")
        #expect(store.trimmedRunIds == [cut])
        store.clear()
        #expect(store.trimmedRunIds.isEmpty)
    }

    @Test func testClearEmptiesMemoryAndDisk() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let store = SyncHistoryStore(fileURL: url)
        defer { store.flushToDisk() }
        store.appendBatch([record(runId: UUID()), record(runId: UUID())])
        store.flushToDisk()
        #expect(!store.records.isEmpty)

        store.clear()
        store.flushToDisk()
        #expect(store.records.isEmpty)

        // Disk is empty too: a fresh store reloads nothing.
        let reloaded = SyncHistoryStore(fileURL: url)
        defer { reloaded.flushToDisk() }
        #expect(reloaded.records.isEmpty)
    }

    /// The guard between a test run and the real history file: suites record into `.shared` and
    /// `clear()` truncates, so a missed runner detection would destroy `~/sync-cloud-history.jsonl`.
    /// `testDefaultLogFileURLAvoidsRealLogUnderTests` is the log's twin.
    @Test func testDefaultFileURLAvoidsRealHistoryUnderTests() {
        let url = SyncHistoryStore.defaultFileURL()
        let realHistory = URL(fileURLWithPath: (NSString(string: "~")).expandingTildeInPath)
            .appendingPathComponent("sync-cloud-history.jsonl")
        #expect(url.path != realHistory.path)
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test func testMalformedLinesAreSkippedOnLoad() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        // One valid JSON-line record, one garbage line, one blank line.
        let valid = SyncHistoryRecord(runId: UUID(), action: .copy, sourcePath: "/src/ok.txt")
        let validLine = String(data: try JSONEncoder().encode(valid), encoding: .utf8)!
        let contents = validLine + "\n" + "{ not valid json\n" + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)

        let store = SyncHistoryStore(fileURL: url)
        defer { store.flushToDisk() }
        #expect(store.records.count == 1)
        #expect(store.records.first?.sourcePath == "/src/ok.txt")
    }

    // MARK: Un-encodable records

    /// A record with a non-finite timestamp can't be JSON-encoded (a `Date` encodes as a `Double`,
    /// and the encoder rejects infinity). It stands in for any record the codec refuses, the only
    /// way this store loses a line.
    private func unencodableRecord(runId: UUID, source: String) -> SyncHistoryRecord {
        SyncHistoryRecord(
            runId: runId,
            timestamp: Date(timeIntervalSinceReferenceDate: .infinity),
            action: .delete,
            sourcePath: source)
    }

    /// A record that can't be encoded is dropped, since persistence must never fail the file
    /// operation, but never silently: this file is the audit trail of real changes, so a missing
    /// line is announced.
    @Test func testADroppedRecordIsReportedOncePerBatchWithItsIdentity() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let reports = ReportSpy()
        let runId = UUID()
        let store = SyncHistoryStore(fileURL: url, reportDroppedRecords: { reports.messages.append($0) })
        defer { store.flushToDisk() }

        store.appendBatch([
            record(runId: runId, source: "/src/good.txt"),
            unencodableRecord(runId: runId, source: "/src/lost.txt"),
            unencodableRecord(runId: runId, source: "/src/lost-too.txt"),
        ])

        // One report for the batch (a bulk run must not emit a line per file), naming how many
        // were lost and enough of the first to find it.
        #expect(reports.messages.count == 1)
        let message = reports.messages.first ?? ""
        #expect(message.contains("2"))
        #expect(message.contains("/src/lost.txt"))
        #expect(message.contains(url.lastPathComponent))

        // Still best-effort: the encodable record reached disk, and the caller never failed.
        store.flushToDisk()
        let reloaded = SyncHistoryStore(fileURL: url)
        defer { reloaded.flushToDisk() }
        #expect(reloaded.records.map(\.sourcePath) == ["/src/good.txt"])
    }

    /// "Once per batch" means once per call: three `append(_:)` calls report three times, one
    /// `appendBatch` of three reports once. Coalescing across calls would hold a report on a timer,
    /// and recording must never delay anything.
    @Test func testTheDropReportIsPerCallSoPerRecordCallersGetAReportPerRecord() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let runId = UUID()
        let perRecordReports = ReportSpy()
        let perRecord = SyncHistoryStore(fileURL: url, reportDroppedRecords: { perRecordReports.messages.append($0) })
        defer { perRecord.flushToDisk() }
        for i in 0..<3 {
            perRecord.append(unencodableRecord(runId: runId, source: "/src/lost\(i).txt"))
        }
        #expect(perRecordReports.messages.count == 3)

        let batchUrl = makeTempURL()
        defer { removeLogFiles(at: batchUrl) }
        let batchReports = ReportSpy()
        let batched = SyncHistoryStore(fileURL: batchUrl, reportDroppedRecords: { batchReports.messages.append($0) })
        defer { batched.flushToDisk() }
        batched.appendBatch((0..<3).map { unencodableRecord(runId: runId, source: "/src/lost\($0).txt") })
        #expect(batchReports.messages.count == 1)
    }

    @Test func testNothingIsReportedWhenEveryRecordEncodes() throws {
        let url = makeTempURL()
        defer { removeLogFiles(at: url) }

        let reports = ReportSpy()
        let store = SyncHistoryStore(fileURL: url, reportDroppedRecords: { reports.messages.append($0) })
        defer { store.flushToDisk() }
        store.appendBatch([record(runId: UUID()), record(runId: UUID())])

        #expect(reports.messages.isEmpty)
    }

    /// A History file that can't be written says so once, at ERROR, or the store looks complete
    /// while the file stops growing.
    @Test func aHistoryFileThatCantBeWrittenSaysSoOnce() throws {
        // A path under a regular file: no directory there, so nothing can be created or written.
        let blocker = makeTempURL()
        try Data("not a folder".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let url = blocker.appendingPathComponent("history.jsonl")
        // A spy, not the shared log: this package's other suites count `Logger.shared`'s entries.
        let failures = FailureSpy()
        let store = SyncHistoryStore(fileURL: url, reportWriteFailure: { failures.append($0) })
        store.append(record(runId: UUID()))
        store.append(record(runId: UUID()))
        store.flushToDisk()
        let lines = failures.lines
        #expect(lines.count == 1, "\(lines) — one line per failure run, not per record")
        #expect(lines.first?.hasPrefix("Sync History: couldn’t write history.jsonl") == true, "\(lines)")
    }
}

/// Captures the drop reports. A reference type so the closure handed to the store writes into the
/// same instance the test reads; main-actor-isolated because that is where the store calls it.
@MainActor
private final class ReportSpy {
    var messages: [String] = []
}

/// Collects write-failure reports, which arrive on the writer's background queue.
final class FailureSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    func append(_ line: String) { lock.lock(); collected.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return collected }
}
