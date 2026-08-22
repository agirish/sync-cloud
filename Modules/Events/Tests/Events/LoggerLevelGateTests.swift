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
        defer { wipeDefaultsSuite(suite) }

        #expect(Logger.persistedMinimumLevel(from: defaults) == .debug)
        defaults.set(LogLevel.warning.rawValue, forKey: Logger.minimumLevelDefaultsKey)
        #expect(Logger.persistedMinimumLevel(from: defaults) == .warning)
        defaults.set("NONSENSE", forKey: Logger.minimumLevelDefaultsKey)
        #expect(Logger.persistedMinimumLevel(from: defaults) == .debug)
    }

    // MARK: - The ambient level is not the developer's

    /// **A test host must not inherit the machine's user-facing state.**
    ///
    /// The app-target tests run *inside SyncCloud.app*, so their `.standard` UserDefaults is the
    /// installed app's own domain — the developer's live preferences. With Log level set to
    /// anything above Debug in Settings, the threshold rose inside the test host and every `debug`
    /// line was dropped before it reached memory, which is what eight marker-based suites assert
    /// on. They failed together, deterministically, with nothing in the diff to explain it, and
    /// passed on CI, whose runner has no such preference.
    ///
    /// Same rule, same reason, as `defaultLogFileURL()` refusing to write the real
    /// `~/sync-cloud.log` under a test runner.
    @Test func theAmbientPersistedLevelIsIgnoredUnderATestRunner() {
        // This process IS a test runner, which is the premise; without it the assertion below
        // would pass for the ordinary reason and prove nothing.
        #expect(Logger.isRunningTests, "the runner detection stopped recognising this process")
        UserDefaults.standard.set(LogLevel.error.rawValue, forKey: Logger.minimumLevelDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: Logger.minimumLevelDefaultsKey) }

        #expect(Logger.persistedMinimumLevel() == .debug,
                "a test host inherited the machine's log level and would drop every debug line")
    }

    /// **And an EXPLICIT suite is still read**, so what the Settings UI writes stays testable. The
    /// override is on the ambient default only — widening it to every suite would have made the
    /// setting itself untestable, which is trading one blind spot for another.
    @Test func anExplicitSuiteIsStillHonouredUnderATestRunner() throws {
        let name = "LoggerLevelGateTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(name) }
        let suite = try #require(UserDefaults(suiteName: name))
        suite.set(LogLevel.warning.rawValue, forKey: Logger.minimumLevelDefaultsKey)

        #expect(Logger.persistedMinimumLevel(from: suite) == .warning)
    }

    /// An explicit suite with nothing stored still falls back to `.debug`, as it always did.
    @Test func anExplicitSuiteWithNothingStoredIsStillDebug() throws {
        let name = "LoggerLevelGateTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(name) }
        let suite = try #require(UserDefaults(suiteName: name))
        #expect(Logger.persistedMinimumLevel(from: suite) == .debug)
    }
}
