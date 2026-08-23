import Foundation
import SwiftUI

/// A durable, observable store of `SyncHistoryRecord`s — the persistent counterpart to
/// `Logger`'s in-memory Activity Log. Records are appended as JSON-lines to a file next to the
/// log (`~/sync-cloud-history.jsonl`): one self-contained JSON object per line, so a partial
/// write at crash time costs at most the last line, never the whole history. The on-disk file
/// reuses `LogFileWriter` (the same serial-queue, single-handle, tail-trim-at-5 MB machinery the
/// log uses), and the in-memory mirror is capped so a long session stays bounded.
///
/// The store is `@MainActor` because its `@Published records` drives the Sync History window.
/// Writes never block or fail an operation: `append`/`appendBatch` mutate the array and hand the
/// disk write to a background queue that swallows its own errors — recording is a best-effort
/// side effect, never a gate on the file operation that produced it. Best-effort is not the same
/// as silent, though: a record the codec refuses is dropped from the file *and* announced through
/// `reportDroppedRecords`, because this file is the audit trail of a real file mutation.
@MainActor
public final class SyncHistoryStore: ObservableObject {
    /// The shared instance the Sync layer records into by default. Tests inject their own store
    /// against a temp-file URL instead of touching this one.
    public static let shared = SyncHistoryStore()

    /// The records observed by the UI, oldest-first (append order). Capped at
    /// `maxInMemoryRecords`; the disk file is trimmed independently by `LogFileWriter`.
    @Published public private(set) var records: [SyncHistoryRecord] = []

    /// The on-disk destination. Public so the UI can reveal it in Finder, mirroring the log file.
    public let fileURL: URL

    /// The most in-memory records kept at once. ~5000 rows is far more than a session produces
    /// while staying cheap to filter and render; older rows still live in the file until trimmed.
    private static let maxInMemoryRecords = 5000

    private let writer: LogFileWriter

    /// Where a dropped record is announced. Best-effort persistence is the design (a failed encode
    /// must never fail the file operation that produced it), but a *silent* drop is not: this file
    /// is the durable audit trail of a real file mutation, so a record that never reaches disk has
    /// to leave a breadcrumb somewhere. It goes to the Activity Log, which is a different file and
    /// a different writer — no loop back into this store.
    ///
    /// Injected (defaulting to the shared logger) rather than called directly so the drop path is
    /// testable without reading `Logger.shared`'s asynchronous in-memory buffer, following
    /// `FolderJump.siblings`' `logError`.
    private let reportDroppedRecords: @MainActor (String) -> Void

    /// One shared codec so persisted lines and in-memory records agree byte-for-byte. The
    /// default `Date` strategy (a numeric interval) is compact and round-trips exactly; the
    /// human-readable ISO-8601 form is reserved for the export path, not this internal store.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Production uses the shared file; tests inject an isolated temp URL. `LogFileWriter`'s
    /// 5 MB cap can be overridden for the size-cap test.
    public init(
        fileURL: URL = SyncHistoryStore.defaultFileURL(),
        maxFileSize: Int = 5 * 1024 * 1024,
        reportDroppedRecords: @escaping @MainActor (String) -> Void = { _ = Logger.shared.error($0) }
    ) {
        self.fileURL = fileURL
        self.writer = LogFileWriter(url: fileURL, maxFileSize: maxFileSize)
        self.reportDroppedRecords = reportDroppedRecords
        self.records = Self.loadRecords(from: fileURL)
    }

    /// Resolves the disk destination for the `shared` store, mirroring `Logger.defaultLogFileURL`
    /// so test runs never pollute (or, via `clear()`, truncate) the user's real history:
    /// - `SYNCCLOUD_HISTORY_FILE` overrides the path outright.
    /// - Under any test runner a per-process temp file is used (the Sync/Dashboard suites build a
    ///   `FileSyncManager`, whose default `syncHistoryStore` is `.shared` — without this they'd
    ///   record every fixture operation into `~/sync-cloud-history.jsonl`).
    /// - Otherwise `~/sync-cloud-history.jsonl`.
    public nonisolated static func defaultFileURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["SYNCCLOUD_HISTORY_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "").lastPathComponent
        let isRunningTests = executable == "swiftpm-testing-helper"
            || executable == "xctest"
            || NSClassFromString("XCTestCase") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
        if isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("sync-cloud-history-tests-\(ProcessInfo.processInfo.processIdentifier).jsonl")
        }
        let homeDir = (NSString(string: "~")).expandingTildeInPath
        return URL(fileURLWithPath: homeDir).appendingPathComponent("sync-cloud-history.jsonl")
    }

    // MARK: - Recording

    /// Appends one record to memory and disk. Never throws — a failed encode is dropped (and
    /// reported to the Activity Log) so the caller's file operation is never affected.
    ///
    /// This is a batch of one, and ``appendBatch(_:)``'s "announced once per batch, never once per
    /// record" is therefore a per-CALL guarantee: recording a run of N files through N calls to
    /// this method gets N drop reports, which is exactly the log-line-per-file the batch rule was
    /// written to prevent. A bulk caller must hand the run to `appendBatch` in one call — which is
    /// what the only production caller does, and why this is a documentation rule rather than a
    /// live defect. Coalescing across calls is the alternative, and it would mean holding a report
    /// back on a timer for a store whose whole contract is that recording never delays anything.
    public func append(_ record: SyncHistoryRecord) {
        appendBatch([record])
    }

    /// Appends a batch of records (one run) in a single memory update. The disk lines are handed
    /// to the background writer; the in-memory mirror is trimmed to the cap in one pass.
    public func appendBatch(_ newRecords: [SyncHistoryRecord]) {
        guard !newRecords.isEmpty else { return }
        records.append(contentsOf: newRecords)
        if records.count > Self.maxInMemoryRecords {
            records.removeFirst(records.count - Self.maxInMemoryRecords)
        }
        // A record that cannot be encoded is still dropped from the file rather than failing the
        // caller's operation — but it is COUNTED and announced once per batch afterwards, never
        // once per record: a batch is one user gesture, and a systematic encode failure would
        // otherwise emit a log line per file in a bulk run. "Per batch" means per CALL — see
        // `append(_:)`, which is a batch of one and reports like one.
        var dropped: [SyncHistoryRecord] = []
        for record in newRecords {
            guard let line = Self.encode(record) else {
                dropped.append(record)
                continue
            }
            writer.append(line + "\n")
        }
        if let first = dropped.first {
            reportDroppedRecords(
                "Sync history: \(dropped.count) record\(dropped.count == 1 ? "" : "s") could not be encoded and "
                + "\(dropped.count == 1 ? "is" : "are") missing from \(fileURL.lastPathComponent) "
                + "— first: \(first.action.rawValue) \(first.sourcePath)")
        }
    }

    // MARK: - Queries

    /// Every record belonging to a run, in append order.
    public func recordsForRun(_ runId: UUID) -> [SyncHistoryRecord] {
        records.filter { $0.runId == runId }
    }

    /// The run id of the most recent record, or nil when the history is empty.
    public var lastRunId: UUID? { records.last?.runId }

    // MARK: - Clearing

    /// Empties both the in-memory mirror and the on-disk file.
    public func clear() {
        // The one destructive clear in the app that had no line: a history that is suddenly empty
        // should be attributable to this action, not read as the store failing to load.
        Logger.shared.info("Sync history cleared — \(records.count) record(s) removed")
        records.removeAll()
        writer.clear()
    }

    /// Flushes buffered disk writes; exposed for tests asserting on file contents (production
    /// relies on the background queue draining normally).
    public func flushToDisk() {
        writer.flush()
    }

    // MARK: - Codec

    /// Encodes one record to a single-line JSON string, or nil if encoding fails. A JSON object
    /// is always one line (no embedded raw newlines), preserving the one-record-per-line invariant.
    private static func encode(_ record: SyncHistoryRecord) -> String? {
        guard let data = try? encoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Loads and decodes every well-formed line from disk, dropping any malformed line rather
    /// than failing the whole load, then caps to the newest `maxInMemoryRecords`.
    private static func loadRecords(from url: URL) -> [SyncHistoryRecord] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var loaded: [SyncHistoryRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(SyncHistoryRecord.self, from: lineData) else { continue }
            loaded.append(record)
        }
        if loaded.count > maxInMemoryRecords {
            loaded.removeFirst(loaded.count - maxInMemoryRecords)
        }
        return loaded
    }
}
