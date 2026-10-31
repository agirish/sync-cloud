import Darwin
import Foundation
import Testing
@testable import Sync

/// Sync replace: iCloud's file goes over Dropbox's and the Dropbox item stays; Dropbox's previous
/// version is cloned into SyncCloud Removed, one a day (DG), seven at most (DJ).
@Suite struct OneWaySyncReplaceTests {
    static let path = "Finance/W-2.pdf"
    static let removedToday = "SyncCloud Removed/2026-10-30/Documents/Finance/W-2.pdf"

    @Test func aReplaceKeepsTheDropboxItemAndClonesTheOldVersion() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, Self.path, "new from iCloud")
        let old = try world.write(.dropbox, Self.path, "old in Dropbox")
        setxattr(old.path, "com.dropbox.attrs", "id", 2, 0, 0)
        let id = try #require(world.documentID(.dropbox, Self.path))
        let inodeBefore = world.inode(old)

        let result = try world.writer().replace(dropboxPath: Self.path, with: Self.path, needsDownload: false,
                                                previousIsDropboxEdit: false, expected: try world.expected(Self.path))

        #expect(world.read(.dropbox, Self.path) == "new from iCloud")
        // The item stays: same document ID, on a new inode, as a rename-over does.
        #expect(world.documentID(.dropbox, Self.path) == id)
        #expect(world.inode(old) != inodeBefore)
        // The previous version, cloned, filed by date under its Dropbox path.
        #expect(result.kept?.path == Self.removedToday)
        #expect(world.read(account: Self.removedToday) == "old in Dropbox")
        #expect(result.kept?.origin == OneWaySyncRemovedItem.Origin(
            dropboxPath: "Documents/" + Self.path, iCloudParent: world.iCloud.path, iCloudPath: Self.path, fileID: id,
            removedAt: Int64(OneWayDiskWorld.day0.timeIntervalSince1970), kind: .replacedSyncCloudVersion))
        // A clone is a new file to Dropbox: none of Dropbox's attributes, no document ID.
        let clone = world.account.appendingPathComponent(Self.removedToday).path
        #expect(OneWaySyncDisk.attributeNames(at: clone).filter { $0.hasPrefix("com.dropbox.") } == [])
        #expect(OneWaySyncDisk.documentID(at: clone) == nil)
        #expect(result.emptied == [])
    }

    @Test func nothingTemporaryIsLeftInDropboxOrInStaging() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, Self.path, "new")
        try world.write(.dropbox, Self.path, "old")
        try world.writer().replace(dropboxPath: Self.path, with: Self.path, needsDownload: false,
                                   previousIsDropboxEdit: false, expected: nil)
        #expect(world.everythingInDropbox == [
            "Documents", "Documents/Finance", "Documents/Finance/W-2.pdf",
            "SyncCloud Removed", "SyncCloud Removed/2026-10-30", "SyncCloud Removed/2026-10-30/Documents",
            "SyncCloud Removed/2026-10-30/Documents/Finance", "SyncCloud Removed/2026-10-30/Documents/Finance/W-2.pdf",
        ])
        #expect(world.stagingContents == [])
    }

    /// The design's "Never send the old file to the Mac's Trash": nothing one-way sync writes
    /// calls it, unlike the panes' `finalizeBackup`.
    @Test func noOneWaySyncSourceSendsAnythingToTheTrash() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Sync").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasPrefix("OneWaySync") }
        #expect(files.count >= 8)
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("trashItem") && !text.contains("recycle"), "\(file) trashes")
        }
    }

    @Test func aDropboxCopyChangedSinceTheDiffWaitsAndNothingMoves() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, Self.path, "new")
        try world.write(.dropbox, Self.path, "old")
        var expected = try world.expected(Self.path)
        expected.size += 1
        #expect(throws: OneWaySyncWriteError.changedSinceDiff(world.dropbox.appendingPathComponent(Self.path).path)) {
            try world.writer().replace(dropboxPath: Self.path, with: Self.path, needsDownload: false,
                                       previousIsDropboxEdit: false, expected: expected)
        }
        #expect(world.read(.dropbox, Self.path) == "old")
        #expect(!world.everythingInDropbox.contains("SyncCloud Removed"))
        #expect(world.stagingContents == [])
    }

    /// Dropbox writing while its old version is cloned: nothing is kept and nothing replaced.
    @Test func aDropboxChangeDuringTheCloneStopsTheReplace() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, Self.path, "new")
        let dropbox = try world.write(.dropbox, Self.path, "old")
        let writer = try world.writer()
        writer.afterCopy = { url in if url.path == dropbox.path { try? Data("arrived from elsewhere".utf8).write(to: url) } }
        #expect(throws: OneWaySyncWriteError.changedSinceDiff(dropbox.path)) {
            try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: false, expected: nil)
        }
        #expect(world.read(.dropbox, Self.path) == "arrived from elsewhere")
        #expect(OneWaySyncRemovedStore(accountFolder: world.account).items() == [])
        #expect(world.stagingContents == [])
    }

    /// With no version to keep (DG already kept today's), the last re-check before the rename is
    /// the only one between the diff and the write.
    @Test func aDropboxChangeWhileStagingStopsAReplaceThatKeepsNothing() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let dropbox = try world.write(.dropbox, Self.path, "v0")
        let writer = try world.writer()
        try world.write(.iCloud, Self.path, "v1")
        _ = try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: false, expected: nil)
        try world.write(.iCloud, Self.path, "v2")
        writer.afterCopy = { _ in try? Data("arrived from elsewhere".utf8).write(to: dropbox) }
        #expect(throws: OneWaySyncWriteError.changedSinceDiff(dropbox.path)) {
            try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: false, expected: nil)
        }
        #expect(world.read(.dropbox, Self.path) == "arrived from elsewhere")
        #expect(world.stagingContents == [])
    }

    /// Dropbox writing after its old version was kept, just before the rename: the kept clone is
    /// taken back out, so a retry doesn't pile up copies.
    @Test func aReplaceStoppedAfterTheCloneTakesTheCloneBack() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, Self.path, "new")
        let dropbox = try world.write(.dropbox, Self.path, "old")
        let writer = try world.writer()
        writer.beforeLastCheck = { try? Data("arrived from elsewhere".utf8).write(to: $0) }
        for _ in 1...3 {
            #expect(throws: OneWaySyncWriteError.changedSinceDiff(dropbox.path)) {
                try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: true, expected: nil)
            }
        }
        #expect(OneWaySyncRemovedStore(accountFolder: world.account).items() == [])
        #expect(!world.everythingInDropbox.contains("SyncCloud Removed/2026-10-30"))
        #expect(world.read(.dropbox, Self.path) == "arrived from elsewhere")
        #expect(world.stagingContents == [])
    }

    @Test func aFileCantReplaceAPackageNorAPackageAFile() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, "Finance/Plan.pages", "now a flat file")
        try world.write(.dropbox, "Finance/Plan.pages/Index.xml", "a package")
        try world.write(.iCloud, "Finance/Notes.rtfd/TXT.rtf", "now a package")
        try world.write(.dropbox, "Finance/Notes.rtfd", "a flat file")
        let writer = try world.writer()
        for path in ["Finance/Plan.pages", "Finance/Notes.rtfd"] {
            #expect(throws: OneWaySyncWriteError.kindChanged(world.dropbox.appendingPathComponent(path).path)) {
                try writer.replace(dropboxPath: path, with: path, needsDownload: false, previousIsDropboxEdit: true, expected: nil)
            }
        }
        #expect(world.read(.dropbox, "Finance/Plan.pages/Index.xml") == "a package")
        #expect(world.read(.dropbox, "Finance/Notes.rtfd") == "a flat file")
        #expect(!world.everythingInDropbox.contains("SyncCloud Removed"))
        #expect(world.stagingContents == [])
    }

    @Test func aLockedDropboxFolderStopsTheReplaceBeforeAnythingIsKept() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, Self.path, "new")
        try world.write(.dropbox, Self.path, "old")
        let folder = world.dropbox.appendingPathComponent("Finance").path
        #expect(chflags(folder, UInt32(UF_IMMUTABLE)) == 0)
        #expect(throws: OneWaySyncWriteError.failed(folder, errno: EPERM)) {
            try world.writer().replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: false, expected: nil)
        }
        #expect(!world.everythingInDropbox.contains("SyncCloud Removed"))
        #expect(world.read(.dropbox, Self.path) == "old")
    }

    @Test func aLockedDropboxFileStopsTheReplaceBeforeAnythingIsKept() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, Self.path, "new")
        let dropbox = try world.write(.dropbox, Self.path, "old")
        #expect(chflags(dropbox.path, UInt32(UF_TRACKED | UF_IMMUTABLE)) == 0)
        #expect(throws: OneWaySyncWriteError.failed(dropbox.path, errno: EPERM)) {
            try world.writer().replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: false, expected: nil)
        }
        #expect(!world.everythingInDropbox.contains("SyncCloud Removed"))
    }

    /// A name at APFS's 255-unit limit: the staged copy is named by an ID alone, and the store's
    /// " 2" takes room from the name, a whole character at a time, rather than running past it.
    @Test func aNameAtTheLimitStillReplacesAndNumbers() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let name = String(repeating: "書", count: 255)  // APFS's longest
        let path = "Finance/" + name
        try world.write(.dropbox, path, "v0")
        let writer = try world.writer()
        var kept: [String] = []
        for version in 1...2 {
            try world.write(.iCloud, path, "v\(version)")
            if let item = try writer.replace(dropboxPath: path, with: path, needsDownload: false, previousIsDropboxEdit: true, expected: nil).kept {
                kept.append(OneWaySyncPath.name(item.path))
            }
        }
        #expect(world.read(.dropbox, path) == "v2")
        #expect(kept.first == name)
        #expect(kept.last == String(repeating: "書", count: 253) + " 2")
    }

    /// A name goes as its own bytes, so a precomposed `é` counts one toward the limit and a
    /// decomposed one two.
    @Test func numberingCountsANameAsItIsSent() {
        let composed = String(repeating: "\u{e9}", count: 127)
        let decomposed = composed.decomposedStringWithCanonicalMapping
        #expect(OneWaySyncRemovedStore.sentLength(composed + ".pdf") == 131)
        #expect(OneWaySyncRemovedStore.sentLength(decomposed + ".pdf") == 258)
        #expect(Array(OneWaySyncRemovedStore.numbered(composed, 2).utf8) == Array((composed + " 2").utf8))
        #expect(Array(OneWaySyncRemovedStore.numbered(decomposed, 2).utf8)
                == Array((String(repeating: "\u{e9}", count: 126).decomposedStringWithCanonicalMapping + " 2").utf8))
        let long = String(repeating: "\u{e9}", count: 254)
        #expect(Array(OneWaySyncRemovedStore.numbered(long, 2).utf8) == Array((String(repeating: "\u{e9}", count: 253) + " 2").utf8))
        #expect(OneWaySyncRemovedStore.numbered("W-2.pdf", 3) == "W-2 3.pdf")
        #expect(OneWaySyncRemovedStore.numbered(".hidden", 2) == ".hidden 2")
    }

    /// A folder on the way to either file that has become a symlink is refused, not followed.
    @Test func aSymlinkedFolderOnTheWayIsRefused() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let outside = world.root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("not iCloud's".utf8).write(to: outside.appendingPathComponent("W-2.pdf"))
        try FileManager.default.createSymbolicLink(at: world.iCloud.appendingPathComponent("Finance"), withDestinationURL: outside)
        try world.write(.dropbox, Self.path, "old")
        let writer = try world.writer()
        #expect(throws: OneWaySyncWriteError.symlink(world.iCloud.appendingPathComponent("Finance").path)) {
            try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: false, expected: nil)
        }
        #expect(throws: OneWaySyncWriteError.symlink(world.iCloud.appendingPathComponent("Finance").path)) {
            try writer.copy(from: Self.path, to: "Finance/copy.pdf", needsDownload: false)
        }
        // On the Dropbox side: Legal points at Finance.
        try FileManager.default.createSymbolicLink(at: world.dropbox.appendingPathComponent("Legal"),
                                                   withDestinationURL: world.dropbox.appendingPathComponent("Finance"))
        try world.write(.iCloud, "Work/x.pdf", "x")
        #expect(throws: OneWaySyncWriteError.symlink(world.dropbox.appendingPathComponent("Legal").path)) {
            try writer.replace(dropboxPath: "Legal/W-2.pdf", with: "Work/x.pdf", needsDownload: false, previousIsDropboxEdit: false, expected: nil)
        }
        #expect(throws: OneWaySyncWriteError.symlink(world.dropbox.appendingPathComponent("Legal").path)) {
            try writer.moveToRemoved(dropboxPath: "Legal/W-2.pdf", cause: .deletedInICloud, iCloudPath: nil, expected: nil)
        }
        #expect(world.read(.dropbox, Self.path) == "old")
        #expect(!world.everythingInDropbox.contains("SyncCloud Removed"))
    }

    /// The design's "No other symlink is followed or copied": a package holding one isn't copied.
    @Test func aPackageHoldingASymlinkIsRefused() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, "Finance/Plan.pages/Index.xml", "index")
        try FileManager.default.createSymbolicLink(at: world.iCloud.appendingPathComponent("Finance/Plan.pages/link"),
                                                   withDestinationURL: world.root)
        #expect(throws: OneWaySyncWriteError.symlink(world.iCloud.appendingPathComponent("Finance/Plan.pages/link").path)) {
            try world.writer().copy(from: "Finance/Plan.pages", to: "Finance/Plan.pages", needsDownload: false)
        }
        #expect(world.read(.dropbox, "Finance/Plan.pages/Index.xml") == nil)
        #expect(world.stagingContents == [])
    }

    @Test func aDropboxCopyWithAnotherDocumentIDWaits() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, Self.path, "new")
        try world.write(.dropbox, Self.path, "old")
        var expected = try world.expected(Self.path)
        expected.documentID = (expected.documentID ?? 0) + 1
        #expect(throws: OneWaySyncWriteError.changedSinceDiff(world.dropbox.appendingPathComponent(Self.path).path)) {
            try world.writer().replace(dropboxPath: Self.path, with: Self.path, needsDownload: false,
                                       previousIsDropboxEdit: false, expected: expected)
        }
        #expect(world.read(.dropbox, Self.path) == "old")
    }

    @Test func aSymlinkOnEitherSideIsRefused() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let real = try world.write(.iCloud, "Finance/real.pdf", "real")
        try FileManager.default.createSymbolicLink(at: world.iCloud.appendingPathComponent("Finance/link.pdf"), withDestinationURL: real)
        try world.write(.dropbox, Self.path, "old")
        #expect(throws: OneWaySyncWriteError.symlink(world.iCloud.appendingPathComponent("Finance/link.pdf").path)) {
            try world.writer().replace(dropboxPath: Self.path, with: "Finance/link.pdf", needsDownload: false,
                                       previousIsDropboxEdit: false, expected: nil)
        }
        let target = try world.write(.dropbox, "Finance/target.pdf", "target")
        try FileManager.default.createSymbolicLink(at: world.dropbox.appendingPathComponent("Finance/linked.pdf"), withDestinationURL: target)
        #expect(throws: OneWaySyncWriteError.symlink(world.dropbox.appendingPathComponent("Finance/linked.pdf").path)) {
            try world.writer().replace(dropboxPath: "Finance/linked.pdf", with: "Finance/real.pdf", needsDownload: false,
                                       previousIsDropboxEdit: false, expected: nil)
        }
        #expect(world.read(.dropbox, "Finance/target.pdf") == "target")
        #expect(world.read(.dropbox, Self.path) == "old")
    }

    // MARK: DG

    @Test func dgKeepsOneSyncCloudVersionADayAndEveryDropboxEdit() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.dropbox, Self.path, "v0")
        let writer = try world.writer()
        var minutes = 0.0
        func replace(_ contents: String, dropboxEdit: Bool = false) throws -> OneWaySyncWriter.Replaced {
            minutes += 1
            let now = OneWayDiskWorld.day0.addingTimeInterval(minutes * 60)
            writer.now = { now }
            try world.write(.iCloud, Self.path, contents)
            return try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false,
                                      previousIsDropboxEdit: dropboxEdit, expected: nil)
        }
        // A Dropbox edit first: kept, and it doesn't use up the day's one.
        try world.write(.dropbox, Self.path, "edited in Dropbox")
        #expect(try replace("v1", dropboxEdit: true).kept?.origin.kind == .replacedDropboxVersion)
        #expect(try replace("v2").kept?.origin.kind == .replacedSyncCloudVersion)
        #expect(try replace("v3").kept == nil)
        try world.write(.dropbox, Self.path, "edited again")
        #expect(try replace("v4", dropboxEdit: true).kept?.origin.kind == .replacedDropboxVersion)
        #expect(try replace("v5").kept == nil)

        minutes = 24 * 60
        #expect(try replace("v6").kept?.path == "SyncCloud Removed/2026-10-31/Documents/Finance/W-2.pdf")
        #expect(world.read(.dropbox, Self.path) == "v6")

        let kept = OneWaySyncRemovedStore(accountFolder: world.account, calendar: OneWayDiskWorld.calendar).items()
        #expect(kept.map { world.read(account: $0.path) } == ["edited in Dropbox", "v1", "edited again", "v5"])
        #expect(kept.map(\.path) == [
            Self.removedToday, "SyncCloud Removed/2026-10-30/Documents/Finance/W-2 2.pdf",
            "SyncCloud Removed/2026-10-30/Documents/Finance/W-2 3.pdf",
            "SyncCloud Removed/2026-10-31/Documents/Finance/W-2.pdf",
        ])
    }

    /// The day is the date folder's: a version kept late last night doesn't hold back this
    /// morning's.
    @Test func dgCountsCalendarDaysNotTwentyFourHours() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.dropbox, Self.path, "v0")
        let writer = try world.writer(at: OneWayDiskWorld.day0.addingTimeInterval(11.5 * 3600))  // 23:30
        try world.write(.iCloud, Self.path, "v1")
        #expect(try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: false, expected: nil).kept != nil)
        writer.now = { OneWayDiskWorld.day0.addingTimeInterval(12.5 * 3600) }  // 00:30 the next day
        try world.write(.iCloud, Self.path, "v2")
        #expect(try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: false, expected: nil).kept?.path
            == "SyncCloud Removed/2026-10-31/Documents/Finance/W-2.pdf")
    }

    // MARK: DJ

    @Test func djKeepsSevenVersionsAndEmptiesTheOldestOfAnEighth() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.dropbox, Self.path, "v0")
        // A version made in Dropbox, kept long ago: never counts, never emptied.
        let store = OneWaySyncRemovedStore(accountFolder: world.account, calendar: OneWayDiskWorld.calendar)
        try world.write(.dropbox, "Finance/scratch.pdf", "a Dropbox edit")
        let dropboxEdit = try store.moveIn(world.dropbox.appendingPathComponent("Finance/scratch.pdf"), origin: .init(
            dropboxPath: "Documents/" + Self.path, fileID: world.documentID(.dropbox, Self.path),
            removedAt: Int64(OneWayDiskWorld.day0.timeIntervalSince1970) - 90 * 86_400, kind: .replacedDropboxVersion))

        var emptied: [[OneWaySyncRemovedItem]] = []
        for day in 1...8 {
            let writer = try world.writer(at: OneWayDiskWorld.day0.addingTimeInterval(Double(day) * 86_400))
            try world.write(.iCloud, Self.path, "v\(day)")
            emptied.append(try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false,
                                              previousIsDropboxEdit: false, expected: nil).emptied)
        }
        #expect(emptied.dropLast().allSatisfy { $0.isEmpty })
        // The eighth kept version sent the first (v0, kept on day 1) to Dropbox's deleted files.
        #expect(emptied.last?.map(\.path) == ["SyncCloud Removed/2026-10-31/Documents/Finance/W-2.pdf"])
        let left = store.items()
        #expect(left.map { world.read(account: $0.path) } == ["a Dropbox edit", "v1", "v2", "v3", "v4", "v5", "v6", "v7"])
        #expect(left.first == dropboxEdit)
        // The emptied version's date folder went with it.
        #expect(!world.everythingInDropbox.contains("SyncCloud Removed/2026-10-31"))
    }

    /// Versions of one file are tied by the live file's document ID, which a replace keeps, so a
    /// file renamed in between still counts as one.
    @Test func djFollowsTheFileThroughARename() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.dropbox, "Finance/old name.pdf", "v0")
        for day in 1...8 {
            let writer = try world.writer(at: OneWayDiskWorld.day0.addingTimeInterval(Double(day) * 86_400))
            let name = day <= 4 ? "Finance/old name.pdf" : "Finance/new name.pdf"
            if day == 5 { try writer.move(from: "Finance/old name.pdf", to: name) }
            try world.write(.iCloud, name, "v\(day)")
            let result = try writer.replace(dropboxPath: name, with: name, needsDownload: false, previousIsDropboxEdit: false, expected: nil)
            #expect(result.emptied.count == (day == 8 ? 1 : 0), "day \(day)")
        }
    }

    /// With no document IDs (untracked files), versions are tied by Dropbox path, ignoring case;
    /// a file of the same name in another folder is another file.
    @Test func djFallsBackToThePathWithoutIDs() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let store = OneWaySyncRemovedStore(accountFolder: world.account, calendar: OneWayDiskWorld.calendar)
        func version(_ path: String, day: Int, kind: OneWaySyncRemovedItem.Kind, fileID: UInt64? = nil) throws {
            let scratch = try world.write(.dropbox, "Scratch/v", "\(path) \(day)")
            _ = try store.moveIn(scratch, origin: .init(dropboxPath: "Documents/" + path, fileID: fileID,
                                                       removedAt: Int64(OneWayDiskWorld.day0.timeIntervalSince1970) + Int64(day) * 86_400, kind: kind))
        }
        for day in 1...7 { try version("Finance/w-2.PDF", day: day, kind: .replacedSyncCloudVersion) }
        // None of these count toward Finance/W-2.pdf's seven.
        try version("Legal/W-2.pdf", day: 0, kind: .replacedSyncCloudVersion)
        try version("Finance/W-2.pdf", day: 0, kind: .deletedInICloud)
        try version("Finance/W-2.pdf", day: 0, kind: .replacedDropboxVersion)
        let unrecorded = world.account.appendingPathComponent("SyncCloud Removed/2026-10-01/Documents/Finance/W-2.pdf")
        try FileManager.default.createDirectory(at: unrecorded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unrecorded".utf8).write(to: unrecorded)

        let path = "Documents/" + Self.path
        #expect(store.versionsPastTheLimit(fileID: nil, dropboxPath: path, in: store.items()) == [])
        try version("Finance/W-2.pdf", day: 8, kind: .replacedSyncCloudVersion)
        #expect(store.versionsPastTheLimit(fileID: nil, dropboxPath: path, in: store.items()).map { world.read(account: $0.path) }
            == ["Finance/w-2.PDF 1"])
    }

    /// A clock set back dates the version just kept before the rest: DJ still keeps it.
    @Test func djNeverEmptiesTheVersionJustKept() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.dropbox, Self.path, "v0")
        for day in 1...7 {
            let writer = try world.writer(at: OneWayDiskWorld.day0.addingTimeInterval(Double(day) * 86_400))
            try world.write(.iCloud, Self.path, "v\(day)")
            _ = try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: false, expected: nil)
        }
        let writer = try world.writer(at: OneWayDiskWorld.day0.addingTimeInterval(-30 * 86_400))
        try world.write(.iCloud, Self.path, "v8")
        let result = try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: false, expected: nil)
        let kept = try #require(result.kept)
        #expect(world.read(account: kept.path) == "v7")
        #expect(result.emptied.map { world.read(account: $0.path) ?? "emptied" } == ["emptied"])
        #expect(result.emptied.map(\.path) == ["SyncCloud Removed/2026-10-31/Documents/Finance/W-2.pdf"])
    }

    /// DG's day is the calendar's, here Los Angeles: 23:30 and 00:30 local are two days.
    @Test func dgUsesTheLocalDay() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        try world.write(.dropbox, Self.path, "v0")
        // 2026-10-30 23:30 PDT is 06:30 UTC on the 31st.
        let lateEvening = Date(timeIntervalSince1970: 1_793_428_200)
        let writer = try OneWaySyncWriter(places: world.places, calendar: calendar)
        writer.now = { lateEvening }
        try world.write(.iCloud, Self.path, "v1")
        #expect(try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: false, expected: nil).kept?.path
            == "SyncCloud Removed/2026-10-30/Documents/Finance/W-2.pdf")
        writer.now = { lateEvening.addingTimeInterval(3600) }
        try world.write(.iCloud, Self.path, "v2")
        #expect(try writer.replace(dropboxPath: Self.path, with: Self.path, needsDownload: false, previousIsDropboxEdit: false, expected: nil).kept?.path
            == "SyncCloud Removed/2026-10-31/Documents/Finance/W-2.pdf")
    }

    @Test func aPackageIsReplacedAsOneFile() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try world.write(.iCloud, "Finance/Plan.pages/Index.xml", "new index")
        try world.write(.iCloud, "Finance/Plan.pages/Data/new.png", "new picture")
        try world.write(.dropbox, "Finance/Plan.pages/Index.xml", "old index")
        try world.write(.dropbox, "Finance/Plan.pages/Data/old.png", "old picture")
        #expect(chflags(world.dropbox.appendingPathComponent("Finance/Plan.pages").path, UInt32(UF_TRACKED)) == 0)
        let id = try #require(world.documentID(.dropbox, "Finance/Plan.pages"))
        let result = try world.writer().replace(dropboxPath: "Finance/Plan.pages", with: "Finance/Plan.pages", needsDownload: false,
                                                previousIsDropboxEdit: false, expected: try world.expected("Finance/Plan.pages"))
        // The package keeps its own document ID through the swap (measured here, not with Dropbox).
        #expect(world.documentID(.dropbox, "Finance/Plan.pages") == id)
        #expect(world.read(.dropbox, "Finance/Plan.pages/Index.xml") == "new index")
        #expect(world.read(.dropbox, "Finance/Plan.pages/Data/new.png") == "new picture")
        #expect(world.read(.dropbox, "Finance/Plan.pages/Data/old.png") == nil)
        let kept = try #require(result.kept)
        #expect(world.read(account: kept.path + "/Data/old.png") == "old picture")
        #expect(world.stagingContents == [])
    }
}
