import Foundation
import Testing
import Sync
@testable import FileExplorer

/// Activity's Recent: what is kept, what folds, what lights the toolbar's dot, and when a row's
/// Undo may act. A fresh center per test, because the app's is `.shared`.
@MainActor
@Suite struct ActivityCenterTests {

    private func message(_ text: String, _ severity: OperationBanner.Severity = .success) -> ActivityMessage {
        ActivityMessage(message: text, severity: severity)
    }

    /// Every message is kept, newest first, up to the store's cap, which is also what survives a quit.
    @Test func keepsTheNewestUpToTheCapNewestFirst() {
        let center = ActivityCenter()
        let over = ActivityCenter.keep + 5
        for index in 1...over { center.record(message("Deleted “\(index).md”"), seen: true) }
        #expect(ActivityCenter.keep == ActivityMessageStore.maxMessages)
        #expect(center.recent.count == ActivityCenter.keep)
        #expect(center.recent.first?.message == "Deleted “\(over).md”")
        #expect(center.recent.last?.message == "Deleted “6.md”")
    }

    /// The same refusal again and again folds into one row with a count, but only in a row:
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

    /// The dot is for a problem nobody saw: a failure that showed where the reader was looking
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

    /// The button and ⌘L reopen the last tab used, or Events while a problem waits.
    @Test func opensOnTheLastTabOrEventsForAProblem() {
        let center = ActivityCenter()
        center.tab = .log
        #expect(center.tabForOpening() == .log)
        center.record(message("Couldn’t copy 3 items", .error), seen: false)
        #expect(center.tabForOpening() == .events)
    }

    /// A message reports the run its operation put on it, and only that run: a message with none
    /// (a refusal, or one after a rename that posted nothing) gets none, however soon it comes.
    @Test func aMessageReportsOnlyTheRunItsOperationNamed() {
        let center = ActivityCenter()
        let run = UUID()
        center.record(OperationBanner.success("Copied 12 items").reporting(run: run), finishedRun: nil, seen: true)
        center.record(OperationBanner.warning("Wait for the current operation to finish", log: .info),
                      finishedRun: nil, seen: true)
        #expect(center.recent.map(\.runId) == [nil, run])
    }

    /// Two runs that say the same words stay two rows: each is its own row in Events, and folding
    /// would leave the second run with no sentence.
    @Test func messagesThatReportRunsNeverFold() {
        let center = ActivityCenter()
        let first = UUID()
        let second = UUID()
        center.record(OperationBanner.success("Copied 2 items").reporting(run: first), finishedRun: nil, seen: true)
        center.record(OperationBanner.success("Copied 2 items").reporting(run: second), finishedRun: nil, seen: true)
        #expect(center.recent.map(\.runId) == [second, first])
        #expect(center.recent.allSatisfy { $0.repeats == 1 })
    }

    /// Show in Log spans the run that just ended, from its start.
    @Test func theLogSpanReachesBackToTheRunsStart() {
        let center = ActivityCenter()
        let now = Date()
        let started = now.addingTimeInterval(-600)
        center.record(OperationBanner.success("Merged “Photos”"),
                      finishedRun: (started: started, ended: now.addingTimeInterval(-1), cancelled: false), seen: true, now: now)
        #expect(center.recent[0].span.lowerBound == started)
        // A run that ended long before the message is not its run.
        center.record(OperationBanner.success("Renamed “a.md”"),
                      finishedRun: (started: started, ended: now.addingTimeInterval(-100), cancelled: false), seen: true, now: now)
        #expect(center.recent[0].span.lowerBound == now.addingTimeInterval(-60))
    }

    /// A row's Undo acts only while its step is the newest: a newer step greys it with
    /// that step's name, undoing the newer one brings it back, and once it is undone itself it says
    /// so. Driven on a real `UndoManager` through the notifications the center watches.
    @Test func aRowsUndoFollowsTheStack() {
        let center = ActivityCenter()
        let undo = UndoManager()
        undo.groupsByEvent = false
        center.watchUndo(undo)
        let target = NSObject()
        // Each action registers its inverse, as the app's do, so a redo has something to redo.
        func reversible() { undo.registerUndo(withTarget: target) { _ in reversible() } }
        func step(_ name: String) {
            undo.beginUndoGrouping()
            reversible()
            undo.setActionName(name)
            undo.endUndoGrouping()
        }

        step("Move to Trash")
        center.record(OperationBanner.success("Deleted “Test3.md”", undoable: true), finishedRun: nil, seen: true)
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

    /// A run the reader stopped ends grey, not as a problem: its sentence says so in the app's own
    /// words, or its run was cancelled, and it never lights the dot, seen or unseen.
    @Test func aStopIsGreyAndNeverAProblem() {
        #expect(ActivityMessage.saysStopped("Stopped. Saved 2 of 6 as PDF."))
        #expect(ActivityMessage.saysStopped("Canceled. Saved 1 rotated copy"))
        #expect(ActivityMessage.saysStopped("Verify All canceled"))
        #expect(!ActivityMessage.saysStopped("Saved 6 files as PDF"))
        #expect(!ActivityMessage.saysStopped("Couldn’t copy “Stopped clock.jpg”"))

        let center = ActivityCenter()
        let now = Date()
        center.record(OperationBanner.warning("Copied 120 of 7,363 items", log: .warn),
                      finishedRun: (started: now.addingTimeInterval(-30), ended: now, cancelled: true),
                      seen: false, now: now)
        #expect(center.recent[0].isStopped, "a cancelled run's ending is not a stop")
        #expect(!center.hasUnseenProblem, "a stop the reader asked for lit the problem dot")
        center.record(OperationBanner.warning("Copied 7,000 of 7,363 items · 363 skipped", log: .warn),
                      finishedRun: (started: now.addingTimeInterval(-30), ended: now, cancelled: false),
                      seen: false, now: now)
        #expect(!center.recent[0].isStopped)
        #expect(center.hasUnseenProblem)
    }

    /// Only the stopped run's own ending is a stop: a failure a moment later is a problem, and
    /// lights the dot.
    @Test func aMessageAfterAStoppedRunsEndingIsNotAStop() {
        let center = ActivityCenter()
        let now = Date()
        let stopped = (started: now.addingTimeInterval(-30), ended: now.addingTimeInterval(-1), cancelled: true)
        center.record(OperationBanner.warning("Copied 120 of 7,363 items", log: .warn), finishedRun: stopped,
                      seen: false, now: now)
        #expect(center.recent[0].isStopped)
        center.record(OperationBanner(message: "Couldn’t move “a.md”", severity: .error, log: .error),
                      finishedRun: stopped, seen: false, now: now.addingTimeInterval(3))
        #expect(!center.recent[0].isStopped, "a failure after the stop was drawn as the stop")
        #expect(center.hasUnseenProblem)
    }

    /// A stop that also failed is a problem: the reader's Stop didn't cause the failure, so it
    /// keeps its red and lights the dot.
    @Test func aStopThatFailedStaysAProblem() {
        let center = ActivityCenter()
        center.record(OperationBanner(message: "Canceled. Nothing was saved · 2 not done · 1 failed", severity: .error, log: .error),
                      finishedRun: nil, seen: false)
        #expect(!center.recent[0].isStopped)
        #expect(center.hasUnseenProblem)
        center.markSeen()
        center.record(OperationBanner.success("Stopped. Saved 2 of 6 as PDF. “a.key” couldn’t be saved."),
                      finishedRun: nil, seen: false)
        #expect(!center.recent[0].isStopped, "a stop naming a failure was drawn grey")
        center.record(OperationBanner.warning("Stopped. Saved 2 of 6 as PDF.", log: .warn), finishedRun: nil, seen: false)
        #expect(center.recent[0].isStopped)
    }

    /// A notification for a repeat folded into an earlier row picks out that row.
    @Test func aFoldedRepeatsNotificationPicksOutItsRow() {
        let center = ActivityCenter()
        let first = OperationBanner.success("Copied “a.txt” to Backup")
        let second = OperationBanner.success("Copied “a.txt” to Backup")
        center.record(first, finishedRun: nil, seen: false)
        center.record(second, finishedRun: nil, seen: false)
        #expect(center.recent.count == 1)
        center.openWindow(highlighting: second.id)
        #expect(center.highlighted == center.recent[0].id)
    }

    /// A folded row's Show in Log covers its last repeat too.
    @Test func aFoldedRowsSpanCoversEveryRepeat() {
        let center = ActivityCenter()
        let now = Date()
        center.record(OperationBanner.warning("Wait for the merge to finish", log: .warn), finishedRun: nil,
                      seen: true, now: now)
        center.record(OperationBanner.warning("Wait for the merge to finish", log: .warn), finishedRun: nil,
                      seen: true, now: now.addingTimeInterval(120))
        #expect(center.recent.count == 1)
        #expect(center.recent[0].span.lowerBound == now.addingTimeInterval(-60))
        #expect(center.recent[0].span.upperBound == now.addingTimeInterval(125))
    }

    /// A message that offered no Undo has none in Recent either.
    @Test func noUndoUnlessTheMessageOfferedOne() {
        let center = ActivityCenter()
        center.record(OperationBanner.warning("Skipped 3 items", log: .warn), finishedRun: nil, seen: true)
        #expect(center.recent[0].undoStep == nil)
    }

    /// A problem the capsule shows keeps its dot until the message goes into Activity.
    @Test func aCapsuleProblemsDotWaitsForItsLanding() {
        let center = ActivityCenter()
        let warning = OperationBanner.warning("Moved 2 of 3 items to the Trash", log: .warn)
        center.record(warning, finishedRun: nil, seen: false, dotWaits: true)
        #expect(center.hasUnseenProblem)
        #expect(!center.showsDot, "the dot showed while the capsule was still showing the problem")
        center.releaseDot()
        #expect(center.showsDot)
    }

    /// A release names the message it is for: another message's leaves the hold in place.
    @Test func aReleaseForAnotherMessageKeepsTheHold() {
        let center = ActivityCenter()
        let warning = OperationBanner.warning("Moved 2 of 3 items to the Trash", log: .warn)
        center.record(warning, finishedRun: nil, seen: false, dotWaits: true)
        center.releaseDot(heldFor: UUID())
        #expect(center.dotHeldFor == warning.id && !center.showsDot)
        center.releaseDot(heldFor: warning.id)
        #expect(center.dotHeldFor == nil && center.showsDot)
    }

    /// A hold never hides a dot that was already showing for an older problem.
    @Test func aHoldLeavesAnOlderProblemsDotShowing() {
        let center = ActivityCenter()
        center.record(message("Copy failed", .error), seen: false)
        center.record(message("Moved 2 of 3", .warning), seen: false, dotWaits: true)
        #expect(center.dotHeldFor == nil)
        #expect(center.showsDot)
    }

    /// Opening Activity sees the problem, held or not; Clear drops the hold with the rows.
    @Test func seeingOrClearingDropsTheHold() {
        let center = ActivityCenter()
        center.record(message("Moved 2 of 3", .warning), seen: false, dotWaits: true)
        center.markSeen()
        #expect(center.dotHeldFor == nil && !center.showsDot)
        center.record(message("Copy failed", .error), seen: false, dotWaits: true)
        center.clear()
        #expect(center.dotHeldFor == nil && !center.showsDot)
    }

    /// A success never lights the dot, so it holds nothing.
    @Test func aSuccessHoldsNoDot() {
        let center = ActivityCenter()
        center.record(message("Moved “Untitled.md” to the Trash"), seen: false, dotWaits: true)
        #expect(center.dotHeldFor == nil && !center.showsDot)
    }

    /// The arriving message's row flashes; a repeat folded into an earlier row flashes that row.
    @Test func aFlashPicksOutTheArrivingRowAndFiresOncePerArrival() {
        let center = ActivityCenter()
        let first = OperationBanner.success("Copied “a.txt” to Backup")
        let second = OperationBanner.success("Copied “a.txt” to Backup")
        center.record(first, finishedRun: nil, seen: true)
        center.record(second, finishedRun: nil, seen: true)
        center.flashRow(for: second.id)
        #expect(center.flashedRow == center.recent[0].id)
        #expect(center.flashes == 1)
        center.flashRow(for: second.id)
        #expect(center.flashes == 2, "a second arrival of the same row must flash again")
    }
}
