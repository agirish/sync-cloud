import Darwin
import Foundation
import Testing
@testable import Sync

/// The plan's other actions on disk: copy, move in Dropbox, tags, and the coordinated, checked
/// read every copy goes through.
@Suite struct OneWaySyncWriterTests {

    @Test func aCopyLandsUnderANewNameWithNoneOfDropboxsAttributes() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let source = try world.write(.iCloud, "Finance/2026/Receipts/Invoice.pdf", "invoice")
        setxattr(source.path, "com.dropbox.attrs", "id", 2, 0, 0)
        setxattr(source.path, "com.example.kept", "k", 1, 0, 0)
        try world.writer().copy(from: "Finance/2026/Receipts/Invoice.pdf", to: "Finance/2026/Receipts/Invoice.pdf", needsDownload: false)
        let copy = world.dropbox.appendingPathComponent("Finance/2026/Receipts/Invoice.pdf").path
        #expect(world.read(.dropbox, "Finance/2026/Receipts/Invoice.pdf") == "invoice")
        // Others' attributes stay; macOS adds its own (`com.apple.provenance`) to a new file.
        let names = OneWaySyncDisk.attributeNames(at: copy)
        #expect(names.contains("com.example.kept"))
        #expect(!names.contains { $0.hasPrefix("com.dropbox.") })
        #expect(world.stagingContents == [])
    }

    @Test func aCopyNeverOverwritesATakenName() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, "Finance/a.pdf", "iCloud's")
        try world.write(.dropbox, "Finance/A.PDF", "a Dropbox-only file")
        #expect(throws: OneWaySyncWriteError.nameTaken(world.dropbox.appendingPathComponent("Finance/a.pdf").path)) {
            try world.writer().copy(from: "Finance/a.pdf", to: "Finance/a.pdf", needsDownload: false)
        }
        #expect(world.read(.dropbox, "Finance/A.PDF") == "a Dropbox-only file")
        #expect(world.stagingContents == [])
    }

    /// A Finder lock would stop the staged copy ever being moved into Dropbox; the copy drops it
    /// and iCloud's file keeps it.
    @Test func aLockedFileStillCopies() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let source = try world.write(.iCloud, "Finance/locked.pdf", "locked")
        setxattr(source.path, "com.dropbox.attrs", "id", 2, 0, 0)
        #expect(chflags(source.path, UInt32(UF_IMMUTABLE)) == 0)
        try world.writer().copy(from: "Finance/locked.pdf", to: "Finance/locked.pdf", needsDownload: false)
        var info = stat()
        let copy = world.dropbox.appendingPathComponent("Finance/locked.pdf").path
        lstat(copy, &info)
        #expect(info.st_flags & UInt32(UF_IMMUTABLE) == 0)
        // A locked file refuses to lose an attribute: the lock goes first.
        #expect(!OneWaySyncDisk.attributeNames(at: copy).contains { $0.hasPrefix("com.dropbox.") })
        lstat(source.path, &info)
        #expect(info.st_flags & UInt32(UF_IMMUTABLE) != 0)
    }

    @Test func aFileThatChangesDuringTheCopyIsNotCopied() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, "Finance/a.pdf", "first")
        let writer = try world.writer()
        writer.afterCopy = { url in try? Data("second, longer".utf8).write(to: url) }
        #expect(throws: OneWaySyncWriteError.changedDuringCopy(world.iCloud.appendingPathComponent("Finance/a.pdf").path)) {
            try writer.copy(from: "Finance/a.pdf", to: "Finance/a.pdf", needsDownload: false)
        }
        #expect(world.read(.dropbox, "Finance/a.pdf") == nil)
        #expect(world.stagingContents == [])

        // A change that leaves size and date alone still moves the change time.
        writer.afterCopy = { url in setxattr(url.path, "com.example.touched", "t", 1, 0, 0) }
        #expect(throws: OneWaySyncWriteError.changedDuringCopy(world.iCloud.appendingPathComponent("Finance/a.pdf").path)) {
            try writer.copy(from: "Finance/a.pdf", to: "Finance/a.pdf", needsDownload: false)
        }

        writer.afterCopy = { _ in }
        try writer.copy(from: "Finance/a.pdf", to: "Finance/a.pdf", needsDownload: false)
        #expect(world.read(.dropbox, "Finance/a.pdf") == "second, longer")
    }

    /// A file another process holds for writing isn't read until it lets go; past the deadline the
    /// copy gives up and writes nothing.
    @Test(.parksAThread) func aCopyWaitsForAWriterOnlyUntilItsDeadline() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let source = try world.write(.iCloud, "Finance/busy.pdf", "busy")
        let writer = try world.writer()
        writer.coordinationDeadline = 0.3

        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            NSFileCoordinator().coordinate(writingItemAt: source, options: [], error: nil) { _ in
                holding.signal()
                _ = release.wait(timeout: .now() + 60)
            }
            done.signal()
        }
        #expect(holding.wait(timeout: .now() + 30) == .success)
        let start = ContinuousClock.now
        #expect(throws: OneWaySyncWriteError.coordinationTimedOut(source.path)) {
            try writer.copy(from: "Finance/busy.pdf", to: "Finance/busy.pdf", needsDownload: false)
        }
        // It gave up at its deadline, not when the writer let go.
        #expect(ContinuousClock.now - start < .seconds(30))
        #expect(world.read(.dropbox, "Finance/busy.pdf") == nil)
        release.signal()
        #expect(done.wait(timeout: .now() + 30) == .success)

        // With the writer gone, the same copy goes through.
        try writer.copy(from: "Finance/busy.pdf", to: "Finance/busy.pdf", needsDownload: false)
        #expect(world.read(.dropbox, "Finance/busy.pdf") == "busy")
    }

    @Test func anOffloadedFileIsOffloadedAgainAfterItsCopy() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, "Finance/a.pdf", "a")
        try world.write(.iCloud, "Finance/b.pdf", "b")
        let writer = try world.writer()
        var evicted: [String] = []
        writer.evict = { evicted.append($0.lastPathComponent) }
        try writer.copy(from: "Finance/a.pdf", to: "Finance/a.pdf", needsDownload: true)
        try writer.copy(from: "Finance/b.pdf", to: "Finance/b.pdf", needsDownload: false)
        #expect(evicted == ["a.pdf"])
    }

    @Test func movesNeverOverwriteAndFollowNoSymlink() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let writer = try world.writer()
        try world.write(.dropbox, "Finance/a.pdf", "a")
        try world.write(.dropbox, "Finance/b.pdf", "b")
        #expect(throws: OneWaySyncWriteError.nameTaken(world.dropbox.appendingPathComponent("Finance/b.pdf").path)) {
            try writer.move(from: "Finance/a.pdf", to: "Finance/b.pdf")
        }
        #expect(world.read(.dropbox, "Finance/b.pdf") == "b")

        // A folder on the way that is a symlink is refused, not followed.
        let elsewhere = world.root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: world.dropbox.appendingPathComponent("Finance/Linked"), withDestinationURL: elsewhere)
        #expect(throws: OneWaySyncWriteError.symlink(world.dropbox.appendingPathComponent("Finance/Linked").path)) {
            try writer.move(from: "Finance/a.pdf", to: "Finance/Linked/a.pdf")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path) == [])
        #expect(throws: OneWaySyncWriteError.badPath("Finance/../../a.pdf")) {
            try writer.move(from: "Finance/a.pdf", to: "Finance/../../a.pdf")
        }
    }

    @Test func aChangeOfLetterCaseRenamesInPlace() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.dropbox, "Finance/w-2.pdf", "w2")
        let id = world.documentID(.dropbox, "Finance/w-2.pdf")
        try world.writer().move(from: "Finance/w-2.pdf", to: "Finance/W-2.pdf")
        #expect(try FileManager.default.contentsOfDirectory(atPath: world.dropbox.appendingPathComponent("Finance").path) == ["W-2.pdf"])
        #expect(world.documentID(.dropbox, "Finance/W-2.pdf") == id)
    }

    @Test func aMoveRefusesADropboxFileChangedSinceTheDiff() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.dropbox, "Finance/a.pdf", "a")
        var expected = try world.expected("Finance/a.pdf")
        expected.modified -= 60
        #expect(throws: OneWaySyncWriteError.changedSinceDiff(world.dropbox.appendingPathComponent("Finance/a.pdf").path)) {
            try world.writer().move(from: "Finance/a.pdf", to: "Finance/b.pdf", expected: expected)
        }
        #expect(world.read(.dropbox, "Finance/a.pdf") == "a")
    }

    @Test func tagsAreSetOnTheDropboxFile() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.dropbox, "Finance/a.pdf", "a")
        try world.writer().setTags(dropboxPath: "Finance/a.pdf", tags: ["Taxes", "Red"])
        let tags = try world.dropbox.appendingPathComponent("Finance/a.pdf").resourceValues(forKeys: [.tagNamesKey]).tagNames
        #expect(Set(tags ?? []) == ["Taxes", "Red"])
    }

    @Test func tagsWaitForADropboxFileChangedSinceTheDiff() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.dropbox, "Finance/a.pdf", "a")
        var expected = try world.expected("Finance/a.pdf")
        expected.size = 99
        #expect(throws: OneWaySyncWriteError.changedSinceDiff(world.dropbox.appendingPathComponent("Finance/a.pdf").path)) {
            try world.writer().setTags(dropboxPath: "Finance/a.pdf", tags: ["Red"], expected: expected)
        }
        let tags = try world.dropbox.appendingPathComponent("Finance/a.pdf").resourceValues(forKeys: [.tagNamesKey]).tagNames
        #expect((tags ?? []).isEmpty)
    }

    @Test func stagingInsideDropboxOrOnAnotherVolumeIsRefused() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        var places = world.places
        places.staging = world.account.appendingPathComponent("Staging")
        #expect(throws: OneWaySyncWriteError.stagingUnusable(places.staging.path)) { try OneWaySyncWriter(places: places) }
        places.staging = world.iCloud.appendingPathComponent("Finance/Staging")
        #expect(throws: OneWaySyncWriteError.stagingUnusable(places.staging.path)) { try OneWaySyncWriter(places: places) }
        // Spelled through /var, the symlink to /private/var: still inside.
        places.staging = URL(fileURLWithPath: world.account.path.replacingOccurrences(of: "/private/var/", with: "/var/") + "/Staging")
        #expect(throws: OneWaySyncWriteError.stagingUnusable(places.staging.path)) { try OneWaySyncWriter(places: places) }
        // Nothing was created inside Dropbox or iCloud by asking.
        #expect(!world.everythingInDropbox.contains("Staging"))
        #expect(OneWaySyncDisk.kind(at: world.iCloud.appendingPathComponent("Finance").path) == nil)
        // /dev is a volume of its own on every Mac.
        places.staging = URL(fileURLWithPath: "/dev/fd")
        #expect(throws: OneWaySyncWriteError.self) { try OneWaySyncWriter(places: places) }
    }

    @Test func leftoverStagingIsRemoved() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let writer = try world.writer()
        try Data("left".utf8).write(to: world.staging.appendingPathComponent("abc-a.pdf"))
        writer.removeTemporaryFiles()
        #expect(world.stagingContents == [])
    }

    // MARK: From a plan

    /// The planner's steps, applied in order to a real folder: a swap through its temporary name,
    /// an edit and a new file. Pins `apply` to the actions the planner emits.
    @Test func aPlanAppliesOnDisk() throws {
        let a = "Finance/a.pdf", b = "Finance/b.pdf", c = "Finance/c.pdf"
        var plan = OneWayWorld(files: [a, b, c])
        let disk = try OneWayDiskWorld()
        defer { disk.remove() }
        for (path, contents) in [(a, "A"), (b, "B"), (c, "C")] {
            try disk.write(.iCloud, path, contents, modified: OneWayWorld.t0)
            try disk.write(.dropbox, path, contents, modified: OneWayWorld.t0)
            for side in OneWaySyncSide.allCases {
                plan.update(side, path) { $0.size = 1; $0.documentID = disk.documentID(side, path) ?? $0.documentID }
            }
        }
        for index in plan.record.files.indices {
            plan.record.files[index].size = 1
            plan.record.files[index].dropboxID = disk.documentID(.dropbox, plan.record.files[index].dropboxPath)
        }
        // a and b swap names in iCloud; c is edited; d is new.
        try FileManager.default.moveItem(at: disk.iCloud.appendingPathComponent(a), to: disk.iCloud.appendingPathComponent("Finance/x"))
        try FileManager.default.moveItem(at: disk.iCloud.appendingPathComponent(b), to: disk.iCloud.appendingPathComponent(a))
        try FileManager.default.moveItem(at: disk.iCloud.appendingPathComponent("Finance/x"), to: disk.iCloud.appendingPathComponent(b))
        plan.update(.iCloud, a) { $0.path = "x" }
        plan.update(.iCloud, b) { $0.path = a }
        plan.update(.iCloud, "x") { $0.path = b }
        try disk.write(.iCloud, c, "C edited")
        plan.edit(.iCloud, c, size: 8)
        try disk.write(.iCloud, "Finance/d.pdf", "D")
        plan.add(.iCloud, OneWayWorld.file("Finance/d.pdf", id: 99, size: 1, hash: "d"))

        let steps = plan.plan().steps
        #expect(steps.map(\.action) == [
            .replace(dropboxPath: c, with: c, needsDownload: false, previousIsDropboxEdit: false),
            .moveInDropbox(from: a, to: "Finance/.SyncCloud-swap-1-a.pdf"),
            .moveInDropbox(from: b, to: a),
            .moveInDropbox(from: "Finance/.SyncCloud-swap-1-a.pdf", to: b),
            .copy(from: "Finance/d.pdf", to: "Finance/d.pdf", needsDownload: false),
        ])
        let writer = try disk.writer()
        let listed = Dictionary(uniqueKeysWithValues: plan.dropbox.map { ($0.path, $0) })
        for step in steps {
            let file = plan.record.files.first { $0.key == step.record }
            // What the diff saw of the file the step touches, wherever earlier steps put it.
            let expected = file.flatMap { listed[$0.dropboxPath] }.map { OneWaySyncExpectedState($0) }
            _ = try writer.apply(step, expected: expected, file: file)
        }
        #expect(disk.read(.dropbox, a) == "B")
        #expect(disk.read(.dropbox, b) == "A")
        #expect(disk.read(.dropbox, c) == "C edited")
        #expect(disk.read(.dropbox, "Finance/d.pdf") == "D")
        #expect(disk.read(account: "SyncCloud Removed/2026-10-30/Documents/Finance/c.pdf") == "C")
        #expect(!disk.everythingInDropbox.contains { $0.contains(OneWaySyncPlanner.temporaryNamePrefix) })
    }
}
