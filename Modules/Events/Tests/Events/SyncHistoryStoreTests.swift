import Testing
import Foundation
@testable import Events

/// Coverage for `SyncHistoryStore`: durable JSON-lines persistence and reload, run scoping,
/// `lastRunId`, the in-memory cap trim, and `clear()` emptying both memory and disk. Every test
/// uses its own temp-file URL so nothing touches the user's real `~/sync-cloud-history.jsonl`.
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
        defer { try? FileManager.default.removeItem(at: url) }

        let runId = UUID()
        let store = SyncHistoryStore(fileURL: url)
        store.append(record(runId: runId, source: "/src/one.txt"))
        store.appendBatch([
            record(runId: runId, action: .move, source: "/src/two.txt"),
            record(runId: runId, action: .delete, source: "/src/three.txt"),
        ])
        #expect(store.records.count == 3)
        store.flushToDisk()

        // A fresh store over the same file reloads every record, in order.
        let reloaded = SyncHistoryStore(fileURL: url)
        #expect(reloaded.records.count == 3)
        #expect(reloaded.records.map(\.sourcePath) == ["/src/one.txt", "/src/two.txt", "/src/three.txt"])
        #expect(reloaded.records.map(\.action) == [.copy, .move, .delete])
        #expect(reloaded.records[0].sizeBytes == 10)
    }

    @Test func testRecordsForRunFiltersByRunId() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let runA = UUID()
        let runB = UUID()
        let store = SyncHistoryStore(fileURL: url)
        store.appendBatch([record(runId: runA, source: "/a1"), record(runId: runA, source: "/a2")])
        store.appendBatch([record(runId: runB, source: "/b1")])

        #expect(store.recordsForRun(runA).map(\.sourcePath) == ["/a1", "/a2"])
        #expect(store.recordsForRun(runB).map(\.sourcePath) == ["/b1"])
        #expect(store.recordsForRun(UUID()).isEmpty)
    }

    @Test func testLastRunIdTracksMostRecentRecord() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SyncHistoryStore(fileURL: url)
        #expect(store.lastRunId == nil)

        let runA = UUID()
        store.appendBatch([record(runId: runA)])
        #expect(store.lastRunId == runA)

        let runB = UUID()
        store.appendBatch([record(runId: runB)])
        #expect(store.lastRunId == runB)
    }

    @Test func testInMemoryCapTrimsOldestRecords() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SyncHistoryStore(fileURL: url)
        // One batch past the 5000 cap: the single oldest record must be dropped, newest kept.
        let batch = (0..<5001).map { i in
            record(runId: UUID(), source: "/src/item-\(i).txt")
        }
        store.appendBatch(batch)

        #expect(store.records.count == 5000)
        // The very first (oldest) record is gone; the last is retained.
        #expect(store.records.first?.sourcePath == "/src/item-1.txt")
        #expect(store.records.last?.sourcePath == "/src/item-5000.txt")
    }

    @Test func testClearEmptiesMemoryAndDisk() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SyncHistoryStore(fileURL: url)
        store.appendBatch([record(runId: UUID()), record(runId: UUID())])
        store.flushToDisk()
        #expect(!store.records.isEmpty)

        store.clear()
        store.flushToDisk()
        #expect(store.records.isEmpty)

        // Disk is empty too: a fresh store reloads nothing.
        let reloaded = SyncHistoryStore(fileURL: url)
        #expect(reloaded.records.isEmpty)
    }

    @Test func testMalformedLinesAreSkippedOnLoad() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // One valid JSON-line record, one garbage line, one blank line.
        let valid = SyncHistoryRecord(runId: UUID(), action: .copy, sourcePath: "/src/ok.txt")
        let validLine = String(data: try JSONEncoder().encode(valid), encoding: .utf8)!
        let contents = validLine + "\n" + "{ not valid json\n" + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)

        let store = SyncHistoryStore(fileURL: url)
        #expect(store.records.count == 1)
        #expect(store.records.first?.sourcePath == "/src/ok.txt")
    }

    // MARK: Un-encodable records

    /// A record whose timestamp is non-finite cannot be JSON-encoded (a `Date` encodes as a
    /// `Double`, and the encoder rejects infinity). It stands in here for any record the codec
    /// refuses — the only way this store loses a line.
    private func unencodableRecord(runId: UUID, source: String) -> SyncHistoryRecord {
        SyncHistoryRecord(
            runId: runId,
            timestamp: Date(timeIntervalSinceReferenceDate: .infinity),
            action: .delete,
            sourcePath: source)
    }

    /// The premise of the two tests below: the record really is un-encodable, so a green result
    /// there can't come from a batch that quietly encoded fine.
    @Test func testTheUnencodableFixtureReallyFailsToEncode() {
        #expect((try? JSONEncoder().encode(unencodableRecord(runId: UUID(), source: "/src/x"))) == nil)
    }

    /// Dropping the record is the documented design (persistence must never fail the file operation
    /// that produced it) — dropping it SILENTLY is not: this file is the durable audit trail of a
    /// real mutation, so a missing line has to be announced somewhere.
    @Test func testADroppedRecordIsReportedOncePerBatchWithItsIdentity() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let reports = ReportSpy()
        let runId = UUID()
        let store = SyncHistoryStore(fileURL: url, reportDroppedRecords: { reports.messages.append($0) })

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

        // Best-effort persistence is preserved: the encodable record still reached disk, and the
        // caller's operation was never failed.
        store.flushToDisk()
        let reloaded = SyncHistoryStore(fileURL: url)
        #expect(reloaded.records.map(\.sourcePath) == ["/src/good.txt"])
    }

    @Test func testNothingIsReportedWhenEveryRecordEncodes() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let reports = ReportSpy()
        let store = SyncHistoryStore(fileURL: url, reportDroppedRecords: { reports.messages.append($0) })
        store.appendBatch([record(runId: UUID()), record(runId: UUID())])

        #expect(reports.messages.isEmpty)
    }
}

/// Captures the drop reports. A reference type so the closure handed to the store writes into the
/// same instance the test reads; main-actor-isolated because that is where the store calls it.
@MainActor
private final class ReportSpy {
    var messages: [String] = []
}
