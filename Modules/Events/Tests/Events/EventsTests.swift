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

    /// A synchronous burst of log calls must land in call order in memory AND on disk. The old
    /// per-call unstructured tasks carried the entries themselves, so scheduling could reorder
    /// lines; the ordered handoff queue makes this deterministic.
    @MainActor
    @Test func testBurstLoggingPreservesCallOrderInMemoryAndOnDisk() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerOrderTest-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let logger = Logger(logFileURL: url)
        let expected = (0..<200).map { "ORDER \($0)" }
        var lastTask: Task<Void, Never>?
        for message in expected {
            lastTask = logger.info(message)
        }
        // All entries were handed off synchronously above, so awaiting any one flush task
        // guarantees the whole burst is visible.
        await lastTask?.value

        #expect(logger.entries.map(\.message) == expected)

        logger.logWriter.flush()
        let diskOrder = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line in line.range(of: "ORDER ").map { String(line[$0.lowerBound...]) } }
        #expect(diskOrder == expected)
    }

    /// clearLogs() must also drop entries still sitting in the handoff queue: a burst logged
    /// just before the clear previously flushed into `entries` afterward, so "cleared" lines
    /// resurrected in the Activity Log UI.
    @MainActor
    @Test func testClearLogsDropsPendingEntriesFromPriorBurst() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerClearPendingTest-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let logger = Logger(logFileURL: url)
        // Enqueue a burst but do NOT await: the entries are pending, their flush tasks have not
        // run yet when clearLogs() executes (no suspension point between the loop and the clear).
        for i in 0..<50 {
            logger.info("PRE-CLEAR \(i)")
        }
        logger.clearLogs()

        await logger.info("POST-CLEAR").value

        #expect(logger.entries.map(\.message) == ["POST-CLEAR"])

        // Disk agrees: the pre-clear appends were enqueued before the truncation on the same
        // serial queue, so only the post-clear line survives.
        logger.logWriter.flush()
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("POST-CLEAR"))
        #expect(!contents.contains("PRE-CLEAR"))
    }

    /// Pins the on-disk line format: "[yyyy-MM-dd HH:mm:ss.SSS] [LEVEL] message". The timestamp
    /// renders in the local timezone, so assert the shape rather than exact digits.
    @Test func testFormattedStringPinsDiskLineFormat() {
        let entry = LogEntry(level: .warning, message: "low disk space")
        let pattern = /^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] \[WARN\] low disk space$/
        #expect(entry.formattedString.wholeMatch(of: pattern) != nil)
    }

    /// warning() and error() append a "| Location: file:line / function" suffix; info() and
    /// debug() must not (their messages land verbatim).
    @MainActor
    @Test func testWarningAndErrorAppendCallSiteLocation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerLocationTest-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let logger = Logger(logFileURL: url)
        await logger.warning("careful").value
        await logger.error("broken").value
        await logger.debug("just details").value

        let messages = logger.entries.map(\.message)
        #expect(messages.count == 3)
        #expect(messages[0].hasPrefix("careful | Location: EventsTests.swift:"))
        #expect(messages[0].hasSuffix("/ testWarningAndErrorAppendCallSiteLocation()"))
        #expect(messages[1].hasPrefix("broken | Location: EventsTests.swift:"))
        #expect(messages[2] == "just details")
        #expect(logger.entries[2].level == .debug)
    }

    /// `messageBody`/`messageLocation` split the developer "| Location:" tail from the human
    /// message so the Activity Log can show the message prominently and the location dimmed.
    /// An entry without the tail (info/debug) reports the whole message as the body and nil location.
    @Test func testMessageBodyAndLocationSplit() {
        let withLocation = LogEntry(level: .warning, message: "careful | Location: Foo.swift:42 / bar()")
        #expect(withLocation.messageBody == "careful")
        #expect(withLocation.messageLocation == "Foo.swift:42 / bar()")

        let plain = LogEntry(level: .info, message: "Synced 3 items")
        #expect(plain.messageBody == "Synced 3 items")
        #expect(plain.messageLocation == nil)
    }

    /// The public `flushToDisk()` barrier must make a just-logged line durable on disk. This is
    /// what `applicationShouldTerminate` relies on to preserve the quit-decision breadcrumb (and
    /// any in-flight operation's own lines) past a `.background`-qos writer that has no implicit
    /// flush on quit.
    @MainActor
    @Test func testFlushToDiskMakesJustLoggedLineVisibleOnDisk() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggerFlushToDiskTest-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let logger = Logger(logFileURL: url)
        // Do NOT await the returned task: flushToDisk() must drain the writer's background queue
        // on its own, exactly as it does at termination when no await is possible.
        logger.warning("User chose Quit Anyway with 3 active file operation(s)")
        logger.flushToDisk()

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("[WARN] User chose Quit Anyway with 3 active file operation(s)"))
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
