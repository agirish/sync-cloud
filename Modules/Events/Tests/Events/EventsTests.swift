import Testing
import Foundation
@testable import Events

@Suite(.serialized) struct EventsTests {
    
    @MainActor
    @Test func testLoggerInfo() async throws {
        let logger = Logger.shared
        logger.clearLogs()
        
        await logger.info("Test info message").value
        
        #expect(logger.entries.count == 1)
        #expect(logger.entries.first?.level == .info)
        #expect(logger.entries.first?.message == "Test info message")
    }
    
    @MainActor
    @Test func testLoggerError() async throws {
        let logger = Logger.shared
        logger.clearLogs()

        await logger.error("Critical failure").value

        #expect(logger.entries.last?.level == .error)
        #expect(logger.entries.last?.message.contains("Critical failure") == true)
    }
    
    @MainActor
    @Test func testLoggerMemoryLimit() async throws {
        let logger = Logger.shared
        logger.clearLogs()
        
        // Log 1100 entries (limit is 1000)
        for i in 0..<1100 {
            await logger.info("Message \(i)").value
        }
        
        #expect(logger.entries.count == 1000)
        #expect(logger.entries.first?.message == "Message 100") // 1100 - 1000 = 100 offset
    }
    
    @MainActor
    @Test func testConcurrentLoggingThreadSafety() async throws {
        let logger = Logger.shared
        logger.clearLogs()
        
        let taskCount = 10
        let logsPerTask = 50
        
        let prefix = "CONCURRENCY_TEST_"
        // Use a TaskGroup for high parallelism
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<taskCount {
                group.addTask {
                    for i in 0..<logsPerTask {
                        await logger.info("\(prefix)Task \(t) - Log \(i)").value
                    }
                }
            }
        }
        
        let filteredCount = logger.entries.filter { $0.message.hasPrefix(prefix) }.count
        #expect(filteredCount == taskCount * logsPerTask)
    }

    @MainActor
    @Test func testLoggerWritesToInjectedURL() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerInjectionTest-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let logger = Logger(logFileURL: url)
        await logger.info("Injected destination message").value
        logger.logWriter.flush()

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("[INFO] Injected destination message"))
    }

    /// The suites of every package log through `Logger.shared`, so under a test runner the
    /// shared instance must resolve to a temp file - never the user's real ~/sync-cloud.log.
    @Test func testDefaultLogFileURLAvoidsRealLogUnderTests() {
        let url = Logger.defaultLogFileURL()
        let realLog = URL(fileURLWithPath: (NSString(string: "~")).expandingTildeInPath)
            .appendingPathComponent("sync-cloud.log")
        #expect(url.path != realLog.path)
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
