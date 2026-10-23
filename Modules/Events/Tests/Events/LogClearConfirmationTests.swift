import Testing
import Foundation
@testable import Events

/// Pins that clearing the log asks first, and honours the answer.
///
/// The Activity Log's trash button and Settings ▸ Advanced ▸ Clear Log both emptied the session and
/// truncated the file on disk on one click. Both call `clearIfConfirmed` now, and `clearLogs` is
/// internal, so a door that skips the question no longer compiles outside this package. Every
/// Logger here writes a scratch file — never the real `~/sync-cloud.log`.
@MainActor
@Suite struct LogClearConfirmationTests {

    /// A logger on a scratch file, holding one line in memory and on disk.
    private func makeLogger() async -> (Logger, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogClearConfirmation-\(UUID().uuidString).log")
        let logger = Logger(logFileURL: url)
        await logger.info("a line worth keeping").value
        logger.flushToDisk()
        return (logger, url)
    }

    private func bytesOnDisk(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    @Test func decliningKeepsTheEntriesAndTheFile() async {
        let (logger, url) = await makeLogger()
        defer { removeLogFiles(at: url) }
        #expect(logger.entries.count == 1)
        #expect(bytesOnDisk(url) > 0)
        var asked = 0

        let cleared = logger.clearIfConfirmed { asked += 1; return false }
        logger.flushToDisk()

        #expect(cleared == false)
        #expect(asked == 1)
        #expect(logger.entries.count == 1)
        #expect(bytesOnDisk(url) > 0)
    }

    @Test func confirmingClearsTheEntriesAndTheFile() async {
        let (logger, url) = await makeLogger()
        defer { removeLogFiles(at: url) }

        let cleared = logger.clearIfConfirmed { true }
        logger.flushToDisk()

        #expect(cleared)
        #expect(logger.entries.isEmpty)
        #expect(bytesOnDisk(url) == 0)
    }

    @Test func theQuestionComesBeforeAnythingIsRemoved() async {
        let (logger, url) = await makeLogger()
        defer { removeLogFiles(at: url) }
        var entriesWhenAsked = -1

        logger.clearIfConfirmed { entriesWhenAsked = logger.entries.count; return true }

        #expect(entriesWhenAsked == 1)
        #expect(logger.entries.isEmpty)
    }

    /// One name for the control, wherever it is spelled. Pinned as a literal so a rename is a
    /// decision, not a drift.
    @Test func theControlHasOneName() {
        #expect(Logger.clearLogName == "Clear Log")
    }
}
