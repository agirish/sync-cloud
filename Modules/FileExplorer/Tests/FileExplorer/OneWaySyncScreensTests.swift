import Foundation
import Testing
import Sync
@testable import FileExplorer

/// What one-way sync's pill, History and sheets say, as words: the pill's rung and what the bar
/// reserves for it, History's headline and outcomes, times past today, and counts of one.
@MainActor
@Suite struct OneWaySyncScreensTests {
    typealias Scratch = OneWaySyncControllerTests.Scratch

    func controller(_ scratch: Scratch, state: OneWaySyncSavedState = OneWaySyncSavedState(),
                    refusal: OneWaySyncLaunchRefusal? = .testRunner) -> (OneWaySyncController, ActivityCenter) {
        let center = ActivityCenter()
        let controller = OneWaySyncController(store: nil, center: center, cloudApps: CloudAppMonitor(), refusal: refusal)
        controller.adopt(scratch.record, state: state)
        return (controller, center)
    }

    static func waiting(_ center: ActivityCenter) {
        center.raiseOneWaySync([OneWaySyncNotice(id: "ows:file:Legal/Will.pdf", kind: .needsYou, scope: .file(folder: "Legal", path: "Legal/Will.pdf"),
                                                 title: "Will.pdf was edited in Dropbox", raisedAt: Date())])
    }

    // MARK: The pill

    /// The page's ladder, first that applies: a running sync's activity never hides what needs you.
    @Test func whatNeedsYouOutranksWhatTheSyncIsDoing() throws {
        let scratch = try Scratch()
        let (controller, center) = controller(scratch, state: OneWaySyncSavedState(lastSyncAt: 1_789_990_000))
        controller.activity = "Syncing 12"
        let pill = OneWaySyncStatusPill(controller: controller, center: center, onSetUp: {})
        #expect(pill.title == "Syncing 12")
        Self.waiting(center)
        #expect(pill.title == "1 needs you · Review…")
    }

    /// A stop saved before a relaunch, with nothing in memory saying so, is still a stop.
    @Test func aSavedStopRowIsTheStoppedRung() throws {
        let scratch = try Scratch()
        let (controller, center) = controller(scratch)
        center.raiseOneWaySync([OneWaySyncRows.stop(.dropboxNotRunning, at: Date())])
        Self.waiting(center)
        #expect(controller.stop == nil)
        #expect(controller.ladder == .stopped("Sync stopped: the Dropbox app isn’t running"))
    }

    /// What the differences bar reserves is what the pill says now, not the widest it could say, so
    /// a short pill costs Verify and Review as little room as it can.
    @Test func theBarReservesWhatThePillSays() throws {
        let scratch = try Scratch()
        let (controller, center) = controller(scratch, state: OneWaySyncSavedState(lastSyncAt: 1_789_990_000), refusal: nil)
        let synced = OneWaySyncStatusPill.width(controller: controller, scale: 1)
        Self.waiting(center)
        let waiting = OneWaySyncStatusPill.width(controller: controller, scale: 1)
        #expect(waiting > 0 && synced > 0)
        #expect(waiting < 200)
        #expect(waiting != synced)
        #expect(OneWaySyncStatusPill.width(controller: controller, scale: 1.3) > waiting)
        // The longest words are capped, and cut short with the whole in the tooltip.
        controller.stop = .dropboxNotUploading
        #expect(OneWaySyncStatusPill.width(controller: controller, scale: 1) == OneWaySyncStatusPill.maxWidth)
        // A copy that may not sync and was never set up draws nothing, and is priced at nothing.
        let (unset, _) = self.controller(scratch, refusal: .outsideApplications(bundlePath: "/tmp/SyncCloud.app"))
        unset.adopt(nil, state: nil)
        #expect(OneWaySyncStatusPill.width(controller: unset, scale: 1) == 0)
    }

    /// Before setup the pill shows only for an iCloud pane compared with a Dropbox one; once set
    /// up, in every Compare.
    @Test func beforeSetupThePillShowsOnlyForICloudAndDropbox() throws {
        let scratch = try Scratch()
        let (controller, _) = controller(scratch, refusal: nil)
        controller.adopt(nil, state: nil)
        #expect(OneWaySyncStatusPill.isShown(controller: controller, paneTypes: [.dropBox, .iCloud]))
        #expect(!OneWaySyncStatusPill.isShown(controller: controller, paneTypes: [.oneDrive, .localFolder]))
        #expect(!OneWaySyncStatusPill.isShown(controller: controller, paneTypes: [.iCloud, .iCloud]))
        controller.adopt(scratch.record, state: OneWaySyncSavedState())
        #expect(OneWaySyncStatusPill.isShown(controller: controller, paneTypes: [.oneDrive, .localFolder]))
        let (refused, _) = self.controller(scratch, refusal: .outsideApplications(bundlePath: "/tmp/SyncCloud.app"))
        refused.adopt(nil, state: nil)
        #expect(!OneWaySyncStatusPill.isShown(controller: refused, paneTypes: [.dropBox, .iCloud]))
    }

    /// A stop whose cause has cleared goes at once, and the pill with it.
    @Test func aStopClearsWhenDropboxRunsAgain() throws {
        let scratch = try Scratch()
        let (controller, center) = controller(scratch)
        controller.stop = .dropboxNotRunning
        center.raiseOneWaySync([OneWaySyncRows.stop(.dropboxNotRunning, at: Date())])
        controller.cloudApps.updateModelForTests { $0.app(.dropbox, isRunning: true, at: Date()) }
        controller.clearStopsThatCleared()
        #expect(controller.stop == nil)
        #expect(center.oneWaySync.rows.isEmpty)
    }

    // MARK: History

    /// A first run's headline counts what it changed, never the files already the same, and
    /// groups its digits.
    @Test func historyCountsChangesNotFilesAlreadyTheSame() {
        var steps = (0..<1_200).map { OneWaySyncHistoryStep(step: OneWaySyncStep(action: .adopt(iCloudPath: "F/\($0)", dropboxPath: "F/\($0)")), status: .confirmed) }
        steps += (0..<1_500).map { OneWaySyncHistoryStep(step: OneWaySyncStep(action: .copy(from: "F/n\($0)", to: "F/n\($0)", needsDownload: false)), status: .confirmed) }
        let entry = OneWaySyncHistoryEntry(firstRun: UUID(), startedAt: 1_790_000_000, steps: steps, held: [], finishedAt: 1_790_000_100)
        #expect(OneWaySyncHistoryRows.headline(entry).hasPrefix("Synced \(1_500.formatted()) · "))
    }

    /// History's right-hand column says what a step did.
    @Test func historySaysWhatEachStepDid() {
        func outcome(_ action: OneWaySyncAction, _ status: OneWaySyncHistoryStep.Status = .confirmed, emptied: [String]? = nil) -> String {
            var step = OneWaySyncHistoryStep(step: OneWaySyncStep(action: action), status: status)
            step.emptied = emptied
            return OneWaySyncWords.outcome(step)
        }
        #expect(outcome(.moveInDropbox(from: "F/W-2.pdf", to: "F/2026 W-2.pdf")) == "Renamed in Dropbox")
        #expect(outcome(.moveInDropbox(from: "F/a.pdf", to: "L/a.pdf")) == "Moved in Dropbox")
        #expect(outcome(.moveFolderInDropbox(from: "F/Receipts", to: "F/2026/Receipts")) == "Folder moved in Dropbox · nothing uploaded")
        #expect(OneWaySyncWords.kind(.moveFolderInDropbox(from: "F/Receipts", to: "F/Receipts 2026")) == "Renamed")
        #expect(OneWaySyncWords.paths(.moveFolderInDropbox(from: "F/Receipts", to: "F/Receipts 2026")) == "F/Receipts/ → F/Receipts 2026/")
        #expect(outcome(.replace(dropboxPath: "F/a", with: "F/a", needsDownload: false, previousIsDropboxEdit: false), emptied: ["x"])
                .hasSuffix("the oldest kept version went to Dropbox’s deleted files"))
        #expect(outcome(.copy(from: "F/a", to: "F/a", needsDownload: false), .applied) == "Not yet uploaded")
        #expect(OneWaySyncWords.why(.overRemovalLimit) == "Over the removal limit")
        #expect(OneWaySyncWords.why(.editedInDropbox) == "Edited in Dropbox")
    }

    // MARK: Words

    @Test func timesPastTodaySayTheDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12)))
        let today = now.addingTimeInterval(-3600)
        let yesterday = now.addingTimeInterval(-86_400)
        let lastWeek = now.addingTimeInterval(-6 * 86_400)
        let lastYear = now.addingTimeInterval(-400 * 86_400)
        #expect(OneWaySyncWords.when(today, now: now, calendar: calendar) == today.formatted(date: .omitted, time: .shortened))
        #expect(OneWaySyncWords.when(today, now: now, saysToday: true, calendar: calendar).hasPrefix("today, "))
        #expect(OneWaySyncWords.when(yesterday, now: now, calendar: calendar).hasPrefix("yesterday, "))
        #expect(OneWaySyncWords.when(lastWeek, now: now, calendar: calendar).hasPrefix(lastWeek.formatted(.dateTime.day().month(.abbreviated))))
        #expect(OneWaySyncWords.when(lastYear, now: now, calendar: calendar).contains("2025"))
    }

    @Test func countsOfOneReadAsOne() {
        let one = [OneWaySyncPendingRemoval(record: 1, iCloudPath: "Legal/a", dropboxPath: "Legal/a", kind: .deleted)]
        #expect(OneWaySyncReviewSheet.title(folder: "Legal", pending: one, loaded: true) == "Legal: 1 removal")
        #expect(OneWaySyncReviewSheet.title(folder: "Legal", pending: [], loaded: false) == "Legal: Review")
        #expect(OneWaySyncEmptySheet.title(count: 1, bytes: 10, loaded: true).hasPrefix("SyncCloud Removed · 1 item · "))
        #expect(OneWaySyncEmptySheet.title(count: 0, bytes: 0, loaded: false) == "SyncCloud Removed")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(OneWaySyncSettingsView.removedLine(count: 1, bytes: 10, oldest: now.addingTimeInterval(-86_400 - 60), now: now)
                .contains(" · 1 item · ") == true)
        #expect(OneWaySyncSettingsView.removedLine(count: 1, bytes: 10, oldest: now.addingTimeInterval(-86_400 - 60), now: now)
                .contains("oldest 1 day ·"))
    }

    /// Resume says what the next sync would apply, the way the first run's step does.
    @Test func resumeSaysWhatTheNextSyncWouldDo() {
        var summary = OneWaySyncSummary()
        #expect(OneWaySyncController.resumeSummary(summary, waiting: 0) == "The next sync has nothing to copy.")
        summary.copies = 12
        summary.removals = 1
        let text = OneWaySyncController.resumeSummary(summary, waiting: 1)
        #expect(text.hasPrefix("The next sync copies 12"))
        #expect(text.contains("moves 1 to SyncCloud Removed"))
        #expect(text.hasSuffix("1 thing waits for you."))
    }

    /// A folder row's Stop Syncing names the folder it stops.
    @Test func stopSyncingNamesItsFolder() {
        let row = OneWaySyncNoticeRow(OneWaySyncNotice(id: "ows:folder:Health:renamed", kind: .needsYou, scope: .folder("Health"),
                                                       title: "Health was renamed to Medical in iCloud",
                                                       buttons: [.renameDropboxsToo, .stopSyncing], raisedAt: Date()))
        #expect(row.buttons.map { $0.title(on: row) } == ["Rename Dropbox’s Too", "Stop Syncing Health"])
    }
}
