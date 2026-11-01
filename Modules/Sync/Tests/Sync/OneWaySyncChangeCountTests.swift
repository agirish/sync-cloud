import Darwin
import Foundation
import Testing
@testable import Sync

/// **FV: the change count Sync Now's pill suggests a sync with.** Scratch parents on disk, a record
/// that matches them, and watcher batches written out by hand — every flag and order here is one
/// FSEvents can deliver. The live half, against real FSEvents, is `OneWaySyncChangeCountLiveTests`.
@Suite struct OneWaySyncChangeCountTests {

    final class World {
        let root: String
        let iCloud: String
        let dropbox: String
        var record: OneWaySyncRecord
        var exclusions = OneWaySyncExclusions()
        private var nextID: UInt64 = 1_000

        init() throws {
            let raw = FileManager.default.temporaryDirectory.appendingPathComponent("OneWayChanges-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            root = OneWaySyncDisk.canonicalPath(raw)
            iCloud = root + "/iCloud"
            dropbox = root + "/Dropbox"
            record = OneWaySyncRecord(
                binding: OneWaySyncBinding(hardwareID: "HW", iCloudAccount: "A", dropboxAccountFolder: root, dataVolumeUUID: "V"),
                iCloudParent: OneWaySyncParentRecord(path: iCloud), dropboxParent: OneWaySyncParentRecord(path: dropbox))
            record.syncedFolders = [OneWaySyncFolderRecord(key: 1, iCloudPath: "Legal", dropboxPath: "Legal", firstRunCompleted: true)]
            for side in [iCloud, dropbox] { try FileManager.default.createDirectory(atPath: side + "/Legal", withIntermediateDirectories: true) }
            // One synced file, the same on both sides, as the record says.
            try synced("Legal/Will.pdf", "will")
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }

        var scope: OneWaySyncChangeScope {
            OneWaySyncChangeScope(record: record, exclusions: exclusions, iCloudParent: iCloud, dropboxParent: dropbox)
        }

        /// Writes `path` on both sides with one date, and records it as synced.
        func synced(_ path: String, _ text: String) throws {
            try write(iCloud + "/" + path, text, at: 1_700_000_000)
            try write(dropbox + "/" + path, text, at: 1_700_000_000)
            record.files.append(OneWaySyncFileRecord(key: record.nextKey, iCloudPath: path, dropboxPath: path, iCloudID: nil, dropboxID: nil,
                                                     size: Int64(text.utf8.count), modified: 1_700_000_000))
            record.nextKey += 1
        }

        func write(_ full: String, _ text: String, at seconds: TimeInterval? = nil) throws {
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: full))
            if let seconds { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: full) }
        }

        func inode(_ full: String) -> UInt64? {
            (try? FileManager.default.attributesOfItem(atPath: full))?[.systemFileNumber] as? UInt64
        }

        /// One event at `full`, under the synced folder that holds it, with the next id.
        func event(_ full: String, _ change: FolderWatchEvent.Change, fileID: UInt64? = nil, isOwn: Bool = false,
                   id: UInt64? = nil) -> FolderWatchEvent {
            nextID += 1
            let root = full.hasPrefix(iCloud + "/") ? iCloud + "/Legal" : dropbox + "/Legal"
            return FolderWatchEvent(id: id ?? nextID, root: root, path: full, realPath: full, change: change,
                                    fileID: fileID ?? inode(full), isOwn: isOwn)
        }

        func count(_ fileURL: URL? = nil) -> OneWaySyncChangeCount {
            let count = OneWaySyncChangeCount(fileURL: fileURL)
            count.use(scope)
            return count
        }
    }

    // MARK: What counts

    /// The headline: an edit in iCloud counts, and only once however often it is reported.
    @Test func anICloudEditCountsOnceThroughABurst() throws {
        let world = try World()
        let count = world.count()
        let will = world.iCloud + "/Legal/Will.pdf"
        try world.write(will, "will, signed")
        #expect(count.note(FolderWatchBatch(events: [world.event(will, [.modified, .isFile])])))
        count.note(FolderWatchBatch(events: [world.event(will, [.modified, .isFile]), world.event(will, [.modified, .inodeMetadata, .isFile])]))
        #expect(count.tally == .init(count: 1))
    }

    /// The record decides: a recorded file reported changed but the same size and date as synced
    /// — iCloud downloading or offloading it, Dropbox marking its upload — isn't a change.
    @Test func aReportedFileTheSameAsRecordedDoesNotCount() throws {
        let world = try World()
        let count = world.count()
        #expect(!count.note(FolderWatchBatch(events: [world.event(world.iCloud + "/Legal/Will.pdf", [.modified, .inodeMetadata, .isFile]),
                                                      world.event(world.dropbox + "/Legal/Will.pdf", [.modified, .isFile])])))
        #expect(count.tally == .init())
    }

    /// FU: an opened stamp, quarantine or tag (extended attributes alone) isn't a change, even on a
    /// file the record doesn't have — a new file whose only event is that would otherwise count.
    @Test func attributesAloneDoNotCount() throws {
        let world = try World()
        let count = world.count()
        let new = world.iCloud + "/Legal/Lease.pdf"
        try world.write(new, "lease")
        count.note(FolderWatchBatch(events: [world.event(new, [.extendedAttributes, .isFile])]))
        #expect(count.tally == .init())
        // An unrecorded file whose owner or mode alone changed was there before: not new either.
        count.note(FolderWatchBatch(events: [world.event(new, [.inodeMetadata, .owner, .isFile])]))
        #expect(count.tally == .init())
        // Created, it is.
        count.note(FolderWatchBatch(events: [world.event(new, [.created, .extendedAttributes, .isFile])]))
        #expect(count.tally == .init(count: 1))
    }

    /// FU where the record can't tell: a file left differing from the record by the last pass (an
    /// edit made in Dropbox, waiting for you in Now) isn't a new change because you opened it.
    @Test func openingAFileThatStillWaitsDoesNotCountAgain() throws {
        let world = try World()
        let count = world.count()
        let copy = world.dropbox + "/Legal/Will.pdf"
        try world.write(copy, "edited on the web, waiting for you")
        count.note(FolderWatchBatch(events: [world.event(copy, [.modified, .isFile], id: 100)]))
        count.passCompleted(startedAt: 200, stopped: false)
        #expect(count.tally == .init(), "precondition: the pass started the count again")
        count.note(FolderWatchBatch(events: [world.event(copy, [.extendedAttributes, .isFile], id: 300)]))
        #expect(count.tally == .init(), "opening the waiting file counted")
        count.note(FolderWatchBatch(events: [world.event(copy, [.modified, .isFile], id: 301)]))
        #expect(count.tally == .init(count: 1))
    }

    /// A rename is one item: its old path (gone, recorded) and its new one (there, not recorded)
    /// share an inode. Without the join it would read as two.
    @Test func aRenameIsOneItem() throws {
        let world = try World()
        let count = world.count()
        let old = world.iCloud + "/Legal/Will.pdf", new = world.iCloud + "/Legal/Will 2026.pdf"
        let inode = try #require(world.inode(old))
        try FileManager.default.moveItem(atPath: old, toPath: new)
        count.note(FolderWatchBatch(events: [world.event(old, [.renamed, .isFile], fileID: inode)]))
        count.note(FolderWatchBatch(events: [world.event(new, [.renamed, .isFile], fileID: inode)]))
        #expect(count.tally == .init(count: 1))
    }

    /// A deletion counts; a file made and gone between two looks (an app's temporary) doesn't.
    @Test func aDeletionCountsATemporaryFileDoesNot() throws {
        let world = try World()
        let count = world.count()
        let will = world.iCloud + "/Legal/Will.pdf"
        try FileManager.default.removeItem(atPath: will)
        count.note(FolderWatchBatch(events: [world.event(will, [.removed, .isFile], fileID: 5),
                                             world.event(world.iCloud + "/Legal/scratch.tmp", [.created, .removed, .isFile], fileID: 6)]))
        #expect(count.tally == .init(count: 1))
    }

    /// Names the sync never lists, symlinks, live libraries and files you stopped syncing never
    /// count; a change inside a package counts as the package, once.
    @Test func whatTheSyncNeverSyncsNeverCounts() throws {
        let world = try World()
        let count = world.count()
        try world.write(world.iCloud + "/Legal/.DS_Store", "x")
        try world.write(world.iCloud + "/Legal/~$Draft.docx", "x")
        try world.write(world.iCloud + "/Legal/Photos.photoslibrary/database/a", "x")
        try world.write(world.iCloud + "/Legal/Kept.pdf", "mine")
        try FileManager.default.createSymbolicLink(atPath: world.iCloud + "/Legal/link", withDestinationPath: "/tmp")
        world.exclusions = OneWaySyncExclusions(files: [OneWaySyncExclusion(iCloudPath: "Legal/Kept.pdf", dropboxPath: "Legal/Kept.pdf", stoppedAt: 0)])
        count.use(world.scope)
        let ignored = ["/Legal/.DS_Store", "/Legal/~$Draft.docx", "/Legal/Photos.photoslibrary/database/a", "/Legal/Kept.pdf", "/Legal/link"]
        count.note(FolderWatchBatch(events: ignored.map { world.event(world.iCloud + $0, [.created, .isFile]) }))
        #expect(count.tally == .init(), "counted what the sync never syncs")

        // RTFD: a package type macOS itself declares, so no app needs to be installed.
        try world.write(world.iCloud + "/Legal/Brief.rtfd/TXT.rtf", "1")
        try world.write(world.iCloud + "/Legal/Brief.rtfd/one.jpg", "2")
        count.note(FolderWatchBatch(events: [world.event(world.iCloud + "/Legal/Brief.rtfd/TXT.rtf", [.created, .isFile]),
                                             world.event(world.iCloud + "/Legal/Brief.rtfd/one.jpg", [.created, .isFile])]))
        #expect(count.tally == .init(count: 1), "a package's inside counted per file")
    }

    /// A folder unticked in Choose Folders takes what it counted with it.
    @Test func aFolderNoLongerSyncedStopsCounting() throws {
        let world = try World()
        try FileManager.default.createDirectory(atPath: world.iCloud + "/Work", withIntermediateDirectories: true)
        world.record.syncedFolders.append(OneWaySyncFolderRecord(key: 9, iCloudPath: "Work", dropboxPath: "Work", firstRunCompleted: true))
        let count = world.count()
        let memo = world.iCloud + "/Work/Memo.txt"
        try world.write(memo, "memo")
        count.note(FolderWatchBatch(events: [FolderWatchEvent(id: 5, root: world.iCloud + "/Work", path: memo, realPath: memo,
                                                              change: [.created, .isFile])]))
        #expect(count.tally == .init(count: 1))
        world.record.syncedFolders.removeLast()
        count.use(world.scope)
        #expect(count.tally == .init())
    }

    /// This process's own changes are yours — an edit or a copy made in SyncCloud's panes — and
    /// count on either side, except on the side the sync or Reverse is writing to, while it does.
    @Test func ownWritesCountExceptWhereTheSyncIsWriting() throws {
        let world = try World()
        let count = world.count()
        let copy = world.dropbox + "/Legal/New.pdf", pasted = world.dropbox + "/Legal/Pasted.pdf"
        let edit = world.iCloud + "/Legal/Will.pdf", held = world.iCloud + "/Legal/Back.pdf"
        for (path, text) in [(copy, "copied by the sync"), (pasted, "pasted in the Dropbox pane"), (edit, "edited in a pane"),
                             (held, "put back by Reverse")] { try world.write(path, text) }
        let now = Date()
        count.holdOwnWrites(on: .dropbox, until: now.addingTimeInterval(10))
        count.note(FolderWatchBatch(events: [world.event(copy, [.created, .isFile], isOwn: true)]), now: now)
        #expect(count.tally == .init(), "the sync's own Dropbox write counted")
        count.note(FolderWatchBatch(events: [world.event(edit, [.modified, .isFile], isOwn: true)]), now: now)
        #expect(count.tally == .init(count: 1), "an edit made in SyncCloud's iCloud pane didn't count while the sync wrote Dropbox")
        // The pass records its copy before the hold ends, as a completed pass does.
        let state = try OneWaySyncDisk.state(at: copy)
        world.record.files.append(OneWaySyncFileRecord(key: 80, iCloudPath: "Legal/New.pdf", dropboxPath: "Legal/New.pdf",
                                                       iCloudID: nil, dropboxID: nil, size: state.size, modified: state.modifiedSecond))
        count.use(world.scope)
        count.note(FolderWatchBatch(events: [world.event(pasted, [.created, .isFile], isOwn: true)]), now: now.addingTimeInterval(11))
        #expect(count.tally == .init(count: 2), "a copy made into Dropbox from a pane didn't count once the sync was done")
        count.holdOwnWrites(on: .iCloud, until: now.addingTimeInterval(10))
        count.note(FolderWatchBatch(events: [world.event(held, [.created, .isFile], isOwn: true)]), now: now)
        #expect(count.tally == .init(count: 2), "Reverse's own iCloud write counted")
        // Someone else's change while held still counts.
        let other = world.iCloud + "/Legal/Other.pdf"
        try world.write(other, "someone else's")
        count.note(FolderWatchBatch(events: [world.event(other, [.created, .isFile], isOwn: false)]), now: now)
        #expect(count.tally == .init(count: 3))
    }

    /// What a hold held back is judged once it ends: a copy the pass recorded doesn't count, and
    /// one no pass recorded (it stopped before saving, or never ran) does.
    @Test func whatAHoldHeldIsJudgedWhenItEnds() throws {
        let world = try World()
        let count = world.count()
        let recorded = world.dropbox + "/Legal/Recorded.pdf", unrecorded = world.dropbox + "/Legal/Unrecorded.pdf"
        try world.write(recorded, "copy", at: 1_700_000_000)
        try world.write(unrecorded, "copy the pass never recorded")
        let now = Date()
        count.holdOwnWrites(on: .dropbox, until: now.addingTimeInterval(10))
        count.note(FolderWatchBatch(events: [world.event(recorded, [.created, .isFile], isOwn: true),
                                             world.event(unrecorded, [.created, .isFile], isOwn: true)]), now: now)
        #expect(count.tally == .init())
        world.record.files.append(OneWaySyncFileRecord(key: 70, iCloudPath: "Legal/Recorded.pdf", dropboxPath: "Legal/Recorded.pdf",
                                                       iCloudID: nil, dropboxID: nil, size: 4, modified: 1_700_000_000))
        count.use(world.scope)
        #expect(!count.settleHolds(now: now.addingTimeInterval(5)), "judged before the hold ended")
        #expect(count.settleHolds(now: now.addingTimeInterval(11)))
        #expect(count.tally == .init(count: 1), "the unrecorded copy didn't count, or the recorded one did")
    }

    /// A folder moved to the Trash takes what was counted inside it: its contents have no events.
    @Test func aFolderMovedAwayTakesItsContentsCount() throws {
        let world = try World()
        let count = world.count()
        let scans = world.iCloud + "/Legal/Scans"
        for name in ["a.pdf", "b.pdf"] { try world.write(scans + "/" + name, name) }
        count.note(FolderWatchBatch(events: [world.event(scans, [.created, .isDirectory]),
                                             world.event(scans + "/a.pdf", [.created, .isFile]),
                                             world.event(scans + "/b.pdf", [.created, .isFile])]))
        #expect(count.tally == .init(count: 3))
        let inode = world.inode(scans)
        try FileManager.default.moveItem(atPath: scans, toPath: world.root + "/Trash-Scans")
        count.note(FolderWatchBatch(events: [world.event(scans, [.renamed, .isDirectory], fileID: inode)]))
        #expect(count.tally == .init(), "what was inside the folder still counted")
    }

    /// An item put back as it was stops counting: a file back from the Trash, a temporary file
    /// gone again, a rename undone.
    @Test func whatIsBackAsRecordedStopsCounting() throws {
        let world = try World()
        let count = world.count()
        let will = world.iCloud + "/Legal/Will.pdf", trash = world.root + "/Trash-Will.pdf"
        let inode = try #require(world.inode(will))
        try FileManager.default.moveItem(atPath: will, toPath: trash)
        count.note(FolderWatchBatch(events: [world.event(will, [.renamed, .isFile], fileID: inode)]))
        #expect(count.tally == .init(count: 1))
        try FileManager.default.moveItem(atPath: trash, toPath: will)
        count.note(FolderWatchBatch(events: [world.event(will, [.renamed, .isFile], fileID: inode)]))
        #expect(count.tally == .init(), "a file put back from the Trash still counted")

        let temp = world.iCloud + "/Legal/Draft.swp"
        try world.write(temp, "x")
        count.note(FolderWatchBatch(events: [world.event(temp, [.created, .isFile])]))
        #expect(count.tally == .init(count: 1))
        try FileManager.default.removeItem(atPath: temp)
        count.note(FolderWatchBatch(events: [world.event(temp, [.removed, .isFile], fileID: 1)]))
        #expect(count.tally == .init(), "a temporary file gone again still counted")

        let renamed = world.iCloud + "/Legal/Will 2026.pdf"
        try FileManager.default.moveItem(atPath: will, toPath: renamed)
        count.note(FolderWatchBatch(events: [world.event(will, [.renamed, .isFile], fileID: inode),
                                             world.event(renamed, [.renamed, .isFile], fileID: inode)]))
        #expect(count.tally == .init(count: 1))
        try FileManager.default.moveItem(atPath: renamed, toPath: will)
        count.note(FolderWatchBatch(events: [world.event(renamed, [.renamed, .isFile], fileID: inode),
                                             world.event(will, [.renamed, .isFile], fileID: inode)]))
        #expect(count.tally == .init(), "a rename undone still counted")
    }

    /// A change made directly in Dropbox counts, judged against Dropbox's own date for the copy.
    @Test func aDropboxEditCountsAgainstDropboxsOwnDate() throws {
        let world = try World()
        world.record.files[0].dropboxModified = 1_700_000_500
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_500)],
                                              ofItemAtPath: world.dropbox + "/Legal/Will.pdf")
        let count = world.count()
        count.note(FolderWatchBatch(events: [world.event(world.dropbox + "/Legal/Will.pdf", [.modified, .isFile])]))
        #expect(count.tally == .init(), "iCloud's date was compared to Dropbox's copy")
        try world.write(world.dropbox + "/Legal/Will.pdf", "edited on the web")
        count.note(FolderWatchBatch(events: [world.event(world.dropbox + "/Legal/Will.pdf", [.modified, .isFile])]))
        #expect(count.tally == .init(count: 1))
    }

    /// Where FSEvents can't say what changed, a number would claim too much: unknown.
    @Test func aRescanMakesTheCountUnknown() throws {
        let world = try World()
        let count = world.count()
        count.note(FolderWatchBatch(rescans: [FolderWatchRescan(root: world.root + "/elsewhere", path: world.root + "/elsewhere",
                                                                reason: .eventsDropped, id: 5_000)]))
        #expect(!count.tally.isUnknown, "a rescan of a folder that isn't synced")
        count.note(FolderWatchBatch(rescans: [FolderWatchRescan(root: world.iCloud + "/Legal", path: world.iCloud + "/Legal",
                                                                reason: .historyLost, id: 5_000)]))
        #expect(count.tally.isUnknown)
    }

    /// Past the limit the count reads as unknown, and its file stays small.
    @Test func pastTheLimitTheCountIsUnknown() throws {
        let world = try World()
        let count = world.count()
        let events = (0...OneWaySyncChangeCount.limit).map { index in
            world.event(world.iCloud + "/Legal/gone-\(index).pdf", [.removed, .isFile], fileID: UInt64(10_000 + index))
        }
        for index in 0...OneWaySyncChangeCount.limit { world.record.files.append(OneWaySyncFileRecord(
            key: UInt64(100 + index), iCloudPath: "Legal/gone-\(index).pdf", dropboxPath: "Legal/gone-\(index).pdf",
            iCloudID: nil, dropboxID: nil, size: 1, modified: 0)) }
        count.use(world.scope)
        count.note(FolderWatchBatch(events: events))
        #expect(count.tally == .init(count: OneWaySyncChangeCount.limit, isUnknown: true))
    }

    // MARK: A pass

    /// A completed pass starts the count again: what changed before it started is that pass's.
    /// What changed while it ran still counts if it differs from the record it saved, and what the
    /// pass itself synced (read again, now matching) goes.
    @Test func aCompletedPassStartsTheCountAgain() throws {
        let world = try World()
        let count = world.count()
        let will = world.iCloud + "/Legal/Will.pdf"
        try world.write(will, "before the pass")
        count.note(FolderWatchBatch(events: [world.event(will, [.modified, .isFile], id: 100)]))
        // During the pass: one new file the pass synced, one edit after its look.
        let synced = world.iCloud + "/Legal/Synced.pdf", late = world.iCloud + "/Legal/Late.pdf"
        try world.write(synced, "synced")
        try world.write(late, "too late")
        count.note(FolderWatchBatch(events: [world.event(synced, [.created, .isFile], id: 300),
                                             world.event(late, [.created, .isFile], id: 301)]))
        #expect(count.tally == .init(count: 3))
        // The pass recorded Synced.pdf (and kept Will.pdf's edit waiting, as a row would).
        let state = try OneWaySyncDisk.state(at: synced)
        world.record.files.append(OneWaySyncFileRecord(key: 50, iCloudPath: "Legal/Synced.pdf", dropboxPath: "Legal/Synced.pdf",
                                                       iCloudID: nil, dropboxID: nil, size: state.size, modified: state.modifiedSecond))
        count.use(world.scope)
        count.passCompleted(startedAt: 200, stopped: false)
        #expect(count.tally == .init(count: 1), "kept what the pass synced, or what it started after")
        // An event older than the pass's start, arriving late (a replay), is that pass's.
        count.note(FolderWatchBatch(events: [world.event(will, [.modified, .isFile], id: 150)]))
        #expect(count.tally == .init(count: 1))
    }

    /// A pass you stopped synced only some of it: nothing is dropped unread.
    @Test func aStoppedPassKeepsWhatItDidNotSync() throws {
        let world = try World()
        let count = world.count()
        let will = world.iCloud + "/Legal/Will.pdf"
        try world.write(will, "not synced before the stop")
        count.note(FolderWatchBatch(events: [world.event(will, [.modified, .isFile], id: 100)]))
        count.note(FolderWatchBatch(rescans: [FolderWatchRescan(root: world.iCloud + "/Legal", path: world.iCloud + "/Legal",
                                                                reason: .mustScanSubDirs, id: 110)]))
        count.passCompleted(startedAt: 200, stopped: true)
        #expect(count.tally == .init(count: 1, isUnknown: true))
        count.passCompleted(startedAt: 200, stopped: false)
        #expect(count.tally == .init())
    }

    /// What a completed pass left for a later one — a deletion inside its 30 minutes, a step that
    /// didn't go through, a folder not fully listed — still counts after it, while it differs.
    @Test func whatAPassLeftForLaterStillCounts() throws {
        let world = try World()
        try world.synced("Legal/Old.pdf", "old")
        let count = world.count()
        let old = world.iCloud + "/Legal/Old.pdf", will = world.iCloud + "/Legal/Will.pdf"
        try FileManager.default.removeItem(atPath: old)
        try world.write(will, "edited, but Dropbox was still changing its copy")
        count.note(FolderWatchBatch(events: [world.event(old, [.removed, .isFile], fileID: 3, id: 100),
                                             world.event(will, [.modified, .isFile], id: 101)]))
        #expect(count.tally == .init(count: 2))
        world.record.files[1].iCloudGoneSince = 1_790_000_000
        count.use(world.scope)
        count.passCompleted(startedAt: 200, stopped: false, leftForLater: ["Legal/OLD.pdf", "Legal/Will.pdf"])
        #expect(count.tally == .init(count: 2), "dropped what the pass left for later, though it still differs")
        count.passCompleted(startedAt: 300, stopped: false, leftForLater: [])
        #expect(count.tally == .init())
    }

    /// A real pass's leftovers: a deletion still inside its 30 minutes is left for later and keeps
    /// counting; an edit the pass carried doesn't.
    @Test func aRealPassLeavesItsDeferredDeletionCounted() async throws {
        let disk = try OneWayDiskWorld()
        defer { disk.remove() }
        for (path, text) in [("Finance/Old.pdf", "old"), ("Finance/Budget.xlsx", "v1")] {
            let url = try disk.write(.iCloud, path, text, modified: OneWayDiskWorld.day0.addingTimeInterval(-86_400))
            chflags(url.path, UInt32(UF_TRACKED))
        }
        let sync = try OneWaySyncRunTests.Sync(world: disk, folders: ["Finance"])
        try await sync.run()
        let iCloud = OneWaySyncDisk.canonicalPath(disk.iCloud), dropbox = OneWaySyncDisk.canonicalPath(disk.dropbox)
        func scope() -> OneWaySyncChangeScope {
            OneWaySyncChangeScope(record: sync.record, exclusions: OneWaySyncExclusions(), iCloudParent: iCloud, dropboxParent: dropbox)
        }
        let count = OneWaySyncChangeCount(fileURL: nil)
        count.use(scope())

        try FileManager.default.removeItem(atPath: iCloud + "/Finance/Old.pdf")
        try disk.write(.iCloud, "Finance/Budget.xlsx", "v2, longer", modified: OneWayDiskWorld.day0)
        func event(_ path: String, _ change: FolderWatchEvent.Change, _ id: UInt64) -> FolderWatchEvent {
            FolderWatchEvent(id: id, root: iCloud + "/Finance", path: iCloud + "/" + path, realPath: iCloud + "/" + path, change: change, fileID: id)
        }
        count.note(FolderWatchBatch(events: [event("Finance/Old.pdf", [.removed, .isFile], 100), event("Finance/Budget.xlsx", [.modified, .isFile], 101)]))
        #expect(count.tally == .init(count: 2))

        sync.now = OneWayDiskWorld.day0.addingTimeInterval(60)
        let result = try await sync.run()
        let left = result.leftForLater(record: sync.record)
        #expect(left.contains("Finance/Old.pdf"), "a deletion the pass deferred isn't left for later: \(left)")
        #expect(!left.contains("Finance/Budget.xlsx"))
        count.use(scope())
        count.passCompleted(startedAt: 200, stopped: false, leftForLater: left)
        #expect(count.tally == .init(count: 1), "the deferred deletion stopped counting, or the carried edit didn't")
    }

    /// A file you stop syncing stops counting at once, as a folder unticked does.
    @Test func aFileYouStopSyncingStopsCounting() throws {
        let world = try World()
        let count = world.count()
        let will = world.iCloud + "/Legal/Will.pdf"
        try world.write(will, "edited")
        count.note(FolderWatchBatch(events: [world.event(will, [.modified, .isFile])]))
        #expect(count.tally == .init(count: 1))
        world.exclusions = OneWaySyncExclusions(files: [OneWaySyncExclusion(iCloudPath: "Legal/Will.pdf", dropboxPath: "Legal/Will.pdf", stoppedAt: 0)])
        count.use(world.scope)
        #expect(count.tally == .init())
    }

    // MARK: Across a relaunch

    /// The count is saved: a relaunch starts from it, and the watcher's replay — whose events
    /// FSEvents no longer marks as this process's — adds only what really differs.
    @Test func aRelaunchKeepsTheCountAndJudgesTheReplay() throws {
        let world = try World()
        let file = URL(fileURLWithPath: world.root + "/store/changes.json")
        let first = world.count(file)
        let will = world.iCloud + "/Legal/Will.pdf"
        try world.write(will, "edited")
        first.note(FolderWatchBatch(events: [world.event(will, [.modified, .isFile])]))
        let second = world.count(file)
        #expect(second.tally == .init(count: 1))
        // Replayed: the same edit again, and a copy the sync wrote and recorded before quitting.
        let copy = world.dropbox + "/Legal/Copied.pdf"
        try world.write(copy, "copy", at: 1_700_000_000)
        world.record.files.append(OneWaySyncFileRecord(key: 60, iCloudPath: "Legal/Copied.pdf", dropboxPath: "Legal/Copied.pdf",
                                                       iCloudID: nil, dropboxID: nil, size: 4, modified: 1_700_000_000))
        second.use(world.scope)
        second.note(FolderWatchBatch(events: [world.event(will, [.modified, .isFile]), world.event(copy, [.created, .isFile])]))
        #expect(second.tally == .init(count: 1))
    }

    /// A saved count that can't be read can't vouch for anything: unknown, not zero.
    @Test func anUnreadableSavedCountIsUnknown() throws {
        let world = try World()
        let file = URL(fileURLWithPath: world.root + "/changes.json")
        try Data("not json".utf8).write(to: file)
        #expect(world.count(file).tally == .init(count: 0, isUnknown: true))
        #expect(world.count(URL(fileURLWithPath: world.root + "/none.json")).tally == .init())
    }
}

/// **FV against real FSEvents**: the watcher on both sides, the count judging what it delivers.
/// Every wait is bounded, and each "doesn't count" waits for the event itself first, so it can't
/// pass by asking too early.
@Suite(.serialized) struct OneWaySyncChangeCountLiveTests {
    typealias World = OneWaySyncChangeCountTests.World
    typealias Inbox = FolderWatcherLiveTests.Inbox

    /// Writes `text` into `path` from another process, so FSEvents doesn't mark it as ours.
    static func writeElsewhere(_ text: String, to path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \"$1\" > \"$2\"", "sh", text, path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    static func watch(_ world: World, _ count: OneWaySyncChangeCount, history: FolderWatchHistory = .inMemory(),
                      replay: FolderWatchReplay = .none, inbox: Inbox) -> FolderWatcher {
        let watcher = FolderWatcher(history: history, latency: 0.05, quiet: 0.2, maxDelay: 2) { batch in
            count.note(batch)
            inbox.add(batch)
        }
        watcher.watch(Set(world.scope.roots.map(FolderWatchRoot.init)), replay: replay)
        return watcher
    }

    /// The brief's case: an edit in an iCloud synced folder raises the count; the sync's own write
    /// into Dropbox doesn't, though nothing in the record matches it yet.
    @MainActor
    @Test func anICloudEditRaisesTheCountAndTheSyncsOwnWriteDoesNot() async throws {
        let world = try World()
        let count = world.count()
        let inbox = Inbox()
        let watcher = Self.watch(world, count, inbox: inbox)
        defer { watcher.stop() }

        // As while a pass runs (the controller's syncNow).
        count.holdOwnWrites(on: .dropbox, until: .distantFuture)
        let copy = world.dropbox + "/Legal/Copied.pdf"
        try Data("written by the sync".utf8).write(to: URL(fileURLWithPath: copy))
        await waitUntil("the sync's own Dropbox write was never reported", timeout: 10) {
            inbox.events.contains { $0.path == copy }
        }
        #expect(inbox.events.filter { $0.path == copy }.allSatisfy { $0.isOwn }, "precondition: FSEvents marked it as ours")
        #expect(count.tally == .init(), "the sync's own Dropbox write counted")

        let will = world.iCloud + "/Legal/Will.pdf"
        try Self.writeElsewhere("edited in Pages", to: will)
        await waitUntil("the iCloud edit never raised the count", timeout: 10) { count.tally.count == 1 }
        #expect(count.tally == .init(count: 1))
        #expect(inbox.events.contains { $0.path == will && !$0.isOwn })
    }

    /// At launch the watcher replays what changed while SyncCloud was closed, from its stored
    /// history, and the count picks it up; with no history to replay it says changes may be waiting.
    @MainActor
    @Test func aRelaunchReplaysWhatChangedWhileClosed() async throws {
        let world = try World()
        let file = URL(fileURLWithPath: world.root + "/store/changes.json")
        let history = FolderWatchHistory.inMemory()
        do {
            let inbox = Inbox()
            let count = world.count(file)
            let watcher = Self.watch(world, count, history: history, inbox: inbox)
            // Something delivered, so the stored id stands past the watcher's start.
            let marker = world.iCloud + "/Legal/.DS_Store"
            try Self.writeElsewhere("x", to: marker)
            await waitUntil("the marker never arrived", timeout: 10) { inbox.events.contains { $0.path == marker } }
            watcher.stop()
            #expect(count.tally == .init())
        }
        // Closed: an edit nobody watches.
        let will = world.iCloud + "/Legal/Will.pdf"
        try Self.writeElsewhere("edited while SyncCloud was closed", to: will)

        let inbox = Inbox()
        let count = world.count(file)
        let watcher = Self.watch(world, count, history: history, replay: .stored, inbox: inbox)
        defer { watcher.stop() }
        await waitUntil("the replay never counted the edit", timeout: 10) { count.tally.count == 1 }
        #expect(count.tally == .init(count: 1), "the history was there, so the count is a number")
        #expect(inbox.rescans.isEmpty)

        // A watcher with no stored history can't say what happened before it: unknown.
        let fresh = world.count()
        let unknown = Self.watch(world, fresh, history: .inMemory(), replay: .stored, inbox: Inbox())
        defer { unknown.stop() }
        await waitUntil("no history never made the count unknown", timeout: 10) { fresh.tally.isUnknown }
    }
}
