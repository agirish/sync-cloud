import Testing
import AppKit
import Foundation
@testable import Events

/// Pins that clearing the log asks first, and honours the answer.
///
/// Clearing empties the session and truncates the file, and can't be undone. Both buttons (the
/// Activity Log's trash, Settings ▸ Advanced ▸ Clear Log) call `clearIfConfirmed`, and `clearLogs`
/// is internal, so a button that skips the question doesn't compile outside this package. Every
/// Logger here writes a scratch file, never the real `~/sync-cloud.log`.
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

    /// Escape cancels Clear Log. Its Cancel answers Return, which takes Escape from it, so the
    /// alert runs with a key monitor; this pins the monitor's choice on real key events.
    /// `NativeAlerts.escapeAnswer` is the same rule in Design.
    @Test func escapePressesCancelAndNothingElse() throws {
        let alert = NSAlert()
        alert.addButton(withTitle: Logger.clearLogName)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        // A stand-in window: ordering the alert's own in outside `runModal` clears its buttons' keys.
        let standIn = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 10, height: 10),
                               styleMask: [.titled], backing: .buffered, defer: false)
        standIn.isReleasedWhenClosed = false
        standIn.orderFrontRegardless()
        defer { standIn.close() }
        try #require(standIn.windowNumber > 0, "no window number — the events would name no window")
        func key(_ characters: String, _ code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                 repeat isARepeat: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                          windowNumber: standIn.windowNumber, context: nil,
                                          characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: isARepeat, keyCode: code))
        }
        func answer(_ event: NSEvent) -> NSButton? {
            Logger.escapeAnswer(for: event, window: standIn, buttons: alert.buttons)
        }

        #expect(answer(try key("\u{1b}", 53))?.title == "Cancel")
        #expect(answer(try key("\r", 36)) == nil)
        #expect(answer(try key("\u{1b}", 53, repeat: true)) == nil)
        #expect(answer(try key("\u{1b}", 53, modifiers: .option)) == nil)
        #expect(answer(try key(".", 47, modifiers: .command))?.title == "Cancel", "⌘. does not cancel")
        let elsewhere = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 10, height: 10),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        elsewhere.isReleasedWhenClosed = false
        elsewhere.orderFrontRegardless()
        defer { elsewhere.close() }
        let aimedElsewhere = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: elsewhere.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(answer(aimedElsewhere) == nil, "Escape at another window cancelled Clear Log")
        // Never the confirm: with a button holding Escape, the monitor stays out.
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.buttons.first?.keyEquivalent = "\r"
        #expect(answer(try key("\u{1b}", 53)) == nil, "Escape pressed Clear Log's confirm")
    }

    /// One name for the control, wherever it is spelled. Pinned as a literal so a rename is a
    /// decision, not a drift.
    @Test func theControlHasOneName() {
        #expect(Logger.clearLogName == "Clear Log")
    }
}
