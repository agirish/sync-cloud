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
        defer { removeLogFiles(at: url) }
        defer { logger.flushToDisk() }

        await logger.debug("d").value
        await logger.info("i").value
        #expect(logger.entries.map(\.level) == [.debug, .info])
    }

    @MainActor
    @Test func testGateDropsBelowThresholdFromMemoryAndDisk() async throws {
        let (logger, url) = makeIsolatedLogger()
        defer { removeLogFiles(at: url) }
        defer { logger.flushToDisk() }

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
        defer { removeLogFiles(at: url) }
        defer { logger.flushToDisk() }

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
        defer { wipeDefaultsSuite(suite) }

        #expect(Logger.persistedMinimumLevel(from: defaults) == .debug)
        defaults.set(LogLevel.warning.rawValue, forKey: Logger.minimumLevelDefaultsKey)
        #expect(Logger.persistedMinimumLevel(from: defaults) == .warning)
        defaults.set("NONSENSE", forKey: Logger.minimumLevelDefaultsKey)
        #expect(Logger.persistedMinimumLevel(from: defaults) == .debug)
    }

    // MARK: - The ambient level is not the developer's

    /// A test host must not inherit the machine's user-facing state. App-target tests run inside
    /// SyncCloud.app, so `.standard` is the owner's live preferences, and a Log level above Debug
    /// there would drop the `debug` lines many suites assert on, red locally and green on CI.
    /// Same rule as `defaultLogFileURL()` refusing the real `~/sync-cloud.log` under a test runner.
    @Test func theAmbientPersistedLevelIsIgnoredUnderATestRunner() {
        // The premise: this process is a test runner, or the assertion below proves nothing.
        #expect(Logger.isRunningTests, "the runner detection stopped recognising this process")
        // A scratch suite stands in for `.standard`: under `swift test` the standard domain is one
        // plist shared by every test process on the machine, so writing it reaches theirs.
        let ambient = ScratchDefaults("LoggerLevelGateTests")
        ambient.set(LogLevel.error.rawValue, forKey: Logger.minimumLevelDefaultsKey)

        #expect(Logger.persistedMinimumLevel(from: ambient, ambient: ambient) == .debug,
                "a test host inherited the machine's log level and would drop every debug line")
    }

    /// An explicit suite is still read, so what the Settings UI writes stays testable: the
    /// override is on the ambient default only.
    @Test func anExplicitSuiteIsStillHonouredUnderATestRunner() throws {
        let name = "LoggerLevelGateTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(name) }
        let suite = try #require(UserDefaults(suiteName: name))
        suite.set(LogLevel.warning.rawValue, forKey: Logger.minimumLevelDefaultsKey)

        #expect(Logger.persistedMinimumLevel(from: suite) == .warning)
    }

    /// An explicit suite with nothing stored still falls back to `.debug`.
    @Test func anExplicitSuiteWithNothingStoredIsStillDebug() throws {
        let name = "LoggerLevelGateTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(name) }
        let suite = try #require(UserDefaults(suiteName: name))
        #expect(Logger.persistedMinimumLevel(from: suite) == .debug)
    }
}
