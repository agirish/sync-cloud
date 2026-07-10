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

    /// The absolute disk URL mapping to the destination log file.
    private let logFileURL: URL
    
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
        let entry = LogEntry(level: level, message: message)
        pendingEntries.enqueue(entry)
        logWriter.append(entry.formattedString + "\n")

        // Awaiting the returned task guarantees the entry is visible in `entries`: the first
        // flush to run drains everything enqueued before it; later flushes are cheap no-ops.
        return Task { @MainActor in
            self.flushPendingEntries()
        }
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
    
    /// Asks the macOS system workspace to launch the disk log file using the default text editor (usually Console or TextEdit).
    public func openLogFile() {
        NSWorkspace.shared.open(logFileURL)
    }
}

/// Lock-guarded FIFO handing `LogEntry` values from nonisolated log callers to the MainActor
/// flush. Enqueue order is the order entries appear in the Activity Log.
private final class PendingLogEntryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [LogEntry] = []

    func enqueue(_ entry: LogEntry) {
        lock.lock()
        pending.append(entry)
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
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
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
            // Reopen if the file is missing - never opened, or removed/replaced externally (the open
            // handle would otherwise write into an orphaned inode and silently lose the line). This
            // preserves the prior open-per-line code's self-healing behavior; the fileExists stat is
            // still far cheaper than the previous open/seek/write/close per line.
            if self.handle == nil || !FileManager.default.fileExists(atPath: self.url.path) {
                try? self.handle?.close()
                self.handle = nil
                if !FileManager.default.fileExists(atPath: self.url.path) {
                    FileManager.default.createFile(atPath: self.url.path, contents: nil, attributes: nil)
                }
                self.handle = try? FileHandle(forWritingTo: self.url)
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
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// Blocks until every append/clear enqueued before this call has finished. Test-only barrier;
    /// production logging never needs to wait on the background queue.
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
