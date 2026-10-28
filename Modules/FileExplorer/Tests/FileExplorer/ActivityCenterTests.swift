import Foundation
import Testing
import Sync
@testable import FileExplorer

/// **Activity's Recent** (Run Room TE222, TE223, CL, CM, CS, R9, R13, R14): what is kept, what
/// folds, what lights the toolbar's dot, and when a row's Undo may act. A fresh center per test —
/// the app's is `.shared`.
@MainActor
@Suite struct ActivityCenterTests {

    private func message(_ text: String, _ severity: OperationBanner.Severity = .success) -> ActivityMessage {
        ActivityMessage(message: text, severity: severity)
    }

    /// Every message is kept, newest first, until there are fifty (CM).
    @Test func keepsTheNewestFiftyNewestFirst() {
        let center = ActivityCenter()
        for index in 1...55 { center.record(message("Deleted “\(index).md”"), seen: true) }
        #expect(center.recent.count == 50)
        #expect(center.recent.first?.message == "Deleted “55.md”")
        #expect(center.recent.last?.message == "Deleted “6.md”")
    }

    /// The same refusal again and again folds into one row with a count (R14) — but only in a row:
    /// another message between them starts a new one.
    @Test func repeatsInARowFold() {
        let center = ActivityCenter()
        let wait = "Wait for the merge to finish"
        for _ in 1...4 { center.record(message(wait, .warning), seen: true) }
        #expect(center.recent.count == 1)
        #expect(center.recent[0].repeats == 4)
        center.record(message("Deleted “a.md”"), seen: true)
        center.record(message(wait, .warning), seen: true)
        #expect(center.recent.map(\.repeats) == [1, 1, 4])
    }

    /// The dot is for a problem nobody saw (CS): a failure that showed where the reader was looking
    /// leaves none, a success never does, and opening Activity takes it away.
    @Test func onlyAnUnseenProblemLightsTheDot() {
        let center = ActivityCenter()
        center.record(message("Couldn’t move “a.md”", .error), seen: true)
        center.record(message("Merged “Photos”"), seen: false)
        #expect(!center.hasUnseenProblem)
        center.record(message("Saved 5 of 6 as PDF", .warning), seen: false)
        #expect(center.hasUnseenProblem)
        center.markSeen()
        #expect(!center.hasUnseenProblem)
    }

    /// The button and ⌘L reopen the last tab used — or Now while a problem waits (CT).
    @Test func opensOnTheLastTabOrNowForAProblem() {
        let center = ActivityCenter()
        center.tab = .log
        #expect(center.tabForOpening() == .log)
        center.record(message("Couldn’t copy 3 items", .error), seen: false)
        #expect(center.tabForOpening() == .now)
    }

    /// A history run is linked to the first message after it records, and to no later one — an
    /// old run's records must not hang off an unrelated message (R13).
    @Test func aRunIsLinkedOnceToTheMessageThatReportedIt() {
        let center = ActivityCenter()
        let run = (token: UUID(), runId: UUID(), recordedAt: Date())
        center.record(OperationBanner.success("Copied 12 items"), run: run, finishedRun: nil, seen: true)
        center.record(OperationBanner.success("Renamed “a.md”"), run: run, finishedRun: nil, seen: true)
        #expect(center.recent.map(\.runId) == [nil, run.runId])
    }

    /// **A run that said nothing is not the next message's run** (R13): a Sync All that ended in an
    /// alert posts no message, and the rename made minutes later must not offer its records.
    @Test func aRunRecordedLongBeforeTheMessageIsNotLinked() {
        let center = ActivityCenter()
        let now = Date()
        let old = (token: UUID(), runId: UUID(), recordedAt: now.addingTimeInterval(-ActivityCenter.runLinkWindow - 1))
        center.record(OperationBanner.success("Renamed “a.md”"), run: old, finishedRun: nil, seen: true, now: now)
        #expect(center.recent[0].runId == nil, "an old run's records hung off an unrelated message")
        let fresh = (token: UUID(), runId: UUID(), recordedAt: now.addingTimeInterval(-2))
        center.record(OperationBanner.success("Copied 12 items"), run: fresh, finishedRun: nil, seen: true, now: now)
        #expect(center.recent[0].runId == fresh.runId)
    }

    /// Show in Log spans the run that just ended, from its start (R13).
    @Test func theLogSpanReachesBackToTheRunsStart() {
        let center = ActivityCenter()
        let now = Date()
        let started = now.addingTimeInterval(-600)
        center.record(OperationBanner.success("Merged “Photos”"), run: nil,
                      finishedRun: (started: started, ended: now.addingTimeInterval(-1), cancelled: false), seen: true, now: now)
        #expect(center.recent[0].span.lowerBound == started)
        // A run that ended long before the message is not its run.
        center.record(OperationBanner.success("Renamed “a.md”"), run: nil,
                      finishedRun: (started: started, ended: now.addingTimeInterval(-100), cancelled: false), seen: true, now: now)
        #expect(center.recent[0].span.lowerBound == now.addingTimeInterval(-60))
    }

    /// **A row's Undo acts only while its step is the newest** (TE223): a newer step greys it with
    /// that step's name, undoing the newer one brings it back, and once it is undone itself it says
    /// so. Driven on a real `UndoManager` through the notifications the center watches.
    @Test func aRowsUndoFollowsTheStack() {
        let center = ActivityCenter()
        let undo = UndoManager()
        undo.groupsByEvent = false
        center.watchUndo(undo)
        let target = NSObject()
        // Each action registers its inverse, as the app's do — so a redo has something to redo.
        func reversible() { undo.registerUndo(withTarget: target) { _ in reversible() } }
        func step(_ name: String) {
            undo.beginUndoGrouping()
            reversible()
            undo.setActionName(name)
            undo.endUndoGrouping()
        }

        step("Move to Trash")
        center.record(OperationBanner.success("Deleted “Test3.md”", undoable: true), run: nil, finishedRun: nil, seen: true)
        let deleted = center.recent[0]
        #expect(center.undoRefusal(for: deleted) == nil)

        step("Rename")
        #expect(center.undoRefusal(for: deleted) == "Undo the newer “Rename” first.")

        undo.undo()
        #expect(center.undoRefusal(for: deleted) == nil, "undoing the newer step did not make this one the newest again")

        center.undo(deleted)
        #expect(!undo.canUndo && undo.canRedo, "the row's Undo did not reverse its step")
        #expect(center.undoRefusal(for: deleted)?.hasPrefix("Already undone") == true)

        undo.redo()
        #expect(center.undoRefusal(for: deleted) == nil)
    }

    /// **A run the reader stopped ends grey, not as a problem** (TE221): its sentence says so in the
    /// app's own words, or its run was cancelled — and it never lights the dot, unseen or not.
    @Test func aStopIsGreyAndNeverAProblem() {
        #expect(ActivityMessage.saysStopped("Stopped. Saved 2 of 6 as PDF."))
        #expect(ActivityMessage.saysStopped("Canceled. Saved 1 rotated copy"))
        #expect(ActivityMessage.saysStopped("Verify All canceled"))
        #expect(!ActivityMessage.saysStopped("Saved 6 files as PDF"))
        #expect(!ActivityMessage.saysStopped("Couldn’t copy “Stopped clock.jpg”"))

        let center = ActivityCenter()
        let now = Date()
        center.record(OperationBanner.warning("Copied 120 of 7,363 items"), run: nil,
                      finishedRun: (started: now.addingTimeInterval(-30), ended: now, cancelled: true),
                      seen: false, now: now)
        #expect(center.recent[0].isStopped, "a cancelled run's ending is not a stop")
        #expect(!center.hasUnseenProblem, "a stop the reader asked for lit the problem dot")
        center.record(OperationBanner.warning("Copied 7,000 of 7,363 items · 363 skipped"), run: nil,
                      finishedRun: (started: now.addingTimeInterval(-30), ended: now, cancelled: false),
                      seen: false, now: now)
        #expect(!center.recent[0].isStopped)
        #expect(center.hasUnseenProblem)
    }

    /// **Only the stopped run's own ending is a stop** (TE221): a failure a moment later is a
    /// problem, and lights the dot.
    @Test func aMessageAfterAStoppedRunsEndingIsNotAStop() {
        let center = ActivityCenter()
        let now = Date()
        let stopped = (started: now.addingTimeInterval(-30), ended: now.addingTimeInterval(-1), cancelled: true)
        center.record(OperationBanner.warning("Copied 120 of 7,363 items"), run: nil, finishedRun: stopped,
                      seen: false, now: now)
        #expect(center.recent[0].isStopped)
        center.record(OperationBanner(message: "Couldn’t move “a.md”", severity: .error), run: nil,
                      finishedRun: stopped, seen: false, now: now.addingTimeInterval(3))
        #expect(!center.recent[0].isStopped, "a failure after the stop was drawn as the stop")
        #expect(center.hasUnseenProblem)
    }

    /// **A stop that also failed is a problem** (TE221): the reader's Stop did not cause the
    /// failure, so it keeps its red and lights the dot.
    @Test func aStopThatFailedStaysAProblem() {
        let center = ActivityCenter()
        center.record(OperationBanner(message: "Canceled. Nothing was saved · 2 not done · 1 failed", severity: .error),
                      run: nil, finishedRun: nil, seen: false)
        #expect(!center.recent[0].isStopped)
        #expect(center.hasUnseenProblem)
        center.markSeen()
        center.record(OperationBanner.success("Stopped. Saved 2 of 6 as PDF. “a.key” couldn’t be saved."),
                      run: nil, finishedRun: nil, seen: false)
        #expect(!center.recent[0].isStopped, "a stop naming a failure was drawn grey")
        center.record(OperationBanner.warning("Stopped. Saved 2 of 6 as PDF."), run: nil, finishedRun: nil, seen: false)
        #expect(center.recent[0].isStopped)
    }

    /// A notification for a repeat folded into an earlier row picks out that row (TE227, R14).
    @Test func aFoldedRepeatsNotificationPicksOutItsRow() {
        let center = ActivityCenter()
        let first = OperationBanner.success("Copied “a.txt” to Backup")
        let second = OperationBanner.success("Copied “a.txt” to Backup")
        center.record(first, run: nil, finishedRun: nil, seen: false)
        center.record(second, run: nil, finishedRun: nil, seen: false)
        #expect(center.recent.count == 1)
        center.openWindow(highlighting: second.id)
        #expect(center.highlighted == center.recent[0].id)
    }

    /// A folded row's Show in Log covers its last repeat too (R13, R14).
    @Test func aFoldedRowsSpanCoversEveryRepeat() {
        let center = ActivityCenter()
        let now = Date()
        center.record(OperationBanner.warning("Wait for the merge to finish"), run: nil, finishedRun: nil,
                      seen: true, now: now)
        center.record(OperationBanner.warning("Wait for the merge to finish"), run: nil, finishedRun: nil,
                      seen: true, now: now.addingTimeInterval(120))
        #expect(center.recent.count == 1)
        #expect(center.recent[0].span.lowerBound == now.addingTimeInterval(-60))
        #expect(center.recent[0].span.upperBound == now.addingTimeInterval(125))
    }

    /// A message that offered no Undo has none in Recent either.
    @Test func noUndoUnlessTheMessageOfferedOne() {
        let center = ActivityCenter()
        center.record(OperationBanner.warning("Skipped 3 items"), run: nil, finishedRun: nil, seen: true)
        #expect(center.recent[0].undoStep == nil)
    }
}
