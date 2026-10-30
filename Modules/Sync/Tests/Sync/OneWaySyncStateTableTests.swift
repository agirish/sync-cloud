import Foundation
import Testing
@testable import Sync

/// RD67's state table, row by row: each side diffed against the record, under each DA setting.
/// Every row starts from Finance/a.pdf and Finance/b.pdf synced as recorded; only a.pdf changes.
@Suite struct OneWaySyncStateTableTests {

    struct Row: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var settings = OneWaySyncSettings()
        var change: @Sendable (inout OneWayWorld) -> Void
        var actions: [OneWaySyncAction] = []
        var waits: [OneWaySyncWaitReason] = []
        var dropboxOnly: [String] = []
    }

    static let a = "Finance/a.pdf"
    static let askMe = OneWaySyncSettings(whenDeletedRenamedOrMoved: .askMe, whenEdited: .askMe)
    static let useICloud = OneWaySyncSettings(whenDeletedRenamedOrMoved: .matchICloud, whenEdited: .useICloud)

    static let rows: [Row] = [
        // new | absent
        Row(testDescription: "added in iCloud: copy",
            change: { $0.add(.iCloud, OneWayWorld.file("Finance/new.pdf", id: 50, hash: "n")) },
            actions: [.copy(from: "Finance/new.pdf", to: "Finance/new.pdf", needsDownload: false)]),
        // changed | as recorded
        Row(testDescription: "edited in iCloud: replace, keeping SyncCloud's previous version",
            change: { $0.edit(.iCloud, a) },
            actions: [.replace(dropboxPath: a, with: a, needsDownload: false, previousIsDropboxEdit: false)]),
        Row(testDescription: "renamed in iCloud: the same rename in Dropbox",
            change: { $0.rename(.iCloud, a, to: "Finance/c.pdf") },
            actions: [.moveInDropbox(from: a, to: "Finance/c.pdf")]),
        Row(testDescription: "tags changed in iCloud: tags copied, nothing uploaded",
            change: { $0.update(.iCloud, a) { $0.tags = ["Red"] } },
            actions: [.setTags(dropboxPath: a, tags: ["Red"])]),
        Row(testDescription: "tags differ only in Dropbox: not rewritten every pass",
            change: { $0.update(.dropbox, a) { $0.tags = ["Blue"] } }),
        // gone | as recorded (first check only; the timing is in OneWaySyncDeletionTests below)
        Row(testDescription: "deleted in iCloud, first check: nothing yet",
            change: { $0.delete(.iCloud, a) }),
        // any | changed
        Row(testDescription: "edited in Dropbox, Ask Me: waits",
            settings: askMe, change: { $0.edit(.dropbox, a) }, waits: [.editedInDropbox]),
        Row(testDescription: "edited on both sides, Ask Me: waits",
            change: { $0.edit(.iCloud, a, hash: "mine"); $0.edit(.dropbox, a, hash: "theirs") },
            waits: [.editedOnBothSides]),
        Row(testDescription: "deleted in iCloud, edited in Dropbox, Ask Me: waits",
            change: { $0.delete(.iCloud, a); $0.edit(.dropbox, a) }, waits: [.deletedInICloudEditedInDropbox]),
        Row(testDescription: "edited in Dropbox, Use iCloud's: Dropbox's edit to SyncCloud Removed",
            settings: useICloud, change: { $0.edit(.dropbox, a) },
            actions: [.replace(dropboxPath: a, with: a, needsDownload: false, previousIsDropboxEdit: true)]),
        Row(testDescription: "renamed in iCloud, edited in Dropbox, Use iCloud's: replaced, then renamed",
            settings: useICloud, change: { $0.rename(.iCloud, a, to: "Finance/c.pdf"); $0.edit(.dropbox, a) },
            actions: [
                .replace(dropboxPath: a, with: "Finance/c.pdf", needsDownload: false, previousIsDropboxEdit: true),
                .moveInDropbox(from: a, to: "Finance/c.pdf"),
            ]),
        // as recorded | gone or moved
        Row(testDescription: "deleted in Dropbox, Match iCloud: iCloud's copied back",
            change: { $0.delete(.dropbox, a) },
            actions: [.copy(from: a, to: a, needsDownload: false)]),
        Row(testDescription: "moved in Dropbox, Match iCloud: moved back",
            change: { $0.rename(.dropbox, a, to: "Finance/Old/a.pdf") },
            actions: [.moveInDropbox(from: "Finance/Old/a.pdf", to: a)]),
        Row(testDescription: "renamed in Dropbox, Match iCloud: renamed back",
            change: { $0.rename(.dropbox, a, to: "Finance/z.pdf") },
            actions: [.moveInDropbox(from: "Finance/z.pdf", to: a)]),
        Row(testDescription: "deleted in Dropbox, Ask Me: waits",
            settings: askMe, change: { $0.delete(.dropbox, a) }, waits: [.deletedOrMovedInDropbox]),
        Row(testDescription: "moved in Dropbox, Ask Me: waits",
            settings: askMe, change: { $0.rename(.dropbox, a, to: "Finance/Old/a.pdf") }, waits: [.deletedOrMovedInDropbox]),
        Row(testDescription: "letter case changed in Dropbox: not a change",
            change: { $0.rename(.dropbox, a, to: "Finance/A.pdf") }),
        // changed, gone or moved | gone or moved
        Row(testDescription: "edited in iCloud, deleted in Dropbox, Match iCloud: iCloud's copied back",
            change: { $0.edit(.iCloud, a); $0.delete(.dropbox, a) },
            actions: [.copy(from: a, to: a, needsDownload: false)]),
        Row(testDescription: "renamed in iCloud, deleted in Dropbox, Match iCloud: waits (only an edit is copied back)",
            change: { $0.rename(.iCloud, a, to: "Finance/c.pdf"); $0.delete(.dropbox, a) },
            waits: [.changedOnBothSides]),
        Row(testDescription: "edited in iCloud, moved out of the synced folders in Dropbox: waits",
            change: { $0.edit(.iCloud, a); $0.rename(.dropbox, a, to: "Elsewhere/a.pdf") },
            waits: [.changedOnBothSides]),
        Row(testDescription: "edited and renamed in iCloud, Dropbox as recorded: replaced, then renamed",
            change: { $0.edit(.iCloud, a); $0.rename(.iCloud, a, to: "Finance/c.pdf") },
            actions: [
                .replace(dropboxPath: a, with: "Finance/c.pdf", needsDownload: false, previousIsDropboxEdit: false),
                .moveInDropbox(from: a, to: "Finance/c.pdf"),
            ]),
        Row(testDescription: "tags changed and renamed in iCloud: tags set at the new name",
            change: { $0.update(.iCloud, a) { $0.tags = ["Red"] }; $0.rename(.iCloud, a, to: "Finance/c.pdf") },
            actions: [.moveInDropbox(from: a, to: "Finance/c.pdf"), .setTags(dropboxPath: "Finance/c.pdf", tags: ["Red"])]),
        Row(testDescription: "edited and renamed in iCloud, renamed alike in Dropbox: waits, the edit isn't lost",
            change: { $0.edit(.iCloud, a); $0.rename(.iCloud, a, to: "Finance/c.pdf"); $0.rename(.dropbox, a, to: "Finance/c.pdf") },
            waits: [.changedOnBothSides]),
        Row(testDescription: "edited on both sides, contents unread: waits rather than assume they match",
            change: {
                $0.update(.iCloud, a) { $0.size = 3000; $0.contentHash = nil }
                $0.update(.dropbox, a) { $0.size = 3000; $0.contentHash = nil }
            },
            waits: [.editedOnBothSides]),
        Row(testDescription: "edited in iCloud, deleted in Dropbox, Ask Me: waits",
            settings: askMe, change: { $0.edit(.iCloud, a); $0.delete(.dropbox, a) }, waits: [.changedOnBothSides]),
        Row(testDescription: "edited in iCloud, moved in Dropbox: waits",
            change: { $0.edit(.iCloud, a); $0.rename(.dropbox, a, to: "Finance/Old/a.pdf") }, waits: [.changedOnBothSides]),
        Row(testDescription: "deleted on both sides: the record is dropped",
            change: { $0.delete(.iCloud, a); $0.delete(.dropbox, a) },
            actions: [.forget(dropboxPath: a)]),
        Row(testDescription: "deleted in iCloud, moved in Dropbox: waits",
            change: { $0.delete(.iCloud, a); $0.rename(.dropbox, a, to: "Finance/Old/a.pdf") }, waits: [.changedOnBothSides]),
        Row(testDescription: "renamed alike on both sides: recorded, nothing moved",
            change: { $0.rename(.iCloud, a, to: "Finance/c.pdf"); $0.rename(.dropbox, a, to: "Finance/c.pdf") },
            actions: [.adopt(iCloudPath: "Finance/c.pdf", dropboxPath: "Finance/c.pdf")]),
        Row(testDescription: "renamed differently on both sides: waits",
            change: { $0.rename(.iCloud, a, to: "Finance/c.pdf"); $0.rename(.dropbox, a, to: "Finance/d.pdf") },
            waits: [.changedOnBothSides]),
        Row(testDescription: "the same edit on both sides: recorded, nothing copied",
            change: { $0.edit(.iCloud, a, hash: "same"); $0.edit(.dropbox, a, hash: "same") },
            actions: [.adopt(iCloudPath: a, dropboxPath: a)]),
        // — | not recorded
        Row(testDescription: "only in Dropbox: left alone, listed",
            change: { $0.add(.dropbox, OneWayWorld.file("Finance/extra.pdf", id: 70, hash: "x")) },
            dropboxOnly: ["Finance/extra.pdf"]),
        Row(testDescription: "a conflicted copy of a synced file: waits, as an edit",
            change: { $0.add(.dropbox, OneWayWorld.file("Finance/a (Ann's conflicted copy 2026-10-30).pdf", id: 71, hash: "x")) },
            waits: [.conflictedCopy(of: a)]),
        // not downloaded | any
        Row(testDescription: "offloaded in iCloud, size and date as recorded: nothing",
            change: { $0.update(.iCloud, a) { $0.isDownloaded = false; $0.contentHash = nil } }),
        Row(testDescription: "offloaded in iCloud and changed: downloaded only to replace",
            change: { $0.update(.iCloud, a) { $0.isDownloaded = false; $0.contentHash = nil; $0.size = 2100 } },
            actions: [.replace(dropboxPath: a, with: a, needsDownload: true, previousIsDropboxEdit: false)]),
        Row(testDescription: "added in iCloud, offloaded: downloaded only to copy",
            change: { $0.add(.iCloud, OneWayWorld.file("Finance/new.pdf", id: 50, hash: nil, downloaded: false)) },
            actions: [.copy(from: "Finance/new.pdf", to: "Finance/new.pdf", needsDownload: true)]),
    ]

    @Test(arguments: rows)
    func row(_ row: Row) {
        var world = OneWayWorld(files: [Self.a, "Finance/b.pdf"])
        row.change(&world)
        let plan = world.plan(settings: row.settings)
        #expect(plan.stop == nil)
        #expect(plan.actions == row.actions)
        #expect(plan.waitReasons == row.waits)
        #expect(plan.dropboxOnly == row.dropboxOnly)
    }

    @Test func untouchedWorldPlansNothing() {
        let plan = OneWayWorld(files: [Self.a, "Finance/b.pdf"]).plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.waits.isEmpty)
        #expect(plan.goneSince.isEmpty)
    }

    @Test func secondDropboxChangeInADayWaits() {
        var world = OneWayWorld(files: [Self.a])
        world.delete(.dropbox, Self.a)
        let now = OneWayWorld.t0.addingTimeInterval(3600)
        world.record.files[0].matchedICloudAt = Int64(now.timeIntervalSince1970) - 2 * 3600
        #expect(world.plan(now: now).waitReasons == [.changedInDropboxAgainToday])

        world.record.files[0].matchedICloudAt = Int64(now.timeIntervalSince1970) - 25 * 3600
        #expect(world.plan(now: now).actions == [.copy(from: Self.a, to: Self.a, needsDownload: false)])

        // A time after now means the clock went backwards: a fresh window.
        world.record.files[0].matchedICloudAt = Int64(now.timeIntervalSince1970) + 600
        #expect(world.plan(now: now).actions == [.copy(from: Self.a, to: Self.a, needsDownload: false)])
    }

    @Test func stepsNameTheirRecordAndMarkWhatUndoesADropboxChange() {
        var world = OneWayWorld(files: [Self.a, "Finance/b.pdf", "Finance/c.pdf"])
        world.delete(.dropbox, Self.a)
        world.edit(.iCloud, "Finance/b.pdf")
        world.rename(.dropbox, "Finance/c.pdf", to: "Finance/Old/c.pdf")
        world.add(.iCloud, OneWayWorld.file("Finance/new.pdf", id: 50, hash: "n"))
        #expect(world.plan().steps == [
            OneWaySyncStep(
                action: .replace(dropboxPath: "Finance/b.pdf", with: "Finance/b.pdf", needsDownload: false, previousIsDropboxEdit: false),
                record: 2),
            OneWaySyncStep(action: .moveInDropbox(from: "Finance/Old/c.pdf", to: "Finance/c.pdf"), record: 3, undoesDropboxChange: true),
            OneWaySyncStep(action: .copy(from: Self.a, to: Self.a, needsDownload: false), record: 1, undoesDropboxChange: true),
            OneWaySyncStep(action: .copy(from: "Finance/new.pdf", to: "Finance/new.pdf", needsDownload: false)),
        ])
    }

    @Test func anEditCopiedBackAfterADropboxDeletionAlsoWaitsTheSecondTimeInADay() {
        var world = OneWayWorld(files: [Self.a])
        world.edit(.iCloud, Self.a)
        world.delete(.dropbox, Self.a)
        let now = OneWayWorld.t0.addingTimeInterval(3600)
        let seconds = Int64(now.timeIntervalSince1970)
        world.record.files[0].matchedICloudAt = seconds - 2 * 3600
        #expect(world.plan(now: now).waitReasons == [.changedInDropboxAgainToday])
        // A day is a day: exactly 24 hours later is a fresh window.
        world.record.files[0].matchedICloudAt = seconds - 24 * 3600
        #expect(world.plan(now: now).actions == [.copy(from: Self.a, to: Self.a, needsDownload: false)])
        world.record.files[0].matchedICloudAt = seconds - 24 * 3600 + 1
        #expect(world.plan(now: now).waitReasons == [.changedInDropboxAgainToday])
    }

    @Test func useICloudsAlsoWaitsWhenDropboxMovesTheFileAgain() {
        var world = OneWayWorld(files: [Self.a])
        world.edit(.dropbox, Self.a)
        world.rename(.dropbox, Self.a, to: "Finance/Old/a.pdf")
        let settings = OneWaySyncSettings(whenEdited: .useICloud)
        #expect(world.plan(settings: settings).steps == [
            OneWaySyncStep(
                action: .replace(dropboxPath: "Finance/Old/a.pdf", with: Self.a, needsDownload: false, previousIsDropboxEdit: true),
                record: 1),
            OneWaySyncStep(action: .moveInDropbox(from: "Finance/Old/a.pdf", to: Self.a), record: 1, undoesDropboxChange: true),
        ])
        let now = OneWayWorld.t0.addingTimeInterval(3600)
        world.record.files[0].matchedICloudAt = Int64(now.timeIntervalSince1970) - 600
        #expect(world.plan(settings: settings, now: now).waitReasons == [.changedInDropboxAgainToday])
    }

    @Test func aFileGoneFromAPartialDropboxListingIsNotCalledDeleted() {
        var world = OneWayWorld(folders: ["Finance", "Legal"], files: [Self.a, "Legal/l.pdf"])
        // Moved by hand into Legal, which Dropbox didn't list in full.
        world.delete(.dropbox, Self.a)
        world.dropboxIncomplete = ["Legal"]
        let plan = world.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.waits.isEmpty)
        #expect(world.plan(settings: OneWaySyncSettings(whenDeletedRenamedOrMoved: .askMe)).waits.isEmpty)

        world.delete(.iCloud, Self.a)
        #expect(world.plan().actions.isEmpty)
    }

    @Test func onlyRemovalsAndReplacementsCountTowardTheLimit() {
        var world = OneWayWorld(files: [Self.a, "Finance/b.pdf"])
        world.update(.iCloud, Self.a) { $0.tags = ["Red"] }
        world.add(.iCloud, OneWayWorld.file("Finance/new.pdf", id: 50, hash: "n"))
        #expect(world.plan().window.changes.isEmpty)

        world.edit(.iCloud, "Finance/b.pdf")
        let now = OneWayWorld.t0.addingTimeInterval(3600)
        #expect(world.plan(now: now).window.changes == [
            OneWaySyncRemovalWindow.Change(file: 2, folder: 1001, kind: .replaced, seenAt: Int64(now.timeIntervalSince1970))
        ])
    }
}

/// Deleted means gone at least 30 minutes and gone at a second full check; a reappearing ID
/// moves the file back.
@Suite struct OneWaySyncDeletionTests {
    static let a = "Finance/a.pdf"
    static let removedAction = OneWaySyncAction.moveToRemoved(dropboxPath: a, cause: .deletedInICloud)

    @Test func removedOnlyOnceGoneThirtyMinutesAndSeenAgain() {
        var world = OneWayWorld(files: [Self.a, "Finance/b.pdf"])
        world.delete(.iCloud, Self.a)
        let first = OneWayWorld.t0.addingTimeInterval(3600)

        let one = world.plan(now: first)
        #expect(one.actions.isEmpty)
        #expect(one.goneSince == [1: Int64(first.timeIntervalSince1970)])

        world.record.files[0].iCloudGoneSince = one.goneSince[1]
        let early = world.plan(now: first.addingTimeInterval(29 * 60))
        #expect(early.actions.isEmpty)
        #expect(early.goneSince == one.goneSince)

        let late = world.plan(now: first.addingTimeInterval(30 * 60))
        #expect(late.actions == [Self.removedAction])
        #expect(late.window.changes.map(\.seenAt) == [Int64(first.timeIntervalSince1970)])
    }

    @Test func aClockMovedBackwardsStartsTheWaitAgain() {
        var world = OneWayWorld(files: [Self.a])
        world.delete(.iCloud, Self.a)
        let now = OneWayWorld.t0.addingTimeInterval(3600)
        world.setGoneSince(Self.a, now.addingTimeInterval(7200))
        let plan = world.plan(now: now)
        #expect(plan.actions.isEmpty)
        #expect(plan.goneSince == [1: Int64(now.timeIntervalSince1970)])
    }

    @Test func nothingIsDeletedWhileAnyFolderIsNotFullyListed() {
        var world = OneWayWorld(folders: ["Finance", "Legal"], files: [Self.a, "Legal/l.pdf"])
        world.delete(.iCloud, Self.a)
        world.setGoneSince(Self.a, OneWayWorld.t0)
        world.iCloudIncomplete = ["Legal"]
        let plan = world.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.notFullyListed == ["Legal"])
        // The clock it already had is kept, not restarted.
        #expect(plan.goneSince == [1: Int64(OneWayWorld.t0.timeIntervalSince1970)])

        // A file gone for the first time while a listing is incomplete starts no clock.
        world.setGoneSince(Self.a, nil)
        #expect(world.plan().goneSince.isEmpty)
    }

    @Test func reappearingBeforeRemovalIsNoChange() {
        var world = OneWayWorld(files: [Self.a])
        world.setGoneSince(Self.a, OneWayWorld.t0)
        let plan = world.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.goneSince.isEmpty)
    }

    @Test func reappearingAfterRemovalMovesItBack() {
        var world = OneWayWorld(files: [Self.a, "Finance/b.pdf"])
        let file = world.record.files.removeFirst()
        world.record.removed = [OneWaySyncRemovedFile(file: file, removedPath: "SyncCloud Removed/2026-10-30/a.pdf")]
        world.delete(.dropbox, Self.a)
        #expect(world.plan().actions == [.moveBackFromRemoved(removedPath: "SyncCloud Removed/2026-10-30/a.pdf", to: Self.a)])

        // Changed while it was gone: moved back, then replaced.
        world.edit(.iCloud, Self.a)
        #expect(world.plan().actions == [
            .moveBackFromRemoved(removedPath: "SyncCloud Removed/2026-10-30/a.pdf", to: Self.a),
            .replace(dropboxPath: Self.a, with: Self.a, needsDownload: false, previousIsDropboxEdit: false),
        ])
    }

    @Test func aMoveBackThatWaitsTakesItsReplaceWithIt() {
        var world = OneWayWorld(files: [Self.a])
        let file = world.record.files.removeFirst()
        world.record.removed = [OneWaySyncRemovedFile(file: file, removedPath: "SyncCloud Removed/a.pdf")]
        world.edit(.iCloud, Self.a)
        // A Dropbox-only file now holds the name.
        world.update(.dropbox, Self.a) { $0.documentID = 90; $0.contentHash = "theirs"; $0.size = 4000 }
        let plan = world.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.waitReasons == [.nameTakenByDropboxOnlyFile(Self.a)])
    }

    @Test func useICloudsOnADropboxEditStillWaitsOutTheDeletion() {
        var world = OneWayWorld(files: [Self.a])
        world.delete(.iCloud, Self.a)
        world.edit(.dropbox, Self.a)
        let settings = OneWaySyncSettings(whenEdited: .useICloud)
        #expect(world.plan(settings: settings).actions.isEmpty)
        world.setGoneSince(Self.a, OneWayWorld.t0)
        #expect(world.plan(settings: settings).actions == [Self.removedAction])
    }
}
