import Foundation
import SwiftUI

/// Defines the severity level of an application log entry.
public enum LogLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Informational telemetry or standard operational success events.
    case info = "INFO"
    /// A non-critical issue that did not halt execution but requires attention.
    case warning = "WARN"
    /// A critical failure or severe application error.
    case error = "ERROR"
    
    public var id: String { self.rawValue }
    
    public var color: Color {
        switch self {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
    
    public var icon: String {
        switch self {
        case .info: return "info.circle.fill"
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
    
    var formattedString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return "[\(formatter.string(from: timestamp))] [\(level.rawValue)] \(message)"
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
    
    /// A volatile string holding the latest severe error. Bound to `.alert()` modifiers to display OS-level popups.
    @Published var currentAlertError: String? = nil
    
    /// The absolute disk URL mapping to the destination log file.
    private let logFileURL: URL
    
    /// A dedicated background GCD queue guaranteeing atomic log file writes without stalling the main UI thread.
    private let fileQueue = DispatchQueue(label: "com.synccloud.logger", qos: .background)
    
    private init() {
        let homeDir = (NSString(string: "~")).expandingTildeInPath
        logFileURL = URL(fileURLWithPath: homeDir).appendingPathComponent("sync-cloud.log")
        
        // Ensure the log file exists
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
        }
    }
    
    /// Records an informational trace event to memory and disk.
    /// - Parameter message: The string description to log.
    @discardableResult
    public nonisolated func info(_ message: String) -> Task<Void, Never> {
        return log(level: .info, message: message)
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
    /// - Parameters:
    ///   - message: The string description of the failure.
    ///   - showAlert: If true, assigns the original message to `currentAlertError`, causing the app UI to natively display a popup alert. Defaults to true.
    @discardableResult
    public nonisolated func error(_ message: String, showAlert: Bool = true, file: String = #file, line: Int = #line, function: String = #function) -> Task<Void, Never> {
        let locationMsg = "\(message) | Location: \((file as NSString).lastPathComponent):\(line) / \(function)"
        return log(level: .error, message: locationMsg, showAlert: showAlert, cleanMessage: message)
    }
    
    /// Internal abstraction formatting the memory entry and dispatching to the disk background queue.
    @discardableResult
    private nonisolated func log(level: LogLevel, message: String, showAlert: Bool = false, cleanMessage: String? = nil) -> Task<Void, Never> {
        let entry = LogEntry(level: level, message: message)
        let logText = entry.formattedString + "\n"

        // Preserve synchronous semantics for main-thread callers while keeping a safe nonisolated API.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                applyLogEntry(entry, logText: logText, showAlert: showAlert, cleanMessage: cleanMessage)
            }
            return Task {}
        }

        return Task { @MainActor in
            self.applyLogEntry(entry, logText: logText, showAlert: showAlert, cleanMessage: cleanMessage)
        }
    }

    @MainActor
    private func applyLogEntry(_ entry: LogEntry, logText: String, showAlert: Bool, cleanMessage: String?) {
        entries.append(entry)

        if entries.count > 1000 {
            entries.removeFirst(entries.count - 1000)
        }

        if showAlert, let clean = cleanMessage {
            currentAlertError = clean
        }

        // Append to file asynchronously on background queue
        fileQueue.async { [url = logFileURL] in
            guard let data = logText.data(using: .utf8) else { return }

            if let fileHandle = try? FileHandle(forWritingTo: url) {
                defer { try? fileHandle.close() }
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
    
    /// Empties the public memory array and overwrites the local disk file with an empty sequence.
    public func clearLogs() {
        entries.removeAll()
        fileQueue.async { [url = self.logFileURL] in
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }
    
    /// Asks the macOS system workspace to launch the disk log file using the default text editor (usually Console or TextEdit).
    public func openLogFile() {
        NSWorkspace.shared.open(logFileURL)
    }
}
