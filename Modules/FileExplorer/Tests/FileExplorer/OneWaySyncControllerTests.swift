import Foundation
import Testing
import Sync
@testable import FileExplorer

/// One-way sync's controller without a pass: what the toolbar's rung says, which panes are which
/// side, and what the Dropbox pane refuses to rename, move or delete. Scratch parents; nothing
/// here syncs (the controller is told this process may not).
@MainActor
@Suite struct OneWaySyncControllerTests {

    final class Scratch {
        let root: URL
        let iCloud: URL
        let dropbox: URL
        init() throws {
            let raw = FileManager.default.temporaryDirectory.appendingPathComponent("OneWayController-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            root = URL(fileURLWithPath: OneWaySyncDisk.canonicalPath(raw), isDirectory: true)
            iCloud = root.appendingPathComponent("iCloud")
            dropbox = root.appendingPathComponent("Library/CloudStorage/Dropbox/Documents")
            for folder in [iCloud.appendingPathComponent("Legal"), dropbox.appendingPathComponent("Legal")] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        var record: OneWaySyncRecord {
            var record = OneWaySyncRecord(
                binding: OneWaySyncBinding(hardwareID: "HW", iCloudAccount: "A", dropboxAccountFolder: dropbox.deletingLastPathComponent().path,
                                           dataVolumeUUID: "V"),
                iCloudParent: OneWaySyncParentRecord(path: iCloud.path), dropboxParent: OneWaySyncParentRecord(path: dropbox.path))
            record.syncedFolders = [OneWaySyncFolderRecord(key: 1, iCloudPath: "Legal", dropboxPath: "Legal", firstRunCompleted: true)]
            record.files = [OneWaySyncFileRecord(key: 2, iCloudPath: "Legal/Will.pdf", dropboxPath: "Legal/Will.pdf",
                                                 iCloudID: 10, dropboxID: 20, size: 3, modified: 0)]
            record.nextKey = 3
            return record
        }

        /// A controller holding `record`, told this process may not sync unless `refusal` says otherwise.
        @MainActor
        func controller(state: OneWaySyncSavedState = OneWaySyncSavedState(),
                        refusal: OneWaySyncLaunchRefusal? = .testRunner) -> (OneWaySyncController, ActivityCenter) {
            let center = ActivityCenter()
            let controller = OneWaySyncController(store: nil, center: center, cloudApps: CloudAppMonitor(), refusal: refusal)
            controller.adopt(record, state: state)
            return (controller, center)
        }
    }

    @Test func theDropboxPaneRefusesSyncedFilesAndTheirFoldersButNotItsOwn() throws {
        let scratch = try Scratch()
        let (controller, _) = scratch.controller()
        let synced = scratch.dropbox.appendingPathComponent("Legal/Will.pdf").path
        #expect(controller.refusal(forChanging: [synced])?.contains("synced from iCloud") == true)
        // A synced folder, spelled in another case, as Dropbox's names ignore case.
        #expect(controller.refusal(forChanging: [scratch.dropbox.appendingPathComponent("legal").path]) != nil)
        #expect(controller.refusal(forChanging: [scratch.dropbox.appendingPathComponent("Legal/mine.txt").path]) == nil)
        #expect(controller.refusal(forChanging: [scratch.dropbox.appendingPathComponent("Unsynced").path]) == nil)
        // iCloud's side is the source: changing it there is the point.
        #expect(controller.refusal(forChanging: [scratch.iCloud.appendingPathComponent("Legal/Will.pdf").path]) == nil)
        #expect(controller.iCloudFile(forDropbox: synced) == scratch.iCloud.appendingPathComponent("Legal/Will.pdf").path)
    }

    /// Setup opens on Compare's folders when one pane is in iCloud Drive and the other in Dropbox,
    /// whichever side each is on, and not otherwise.
    @Test func setupOpensOnThePanesWhenTheyAreAnICloudAndADropboxFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs/Documents/SyncCloud Test"
        let dropbox = home + "/Library/CloudStorage/Dropbox/Documents/SyncCloud Test"
        let both = OneWaySyncController.prefill(fromPanes: [dropbox, iCloud])
        #expect(both?.iCloud.path == iCloud)
        #expect(both?.dropbox.path == dropbox)
        #expect(OneWaySyncController.prefill(fromPanes: [iCloud, home + "/Library/CloudStorage/OneDrive-Personal/Documents"]) == nil)
        #expect(OneWaySyncController.prefill(fromPanes: [dropbox, dropbox]) == nil)
    }

    /// Setup ticks nothing for you: opened on your whole Documents, every folder offered stays
    /// unticked until you tick it.
    @Test func setupNeverTicksTheFoldersItOffers() {
        let offered: Set<String> = ["Family", "Finance", "Legal"]
        #expect(OneWaySyncSetupSheet.ticks(offered: offered, synced: nil, startsFromSynced: false, current: []).isEmpty)
        #expect(OneWaySyncSetupSheet.ticks(offered: offered, synced: ["Legal"], startsFromSynced: false, current: []).isEmpty)
        #expect(OneWaySyncSetupSheet.ticks(offered: offered, synced: nil, startsFromSynced: false, current: ["Family", "Gone"]) == ["Family"])
        // Choose Folders starts from what syncs now.
        #expect(OneWaySyncSetupSheet.ticks(offered: offered, synced: ["Legal", "Old"], startsFromSynced: true, current: []) == ["Legal"])
    }

    /// In Choose Folders, a folder ticked now that doesn't sync yet needs "not shared on Dropbox"
    /// before Save; unticking one, or keeping what syncs, doesn't.
    @Test func chooseFoldersAsksAboutSharingForFoldersTickedNow() {
        let added = OneWaySyncSetupSheet.added(ticked: ["legal", "Work"], synced: ["Legal", "Old"])
        #expect(added == ["Work"])
        #expect(OneWaySyncSetupSheet.saveRefusal(added: added, notShared: false) != nil)
        #expect(OneWaySyncSetupSheet.saveRefusal(added: added, notShared: true) == nil)
        #expect(OneWaySyncSetupSheet.saveRefusal(added: [], notShared: false) == nil)
    }

    /// A takeover's first run says so in its state, so its Dropbox-only files are offered as a
    /// group; any other first run doesn't.
    @Test func aTakeoversFirstRunIsMarked() throws {
        let scratch = try Scratch()
        let (controller, _) = scratch.controller()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(OneWaySyncController.firstRunState(settings: OneWaySyncSettings(), unticked: [], takingOver: false, now: now).takenOverAt == nil)
        #expect(OneWaySyncController.firstRunState(settings: OneWaySyncSettings(), unticked: ["Work"], takingOver: true, now: now).takenOverAt
                == 1_790_000_000)
        controller.syncFromThisMacInstead()
        #expect(controller.takingOver)
        // Its setup closed without starting: a later first run is no takeover.
        controller.setupClosed()
        #expect(!controller.takingOver)
    }

    /// Pause, or a setting, changed while a pass runs saves over what is stored, not over the
    /// copy the controller took when the pass started: the pass's removal window stays.
    @Test func pauseKeepsTheWindowAPassSaved() throws {
        let scratch = try Scratch()
        let store = OneWaySyncStore(directory: scratch.root.appendingPathComponent("Store"))
        _ = try store.startFirstRun(scratch.record, state: OneWaySyncSavedState())
        let controller = OneWaySyncController(store: store, center: ActivityCenter(), cloudApps: CloudAppMonitor(), refusal: .testRunner)
        controller.adopt(scratch.record, state: OneWaySyncSavedState())
        var passSaved = OneWaySyncSavedState()
        passSaved.window = OneWaySyncRemovalWindow(changes: [.init(file: 2, folder: 1, kind: .deletedOrMovedOut, seenAt: 1_790_000_000)])
        try store.saveState(passSaved)
        controller.pause()
        let saved = try #require(store.loadState().value)
        #expect(saved.window == passSaved.window)
        #expect(saved.pausedSince != nil)
    }

    @Test func eachPaneKnowsItsSide() throws {
        let scratch = try Scratch()
        let (controller, _) = scratch.controller()
        #expect(controller.role(ofFolder: scratch.iCloud.appendingPathComponent("Legal").path) == .source)
        // A folder beside the synced ones isn't synced, so it has no side.
        try FileManager.default.createDirectory(at: scratch.iCloud.appendingPathComponent("Work"), withIntermediateDirectories: true)
        #expect(controller.role(ofFolder: scratch.iCloud.appendingPathComponent("Work").path) == nil)
        #expect(controller.role(ofFolder: scratch.dropbox.path) == .copy)
        #expect(controller.role(ofFolder: scratch.root.path) == nil)
    }

    @Test func theToolbarSaysTheFirstRungThatApplies() throws {
        let scratch = try Scratch()
        let (controller, center) = scratch.controller(state: OneWaySyncSavedState(pausedSince: 1_790_000_000, lastSyncAt: 1_789_990_000))
        #expect(controller.ladder == .paused(since: Date(timeIntervalSince1970: 1_790_000_000)))
        center.raiseOneWaySync([OneWaySyncNotice(id: "ows:file:Legal/Will.pdf", kind: .needsYou, scope: .file(folder: "Legal", path: "Legal/Will.pdf"),
                                                 title: "Will.pdf was edited in Dropbox", raisedAt: Date())])
        #expect(controller.ladder == .needsYou(1))
        controller.stop = .dropboxNotRunning
        #expect(controller.ladder == .stopped("Sync stopped: the Dropbox app isn’t running"))
        controller.stop = nil
        controller.adopt(scratch.record, state: OneWaySyncSavedState(lastSyncAt: 1_789_990_000))
        center.clearOneWaySync(["ows:file:Legal/Will.pdf"])
        #expect(controller.ladder == .upToDate(asOf: Date(timeIntervalSince1970: 1_789_990_000), skipped: 0))
        // A copy that may not sync says why, and offers nothing to run.
        #expect(controller.syncNowRefusal == "Only SyncCloud in Applications syncs")
    }

    /// A file Dropbox refused is counted as skipped from the record, before any pass looks.
    @Test func theRungCountsWhatDropboxRefusedAsSkipped() throws {
        let scratch = try Scratch()
        var record = scratch.record
        record.refused = [OneWaySyncRefusedFile(
            iCloudPath: "Legal/CON.pdf", iCloudID: 11, size: 3, modified: 0, changed: nil, dropboxPath: "Legal/CON.pdf",
            record: nil, why: "excluded from sync", refusedAt: 0)]
        let (controller, center) = scratch.controller(state: OneWaySyncSavedState(lastSyncAt: 1_789_990_000))
        controller.adopt(record, state: OneWaySyncSavedState(lastSyncAt: 1_789_990_000))
        #expect(controller.ladder == .upToDate(asOf: Date(timeIntervalSince1970: 1_789_990_000), skipped: 1))
        #expect(OneWaySyncStatusPill(controller: controller, center: center, onSetUp: {}).title.hasSuffix(" · 1 skipped · Sync Now"))
    }

    /// Sync Now's refusals past the first rung: a copy that may sync still doesn't while paused,
    /// so an answer (which syncs after) never starts a pass you paused.
    @Test func syncNowIsRefusedWhilePaused() throws {
        let scratch = try Scratch()
        let controller = OneWaySyncController(store: nil, center: ActivityCenter(), cloudApps: CloudAppMonitor(), refusal: nil)
        controller.adopt(scratch.record, state: OneWaySyncSavedState(pausedSince: 1_790_000_000))
        #expect(controller.syncNowRefusal == "Paused — resume to sync")
        controller.adopt(scratch.record, state: OneWaySyncSavedState())
        #expect(controller.syncNowRefusal == nil)
        controller.adopt(nil, state: nil)
        #expect(controller.syncNowRefusal == "Set up one-way sync first")
    }

    /// Reverse in iCloud and Choose Items to Empty write as an answer does: on the write queue, with
    /// no Sync Now while they do, since a pass clears the staging folder a restore copies through.
    @Test func reverseAndEmptyHoldSyncNowWhileTheyWrite() async throws {
        let scratch = try Scratch()
        let controller = OneWaySyncController(store: nil, center: ActivityCenter(), cloudApps: CloudAppMonitor(), refusal: nil,
                                              staging: scratch.root.appendingPathComponent("Staging"))
        var record = scratch.record
        // iCloud's parent around the staging folder: the writer refuses it before making anything,
        // so nothing outside the scratch folders is touched.
        record.iCloudParent = OneWaySyncParentRecord(path: scratch.root.path)
        controller.adopt(record, state: OneWaySyncSavedState())
        let answers: [(String, @MainActor @Sendable () async -> Void)] = [
            ("reverse", { _ = await controller.reverse([]) }),
            ("empty", { _ = await controller.empty([]) }),
        ]
        for (name, answer) in answers {
            let gate = DispatchSemaphore(value: 0)
            OneWaySyncRun.writeQueue.async { gate.wait() }
            let running = Task { @MainActor in await answer() }
            #expect(await LayoutPumpWait.poll(upTo: 5) { controller.isAnswering }.held, "\(name)")
            #expect(controller.syncNowRefusal == "Wait for the change you asked for to finish", "\(name)")
            gate.signal()
            await running.value
            #expect(!controller.isAnswering, "\(name)")
            // Reverse syncs after: that pass (with no store, it returns at once) ends first.
            #expect(await LayoutPumpWait.poll(upTo: 5) { !controller.isRunning }.held, "\(name): the pass after never ended")
        }
    }

    /// Turn Off removes this Mac's own marker in Dropbox, and never another Mac's: on a Mac the
    /// sync was taken over from, removing it would stop the Mac that syncs now.
    @Test func turnOffLeavesAnotherMacsMarker() throws {
        let scratch = try Scratch()
        let store = OneWaySyncStore(directory: scratch.root.appendingPathComponent("Store"))
        let marker = OneWaySyncMarkerFile(folder: scratch.dropbox)
        for (hardwareID, kept) in [("HW-OTHER", true), (OneWaySyncBinding.platformUUID() ?? "", false)] {
            _ = try store.startFirstRun(scratch.record, state: OneWaySyncSavedState())
            try marker.claim(OneWaySyncMacMarker(hardwareID: hardwareID, macName: "A Mac", claimedAt: 1_790_000_000))
            // Its own staging folder: Turn Off empties it, and the real one may hold a pass in flight.
            let controller = OneWaySyncController(store: store, center: ActivityCenter(), cloudApps: CloudAppMonitor(), refusal: nil,
                                                  staging: scratch.root.appendingPathComponent("Staging"))
            controller.adopt(scratch.record, state: OneWaySyncSavedState())
            controller.turnOff()
            #expect(controller.isSetUp == false)
            #expect((marker.check(hardwareID: hardwareID) != .missing) == kept, "\(hardwareID)")
        }
    }

    /// A list of files you stopped syncing that couldn't be read is never written over by an
    /// answer starting from an empty one.
    @Test func anUnreadableStoppedFilesListIsNotWrittenOver() throws {
        let scratch = try Scratch()
        let store = OneWaySyncStore(directory: scratch.root.appendingPathComponent("Store"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not a list".utf8).write(to: store.exclusionsURL)
        let controller = OneWaySyncController(store: store, center: ActivityCenter(), cloudApps: CloudAppMonitor(), refusal: .testRunner)
        controller.adopt(scratch.record, state: OneWaySyncSavedState())
        #expect(throws: CocoaError.self) { try controller.save(OneWaySyncExclusions()) }
        #expect(try String(contentsOf: store.exclusionsURL, encoding: .utf8) == "not a list")
    }

    /// History says a copy of a file moved in was a move in, and from where.
    @Test func historyNamesAMoveInAndWhereFrom() {
        let movedIn = OneWaySyncStep(action: .copy(from: "Finance/Invoice.pdf", to: "Finance/Invoice.pdf", needsDownload: false),
                                     movedInFrom: "Work/Invoice.pdf")
        #expect(OneWaySyncWords.kind(movedIn) == "Moved in")
        #expect(OneWaySyncWords.paths(movedIn) == "Work/Invoice.pdf → Finance/Invoice.pdf")
        let added = OneWaySyncStep(action: .copy(from: "Finance/New.pdf", to: "Finance/New.pdf", needsDownload: false))
        #expect(OneWaySyncWords.kind(added) == "Added")
        #expect(OneWaySyncWords.paths(added) == "Finance/New.pdf")
    }
}
