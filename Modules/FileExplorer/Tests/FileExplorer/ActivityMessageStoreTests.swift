import Foundation
import Testing
import Sync
@testable import FileExplorer

/// Activity's messages kept across quits: every one but a refusal, without the Undo and Download a
/// later session can't honour, the newest line for each id winning, inside 90 days and 500 rows.
@MainActor
@Suite struct ActivityMessageStoreTests {

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("activity-messages-\(UUID().uuidString).jsonl")
    }

    private func message(_ text: String, at date: Date = Date(), severity: OperationBanner.Severity = .success,
                         runId: UUID? = nil) -> ActivityMessage {
        var message = ActivityMessage(date: date, message: text, detail: "detail of \(text)", severity: severity,
                                      followUps: [.revealInBrowse(["/A/\(text)"]), .download("/A/\(text)")],
                                      undoStep: 7, runId: runId, span: date.addingTimeInterval(-60)...date)
        message.isStopped = text.hasPrefix("Stopped")
        return message
    }

    /// What is kept comes back as it was said, but with no Undo, whose step belonged to the session
    /// that wrote it, and no Download, whose path may name another file by now.
    @Test func aKeptMessageComesBackWithoutUndoOrDownload() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityMessageStore(fileURL: url)
        let run = UUID()
        let said = message("Copied 3 items", runId: run)
        store.save(said)
        store.flush()
        let back = try #require(ActivityMessageStore(fileURL: url).load().first)
        #expect(back.id == said.id)
        #expect(back.message == "Copied 3 items")
        #expect(back.detail == "detail of Copied 3 items")
        #expect(back.runId == run)
        #expect(back.undoStep == nil)
        #expect(back.followUps == [.revealInBrowse(["/A/Copied 3 items"])])
        #expect(abs(back.date.timeIntervalSince(said.date)) < 0.001)
        #expect(abs(back.span.lowerBound.timeIntervalSince(said.span.lowerBound)) < 0.001)
    }

    /// A refusal is shown this session and never written.
    @Test func aRefusalIsNeverKept() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityMessageStore(fileURL: url)
        var refusal = message("Wait for the current operation to finish before syncing", severity: .warning)
        refusal.isRefusal = true
        store.save(refusal)
        store.save(message("Couldn’t move “a.pdf”", severity: .error))
        store.flush()
        #expect(ActivityMessageStore(fileURL: url).load().map(\.message) == ["Couldn’t move “a.pdf”"])
    }

    /// A repeat folding into a row writes the row again; the newest line for its id wins.
    @Test func theNewestLineForARowWins() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityMessageStore(fileURL: url)
        var row = message("Skipped 3 items", severity: .warning)
        store.save(row)
        row.repeats = 3
        store.save(row)
        store.flush()
        let back = ActivityMessageStore(fileURL: url).load()
        #expect(back.count == 1)
        #expect(back.first?.repeats == 3)
    }

    /// Older than 90 days goes, and past the newest 500 goes, newest first.
    @Test func theOldAndThePastTheCapGo() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityMessageStore(fileURL: url)
        let now = Date()
        store.save(message("Too old", at: now.addingTimeInterval(-ActivityMessageStore.maxAge - 60)))
        for i in 0..<(ActivityMessageStore.maxMessages + 5) {
            store.save(message("Message \(i)", at: now.addingTimeInterval(Double(-i))))
        }
        store.flush()
        let back = ActivityMessageStore(fileURL: url).load(now: now)
        #expect(back.count == ActivityMessageStore.maxMessages)
        #expect(back.first?.message == "Message 0")
        #expect(!back.contains { $0.message == "Too old" })
    }

    /// A trim keeps the lines this build can't read, so an older build never deletes a newer one's.
    @Test func aTrimKeepsLinesThisBuildCannotRead() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityMessageStore(fileURL: url)
        store.save(message("Too old", at: Date().addingTimeInterval(-ActivityMessageStore.maxAge - 60)))
        store.flush()
        let foreign = #"{"version":99,"id":"from-a-newer-build"}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((foreign + "\n").utf8))
        try handle.close()
        #expect(ActivityMessageStore(fileURL: url).load().isEmpty)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("Too old"), "the trim didn't rewrite the file")
        #expect(text.contains(foreign), "the trim dropped a line from a newer build")
    }

    /// Clear empties the file, the earlier sessions' messages too.
    @Test func clearEmptiesTheFile() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityMessageStore(fileURL: url)
        let center = ActivityCenter()
        center.attachMessages(store)
        center.record(OperationBanner.success("Copied 2 items"), finishedRun: nil, seen: true)
        center.clear()
        store.flush()
        #expect(ActivityMessageStore(fileURL: url).load().isEmpty)
    }

    // MARK: ActivityCenter

    /// At launch the kept messages come in under this session's, newest first, and light no dot.
    @Test func keptMessagesComeInUnderThisSessionsWithNoDot() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let earlier = ActivityMessageStore(fileURL: url)
        earlier.save(message("Couldn’t move “a.pdf”", at: Date().addingTimeInterval(-3_600), severity: .error))
        earlier.flush()

        let center = ActivityCenter()
        center.record(OperationBanner.success("Saved 1 PDF"), finishedRun: nil, seen: true)
        center.attachMessages(ActivityMessageStore(fileURL: url))
        #expect(center.recent.map(\.message) == ["Saved 1 PDF", "Couldn’t move “a.pdf”"])
        #expect(!center.hasUnseenProblem, "a problem from an earlier session lit the dot")
    }

    /// The center keeps what it records, but not a refusal.
    @Test func theCenterKeepsAllButRefusals() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityMessageStore(fileURL: url)
        let center = ActivityCenter()
        center.attachMessages(store)
        center.record(OperationBanner.refusal("Wait for the current operation to finish before syncing", log: .info),
                      finishedRun: nil, seen: true)
        center.record(OperationBanner.success("Copied 2 items"), finishedRun: nil, seen: true)
        store.flush()
        #expect(center.recent.count == 2)
        #expect(center.recent.last?.isRefusal == true)
        #expect(ActivityMessageStore(fileURL: url).load().map(\.message) == ["Copied 2 items"])
    }

    /// Clearing Sync History forgets the messages that reported its runs, and keeps the rest.
    @Test func forgettingRunsDropsOnlyTheirMessages() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityMessageStore(fileURL: url)
        let center = ActivityCenter()
        center.attachMessages(store)
        center.record(OperationBanner.success("Copied 2 items").reporting(run: UUID()), finishedRun: nil, seen: true)
        center.record(OperationBanner.success("Saved 1 PDF"), finishedRun: nil, seen: true)
        center.forgetRunMessages()
        store.flush()
        #expect(center.recent.map(\.message) == ["Saved 1 PDF"])
        #expect(ActivityMessageStore(fileURL: url).load().map(\.message) == ["Saved 1 PDF"])
    }

    /// A refusal is drawn as a warning, and says it is one.
    @Test func aRefusalIsAWarningThatSaysSo() {
        let refusal = OperationBanner.refusal("Can’t swap panes while an operation is running", log: .info)
        #expect(refusal.severity == .warning)
        #expect(refusal.isRefusal)
        #expect(!OperationBanner.warning("Skipped 3 items", log: .warn).isRefusal)
    }
}
