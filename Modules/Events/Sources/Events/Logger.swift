import Foundation
import SwiftUI

/// Defines the severity level of an application log entry.
public enum LogLevel: String, CaseIterable, Identifiable, Sendable {
    /// Informational telemetry or standard operational success events.
    case info = "INFO"
    /// Detailed diagnostic information for development.
    case debug = "DEBUG"
    /// A non-critical issue that did not halt execution but requires attention.
    case warning = "WARN"
    /// A critical failure or severe application error.
    case error = "ERROR"
    
    public var id: String { self.rawValue }

    /// Ordering for the minimum-level gate: entries below `Logger.minimumLevel`'s severity
    /// are dropped. Debug is the lowest so the default gate changes nothing.
    public var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public var color: Color {
        switch self {
        case .info: return .blue
        case .debug: return .gray
        case .warning: return .orange
        case .error: return .red
        }
    }
    
    public var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .debug: return "ant.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// Represents a single recorded event in the application's lifecycle.
public struct LogEntry: Identifiable, Sendable {
    /// A unique identifier for the entry.
    public let id: UUID
    /// The exact timestamp when the event occurred.
    public let timestamp: Date
    /// The severity classification of the event.
    public let level: LogLevel
    /// A detailed human-readable description of the event.
    public let message: String
    
    public init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
    
    /// Shared timestamp formatter. Reused instead of reallocated per log line (DateFormatter is
    /// expensive to create and is thread-safe for formatting).
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    var formattedString: String {
        return "[\(Self.timestampFormatter.string(from: timestamp))] [\(level.rawValue)] \(message)"
    }
}

/// A thread-safe, globally accessible logging service for the SyncCloud application.
/// Manages writing event traces to disk (`~/sync-cloud.log`) and maintaining an observable history for the LogViewer UI.
@MainActor
public class Logger: ObservableObject {
    /// The shared singleton instance used across the application to trace events.
    public static let shared = Logger(logFileURL: Logger.defaultLogFileURL())

    /// The active memory cache of recent log entries presented in the UI.
    @Published public var entries: [LogEntry] = []

    /// The absolute disk URL mapping to the destination log file. Public so Settings can
    /// reveal it in Finder and show its size next to the Clear Log control.
    public let logFileURL: URL

    /// Defaults key holding the persisted minimum level (a `LogLevel` raw value). The app
    /// seeds `shared.minimumLevel` from it at launch; Settings writes both.
    public nonisolated static let minimumLevelDefaultsKey = "logMinimumLevel"

    /// The persisted minimum level, falling back to `.debug` (log everything — the historical
    /// behavior) when unset or unrecognized.
    public nonisolated static func persistedMinimumLevel(from defaults: UserDefaults = .standard) -> LogLevel {
        defaults.string(forKey: minimumLevelDefaultsKey).flatMap(LogLevel.init(rawValue:)) ?? .debug
    }

    /// Entries below this severity are dropped before they reach memory or disk. Nonisolated
    /// (lock-guarded) because `log()` runs on the caller's thread.
    public nonisolated var minimumLevel: LogLevel {
        get { minimumLevelBox.get() }
        set { minimumLevelBox.set(newValue) }
    }
    private let minimumLevelBox = MinimumLevelBox()


    /// Serializes writes to the log file on a background queue while keeping a single file handle
    /// open, avoiding a per-line open/seek/close cycle. Internal (not private) so tests can
    /// `flush()` before asserting on file contents.
    let logWriter: LogFileWriter

    /// Internal (not private) so tests can construct an isolated Logger against a temp-file URL;
    /// production code only ever uses the `shared` instance.
    init(logFileURL: URL) {
        self.logFileURL = logFileURL
        logWriter = LogFileWriter(url: logFileURL)
    }

    /// Resolves the disk destination for the `shared` logger.
    ///
    /// Production: `~/sync-cloud.log`, unchanged. Two escape hatches keep test runs from
    /// polluting (or truncating, via `clearLogs`) the user's real app log and the Activity Log
    /// viewer that displays it:
    /// - `SYNCCLOUD_LOG_FILE` in the environment overrides the path outright.
    /// - Under a test runner (every package suite logs through `Logger.shared`, so `swift test`
    ///   would otherwise fill the real log with test entries), a per-process temp file is used.
    nonisolated static func defaultLogFileURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["SYNCCLOUD_LOG_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        // `swift test` runs swift-testing suites inside swiftpm-testing-helper (no XCTest linked,
        // no XCTest* environment), XCTest suites inside an xctest runner; Xcode sets the
        // XCTest* environment markers. Cover all three.
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "").lastPathComponent
        let isRunningTests = executable == "swiftpm-testing-helper"
            || executable == "xctest"
            || NSClassFromString("XCTestCase") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
        if isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("sync-cloud-tests-\(ProcessInfo.processInfo.processIdentifier).log")
        }
        let homeDir = (NSString(string: "~")).expandingTildeInPath
        return URL(fileURLWithPath: homeDir).appendingPathComponent("sync-cloud.log")
    }

    /// Records an informational trace event to memory and disk.
    /// - Parameter message: The string description to log.
    @discardableResult
    public nonisolated func info(_ message: String) -> Task<Void, Never> {
        return log(level: .info, message: message)
    }
    
    /// Records a diagnostic debug event.
    /// - Parameter message: The string description to log.
    @discardableResult
    public nonisolated func debug(_ message: String) -> Task<Void, Never> {
        return log(level: .debug, message: message)
    }
    
    /// Records a warning trace event to memory and disk.
    /// - Parameters:
    ///   - message: The string description of the warning.
    @discardableResult
    public nonisolated func warning(_ message: String, file: String = #file, line: Int = #line, function: String = #function) -> Task<Void, Never> {
        let locationMsg = "\(message) | Location: \((file as NSString).lastPathComponent):\(line) / \(function)"
        return log(level: .warning, message: locationMsg)
    }
    
    /// Records an error trace event.
    /// - Parameter message: The string description of the failure.
    @discardableResult
    public nonisolated func error(_ message: String, file: String = #file, line: Int = #line, function: String = #function) -> Task<Void, Never> {
        let locationMsg = "\(message) | Location: \((file as NSString).lastPathComponent):\(line) / \(function)"
        return log(level: .error, message: locationMsg)
    }

    /// FIFO handoff buffer between nonisolated log callers and the MainActor `entries` array.
    private let pendingEntries = PendingLogEntryQueue()

    /// Internal abstraction routing the entry to memory and disk.
    ///
    /// Both destinations are sequenced at the call site, not by task scheduling: the pending
    /// queue (drained in FIFO order on the MainActor) and the writer's serial disk queue each
    /// preserve enqueue order, so lines land in call order. The per-call unstructured task this
    /// replaces carried the entry itself, which let concurrent bursts reorder lines.
    @discardableResult
    private nonisolated func log(level: LogLevel, message: String) -> Task<Void, Never> {
        guard level.severity >= minimumLevel.severity else { return Task {} }
        let entry = LogEntry(level: level, message: message)
        // Awaiting the returned task guarantees the entry is visible in `entries`: the queue
        // hands back the one MainActor flush task covering the current burst (see
        // PendingLogEntryQueue — a task per line meant thousands of no-op drains during sync
        // bursts), and that flush drains everything enqueued before it runs.
        let flushTask = pendingEntries.enqueue(entry) { self.flushPendingEntries() }
        logWriter.append(entry.formattedString + "\n")
        return flushTask
    }

    @MainActor
    private func flushPendingEntries() {
        let batch = pendingEntries.drain()
        guard !batch.isEmpty else { return }
        entries.append(contentsOf: batch)

        // One batched trim (and one array republish) per flush, instead of an O(count) shift
        // per line while at the cap during per-file sync bursts.
        if entries.count > 1000 {
            entries.removeFirst(entries.count - 1000)
        }
    }
    
    /// Empties the public memory array and overwrites the local disk file with an empty sequence.
    public func clearLogs() {
        // Drop entries still sitting in the handoff queue too: without this, lines enqueued just
        // before the clear would flush into `entries` afterward and "resurrect" in the UI.
        _ = pendingEntries.drain()
        entries.removeAll()
        logWriter.clear()
    }
    
    /// Synchronously drains the disk writer's background queue so every line enqueued before this
    /// call is committed to disk. Callers append synchronously in `log()`, so once this returns
    /// the buffered writes are durable.
    ///
    /// This exists for app termination: the writer runs at `.background` qos with no implicit
    /// flush, so an in-flight file operation's own log lines could be lost exactly when a
    /// crash-time corruption most needs them. `applicationShouldTerminate` calls this before
    /// allowing the quit so the breadcrumb survives.
    public nonisolated func flushToDisk() {
        logWriter.flush()
    }

    /// Asks the macOS system workspace to launch the disk log file using the default text editor (usually Console or TextEdit).
    public func openLogFile() {
        NSWorkspace.shared.open(logFileURL)
    }
}

/// Lock-guarded `LogLevel` cell readable/writable from any thread — `log()` runs on the
/// caller's thread, so the gate can't live in MainActor state.
private final class MinimumLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LogLevel = .debug

    func get() -> LogLevel {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: LogLevel) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// Lock-guarded FIFO handing `LogEntry` values from nonisolated log callers to the MainActor
/// flush. Enqueue order is the order entries appear in the Activity Log.
///
/// Flush scheduling is coalesced: all enqueues of a burst share ONE MainActor flush task
/// instead of spawning a task per line whose drains are mostly no-ops. The shared task still
/// honors the awaitable contract (`entry` is visible in `entries` once the returned task
/// completes): the scheduled-task marker clears on the MainActor *before* the drain with no
/// suspension in between, so an entry enqueued too late for a running drain observed a cleared
/// marker and scheduled the next flush for itself.
private final class PendingLogEntryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [LogEntry] = []
    /// The MainActor flush task covering everything currently in `pending`; nil once that
    /// task has started clearing/draining (guarded by `lock`).
    private var scheduledFlush: Task<Void, Never>?

    /// Appends the entry and returns the flush task that will make it visible, creating a
    /// task only when none is scheduled (the empty→non-empty transition of a burst).
    func enqueue(_ entry: LogEntry, flush: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        lock.lock()
        pending.append(entry)
        if let scheduledFlush {
            lock.unlock()
            return scheduledFlush
        }
        let task = Task { @MainActor [weak self] in
            self?.clearScheduledFlush()
            flush()
        }
        scheduledFlush = task
        lock.unlock()
        return task
    }

    private func clearScheduledFlush() {
        lock.lock()
        scheduledFlush = nil
        lock.unlock()
    }

    func drain() -> [LogEntry] {
        lock.lock()
        let batch = pending
        pending = []
        lock.unlock()
        return batch
    }
}

/// Appends log text to a file on a dedicated serial queue, keeping one `FileHandle` open across
/// writes instead of opening/seeking/closing per line. All handle access is confined to `queue`,
/// including the initial tail-trim and handle opening (appends enqueue behind them).
///
/// Internal (not private) so the self-heal / truncate behavior can be tested directly against an
/// injected temp-file URL; production code only ever uses it via `Logger`.
final class LogFileWriter: @unchecked Sendable {
    /// Size cap for the log file, enforced at startup and re-checked periodically as the session
    /// writes. ~5 MB is tens of thousands of lines; an oversized file is trimmed to roughly half
    /// the cap so trims don't run back-to-back.
    private static let defaultMaxFileSize = 5 * 1024 * 1024

    private let url: URL
    private let queue = DispatchQueue(label: "com.synccloud.logger", qos: .background)
    private var handle: FileHandle?
    /// Inode of the file `handle` was opened against (confined to `queue`). Appends compare it
    /// to the path's current inode: an external atomic rewrite (write-temp-then-rename, e.g.
    /// another process's tail-trim of the shared log) keeps the path present while orphaning
    /// the open handle's inode, so existence alone cannot detect a stale handle.
    private var handleFileIdentity: UInt64?
    private let maxFileSize: Int

    /// Bytes appended since the last mid-session size check (confined to `queue`). Re-statting
    /// the file on every line would be wasted syscalls; instead the oversize check re-runs each
    /// time this crosses `trimCheckInterval`, so a long-running session stays bounded near the
    /// cap instead of growing until next launch.
    private var bytesSinceTrimCheck = 0
    private let trimCheckInterval: Int

    init(url: URL, maxFileSize: Int = LogFileWriter.defaultMaxFileSize) {
        self.url = url
        self.maxFileSize = maxFileSize
        trimCheckInterval = min(1024 * 1024, max(1, maxFileSize / 2))
        queue.async { [self] in
            trimTailIfOversized(maxFileSize: maxFileSize)
            openHandle()
        }
    }

    /// Inode of the item currently at `url`; nil when the path does not exist. One
    /// `attributesOfItem` stat answers both existence and identity. Runs on `queue`.
    private func currentFileIdentity() -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// (Re)opens the write handle positioned at end-of-file, creating the file if missing, and
    /// records the opened file's identity for the staleness check in `append`. Runs on `queue`.
    private func openHandle() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        handleFileIdentity = handle == nil ? nil : currentFileIdentity()
    }

    /// Tail-trims the file when it exceeds `maxFileSize`, keeping the newest half of the cap
    /// aligned to a line boundary, so `~/sync-cloud.log` cannot grow unbounded across runs.
    /// Runs on `queue` before the write handle opens.
    private func trimTailIfOversized(maxFileSize: Int) {
        guard maxFileSize > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > maxFileSize,
              let readHandle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? readHandle.close() }

        let keepBytes = maxFileSize / 2
        guard (try? readHandle.seek(toOffset: UInt64(size - keepBytes))) != nil,
              var tail = try? readHandle.readToEnd() else { return }
        // Drop the partial first line so the trimmed file still starts at a line boundary.
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail.suffix(from: tail.index(after: newline))
        }
        try? tail.write(to: url, options: .atomic)
    }

    func append(_ text: String) {
        queue.async { [weak self] in
            guard let self, let data = text.data(using: .utf8) else { return }
            // Reopen if the path's current inode no longer matches the handle's - never opened,
            // removed, or replaced externally. Removal makes the identity nil; REPLACEMENT
            // (atomic rewrite, e.g. the CLI's tail-trim of the shared log while the app runs)
            // keeps the path present but swaps the inode, so a plain fileExists check would let
            // the handle keep writing into the orphaned old inode and silently lose every line.
            // Same cost profile as the old existence check: one stat per append.
            if self.handle == nil || self.currentFileIdentity() != self.handleFileIdentity {
                try? self.handle?.close()
                self.handle = nil
                self.openHandle()
            }
            if let handle = self.handle {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                // Last-resort fallback when the handle could not be opened. Append manually — a
                // bare `.atomic` write would replace the entire log history with this one line.
                // (Known cost: this re-reads and rewrites the whole file per line, but it only
                // runs while the handle is unopenable, which self-heals on the next append.)
                let existing = (try? Data(contentsOf: self.url)) ?? Data()
                try? (existing + data).write(to: self.url, options: .atomic)
            }
            self.bytesSinceTrimCheck += data.count
            if self.bytesSinceTrimCheck >= self.trimCheckInterval {
                self.bytesSinceTrimCheck = 0
                self.trimMidSessionIfOversized()
            }
        }
    }

    /// Mid-session counterpart to the init-time trim. Runs on `queue`. The trim rewrites the
    /// file atomically (new inode), so the open handle must be closed first and reopened after —
    /// otherwise subsequent appends would land in the orphaned old inode and vanish.
    private func trimMidSessionIfOversized() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > maxFileSize else { return }
        try? handle?.close()
        handle = nil
        trimTailIfOversized(maxFileSize: maxFileSize)
        openHandle()
    }

    /// Blocks until every append/clear enqueued before this call has finished. The barrier
    /// behind `Logger.flushToDisk()`, which production calls at app termination (and the CLI
    /// before process exit) so buffered lines survive the quit; tests also use it before
    /// asserting on file contents.
    func flush() {
        queue.sync {}
    }

    /// Truncates the log file to empty, keeping the open handle valid.
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            if let handle = self.handle {
                try? handle.truncate(atOffset: 0)
                try? handle.seek(toOffset: 0)
            } else {
                try? "".write(to: self.url, atomically: true, encoding: .utf8)
            }
        }
    }
}
