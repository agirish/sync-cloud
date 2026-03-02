import Foundation
import SwiftUI

enum LogLevel: String, CaseIterable, Identifiable, Codable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
    
    var id: String { self.rawValue }
    
    var color: Color {
        switch self {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

struct LogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String
    
    init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, message: String) {
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

@MainActor
class Logger: ObservableObject {
    static let shared = Logger()
    
    @Published private(set) var entries: [LogEntry] = []
    
    // Global UX error bubbled up to the UI alert
    @Published var currentAlertError: String? = nil
    
    private let logFileURL: URL
    private let fileQueue = DispatchQueue(label: "com.synccloud.logger", qos: .background)
    
    private init() {
        let homeDir = (NSString(string: "~")).expandingTildeInPath
        logFileURL = URL(fileURLWithPath: homeDir).appendingPathComponent("sync-cloud.log")
        
        // Ensure the log file exists
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
        }
    }
    
    func info(_ message: String) {
        log(level: .info, message: message)
    }
    
    func warning(_ message: String) {
        log(level: .warning, message: message)
    }
    
    func error(_ message: String, showAlert: Bool = true) {
        log(level: .error, message: message)
        if showAlert {
            currentAlertError = message
        }
    }
    
    private func log(level: LogLevel, message: String) {
        let entry = LogEntry(level: level, message: message)
        
        // Update UI state
        entries.append(entry)
        
        // Maintain reasonable memory footprint (e.g., last 1000 logs)
        if entries.count > 1000 {
            entries.removeFirst(entries.count - 1000)
        }
        
        // Append to file asynchronously
        let logText = entry.formattedString + "\n"
        fileQueue.async { [url = self.logFileURL] in
            if let data = logText.data(using: .utf8) {
                if let fileHandle = try? FileHandle(forWritingTo: url) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }
    
    func clearLogs() {
        entries.removeAll()
        fileQueue.async { [url = self.logFileURL] in
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }
    
    func openLogFile() {
        NSWorkspace.shared.open(logFileURL)
    }
}
