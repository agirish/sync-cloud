import Foundation
import SwiftUI

/// A durable, observable store of `SyncHistoryRecord`s, appended as JSON lines to
/// `~/sync-cloud-history.jsonl`, so a crash mid-write costs at most the last line. The file uses
/// the log's `LogFileWriter` (serial queue, one handle, trimmed at 5 MB); the memory copy is capped.
///
/// `@MainActor` because `records` drives Activity's Events. Recording is best-effort and
/// never blocks or fails the file operation it records, but not silent: a record that can't be
/// encoded is announced through `reportDroppedRecords`.
@MainActor
public final class SyncHistoryStore: ObservableObject {
    /// The instance the Sync layer records into by default; tests inject their own.
    public static let shared = SyncHistoryStore()

    /// The records observed by the UI, oldest-first (append order). Capped at
    /// `maxInMemoryRecords`; the disk file is trimmed independently by `LogFileWriter`.
    @Published public private(set) var records: [SyncHistoryRecord] = []

    /// Runs the in-memory cap cut: some of their records were dropped from `records` (the file
    /// still has them). Activity's Events says such a run's count is only what is kept.
    public private(set) var trimmedRunIds: Set<UUID> = []

    /// The on-disk destination. Public so the UI can reveal it in Finder, mirroring the log file.
    public let fileURL: URL

    /// The most records kept in memory: far more than a session produces, still cheap to filter
    /// and render. Older rows stay in the file until trimmed.
    private static let maxInMemoryRecords = 5000

    private let writer: LogFileWriter

    /// Where a dropped record is announced: the Activity Log, a different file and writer, so no
    /// loop back into this store. This file is the audit trail of real file changes, so a record
    /// that never reaches disk must leave a trace. Injected, like `FolderJump.siblings`'
    /// `logError`, so tests needn't read `Logger.shared`'s asynchronous buffer.
    private let reportDroppedRecords: @MainActor (String) -> Void

    /// One shared codec so persisted lines and in-memory records agree. The default `Date`
    /// strategy (a numeric interval) is compact and round-trips exactly; ISO-8601 is for exports.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Production uses the shared file; tests inject an isolated temp URL. `LogFileWriter`'s
    /// 5 MB cap can be overridden for the size-cap test.
    public init(
        fileURL: URL = SyncHistoryStore.defaultFileURL(),
        maxFileSize: Int = 5 * 1024 * 1024,
        reportDroppedRecords: @escaping @MainActor (String) -> Void = { _ = Logger.shared.error($0) },
        reportWriteFailure: @escaping @Sendable (String) -> Void = { _ = Logger.shared.error($0) },
        reportWriteRecovered: @escaping @Sendable (String) -> Void = { _ = Logger.shared.info($0) }
    ) {
        self.fileURL = fileURL
        // A failed write is otherwise silent: History looks complete while the file stops growing.
        // Once per failure run (the writer's latch), and once more when writes land again.
        let name = fileURL.lastPathComponent
        self.writer = LogFileWriter(
            url: fileURL, maxFileSize: maxFileSize,
            onWriteFailure: { reason in
                reportWriteFailure("Sync History: couldn’t write \(name) (\(reason)) — runs from now on "
                                   + "are missing from the file until a write lands")
            },
            onWriteRecovered: {
                reportWriteRecovered("Sync History: \(name) is being written again; runs recorded while it "
                                     + "couldn’t be are in this session’s History only")
            })
        self.reportDroppedRecords = reportDroppedRecords
        let loaded = Self.loadRecords(from: fileURL)
        self.records = loaded.records
        self.trimmedRunIds = loaded.trimmed
    }

    /// The `shared` store's file, mirroring `Logger.defaultLogFileURL` so tests never fill or
    /// clear the real history (a test's `FileSyncManager` records into `.shared` by default):
    /// - `SYNCCLOUD_HISTORY_FILE` overrides the path outright.
    /// - Under a test runner, a per-process temp file (see `PerProcessTestFile`).
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
            return PerProcessTestFile.url(stem: PerProcessTestFile.historyStem, extension: "jsonl")
        }
        let homeDir = (NSString(string: "~")).expandingTildeInPath
        return URL(fileURLWithPath: homeDir).appendingPathComponent("sync-cloud-history.jsonl")
    }

    // MARK: - Recording

    /// Appends one record to memory and disk. Never throws: a failed encode is dropped and
    /// reported, so the caller's file operation is never affected.
    ///
    /// A batch of one, so it reports a drop per call: a bulk caller must hand its run to
    /// ``appendBatch(_:)`` in one call, or a failing run logs a line per file.
    public func append(_ record: SyncHistoryRecord) {
        appendBatch([record])
    }

    /// Appends a batch of records (one run) in a single memory update. The disk lines are handed
    /// to the background writer; the in-memory mirror is trimmed to the cap in one pass.
    public func appendBatch(_ newRecords: [SyncHistoryRecord]) {
        guard !newRecords.isEmpty else { return }
        records.append(contentsOf: newRecords)
        if records.count > Self.maxInMemoryRecords {
            let cut = records.count - Self.maxInMemoryRecords
            trimmedRunIds.formUnion(records.prefix(cut).map(\.runId))
            records.removeFirst(cut)
        }
        // A record that can't be encoded is dropped from the file, not failing the caller, and
        // the drops are announced once per call: a batch is one gesture, and a systematic failure
        // would otherwise log a line per file.
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
    ///
    /// Silent on purpose: the user-facing clear logs at its confirm
    /// (`ActivityEventsView.clearIfConfirmed`). A line here would fire from every test fixture's
    /// cleanup and break `Logger.shared`'s exact-count suite in the same package.
    public func clear() {
        records.removeAll()
        trimmedRunIds = []
        writer.clear()
    }

    /// Flushes buffered disk writes, for tests reading the file; the app lets the queue drain.
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
    private static func loadRecords(from url: URL) -> (records: [SyncHistoryRecord], trimmed: Set<UUID>) {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return ([], []) }
        var loaded: [SyncHistoryRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(SyncHistoryRecord.self, from: lineData) else { continue }
            loaded.append(record)
        }
        var trimmed: Set<UUID> = []
        if loaded.count > maxInMemoryRecords {
            let cut = loaded.count - maxInMemoryRecords
            trimmed = Set(loaded.prefix(cut).map(\.runId))
            loaded.removeFirst(cut)
        }
        return (loaded, trimmed)
    }
}
