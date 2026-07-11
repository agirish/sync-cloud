import Testing
import Foundation
@testable import Events

/// Pins the minimum-level gate: below-threshold entries reach neither memory nor disk, the
/// default gate (.debug) changes nothing, and the persisted-level parsing falls back safely.
@Suite struct LoggerLevelGateTests {

    @MainActor
    private func makeIsolatedLogger() -> (Logger, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerLevelGate-\(UUID().uuidString).log")
        return (Logger(logFileURL: url), url)
    }

    @MainActor
    @Test func testDefaultGateLogsEverything() async {
        let (logger, url) = makeIsolatedLogger()
        defer { try? FileManager.default.removeItem(at: url) }

        await logger.debug("d").value
        await logger.info("i").value
        #expect(logger.entries.map(\.level) == [.debug, .info])
    }

    @MainActor
    @Test func testGateDropsBelowThresholdFromMemoryAndDisk() async throws {
        let (logger, url) = makeIsolatedLogger()
        defer { try? FileManager.default.removeItem(at: url) }

        logger.minimumLevel = .warning
        await logger.debug("dropped-debug").value
        await logger.info("dropped-info").value
        await logger.warning("kept-warning").value
        await logger.error("kept-error").value

        #expect(logger.entries.map(\.level) == [.warning, .error])

        logger.logWriter.flush()
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.contains("dropped-debug"))
        #expect(!contents.contains("dropped-info"))
        #expect(contents.contains("kept-warning"))
        #expect(contents.contains("kept-error"))
    }

    @MainActor
    @Test func testLoweringTheGateResumesLogging() async {
        let (logger, url) = makeIsolatedLogger()
        defer { try? FileManager.default.removeItem(at: url) }

        logger.minimumLevel = .error
        await logger.info("dropped").value
        logger.minimumLevel = .debug
        await logger.info("kept").value
        #expect(logger.entries.map(\.message) == ["kept"])
    }

    @Test func testSeverityOrdering() {
        #expect(LogLevel.debug.severity < LogLevel.info.severity)
        #expect(LogLevel.info.severity < LogLevel.warning.severity)
        #expect(LogLevel.warning.severity < LogLevel.error.severity)
    }

    @Test func testPersistedMinimumLevelParsing() {
        let suite = "LoggerLevelGateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(Logger.persistedMinimumLevel(from: defaults) == .debug)
        defaults.set(LogLevel.warning.rawValue, forKey: Logger.minimumLevelDefaultsKey)
        #expect(Logger.persistedMinimumLevel(from: defaults) == .warning)
        defaults.set("NONSENSE", forKey: Logger.minimumLevelDefaultsKey)
        #expect(Logger.persistedMinimumLevel(from: defaults) == .debug)
    }
}
