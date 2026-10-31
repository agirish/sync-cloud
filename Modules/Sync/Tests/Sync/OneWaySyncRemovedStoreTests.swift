import Darwin
import Foundation
import Testing
@testable import Sync

/// Dropbox ▸ SyncCloud Removed: moves in stay inside Dropbox, nothing overwrites anything, each
/// item says where it came from, Restore keeps both, and Choose Items to Empty goes by age and size.
@Suite struct OneWaySyncRemovedStoreTests {

    func store(_ world: OneWayDiskWorld) -> OneWaySyncRemovedStore {
        OneWaySyncRemovedStore(accountFolder: world.account, calendar: OneWayDiskWorld.calendar)
    }

    @Test func aRemovalIsARenameInsideDropbox() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let file = try world.write(.dropbox, "Finance/Old scan.pdf", "scan")
        let inode = world.inode(file)
        let id = try #require(world.documentID(.dropbox, "Finance/Old scan.pdf"))

        let item = try world.writer().moveToRemoved(dropboxPath: "Finance/Old scan.pdf", cause: .movedOutInICloud(to: "Work"),
                                                    iCloudPath: "Finance/Old scan.pdf", expected: try world.expected("Finance/Old scan.pdf"))

        let placed = world.account.appendingPathComponent(item.path)
        #expect(item.path == "SyncCloud Removed/2026-10-30/Documents/Finance/Old scan.pdf")
        // The same file, not a copy: nothing for Dropbox to download or upload again.
        #expect(world.inode(placed) == inode)
        #expect(OneWaySyncDisk.documentID(at: placed.path) == id)
        #expect(world.read(.dropbox, "Finance/Old scan.pdf") == nil)
        #expect(item.origin.kind == .movedOutInICloud)
        #expect(item.origin.fileID == id)
    }

    @Test func itemsNeverOverwriteEachOther() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let writer = try world.writer()
        for contents in ["first", "second", "third"] {
            try world.write(.dropbox, "Finance/a.pdf", contents)
            _ = try writer.moveToRemoved(dropboxPath: "Finance/a.pdf", cause: .deletedInICloud, iCloudPath: "Finance/a.pdf", expected: nil)
        }
        try world.write(.dropbox, "Finance/README", "no extension")
        _ = try writer.moveToRemoved(dropboxPath: "Finance/README", cause: .deletedInICloud, iCloudPath: nil, expected: nil)
        try world.write(.dropbox, "Finance/README", "again")
        _ = try writer.moveToRemoved(dropboxPath: "Finance/README", cause: .deletedInICloud, iCloudPath: nil, expected: nil)

        let folder = "SyncCloud Removed/2026-10-30/Documents/Finance/"
        #expect(world.read(account: folder + "a.pdf") == "first")
        #expect(world.read(account: folder + "a 2.pdf") == "second")
        #expect(world.read(account: folder + "a 3.pdf") == "third")
        #expect(world.read(account: folder + "README") == "no extension")
        #expect(world.read(account: folder + "README 2") == "again")
    }

    /// Turn Off removes the record, not the store: each item says where it came from on its own,
    /// so a fresh store reading only the disk knows.
    @Test func eachItemSaysWhereItCameFromWithoutTheRecord() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.dropbox, "Legal/2019/Lease.pdf", "lease")
        let id = try #require(world.documentID(.dropbox, "Legal/2019/Lease.pdf"))
        let item = try world.writer().moveToRemoved(dropboxPath: "Legal/2019/Lease.pdf", cause: .deletedInICloud,
                                                    iCloudPath: "Legal/2019/Lease.pdf", expected: nil)
        let read = store(world).items()
        #expect(read == [item])
        #expect(read.first?.origin == OneWaySyncRemovedItem.Origin(
            dropboxPath: "Documents/Legal/2019/Lease.pdf", iCloudParent: world.iCloud.path, iCloudPath: "Legal/2019/Lease.pdf",
            fileID: id, removedAt: 1_793_361_600, kind: .deletedInICloud))
        #expect(read.first?.size == 5)
    }

    /// An item that lost its attribute (copied in by hand, or by Dropbox from another Mac that
    /// dropped it) is still read from its place.
    @Test func anItemWithNoRecordIsReadFromItsPlace() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let url = world.account.appendingPathComponent("SyncCloud Removed/2026-09-02/Documents/Health/x-ray.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: url)
        try Data().write(to: url.deletingLastPathComponent().appendingPathComponent(".DS_Store"))
        #expect(store(world).items() == [OneWaySyncRemovedItem(
            path: "SyncCloud Removed/2026-09-02/Documents/Health/x-ray.png",
            origin: .init(dropboxPath: "Documents/Health/x-ray.png", removedAt: 1_788_307_200, kind: .unrecorded), size: 3)])
    }

    @Test func restoreToICloudKeepsBothWhenTheNameIsTaken() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let writer = try world.writer()
        let removed = try world.write(.dropbox, "Finance/W-2.pdf", "the removed one")
        setxattr(removed.path, "com.dropbox.attrs", "id", 2, 0, 0)
        let item = try writer.moveToRemoved(dropboxPath: "Finance/W-2.pdf", cause: .deletedInICloud, iCloudPath: "Finance/W-2.pdf", expected: nil)
        try world.write(.iCloud, "Finance/W-2.pdf", "a new one in iCloud")

        let restored = try store(world).restoreToICloud(item, iCloudParent: world.iCloud, staging: world.staging, deadline: 10)

        #expect(restored.lastPathComponent == "W-2 2.pdf")
        #expect(world.read(.iCloud, "Finance/W-2.pdf") == "a new one in iCloud")
        #expect(world.read(.iCloud, "Finance/W-2 2.pdf") == "the removed one")
        let names = OneWaySyncDisk.attributeNames(at: restored.path)
        #expect(!names.contains(OneWaySyncRemovedStore.originAttribute))
        #expect(!names.contains { $0.hasPrefix("com.dropbox.") })
        // The item stays until the sync puts it back in Dropbox.
        #expect(store(world).items() == [item])
        #expect(world.stagingContents == [])
    }

    @Test func restoreRecreatesTheFoldersItCameFrom() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.dropbox, "Legal/2019/Lease.pdf", "lease")
        let item = try world.writer().moveToRemoved(dropboxPath: "Legal/2019/Lease.pdf", cause: .deletedInICloud,
                                                    iCloudPath: "Legal/2019/Lease.pdf", expected: nil)
        let restored = try store(world).restoreToICloud(item, iCloudParent: world.iCloud, staging: world.staging, deadline: 10)
        #expect(restored.path == world.iCloud.appendingPathComponent("Legal/2019/Lease.pdf").path)
        #expect(world.read(.iCloud, "Legal/2019/Lease.pdf") == "lease")
    }

    @Test func chooseItemsToEmptyByAgeAndSize() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        // Newest is largest, so the two orders differ.
        let sizes = [("old.pdf", 10, -40), ("middle.pdf", 1, -10), ("new.pdf", 100, 0)]
        for (name, size, days) in sizes {
            let writer = try world.writer(at: OneWayDiskWorld.day0.addingTimeInterval(Double(days) * 86_400))
            try world.write(.dropbox, "Finance/" + name, String(repeating: "x", count: size))
            _ = try writer.moveToRemoved(dropboxPath: "Finance/" + name, cause: .deletedInICloud, iCloudPath: nil, expected: nil)
        }
        let store = store(world)
        func names(_ items: [OneWaySyncRemovedItem]) -> [String] { items.map { OneWaySyncPath.name($0.path) } }
        #expect(names(store.itemsToEmpty(.oldestFirst)) == ["old.pdf", "middle.pdf", "new.pdf"])
        #expect(names(store.itemsToEmpty(.largestFirst)) == ["new.pdf", "old.pdf", "middle.pdf"])
        #expect(names(store.items(removedBefore: OneWayDiskWorld.day0.addingTimeInterval(-30 * 86_400))) == ["old.pdf"])

        let emptied = store.empty(store.items(removedBefore: OneWayDiskWorld.day0.addingTimeInterval(-5 * 86_400)))
        #expect(names(emptied.emptied) == ["old.pdf", "middle.pdf"])
        #expect(emptied.bytes == 11)
        #expect(names(store.items()) == ["new.pdf"])
        // Their date folders went with them; the store itself stays.
        #expect(world.everythingInDropbox.filter { $0.hasPrefix("SyncCloud Removed/") && OneWaySyncPath.depth($0) == 2 }
            == ["SyncCloud Removed/2026-10-30"])
    }

    @Test func emptyRefusesAnythingOutsideTheStore() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.dropbox, "Finance/live.pdf", "live")
        let outside = OneWaySyncRemovedItem(path: "Documents/Finance/live.pdf",
                                            origin: .init(dropboxPath: "Documents/Finance/live.pdf", removedAt: 0, kind: .unrecorded), size: 4)
        let sneaky = OneWaySyncRemovedItem(path: "SyncCloud Removed/../Documents/Finance/live.pdf", origin: outside.origin, size: 4)
        let result = store(world).empty([outside, sneaky])
        #expect(result.emptied == [])
        #expect(result.failed.count == 2)
        #expect(world.read(.dropbox, "Finance/live.pdf") == "live")
    }

    /// What was chosen is deleted only while it is still at its place: a different item that has
    /// taken the name since is left alone.
    @Test func emptyLeavesAnItemThatHasTakenAChosenOnesPlace() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let writer = try world.writer()
        try world.write(.dropbox, "Finance/a.pdf", "first")
        let chosen = try writer.moveToRemoved(dropboxPath: "Finance/a.pdf", cause: .deletedInICloud, iCloudPath: "Finance/a.pdf", expected: nil)
        try writer.moveBack(removedPath: chosen.path, to: "Finance/a.pdf")
        try world.write(.dropbox, "Finance/a.pdf", "second")
        let later = try world.writer(at: OneWayDiskWorld.day0.addingTimeInterval(60))
        let newer = try later.moveToRemoved(dropboxPath: "Finance/a.pdf", cause: .deletedInICloud, iCloudPath: "Finance/a.pdf", expected: nil)
        #expect(newer.path == chosen.path)

        let result = store(world).empty([chosen])
        #expect(result.emptied == [])
        #expect(result.failed == [chosen])
        #expect(world.read(account: newer.path) == "second")
    }

    /// Reached through a symlink, as `~/Dropbox` reaches the account folder: the store resolves
    /// it once, so its moves, which refuse any symlink on the way, still go.
    @Test func aStoreReachedThroughASymlinkStillWorks() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let link = world.root.appendingPathComponent("Dropbox link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: world.account)
        let file = try world.write(.dropbox, "Finance/a.pdf", "a")
        let store = OneWaySyncRemovedStore(accountFolder: link, calendar: OneWayDiskWorld.calendar)
        let item = try store.moveIn(file, origin: .init(dropboxPath: "Documents/Finance/a.pdf", iCloudPath: "Finance/a.pdf",
                                                        removedAt: 1_793_361_600, kind: .deletedInICloud))
        #expect(world.read(account: item.path) == "a")
        let iCloudLink = world.root.appendingPathComponent("iCloud link")
        try FileManager.default.createSymbolicLink(at: iCloudLink, withDestinationURL: world.iCloud)
        let restored = try store.restoreToICloud(item, iCloudParent: iCloudLink, staging: world.staging, deadline: 10)
        #expect(world.read(.iCloud, "Finance/a.pdf") == "a")
        #expect(restored.path == world.iCloud.appendingPathComponent("Finance/a.pdf").path)
    }

    @Test func pruningRemovesOnlyFoldersThatAreEmpty() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let store = store(world)
        let deep = world.account.appendingPathComponent("SyncCloud Removed/2026-10-30/Documents/Finance/2026")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data().write(to: deep.appendingPathComponent(".DS_Store"))
        try Data("kept".utf8).write(to: deep.deletingLastPathComponent().appendingPathComponent("b.pdf"))
        store.pruneEmptyFolders(above: "SyncCloud Removed/2026-10-30/Documents/Finance/2026/a.pdf")
        #expect(OneWaySyncDisk.kind(at: deep.path) == nil)
        #expect(world.read(account: "SyncCloud Removed/2026-10-30/Documents/Finance/b.pdf") == "kept")
    }

    @Test func movingBackOutOfTheStoreDropsTheOriginAndTheEmptyFolders() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let writer = try world.writer()
        try world.write(.dropbox, "Finance/a.pdf", "a")
        let item = try writer.moveToRemoved(dropboxPath: "Finance/a.pdf", cause: .deletedInICloud, iCloudPath: "Finance/a.pdf", expected: nil)
        try writer.moveBack(removedPath: item.path, to: "Finance/2026/a.pdf")
        #expect(world.read(.dropbox, "Finance/2026/a.pdf") == "a")
        #expect(OneWaySyncDisk.attribute(OneWaySyncRemovedStore.originAttribute,
                                         at: world.dropbox.appendingPathComponent("Finance/2026/a.pdf").path) == nil)
        #expect(world.everythingInDropbox.filter { $0.hasPrefix("SyncCloud Removed") } == ["SyncCloud Removed"])
    }
}
