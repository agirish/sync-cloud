import Foundation
import Testing
@testable import Sync

/// No test moves the process-wide log gate.
///
/// Every target runs its suites in parallel against one `Logger.shared`, and `LogCapture` reads a
/// window by awaiting a Debug flush marker. A test that raised the gate, even for a moment, would
/// drop every sibling suite's Debug lines and that marker with them, so their absence assertions
/// would pass having seen nothing. Under a test runner the shipped Info default never applies
/// (`Logger.persistedMinimumLevel`); this keeps a test from applying a level by hand.
///
/// Banned in test code: assigning `Logger.shared.minimumLevel`, and calling the setters that apply
/// a level to it without a seam. An isolated `Logger(logFileURL:)`'s gate is a test's own and
/// stays allowed (`LoggerLevelGateTests`). Same walk as `LogBufferReadScanTests`.
@Suite struct LogLevelWriteScanTests {

    /// The shapes that move the shared gate. `LogLevelSetting.set(` is banned only without its
    /// `applyRunning` seam, which every test passes as a trailing closure or argument.
    static func movesTheSharedGate(_ source: String) -> Bool {
        let code = source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
        return code.contains { line in
            line.contains("Logger.shared.minimumLevel =")
                || line.contains("LogLevelSetting.applyRunning(")
                || (line.contains("LogLevelSetting.set(") && !line.contains("applyRunning") && !line.contains(") {"))
        }
    }

    static let ownPath = String(URL(fileURLWithPath: #filePath).standardizedFileURL.path
        .dropFirst(LogBufferReadScanTests.root.path.count + 1))

    @Test func noTestMovesTheSharedLogGate() {
        let sources = LogBufferReadScanTests.sources()
        #expect(sources.count >= 600, "the scan read \(sources.count) files — it has stopped reading the test trees")
        let movers = sources.filter { $0.path != Self.ownPath && Self.movesTheSharedGate($0.text) }.map(\.path)
        #expect(movers.isEmpty, """
            \(movers.sorted()) move Logger.shared's gate. A raised gate drops every parallel suite's \
            Debug lines and LogCapture's flush marker; build an isolated Logger(logFileURL:) or pass \
            the applyRunning seam instead.
            """)
    }

    /// Positive control: the judgement tells the banned shapes from the allowed ones.
    @Test func theScanTellsTheSharedGateFromAnIsolatedOne() {
        #expect(Self.movesTheSharedGate("Logger.shared.minimumLevel = .warning"))
        #expect(Self.movesTheSharedGate("LogLevelSetting.applyRunning(raw: \"WARN\")"))
        #expect(Self.movesTheSharedGate("LogLevelSetting.set(.warning, in: defaults)"))
        #expect(!Self.movesTheSharedGate("logger.minimumLevel = .warning"), "an isolated logger is a test's own")
        #expect(!Self.movesTheSharedGate("LogLevelSetting.set(.warning, in: defaults) { told.append($0) }"))
        #expect(!Self.movesTheSharedGate("// Logger.shared.minimumLevel = .error"), "a comment moves nothing")
    }
}
