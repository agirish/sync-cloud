import Darwin
import Foundation
import Testing
@testable import Sync

/// Now's answers on scratch folders: each does its one thing on disk, and the next pass records
/// both sides as agreeing.
@Suite struct OneWaySyncAnswersTests {
    typealias Sync = OneWaySyncRunTests.Sync
    let run = OneWaySyncRunTests()

    /// A synced pair whose Dropbox copy is then edited directly.
    func editedInDropbox() async throws -> (OneWayDiskWorld, Sync) {
        let world = try OneWayDiskWorld()
        try run.write(world, .iCloud, "Legal/POA.pdf", "iCloud's", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Legal"])
        try await sync.run()
        try run.write(world, .dropbox, "Legal/POA.pdf", "edited in Dropbox", modified: OneWayDiskWorld.day0)
        return (world, sync)
    }

    func versions(_ sync: Sync, _ path: String) throws -> OneWaySyncVersions {
        let look = sync.look()
        let wait = try #require(look.plan.waits.first { if case .file(let i, _) = $0.subject { return i == path } else { return false } })
        return try #require(OneWaySyncAnswers.versions(for: wait.subject, in: look))
    }

    @Test func useICloudsPutsICloudsVersionBackAndKeepsDropboxsEdit() async throws {
        let (world, sync) = try await editedInDropbox()
        defer { world.remove() }
        #expect(sync.look().plan.waits.map(\.reason) == [.editedInDropbox])
        try OneWaySyncAnswers.useICloudsVersion(try versions(sync, "Legal/POA.pdf"), writer: world.writer())
        #expect(world.read(.dropbox, "Legal/POA.pdf") == "iCloud's")
        let kept = try world.writer().removed.items()
        #expect(kept.map { world.read(account: $0.path) } == ["edited in Dropbox"])
        #expect(kept.map(\.origin.kind) == [.replacedDropboxVersion])
        // The next pass finds the two agreeing: nothing to do, nothing waits.
        try await sync.run()
        #expect(sync.look().plan.steps.isEmpty)
        #expect(sync.look().plan.waits.isEmpty)
    }

    @Test func copyDropboxsIntoICloudKeepsICloudsVersion() async throws {
        let (world, sync) = try await editedInDropbox()
        defer { world.remove() }
        let iCloudID = world.documentID(.iCloud, "Legal/POA.pdf")
        try OneWaySyncAnswers.copyDropboxsIntoICloud(try versions(sync, "Legal/POA.pdf"), writer: world.writer())
        #expect(world.read(.iCloud, "Legal/POA.pdf") == "edited in Dropbox")
        // Renamed over, so iCloud's item stays the same one.
        #expect(world.documentID(.iCloud, "Legal/POA.pdf") == iCloudID)
        let kept = try world.writer().removed.items()
        #expect(kept.map(\.origin.kind) == [.replacedICloudVersion])
        #expect(kept.map { world.read(account: $0.path) } == ["iCloud's"])
        try await sync.run()
        #expect(sync.look().plan.steps.isEmpty)
        #expect(sync.look().plan.waits.isEmpty)
        #expect(sync.file("Legal/POA.pdf")?.size == Int64("edited in Dropbox".utf8.count))
    }

    @Test func stopSyncingThisFileLeavesDropboxsVersionAndListsIt() async throws {
        let (world, sync) = try await editedInDropbox()
        defer { world.remove() }
        let (record, exclusions) = OneWaySyncAnswers.stopSyncingFile(try versions(sync, "Legal/POA.pdf"), record: sync.record,
                                                                     exclusions: OneWaySyncExclusions(), now: OneWayDiskWorld.day0)
        #expect(record.files.isEmpty)
        #expect(exclusions.files.map(\.iCloudPath) == ["Legal/POA.pdf"])
        sync.record = record
        let look = OneWaySyncRun.look(record: record, state: sync.state, exclusions: exclusions, places: world.places,
                                      download: false, now: sync.now, isShared: { _ in false })
        #expect(look.plan.steps.isEmpty)
        #expect(look.plan.waits.isEmpty)
        #expect(world.read(.dropbox, "Legal/POA.pdf") == "edited in Dropbox")
    }

    @Test func matchICloudMovesARenamedDropboxCopyBack() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Legal/Will.pdf", "will")
        let sync = try Sync(world: world, folders: ["Legal"])
        sync.state.settings.whenDeletedRenamedOrMoved = .askMe
        try await sync.run()
        try run.move(world, .dropbox, "Legal/Will.pdf", "Legal/Renamed.pdf")
        #expect(sync.look().plan.waits.map(\.reason) == [.deletedOrMovedInDropbox])
        try OneWaySyncAnswers.matchICloud(try versions(sync, "Legal/Will.pdf"), writer: world.writer())
        #expect(world.read(.dropbox, "Legal/Will.pdf") == "will")
        #expect(world.read(.dropbox, "Legal/Renamed.pdf") == nil)
        try await sync.run()
        #expect(sync.look().plan.waits.isEmpty)
        #expect(sync.look().plan.steps.isEmpty)
    }

    @Test func renameDropboxsTooFollowsASyncedFolderRenamedInICloud() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Health/x.pdf", "x")
        let sync = try Sync(world: world, folders: ["Health"])
        try await sync.run()
        try run.move(world, .iCloud, "Health", "Medical")
        let look = sync.look()
        #expect(look.plan.waits.map(\.reason) == [.syncedFolderRenamedInICloud(to: "Medical")])
        sync.record = try OneWaySyncAnswers.renameDropboxFolderToo("Health", look: look, writer: world.writer())
        #expect(world.read(.dropbox, "Medical/x.pdf") == "x")
        #expect(sync.record.syncedFolders.map(\.dropboxPath) == ["Medical"])
        let after = sync.look()
        #expect(after.plan.waits.isEmpty)
        #expect(after.plan.steps.isEmpty)
    }

    @Test func aSyncedFolderDeletedInICloudGoesToSyncCloudRemovedButKeepsDropboxOnlyFiles() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Old/a.pdf", "a")
        let sync = try Sync(world: world, folders: ["Old"])
        try await sync.run()
        try run.write(world, .dropbox, "Old/mine.txt", "only in Dropbox")
        try FileManager.default.removeItem(at: world.iCloud.appendingPathComponent("Old"))
        let look = sync.look()
        #expect(look.plan.waits.map(\.reason) == [.syncedFolderMovedOrDeletedInICloud])
        let (record, failed) = OneWaySyncAnswers.moveFolderToRemoved("Old", look: look, writer: try world.writer())
        #expect(failed.isEmpty)
        #expect(record.syncedFolders.isEmpty)
        #expect(record.files.isEmpty)
        #expect(world.read(.dropbox, "Old/a.pdf") == nil)
        // It stays while it holds a Dropbox-only file.
        #expect(world.read(.dropbox, "Old/mine.txt") == "only in Dropbox")
        let kept = try world.writer().removed.items().map { world.read(account: $0.path) }
        #expect(kept == ["a"])
    }

    @Test func reverseInICloudUndoesARenameAndBringsBackADeletion() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/W-2.pdf", "w2", modified: OneWaySyncRunTests.earlier)
        try run.write(world, .iCloud, "Finance/Old.pdf", "old", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try run.move(world, .iCloud, "Finance/W-2.pdf", "Finance/2026 W-2.pdf")
        try FileManager.default.removeItem(at: world.iCloud.appendingPathComponent("Finance/Old.pdf"))
        try await sync.run()
        sync.now = sync.now.addingTimeInterval(31 * 60)
        try await sync.run()
        let entries = sync.store.history.entries()
        let renamed = try #require(entries.first { $0.steps.contains { if case .moveInDropbox = $0.step.action { return true } else { return false } } })
        let removed = try #require(entries.first { $0.steps.contains { if case .moveToRemoved = $0.step.action { return true } else { return false } } })
        let look = sync.look()
        let store = try world.writer().removed.items()
        let undoRename = OneWaySyncAnswers.reversals(of: renamed, look: look, removed: store)
        #expect(undoRename.map(\.summary) == ["rename back to W-2.pdf"])
        let undoDelete = OneWaySyncAnswers.reversals(of: removed, look: look, removed: store)
        #expect(undoDelete.map(\.summary) == ["bring back from SyncCloud Removed"])

        let failed = OneWaySyncAnswers.reverse(undoRename + undoDelete, writer: try world.writer())
        #expect(failed.isEmpty)
        #expect(world.read(.iCloud, "Finance/W-2.pdf") == "w2")
        #expect(world.read(.iCloud, "Finance/Old.pdf") == "old")
        // The sync then carries them over as usual.
        try await sync.run()
        #expect(world.read(.dropbox, "Finance/W-2.pdf") == "w2")
        #expect(world.read(.dropbox, "Finance/Old.pdf") == "old")
        #expect(sync.look().plan.steps.isEmpty)
    }

    @Test func aRenamedICloudFileStopsWaitingOnADropboxOnlyName() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try run.write(world, .dropbox, "Finance/Taken.pdf", "Dropbox's own, longer")
        try run.write(world, .iCloud, "Finance/Taken.pdf", "iCloud's")
        #expect(sync.look().plan.waits.map(\.reason) == [.nameTakenByDropboxOnlyFile("Finance/Taken.pdf")])
        try OneWaySyncAnswers.renameICloudFile("Finance/Taken.pdf", to: "Taken (iCloud).pdf", places: world.places)
        try await sync.run()
        #expect(world.read(.dropbox, "Finance/Taken (iCloud).pdf") == "iCloud's")
        #expect(world.read(.dropbox, "Finance/Taken.pdf") == "Dropbox's own, longer")
    }

    @Test func keepInDropboxDropsTheRecordOfAnUntickedRemoval() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        for index in 0..<30 { try run.write(world, .iCloud, "Legal/\(index).pdf", "file \(index)") }
        let sync = try Sync(world: world, folders: ["Legal"])
        try await sync.run()
        for index in 0..<30 { try FileManager.default.removeItem(at: world.iCloud.appendingPathComponent("Legal/\(index).pdf")) }
        try await sync.run()
        sync.now = sync.now.addingTimeInterval(31 * 60)
        let look = sync.look()
        let pending = OneWaySyncAnswers.pendingRemovals(in: look, folder: "Legal")
        #expect(pending.count == 30)
        #expect(look.plan.steps.isEmpty)
        let (record, exclusions) = OneWaySyncAnswers.keepInDropbox(Array(pending.prefix(10)), look: look, record: sync.record,
                                                                   exclusions: OneWaySyncExclusions(), now: sync.now)
        #expect(record.files.count == 20)
        #expect(exclusions.files.isEmpty)
        // The rest, confirmed, go ahead and don't count.
        sync.record = record
        sync.state.confirmed = pending.dropFirst(10).map(\.record)
        try await sync.run()
        #expect(sync.record.files.isEmpty)
        let left = (0..<30).map { "Legal/\($0).pdf" }.filter { world.read(.dropbox, $0) != nil }
        #expect(Set(left) == Set(pending.prefix(10).map(\.iCloudPath)))
        #expect(sync.state.confirmed.isEmpty)
    }
}
