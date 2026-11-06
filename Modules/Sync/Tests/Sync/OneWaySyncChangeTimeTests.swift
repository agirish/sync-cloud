import Darwin
import Foundation
import Testing
@testable import Sync

/// An edit that keeps a file's size and date is caught by its change time. The file's contents are
/// then read and compared, with the recorded hash or Dropbox's copy as recorded; never for a file
/// offloaded from this Mac, and never for one whose download state is all that changed.
@Suite struct OneWaySyncChangeTimeTests {
    typealias Sync = OneWaySyncRunTests.Sync
    let run = OneWaySyncRunTests()

    func changeTime(_ url: URL) -> Int64 {
        var info = stat()
        precondition(lstat(url.path, &info) == 0)
        return OneWaySyncDisk.nanoseconds(info.st_ctimespec)
    }

    @Test func anEditKeepingSizeAndDateIsSyncedAsAnEdit() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let url = try run.write(world, .iCloud, "Finance/Budget.txt", "budget v1", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        #expect(sync.file("Finance/Budget.txt")?.changed == changeTime(url))
        #expect(sync.look().plan.iCloudContentsToRead.isEmpty)

        // Same length, the date put back to the second: only the change time says so.
        try run.write(world, .iCloud, "Finance/Budget.txt", "budget v2", modified: OneWaySyncRunTests.earlier)
        #expect(sync.look().plan.actions == [.replace(dropboxPath: "Finance/Budget.txt", with: "Finance/Budget.txt",
                                                      needsDownload: false, previousIsDropboxEdit: false)])
        try await sync.run()
        #expect(world.read(.dropbox, "Finance/Budget.txt") == "budget v2")
        #expect(sync.file("Finance/Budget.txt")?.changed == changeTime(url))
        #expect(sync.look().plan.steps.isEmpty)
    }

    /// The change time moved and the contents didn't (an attribute, a lock, a tag): nothing is
    /// written, and the record takes the new change time, so the next pass reads nothing.
    @Test func aChangeTimeMovedWithTheSameContentsIsReadOnce() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let url = try run.write(world, .iCloud, "Finance/Budget.txt", "budget v1", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        let before = try #require(sync.file("Finance/Budget.txt")?.changed)
        #expect(setxattr(url.path, "com.example.note", "x", 1, 0, 0) == 0)
        #expect(changeTime(url) != before)

        let look = sync.look()
        #expect(look.plan.steps.isEmpty)
        // Read, both sides: the record had no hash to compare with.
        #expect(look.pass.iCloud.items.first { $0.path == "Finance/Budget.txt" }?.contentHash != nil)
        #expect(look.pass.dropbox.items.first { $0.path == "Finance/Budget.txt" }?.contentHash != nil)
        #expect(look.plan.settledChangeTimes == [try #require(sync.file("Finance/Budget.txt")?.key)])
        try await sync.run()
        #expect(sync.file("Finance/Budget.txt")?.changed == changeTime(url))
        #expect(sync.file("Finance/Budget.txt")?.contentHash != nil)
        let again = sync.look()
        #expect(again.pass.iCloud.items.first { $0.path == "Finance/Budget.txt" }?.contentHash == nil)
        #expect(again.pass.dropbox.items.first { $0.path == "Finance/Budget.txt" }?.contentHash == nil)
    }

    // MARK: The planner and the record, without a disk

    static func world(changed: Int64?, hash: String? = nil) -> OneWayWorld {
        var world = OneWayWorld(files: ["Finance/a.pdf"])
        world.record.files[0].changed = changed
        world.record.files[0].contentHash = hash
        world.update(.iCloud, "Finance/a.pdf") {
            $0.changed = 2_000
            $0.contentHash = nil
        }
        world.update(.dropbox, "Finance/a.pdf") { $0.contentHash = nil }
        return world
    }

    @Test func aMovedChangeTimeAsksForTheContentsOfBothSides() {
        let plan = Self.world(changed: 1_000).plan()
        #expect(plan.iCloudContentsToRead == ["Finance/a.pdf"])
        #expect(plan.dropboxContentsToRead == ["Finance/a.pdf"])
        #expect(plan.steps.isEmpty)
    }

    @Test func aRecordedHashIsComparedWithoutReadingDropbox() {
        var world = Self.world(changed: 1_000, hash: "h1")
        #expect(world.plan().iCloudContentsToRead == ["Finance/a.pdf"])
        #expect(world.plan().dropboxContentsToRead.isEmpty)
        world.update(.iCloud, "Finance/a.pdf") { $0.contentHash = "other" }
        #expect(world.plan().actions == [.replace(dropboxPath: "Finance/a.pdf", with: "Finance/a.pdf", needsDownload: false,
                                                  previousIsDropboxEdit: false)])
    }

    @Test func anUnmovedChangeTimeAsksForNothing() {
        let plan = Self.world(changed: 2_000).plan()
        #expect(plan.iCloudContentsToRead.isEmpty)
        #expect(plan.dropboxContentsToRead.isEmpty)
    }

    /// Offloading and downloading move the change time themselves, and an offloaded file is never
    /// read just to compare.
    @Test func anOffloadedFileIsNeverReadAndKeepsNoChangeTime() {
        var world = Self.world(changed: 1_000)
        world.update(.iCloud, "Finance/a.pdf") { $0.isDownloaded = false }
        let pass = world.pass()
        let plan = OneWaySyncPlanner.plan(pass)
        #expect(plan.iCloudContentsToRead.isEmpty)
        #expect(plan.dropboxContentsToRead.isEmpty)
        let record = OneWaySyncRecordKeeper.update(world.record, pass: pass, plan: plan, outcomes: [],
                                                   dropboxFolderID: { _ in nil }, now: pass.now)
        #expect(record.files[0].changed == nil)
    }

    /// A record made while the file was offloaded, or before change times were kept: the change
    /// time is taken as found, with nothing read.
    @Test func aRecordWithNoChangeTimeTakesTheOneFoundWithoutReading() {
        let world = Self.world(changed: nil)
        let pass = world.pass()
        let plan = OneWaySyncPlanner.plan(pass)
        #expect(plan.iCloudContentsToRead.isEmpty)
        let record = OneWaySyncRecordKeeper.update(world.record, pass: pass, plan: plan, outcomes: [],
                                                   dropboxFolderID: { _ in nil }, now: pass.now)
        #expect(record.files[0].changed == 2_000)
    }

    /// Unread (the read failed), the old change time stays, so the next pass asks again.
    @Test func anUnreadChangeKeepsTheOldChangeTime() {
        let world = Self.world(changed: 1_000)
        let pass = world.pass()
        let plan = OneWaySyncPlanner.plan(pass)
        let record = OneWaySyncRecordKeeper.update(world.record, pass: pass, plan: plan, outcomes: [],
                                                   dropboxFolderID: { _ in nil }, now: pass.now)
        #expect(record.files[0].changed == 1_000)
    }
}
