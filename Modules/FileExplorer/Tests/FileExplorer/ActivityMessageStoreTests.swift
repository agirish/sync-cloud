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

    /// A trim keeps the lines a newer build wrote, so an older build never deletes them, and drops
    /// lines no build can read.
    @Test func aTrimKeepsANewerBuildsLinesAndDropsBrokenOnes() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityMessageStore(fileURL: url)
        store.save(message("Too old", at: Date().addingTimeInterval(-ActivityMessageStore.maxAge - 60)))
        store.flush()
        let newer = #"{"version":99,"id":"from-a-newer-build"}"#
        let broken = #"{"message":"half a li"#
        try append(url, newer + "\n" + broken + "\n")
        #expect(ActivityMessageStore(fileURL: url).load().isEmpty)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("Too old"), "the trim didn't rewrite the file")
        #expect(text.contains(newer), "the trim dropped a line from a newer build")
        #expect(!text.contains(broken), "the trim kept a line no build can read")
    }

    /// Half a line left by a crash doesn't swallow the next message: it starts a line of its own.
    @Test func aLineCutShortDoesNotSwallowTheNext() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try append(url, #"{"message":"cut sh"#)
        let store = ActivityMessageStore(fileURL: url)
        store.save(message("Saved 1 PDF"))
        store.flush()
        #expect(ActivityMessageStore(fileURL: url).load().map(\.message) == ["Saved 1 PDF"])
    }

    /// A long session trims the file as it goes, rather than leaving it all for the next launch.
    @Test func aLongSessionTrimsAsItGoes() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityMessageStore(fileURL: url)
        var row = message("Skipped 3 items", severity: .warning)
        for count in 1...(ActivityMessageStore.maxMessages * 2 + 10) {
            row.repeats = count
            store.save(row)
        }
        store.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count
        #expect(lines <= ActivityMessageStore.maxMessages + 1, "\(lines) lines: nothing trimmed the file mid-session")
        #expect(ActivityMessageStore(fileURL: url).load().first?.repeats == ActivityMessageStore.maxMessages * 2 + 10)
    }

    /// Clear empties the file, the earlier sessions' messages too.
    @Test func clearEmptiesTheFile() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ActivityMessageStore(fileURL: url)
        let center = ActivityCenter()
        center.attachMessages(store)
        center.record(OperationBanner.success("Copied 2 items"), finishedRun: nil, seen: true)
        store.flush()
        #expect(ActivityMessageStore(fileURL: url).load().count == 1, "the message was never written")
        center.clear()
        store.flush()
        #expect(ActivityMessageStore(fileURL: url).load().isEmpty)
    }

    /// Forgetting the runs' messages reads the file as it is: another copy's other lines survive.
    @Test func forgettingRunsKeepsAnotherCopysOtherLines() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let mine = ActivityMessageStore(fileURL: url)
        let center = ActivityCenter()
        center.attachMessages(mine)
        let theirs = ActivityMessageStore(fileURL: url)
        theirs.save(message("Couldn’t move “a.pdf”", severity: .error))
        theirs.save(message("Copied 4 items", runId: UUID()))
        theirs.flush()
        center.forgetRunMessages()
        mine.flush()
        #expect(ActivityMessageStore(fileURL: url).load().map(\.message) == ["Couldn’t move “a.pdf”"])
    }

    private func append(_ url: URL, _ text: String) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
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

    /// A message this session never folds into a row from an earlier one.
    @Test func aNewMessageNeverFoldsIntoAnEarlierSessionsRow() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let earlier = ActivityMessageStore(fileURL: url)
        var old = message("Skipped 3 items", at: Date().addingTimeInterval(-60), severity: .warning)
        old.followUps = []
        old.detail = nil
        earlier.save(old)
        earlier.flush()
        let center = ActivityCenter()
        center.attachMessages(ActivityMessageStore(fileURL: url))
        center.record(ActivityMessage(message: "Skipped 3 items", severity: .warning), seen: true)
        #expect(center.recent.count == 2)
        #expect(center.recent.allSatisfy { $0.repeats == 1 })
    }

    /// The same message published again with its words amended is one row, updated.
    @Test func theSameMessageAgainUpdatesItsRow() {
        let center = ActivityCenter()
        var banner = OperationBanner.success("Moved 3 items to the Trash")
        center.record(banner, finishedRun: nil, seen: true)
        banner.message += ". Includes 2 items the filter is hiding"
        center.record(banner, finishedRun: nil, seen: true)
        #expect(center.recent.map(\.message) == ["Moved 3 items to the Trash. Includes 2 items the filter is hiding"])
    }

    /// What this launch said before the store was attached is kept too.
    @Test func whatWasSaidBeforeAttachIsKept() {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let center = ActivityCenter()
        center.record(OperationBanner.success("Saved 1 PDF"), finishedRun: nil, seen: true)
        let store = ActivityMessageStore(fileURL: url)
        center.attachMessages(store)
        store.flush()
        #expect(ActivityMessageStore(fileURL: url).load().map(\.message) == ["Saved 1 PDF"])
    }

    /// A problem waiting when Activity opens is pointed at, so a filter left on can't hide it.
    @Test func aWaitingProblemIsPointedAt() {
        let center = ActivityCenter()
        center.record(OperationBanner.success("Copied 2 items"), finishedRun: nil, seen: false)
        center.record(OperationBanner.error("Couldn’t move “a.pdf”", log: .error), finishedRun: nil, seen: false)
        let problem = center.recent[0].id
        center.record(OperationBanner.success("Saved 1 PDF"), finishedRun: nil, seen: false)
        center.tab = .log
        #expect(center.tabForOpening() == .events)
        #expect(center.pointRequest == problem)
    }

    /// One-way sync's History… is kept until Events takes it, so it holds when the window opens later.
    @Test func oneWaySyncHistoryWaitsForEvents() {
        let center = ActivityCenter()
        center.tab = .log
        center.showOneWaySyncHistory()
        #expect(center.tab == .events)
        #expect(center.wantsOneWaySyncHistory)
    }

    /// A refusal is drawn as a warning, and says it is one.
    @Test func aRefusalIsAWarningThatSaysSo() {
        let refusal = OperationBanner.refusal("Can’t swap panes while an operation is running", log: .info)
        #expect(refusal.severity == .warning)
        #expect(refusal.isRefusal)
        #expect(!OperationBanner.warning("Skipped 3 items", log: .warn).isRefusal)
    }
}
