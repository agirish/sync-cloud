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
}
