import Foundation
import SwiftUI

/// Defines the severity level of an application log entry.
public enum LogLevel: String, CaseIterable, Identifiable, Codable, Sendable {
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
public struct LogEntry: Identifiable, Codable, Sendable {
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
    public static let shared = Logger()
    
    /// The active memory cache of recent log entries presented in the UI.
    @Published public var entries: [LogEntry] = []

    /// The absolute disk URL mapping to the destination log file.
    private let logFileURL: URL
    
    /// Serializes writes to the log file on a background queue while keeping a single file handle
    /// open, avoiding a per-line open/seek/close cycle.
    private let logWriter: LogFileWriter

    private init() {
        let homeDir = (NSString(string: "~")).expandingTildeInPath
        logFileURL = URL(fileURLWithPath: homeDir).appendingPathComponent("sync-cloud.log")
        logWriter = LogFileWriter(url: logFileURL)
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

    /// Internal abstraction formatting the memory entry and dispatching to the disk background queue.
    @discardableResult
    private nonisolated func log(level: LogLevel, message: String) -> Task<Void, Never> {
        let entry = LogEntry(level: level, message: message)
        let logText = entry.formattedString + "\n"

        return Task { @MainActor in
            self.applyLogEntry(entry, logText: logText)
        }
    }

    @MainActor
    private func applyLogEntry(_ entry: LogEntry, logText: String) {
        entries.append(entry)

        if entries.count > 1000 {
            entries.removeFirst(entries.count - 1000)
        }

        // Append to the log file on a background queue (reuses one open handle).
        logWriter.append(logText)
    }
    
    /// Empties the public memory array and overwrites the local disk file with an empty sequence.
    public func clearLogs() {
        entries.removeAll()
        logWriter.clear()
    }
    
    /// Asks the macOS system workspace to launch the disk log file using the default text editor (usually Console or TextEdit).
    public func openLogFile() {
        NSWorkspace.shared.open(logFileURL)
    }
}

/// Appends log text to a file on a dedicated serial queue, keeping one `FileHandle` open across
/// writes instead of opening/seeking/closing per line. All handle access is confined to `queue`.
///
/// Internal (not private) so the self-heal / truncate behavior can be tested directly against an
/// injected temp-file URL; production code only ever uses it via `Logger`.
final class LogFileWriter: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.synccloud.logger", qos: .background)
    private var handle: FileHandle?

    init(url: URL) {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
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
                // Fallback if the handle could not be opened (matches prior behavior).
                try? data.write(to: self.url, options: .atomic)
            }
        }
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
