import Testing
import Foundation
@testable import Events

@Suite struct EventsTests {
    
    @MainActor
    @Test func testLoggerInfo() async throws {
        let logger = Logger.shared
        logger.clearLogs()
        
        logger.info("Test info message")
        
        #expect(logger.entries.count == 1)
        #expect(logger.entries.first?.level == .info)
        #expect(logger.entries.first?.message == "Test info message")
    }
    
    @MainActor
    @Test func testLoggerErrorWithAlert() async throws {
        let logger = Logger.shared
        logger.clearLogs()
        
        logger.error("Critical failure", showAlert: true)
        
        #expect(logger.entries.last?.level == .error)
        #expect(logger.currentAlertError == "Critical failure")
    }
    
    @MainActor
    @Test func testLoggerMemoryLimit() async throws {
        let logger = Logger.shared
        logger.clearLogs()
        
        // Log 1100 entries (limit is 1000)
        for i in 0..<1100 {
            logger.info("Message \(i)")
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
                        await logger.info("\(prefix)Task \(t) - Log \(i)")
                    }
                }
            }
        }
        
        let filteredCount = logger.entries.filter { $0.message.hasPrefix(prefix) }.count
        #expect(filteredCount == taskCount * logsPerTask)
    }
}
