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
    }

    func controller(_ scratch: Scratch, state: OneWaySyncSavedState = OneWaySyncSavedState()) -> (OneWaySyncController, ActivityCenter) {
        let center = ActivityCenter()
        let controller = OneWaySyncController(store: nil, center: center, cloudApps: CloudAppMonitor(), refusal: .testRunner)
        controller.adopt(scratch.record, state: state)
        return (controller, center)
    }

    @Test func theDropboxPaneRefusesSyncedFilesAndTheirFoldersButNotItsOwn() throws {
        let scratch = try Scratch()
        let (controller, _) = controller(scratch)
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
    /// whichever side each is on, and not otherwise (RD67 EE).
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
    /// unticked until you tick it (31 Oct: it ticked them all).
    @Test func setupNeverTicksTheFoldersItOffers() {
        let offered: Set<String> = ["Family", "Finance", "Legal"]
        #expect(OneWaySyncSetupSheet.ticks(offered: offered, synced: nil, startsFromSynced: false, current: []).isEmpty)
        #expect(OneWaySyncSetupSheet.ticks(offered: offered, synced: ["Legal"], startsFromSynced: false, current: []).isEmpty)
        #expect(OneWaySyncSetupSheet.ticks(offered: offered, synced: nil, startsFromSynced: false, current: ["Family", "Gone"]) == ["Family"])
        // Choose Folders starts from what syncs now.
        #expect(OneWaySyncSetupSheet.ticks(offered: offered, synced: ["Legal", "Old"], startsFromSynced: true, current: []) == ["Legal"])
    }

    @Test func eachPaneKnowsItsSide() throws {
        let scratch = try Scratch()
        let (controller, _) = controller(scratch)
        #expect(controller.role(ofFolder: scratch.iCloud.appendingPathComponent("Legal").path) == .source)
        // A folder beside the synced ones isn't synced, so it has no side.
        try FileManager.default.createDirectory(at: scratch.iCloud.appendingPathComponent("Work"), withIntermediateDirectories: true)
        #expect(controller.role(ofFolder: scratch.iCloud.appendingPathComponent("Work").path) == nil)
        #expect(controller.role(ofFolder: scratch.dropbox.path) == .copy)
        #expect(controller.role(ofFolder: scratch.root.path) == nil)
    }

    @Test func theToolbarSaysTheFirstRungThatApplies() throws {
        let scratch = try Scratch()
        let (controller, center) = controller(scratch, state: OneWaySyncSavedState(pausedSince: 1_790_000_000, lastSyncAt: 1_789_990_000))
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
}
