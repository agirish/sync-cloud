import Testing
import Foundation
@testable import Events

/// Pins the minimum-level gate: below-threshold entries reach neither memory nor disk, an isolated
/// logger's gate (.debug) changes nothing, and the persisted level falls back to Info.
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

        #expect(Logger.persistedMinimumLevel(from: defaults) == .info)
        #expect(Logger.defaultMinimumLevel == .info)
        defaults.set(LogLevel.warning.rawValue, forKey: Logger.minimumLevelDefaultsKey)
        #expect(Logger.persistedMinimumLevel(from: defaults) == .warning)
        defaults.set("NONSENSE", forKey: Logger.minimumLevelDefaultsKey)
        #expect(Logger.persistedMinimumLevel(from: defaults) == .info)
    }

    // MARK: - The ambient level is not the developer's

    /// App-target tests run inside SyncCloud.app, so `.standard` is the owner's live preferences,
    /// and a Log level above Debug there would drop the `debug` lines many suites assert on.
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

    // MARK: - The level-change line

    @Test func aLevelChangeIsOneLineNamingBothLevelsInThePickersWords() {
        #expect(Logger.levelChangeLine(from: .debug, to: .info, because: "Reset All")
                == "Log level Debug → Info (Reset All)")
        #expect(Logger.levelChangeLine(from: .info, to: .error, because: "chosen in Settings")
                == "Log level Info → Errors only (chosen in Settings)")
    }

    /// The picker's `.onChange` and the catalog writer both apply one choice, so the second call
    /// must be silent.
    @Test func noChangeWritesNoLine() {
        for level in LogLevel.allCases {
            #expect(Logger.levelChangeLine(from: level, to: level, because: "x") == nil)
        }
    }

    // MARK: - Once per launch

    @Test func aKeyIsFirstOnceAndNeverAgain() {
        let once = OncePerLaunch()
        #expect(once.isFirst("/a"))
        #expect(!once.isFirst("/a"))
        #expect(once.isFirst("/b"), "one key's report used up another's")
    }
}
