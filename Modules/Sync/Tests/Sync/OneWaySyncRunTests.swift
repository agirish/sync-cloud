import Darwin
import Foundation
import Testing
@testable import Sync

/// A whole *Sync Now* on scratch folders: setup's record, the look, the apply, and what the record
/// says afterwards, pass after pass. Dropbox's upload is stood in for by setting the tracking flag
/// Dropbox sets, and reporting the file uploaded.
@Suite struct OneWaySyncRunTests {

    /// A sync between the scratch world's parents, with its own saved state.
    final class Sync {
        let world: OneWayDiskWorld
        let scratch = OneWayScratch()
        var record: OneWaySyncRecord
        var state = OneWaySyncSavedState()
        let firstRun = UUID()
        var now = OneWayDiskWorld.day0
        /// Paths whose upload Dropbox "refuses" or never reports.
        var refuse: Set<String> = []
        var neverReport: Set<String> = []

        init(world: OneWayDiskWorld, folders: [String]) throws {
            self.world = world
            // Setup offers only folders directly in both parents.
            for folder in folders {
                for base in [world.iCloud, world.dropbox] {
                    try FileManager.default.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
                }
            }
            let iCloud = OneWaySyncLister(side: .iCloud, parent: world.iCloud).list(syncedFolders: [])
            let dropbox = OneWaySyncLister(side: .dropbox, parent: world.dropbox).list(syncedFolders: [])
            record = OneWaySyncSetup.record(
                binding: OneWayWorld.binding, iCloudParent: OneWaySyncSetup.parentRecord(world.iCloud),
                dropboxParent: OneWaySyncSetup.parentRecord(world.dropbox), folders: folders, iCloud: iCloud, dropbox: dropbox)
        }

        var store: OneWaySyncStore { scratch.store }

        func look() -> OneWaySyncLook {
            OneWaySyncRun.look(record: record, state: state, exclusions: OneWaySyncExclusions(), places: world.places,
                               download: false, now: now, isShared: { _ in false })
        }

        @discardableResult
        func run() async throws -> OneWaySyncRunResult {
            let look = look()
            let writer = try world.writer(at: now)
            let refuse = refuse, neverReport = neverReport, now = now
            let result = try await OneWaySyncRun.apply(
                look, state: state, firstRun: firstRun, store: store, writer: writer, marker: nil,
                hardwareID: "HW-1", macName: "Test Mac",
                confirmUploads: { paths in
                    var outcomes: [String: OneWaySyncUploadOutcome] = [:]
                    for path in paths {
                        let name = (path as NSString).lastPathComponent
                        if refuse.contains(name) { outcomes[path] = .refused("Dropbox won’t take it"); continue }
                        if neverReport.contains(name) { outcomes[path] = .notConfirmed; continue }
                        chflags(path, UInt32(UF_TRACKED))
                        outcomes[path] = .uploaded(documentID: OneWaySyncDisk.documentID(at: path))
                    }
                    return outcomes
                },
                now: { now })
            record = result.record
            if case .ready(_, _, let saved) = store.loadRecord(on: OneWayWorld.binding) { state = saved }
            return result
        }

        func file(_ iCloudPath: String) -> OneWaySyncFileRecord? { record.files.first { $0.iCloudPath == iCloudPath } }
    }

    /// iCloud tracks every file too: its files carry document IDs the record follows.
    @discardableResult
    func write(_ world: OneWayDiskWorld, _ side: OneWaySyncSide, _ path: String, _ text: String, modified: Date? = nil) throws -> URL {
        let url = try world.write(side, path, text, modified: modified)
        chflags(url.path, UInt32(UF_TRACKED))
        return url
    }

    func move(_ world: OneWayDiskWorld, _ side: OneWaySyncSide, _ from: String, _ to: String) throws {
        let base = world.base(side)
        try FileManager.default.createDirectory(at: base.appendingPathComponent(to).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: base.appendingPathComponent(from), to: base.appendingPathComponent(to))
    }

    static let earlier = OneWayDiskWorld.day0.addingTimeInterval(-86_400)
    static let earliest = OneWayDiskWorld.day0.addingTimeInterval(-2 * 86_400)

    // MARK: First run

    @Test func aFirstRunCopiesReplacesRecordsAndLeavesDropboxOnlyFilesAlone() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try write(world, .iCloud, "Finance/new.pdf", "only in iCloud", modified: Self.earlier)
        try write(world, .iCloud, "Finance/same.pdf", "the same on both", modified: Self.earlier)
        try write(world, .dropbox, "Finance/same.pdf", "the same on both", modified: Self.earlier)
        try write(world, .iCloud, "Finance/newer.pdf", "iCloud's, newer", modified: Self.earlier)
        try write(world, .dropbox, "Finance/newer.pdf", "Dropbox's, older", modified: Self.earliest)
        try write(world, .iCloud, "Finance/older.pdf", "iCloud's, older", modified: Self.earliest)
        try write(world, .dropbox, "Finance/older.pdf", "Dropbox's, newer!", modified: Self.earlier)
        try write(world, .dropbox, "Finance/mine.pdf", "only in Dropbox")
        let sync = try Sync(world: world, folders: ["Finance"])

        let summary = sync.look().summary
        #expect(summary.copies == 1)
        #expect(summary.replaces == 1)
        #expect(summary.same == 1)
        #expect(summary.waitsForYou == 1)
        #expect(summary.dropboxOnly == 1)

        let result = try await sync.run()
        #expect(result.notDone.isEmpty)
        #expect(world.read(.dropbox, "Finance/new.pdf") == "only in iCloud")
        #expect(world.read(.dropbox, "Finance/newer.pdf") == "iCloud's, newer")
        #expect(world.read(.dropbox, "Finance/older.pdf") == "Dropbox's, newer!")
        #expect(world.read(.dropbox, "Finance/mine.pdf") == "only in Dropbox")
        // Dropbox's replaced version is kept, not deleted.
        let kept = try world.writer().removed.items().map { world.read(account: $0.path) }
        #expect(kept == ["Dropbox's, older"])
        #expect(Set(sync.record.files.map(\.iCloudPath)) == ["Finance/new.pdf", "Finance/same.pdf", "Finance/newer.pdf"])
        // A first-run pair still waits for you, so the folder's first run isn't over: the pair is
        // still decided by first-run rules once you choose.
        let finished = sync.record.syncedFolders.map(\.firstRunCompleted)
        #expect(finished == [false])
        #expect(sync.file("Finance/new.pdf")?.dropboxID == world.documentID(.dropbox, "Finance/new.pdf"))

        // Nothing left to do but the file that waits.
        let again = sync.look()
        #expect(again.plan.steps.isEmpty)
        #expect(again.plan.waits.map(\.reason) == [.dropboxNewerOnFirstRun])
        #expect(sync.store.history.entries().first?.finishedAt != nil)
    }

    @Test func aFileDropboxNeverReportsUploadedIsRecordedByContentsNextTime() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try write(world, .iCloud, "Finance/slow.pdf", "slow to upload")
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.neverReport = ["slow.pdf"]
        let first = try await sync.run()
        #expect(first.unconfirmed == ["Finance/slow.pdf"])
        #expect(sync.record.files.isEmpty)

        sync.neverReport = []
        let next = sync.look()
        #expect(next.plan.actions == [.adopt(iCloudPath: "Finance/slow.pdf", dropboxPath: "Finance/slow.pdf")])
        try await sync.run()
        #expect(sync.record.files.map(\.iCloudPath) == ["Finance/slow.pdf"])
        #expect(sync.look().plan.steps.isEmpty)
    }

    // MARK: Changes after it

    @Test func aRenameAnEditAndADeletionFollowFromICloud() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try write(world, .iCloud, "Finance/W-2.pdf", "w2", modified: Self.earlier)
        try write(world, .iCloud, "Finance/Budget.xlsx", "budget v1", modified: Self.earlier)
        try write(world, .iCloud, "Finance/Old.pdf", "old", modified: Self.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        let dropboxID = world.documentID(.dropbox, "Finance/W-2.pdf")

        try move(world, .iCloud, "Finance/W-2.pdf", "Finance/2026 W-2.pdf")
        try write(world, .iCloud, "Finance/Budget.xlsx", "budget v2, longer", modified: OneWayDiskWorld.day0)
        try FileManager.default.removeItem(at: world.iCloud.appendingPathComponent("Finance/Old.pdf"))
        sync.now = OneWayDiskWorld.day0.addingTimeInterval(60)
        try await sync.run()

        // Renamed in Dropbox, same item.
        #expect(world.read(.dropbox, "Finance/2026 W-2.pdf") == "w2")
        #expect(world.read(.dropbox, "Finance/W-2.pdf") == nil)
        #expect(world.documentID(.dropbox, "Finance/2026 W-2.pdf") == dropboxID)
        #expect(world.read(.dropbox, "Finance/Budget.xlsx") == "budget v2, longer")
        // Gone from iCloud: it waits 30 minutes and a second check.
        #expect(world.read(.dropbox, "Finance/Old.pdf") == "old")
        #expect(sync.file("Finance/Old.pdf")?.iCloudGoneSince == Int64(sync.now.timeIntervalSince1970))
        #expect(sync.file("Finance/2026 W-2.pdf") != nil)

        sync.now = sync.now.addingTimeInterval(31 * 60)
        try await sync.run()
        #expect(world.read(.dropbox, "Finance/Old.pdf") == nil)
        #expect(sync.file("Finance/Old.pdf") == nil)
        #expect(sync.record.removed.map(\.file.iCloudPath) == ["Finance/Old.pdf"])
        #expect(sync.look().plan.steps.isEmpty)
        // History says where the removed file went.
        let removal = sync.store.history.entries().first?.steps.first { if case .moveToRemoved = $0.step.action { return true } else { return false } }
        #expect(removal?.status == .confirmed)
        #expect(removal?.keptAt.map { world.read(account: $0) } == "old")
    }

    @Test func aRenamedFolderBelowASyncedOneMovesOnceInDropbox() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        for name in ["a", "b", "c"] { try write(world, .iCloud, "Finance/Receipts/\(name).pdf", name) }
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        #expect(sync.record.subfolders.map(\.iCloudPath) == ["Finance/Receipts"])

        try move(world, .iCloud, "Finance/Receipts", "Finance/2026 Receipts")
        let look = sync.look()
        #expect(look.plan.actions == [.moveFolderInDropbox(from: "Finance/Receipts", to: "Finance/2026 Receipts")])
        try await sync.run()
        #expect(world.read(.dropbox, "Finance/2026 Receipts/b.pdf") == "b")
        #expect(Set(sync.record.files.map(\.dropboxPath)) == ["Finance/2026 Receipts/a.pdf", "Finance/2026 Receipts/b.pdf", "Finance/2026 Receipts/c.pdf"])
        #expect(sync.record.subfolders.map(\.iCloudPath) == ["Finance/2026 Receipts"])
        #expect(sync.look().plan.steps.isEmpty)
    }

    @Test func twoNamesSwappedInICloudSwapInDropboxAndLeaveNoTemporaryName() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try write(world, .iCloud, "Finance/a.pdf", "first")
        try write(world, .iCloud, "Finance/b.pdf", "second")
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try move(world, .iCloud, "Finance/a.pdf", "Finance/x.pdf")
        try move(world, .iCloud, "Finance/b.pdf", "Finance/a.pdf")
        try move(world, .iCloud, "Finance/x.pdf", "Finance/b.pdf")
        try await sync.run()
        #expect(world.read(.dropbox, "Finance/a.pdf") == "second")
        #expect(world.read(.dropbox, "Finance/b.pdf") == "first")
        #expect(!world.everythingInDropbox.contains { $0.contains(OneWaySyncPlanner.temporaryNamePrefix) })
        #expect(sync.look().plan.steps.isEmpty)
    }

    /// A swap whose second step stops (Dropbox's copy changed since the check) puts the parked
    /// file back: nothing is left under a temporary name, and the next pass tries again.
    @Test func aSwapCutShortPutsTheParkedFileBack() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try write(world, .iCloud, "Finance/a.pdf", "first")
        try write(world, .iCloud, "Finance/b.pdf", "second")
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try move(world, .iCloud, "Finance/a.pdf", "Finance/x.pdf")
        try move(world, .iCloud, "Finance/b.pdf", "Finance/a.pdf")
        try move(world, .iCloud, "Finance/x.pdf", "Finance/b.pdf")
        let look = sync.look()
        #expect(look.plan.steps.count == 3)
        // b changes in Dropbox after the look: its move into a's name refuses.
        try write(world, .dropbox, "Finance/b.pdf", "second, edited in Dropbox")
        let result = try await OneWaySyncRun.apply(
            look, state: sync.state, firstRun: sync.firstRun, store: sync.store, writer: try world.writer(at: sync.now),
            marker: nil, hardwareID: "HW-1", macName: "Test Mac",
            confirmUploads: { paths in Dictionary(uniqueKeysWithValues: paths.map { ($0, OneWaySyncUploadOutcome.uploaded(documentID: nil)) }) },
            now: { OneWayDiskWorld.day0 })
        #expect(!result.notDone.isEmpty)
        #expect(!world.everythingInDropbox.contains { $0.contains(OneWaySyncPlanner.temporaryNamePrefix) })
        #expect(world.read(.dropbox, "Finance/a.pdf") == "first")
        #expect(world.read(.dropbox, "Finance/b.pdf") == "second, edited in Dropbox")
        // The record says where Dropbox's copies are, not the temporary name.
        let record = result.record
        #expect(!record.files.contains { $0.dropboxPath.contains(OneWaySyncPlanner.temporaryNamePrefix) })
        #expect(Set(record.files.map(\.dropboxPath)) == ["Finance/a.pdf", "Finance/b.pdf"])
    }

    /// With *Deleted, renamed or moved* on Ask Me, a rename made in Dropbox waits, and goes on
    /// waiting: the record doesn't take Dropbox's new name as agreed.
    @Test func aRenameInDropboxWaitsPassAfterPassUnderAskMe() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try write(world, .iCloud, "Legal/Will.pdf", "will")
        let sync = try Sync(world: world, folders: ["Legal"])
        sync.state.settings.whenDeletedRenamedOrMoved = .askMe
        try await sync.run()
        try move(world, .dropbox, "Legal/Will.pdf", "Legal/Renamed.pdf")
        try await sync.run()
        #expect(sync.file("Legal/Will.pdf")?.dropboxPath == "Legal/Will.pdf")
        let again = sync.look()
        #expect(again.plan.steps.isEmpty)
        #expect(again.plan.waits.map(\.reason) == [.deletedOrMovedInDropbox])
        #expect(world.read(.dropbox, "Legal/Renamed.pdf") == "will")
    }

    /// An edit and a rename in iCloud in one pass: the replace, then the move, which re-checks
    /// Dropbox's copy against what the replace left rather than the version before it.
    @Test func anEditAndARenameTogetherBothLand() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try write(world, .iCloud, "Legal/Draft.pdf", "draft", modified: Self.earlier)
        let sync = try Sync(world: world, folders: ["Legal"])
        try await sync.run()
        try write(world, .iCloud, "Legal/Draft.pdf", "final, longer", modified: OneWayDiskWorld.day0)
        try move(world, .iCloud, "Legal/Draft.pdf", "Legal/Final.pdf")
        let result = try await sync.run()
        #expect(result.notDone.isEmpty)
        #expect(world.read(.dropbox, "Legal/Final.pdf") == "final, longer")
        #expect(world.read(.dropbox, "Legal/Draft.pdf") == nil)
        #expect(sync.look().plan.steps.isEmpty)
        #expect(sync.look().plan.waits.isEmpty)
    }

    /// Renamed in iCloud onto a Dropbox-only file with the same contents: that file is adopted,
    /// the old copy goes to SyncCloud Removed, and the record follows the adopted one.
    @Test func aRenameOntoAnIdenticalDropboxOnlyFileAdoptsIt() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let text = String(repeating: "contents ", count: 200)
        try write(world, .iCloud, "Legal/Scan.pdf", text, modified: Self.earlier)
        let sync = try Sync(world: world, folders: ["Legal"])
        try await sync.run()
        try write(world, .dropbox, "Legal/Scan 2026.pdf", text, modified: Self.earlier)
        try move(world, .iCloud, "Legal/Scan.pdf", "Legal/Scan 2026.pdf")
        try await sync.run()
        #expect(world.read(.dropbox, "Legal/Scan.pdf") == nil)
        #expect(sync.file("Legal/Scan 2026.pdf")?.dropboxPath == "Legal/Scan 2026.pdf")
        #expect(sync.record.removed.isEmpty)
        #expect(sync.look().plan.steps.isEmpty)
        #expect(sync.look().plan.waits.isEmpty)
    }

    @Test func aFileYouStoppedSyncingIsLeftAsItIsInDropbox() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try write(world, .iCloud, "Finance/kept.pdf", "iCloud's")
        try write(world, .dropbox, "Finance/kept.pdf", "Dropbox's own")
        let sync = try Sync(world: world, folders: ["Finance"])
        let exclusions = OneWaySyncExclusions(files: [OneWaySyncExclusion(iCloudPath: "Finance/kept.pdf", dropboxPath: "Finance/kept.pdf", stoppedAt: 0)])
        let look = OneWaySyncRun.look(record: sync.record, state: sync.state, exclusions: exclusions, places: world.places,
                                      download: false, now: sync.now, isShared: { _ in false })
        #expect(look.plan.steps.isEmpty)
        #expect(look.plan.waits.isEmpty)
        #expect(look.plan.dropboxOnly.isEmpty)
    }
}
