import Foundation
import Testing
@testable import Sync

/// RD67's matching order, through the examples the design names: what each record now is on
/// disk, and the plan that follows from it.
@Suite struct OneWaySyncMatchingTests {
    static let a = "Finance/a.pdf"
    static let b = "Finance/b.pdf"

    @Test func renameThenANewFileAtTheOldNameIsBoth() {
        var world = OneWayWorld(files: [Self.a])
        world.rename(.iCloud, Self.a, to: "Finance/c.pdf")
        world.add(.iCloud, OneWayWorld.file(Self.a, id: 60, hash: "new"))
        let plan = world.plan()
        #expect(plan.matches.iCloud.files[1] == .found(world.item(.iCloud, "Finance/c.pdf")!, by: .id))
        #expect(plan.actions == [
            .moveInDropbox(from: Self.a, to: "Finance/c.pdf"),
            .copy(from: Self.a, to: Self.a, needsDownload: false),
        ])
    }

    @Test func aSaveThatMakesANewFileIsAnEdit() {
        var world = OneWayWorld(files: [Self.a])
        world.update(.iCloud, Self.a) {
            $0.documentID = 61
            $0.size = 2500
            $0.contentHash = "saved"
        }
        let plan = world.plan()
        #expect(plan.matches.iCloud.files[1] == .found(world.item(.iCloud, Self.a)!, by: .name))
        #expect(plan.matches.iCloud.recordableID(of: world.item(.iCloud, Self.a)!) == 61)
        #expect(plan.actions == [.replace(dropboxPath: Self.a, with: Self.a, needsDownload: false, previousIsDropboxEdit: false)])

        // The same save with unchanged contents changes nothing in Dropbox.
        world.update(.iCloud, Self.a) {
            $0.size = 2000
            $0.contentHash = "h1"
        }
        #expect(world.plan().actions.isEmpty)
    }

    @Test func aMoveOverAnotherFileWaitsForThatFilesRemoval() {
        var world = OneWayWorld(files: [Self.a, Self.b])
        world.delete(.iCloud, Self.b)
        world.rename(.iCloud, Self.a, to: Self.b)
        let first = OneWayWorld.t0.addingTimeInterval(3600)

        let one = world.plan(now: first)
        #expect(one.matches.iCloud.files[1] == .found(world.item(.iCloud, Self.b)!, by: .id))
        #expect(one.matches.iCloud.files[2] == .gone)
        #expect(one.actions.isEmpty)
        #expect(one.waits == [OneWaySyncWait(
            subject: .file(iCloudPath: Self.a, dropboxPath: Self.a), reason: .waitingForRemovalOf(Self.b))])
        #expect(one.waits.allSatisfy { !$0.reason.needsYou })

        world.record.files[1].iCloudGoneSince = one.goneSince[2]
        let two = world.plan(now: first.addingTimeInterval(31 * 60))
        #expect(two.actions == [
            .moveToRemoved(dropboxPath: Self.b, cause: .deletedInICloud),
            .moveInDropbox(from: Self.a, to: Self.b),
        ])
        #expect(two.waits.isEmpty)
    }

    @Test func aSwapGoesThroughATemporaryName() {
        var world = OneWayWorld(files: [Self.a, Self.b])
        world.update(.iCloud, Self.a) { $0.path = "swapping" }
        world.update(.iCloud, Self.b) { $0.path = Self.a }
        world.update(.iCloud, "swapping") { $0.path = Self.b }
        let parked = "Finance/.SyncCloud-swap-1-a.pdf"
        #expect(world.plan().steps == [
            OneWaySyncStep(action: .moveInDropbox(from: Self.a, to: parked), record: 1),
            OneWaySyncStep(action: .moveInDropbox(from: Self.b, to: Self.a), record: 2),
            OneWaySyncStep(action: .moveInDropbox(from: parked, to: Self.b), record: 1),
        ])
    }

    @Test func aThreeWayRotationGoesThroughOneTemporaryName() {
        let c = "Finance/c.pdf"
        var world = OneWayWorld(files: [Self.a, Self.b, c])
        // a → b, b → c, c → a.
        world.update(.iCloud, Self.a) { $0.path = "x" }
        world.update(.iCloud, c) { $0.path = Self.a }
        world.update(.iCloud, Self.b) { $0.path = c }
        world.update(.iCloud, "x") { $0.path = Self.b }
        let parked = "Finance/.SyncCloud-swap-1-a.pdf"
        #expect(world.plan().actions == [
            .moveInDropbox(from: Self.a, to: parked),
            .moveInDropbox(from: c, to: Self.a),
            .moveInDropbox(from: Self.b, to: c),
            .moveInDropbox(from: parked, to: Self.b),
        ])
    }

    @Test func aChainOfMovesRunsFromTheFreeEnd() {
        let c = "Finance/c.pdf"
        var world = OneWayWorld(files: [Self.a, Self.b])
        // a → b and b → c: b must leave before a arrives.
        world.rename(.iCloud, Self.b, to: c)
        world.rename(.iCloud, Self.a, to: Self.b)
        #expect(world.plan().actions == [
            .moveInDropbox(from: Self.b, to: c),
            .moveInDropbox(from: Self.a, to: Self.b),
        ])
    }

    @Test func aWaitThatKeepsANameTakenMakesTheMoveIntoItWaitToo() {
        let c = "Finance/c.pdf"
        var world = OneWayWorld(files: [Self.a, Self.b])
        // b → c, onto a Dropbox-only c; a → b, which needs b gone first.
        world.rename(.iCloud, Self.b, to: c)
        world.rename(.iCloud, Self.a, to: Self.b)
        world.add(.dropbox, OneWayWorld.file(c, id: 90, hash: "other"))
        let plan = world.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.waitReasons == [.nameTakenByDropboxOnlyFile(c), .nameTaken(Self.b)])
    }

    @Test func aMoveBelowAFileWaitsForThatFileToMove() {
        // Notes, a file, becomes Notes.txt; folder A becomes Notes. A's move falls back to its
        // files (the name is taken now), and they must wait until Notes has moved.
        var world = OneWayWorld(subfolders: ["Finance/A"], files: ["Finance/Notes", "Finance/A/x.pdf"])
        world.rename(.iCloud, "Finance/Notes", to: "Finance/Notes.txt")
        world.rename(.iCloud, "Finance/A", to: "Finance/Notes")
        #expect(world.plan().actions == [
            .moveInDropbox(from: "Finance/Notes", to: "Finance/Notes.txt"),
            .moveInDropbox(from: "Finance/A/x.pdf", to: "Finance/Notes/x.pdf"),
        ])

        // A file that stays where a folder should be: the move waits.
        var stays = OneWayWorld(subfolders: ["Finance/A"], files: ["Finance/A/x.pdf"])
        stays.add(.dropbox, OneWayWorld.file("Finance/Notes", id: 90, hash: "n"))
        stays.rename(.iCloud, "Finance/A", to: "Finance/Notes")
        let plan = stays.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.waitReasons == [.nameTaken("Finance/Notes")])
    }

    @Test func folderMovesRunShallowestDestinationFirst() {
        var world = OneWayWorld(subfolders: ["Finance/A", "Finance/B"], files: ["Finance/A/x.pdf", "Finance/B/y.pdf"])
        world.rename(.iCloud, "Finance/B", to: "Finance/C")
        world.rename(.iCloud, "Finance/A", to: "Finance/C/A")
        #expect(world.plan().actions == [
            .moveFolderInDropbox(from: "Finance/B", to: "Finance/C"),
            .moveFolderInDropbox(from: "Finance/A", to: "Finance/C/A"),
        ])
    }

    @Test func aRenamedChildOfARenamedFolderFollowsIt() {
        var world = OneWayWorld(subfolders: ["Finance/A", "Finance/A/B"], files: ["Finance/A/B/x.pdf"])
        world.rename(.iCloud, "Finance/A", to: "Finance/P")
        world.rename(.iCloud, "Finance/P/B", to: "Finance/P/Q")
        #expect(world.plan().actions == [
            .moveFolderInDropbox(from: "Finance/A", to: "Finance/P"),
            .moveFolderInDropbox(from: "Finance/P/B", to: "Finance/P/Q"),
        ])
    }

    @Test func aFileInAFolderRenamedInICloudIsUnchangedThere() {
        // Only Dropbox renamed the file: under Match iCloud it moves back, into the renamed folder.
        var world = OneWayWorld(subfolders: ["Finance/A"], files: ["Finance/A/x.pdf"])
        world.rename(.iCloud, "Finance/A", to: "Finance/B")
        world.rename(.dropbox, "Finance/A/x.pdf", to: "Finance/A/y.pdf")
        #expect(world.plan().steps == [
            OneWaySyncStep(action: .moveFolderInDropbox(from: "Finance/A", to: "Finance/B")),
            OneWaySyncStep(action: .moveInDropbox(from: "Finance/B/y.pdf", to: "Finance/B/x.pdf"), record: 1, undoesDropboxChange: true),
        ])
    }

    @Test func aFolderRecreatedUnderItsNameIsFoundByName() {
        var world = OneWayWorld(subfolders: ["Finance/Receipts"], files: ["Finance/Receipts/x.pdf"])
        let key = world.record.subfolders[0].key
        world.update(.dropbox, "Finance/Receipts") { $0.folderID = OneWaySyncFolderID(inode: 777) }
        let plan = world.plan()
        #expect(plan.matches.dropbox.folders[key] == .found(world.item(.dropbox, "Finance/Receipts")!, by: .name))
        #expect(plan.actions.isEmpty)

        // Its old ID elsewhere: not the same folder.
        world.add(.dropbox, OneWayWorld.folder("Finance/Old", inode: world.record.subfolders[0].dropboxID!.inode!))
        #expect(world.plan().matches.dropbox.folders[key].map { if case .found(_, .id) = $0 { return true } else { return false } } == true)
    }

    @Test func aFolderRenamedWhileAFileInsideIsSavedAsNew() {
        let x = "Finance/Receipts/x.pdf"
        var world = OneWayWorld(subfolders: ["Finance/Receipts"], files: [x])
        world.rename(.iCloud, "Finance/Receipts", to: "Finance/Receipts 2026")
        world.update(.iCloud, "Finance/Receipts 2026/x.pdf") {
            $0.documentID = 77
            $0.size = 3000
            $0.contentHash = "saved"
        }
        let plan = world.plan()
        #expect(plan.matches.iCloud.files[1]?.item?.path == "Finance/Receipts 2026/x.pdf")
        #expect(plan.actions == [
            .moveFolderInDropbox(from: "Finance/Receipts", to: "Finance/Receipts 2026"),
            .replace(dropboxPath: "Finance/Receipts 2026/x.pdf", with: "Finance/Receipts 2026/x.pdf",
                     needsDownload: false, previousIsDropboxEdit: false),
        ])
    }

    @Test func aMovedFolderTakesItsFilesWithoutAMoveEach() {
        var world = OneWayWorld(subfolders: ["Finance/Receipts"], files: ["Finance/Receipts/x.pdf", "Finance/Receipts/y.pdf"])
        world.add(.iCloud, OneWayWorld.folder("Finance/2026", inode: 9))
        world.rename(.iCloud, "Finance/Receipts", to: "Finance/2026/Receipts")
        #expect(world.plan().actions == [.moveFolderInDropbox(from: "Finance/Receipts", to: "Finance/2026/Receipts")])
    }

    @Test func aFolderMoveOntoATakenNameFallsBackToFileMoves() {
        var world = OneWayWorld(subfolders: ["Finance/Receipts"], files: ["Finance/Receipts/x.pdf"])
        world.add(.dropbox, OneWayWorld.folder("Finance/Old", inode: 9))
        world.rename(.iCloud, "Finance/Receipts", to: "Finance/Old")
        #expect(world.plan().actions == [.moveInDropbox(from: "Finance/Receipts/x.pdf", to: "Finance/Old/x.pdf")])
    }

    @Test func hardLinksAreNeverMatchedByTheirSharedID() {
        var world = OneWayWorld(files: [Self.a])
        world.add(.iCloud, OneWayWorld.file("Finance/link.pdf", id: 1, hash: "h1"))
        let plan = world.plan()
        // The recorded name and ID still agree on a.pdf; the ID is no longer recordable.
        #expect(plan.matches.iCloud.files[1] == .found(world.item(.iCloud, Self.a)!, by: .name))
        #expect(plan.matches.iCloud.sharedIDs == [1])
        #expect(plan.matches.iCloud.recordableID(of: world.item(.iCloud, Self.a)!) == nil)
        #expect(plan.actions == [.copy(from: "Finance/link.pdf", to: "Finance/link.pdf", needsDownload: false)])
    }

    @Test func aHardLinkedFileUnderNewNamesIsTreatedAsGone() {
        var world = OneWayWorld(files: [Self.a])
        world.rename(.iCloud, Self.a, to: "Finance/c.pdf")
        world.add(.iCloud, OneWayWorld.file("Finance/d.pdf", id: 1, hash: "h1"))
        let plan = world.plan()
        #expect(plan.matches.iCloud.files[1] == .gone)
        #expect(plan.actions == [
            .copy(from: "Finance/c.pdf", to: "Finance/c.pdf", needsDownload: false),
            .copy(from: "Finance/d.pdf", to: "Finance/d.pdf", needsDownload: false),
        ])
    }

    @Test func aNewIDIsNotTakenWhileTheOldIDIsElsewhere() {
        var world = OneWayWorld(files: [Self.a])
        world.update(.iCloud, Self.a) { $0.documentID = 2 }
        // The old ID, 1, is at two other paths: hard links, so it can't be followed, and it can't
        // be ruled out either.
        world.add(.iCloud, OneWayWorld.file("Finance/c.pdf", id: 1, hash: "h1"))
        world.add(.iCloud, OneWayWorld.file("Finance/d.pdf", id: 1, hash: "h1"))
        #expect(world.plan().matches.iCloud.files[1] == .gone)
    }

    @Test func aNewIDHeldByAnotherRecordIsNotTaken() {
        var world = OneWayWorld(files: [Self.a, Self.b])
        // b.pdf was removed earlier; its ID turns up at a.pdf's name.
        let b = world.record.files.removeLast()
        world.record.removed = [OneWaySyncRemovedFile(file: b, removedPath: "SyncCloud Removed/b.pdf")]
        world.delete(.iCloud, Self.b)
        world.delete(.dropbox, Self.b)
        world.update(.iCloud, Self.a) { $0.documentID = 2 }
        let plan = world.plan()
        #expect(plan.matches.iCloud.files[1] == .gone)
        #expect(plan.matches.reappeared.map(\.removed.removedPath) == ["SyncCloud Removed/b.pdf"])
        #expect(plan.waitReasons == [.waitingForRemovalOf(Self.a)])
    }

    @Test func aFileRecordedWithoutAnIDIsFollowedByName() {
        var world = OneWayWorld(files: [Self.a])
        world.record.files[0].iCloudID = nil
        world.update(.iCloud, Self.a) { $0.documentID = 33; $0.size = 2500 }
        let plan = world.plan()
        #expect(plan.matches.iCloud.files[1] == .found(world.item(.iCloud, Self.a)!, by: .name))
        #expect(plan.actions == [.replace(dropboxPath: Self.a, with: Self.a, needsDownload: false, previousIsDropboxEdit: false)])
    }

    @Test func aCaseOnlyRenameInICloudRenamesInPlace() {
        var world = OneWayWorld(files: [Self.a])
        world.rename(.iCloud, Self.a, to: "Finance/A.pdf")
        #expect(world.plan().actions == [.moveInDropbox(from: Self.a, to: "Finance/A.pdf")])
    }

    @Test func aCaseOnlyRenameOfAFolderInICloudRenamesItInPlace() {
        var world = OneWayWorld(subfolders: ["Finance/receipts"], files: ["Finance/receipts/x.pdf"])
        world.rename(.iCloud, "Finance/receipts", to: "Finance/Receipts")
        #expect(world.plan().actions == [.moveFolderInDropbox(from: "Finance/receipts", to: "Finance/Receipts")])
    }

    @Test func unicodeFormNeverCounts() {
        let nfc = "Finance/caf\u{00E9}.pdf"
        let nfd = "Finance/cafe\u{0301}.pdf"
        #expect(Array(nfc.utf8) != Array(nfd.utf8))

        // iCloud reports the other form, same ID: not a rename.
        var world = OneWayWorld(files: [nfc])
        world.update(.iCloud, nfc) { $0.path = nfd }
        #expect(world.plan().actions.isEmpty)

        // ...or a new ID at that name: the same file, by name.
        world.update(.iCloud, nfd) { $0.documentID = 90 }
        let plan = world.plan()
        #expect(plan.matches.iCloud.files[1] == .found(world.item(.iCloud, nfd)!, by: .name))
        #expect(plan.actions.isEmpty)

        // Dropbox in the other form: not a rename either.
        var dropbox = OneWayWorld(files: [nfc])
        dropbox.update(.dropbox, nfc) { $0.path = nfd }
        #expect(dropbox.plan().actions.isEmpty)
        #expect(OneWaySyncSide.dropbox.nameKey(nfd) == OneWaySyncSide.dropbox.nameKey("Finance/CAF\u{00C9}.pdf"))
        #expect(Array(OneWaySyncSide.iCloud.nameKey(nfd).utf8) == Array(nfc.utf8))
    }

    @Test func movedBetweenSyncedFoldersIsAMove() {
        var world = OneWayWorld(folders: ["Finance", "Legal"], files: [Self.a])
        world.rename(.iCloud, Self.a, to: "Legal/a.pdf")
        #expect(world.plan().actions == [.moveInDropbox(from: Self.a, to: "Legal/a.pdf")])
    }

    @Test func movedOutToAFolderThatIsNotSyncedIsRemoved() {
        var world = OneWayWorld(files: [Self.a])
        world.add(.iCloud, OneWayWorld.folder("Work", inode: 9))
        world.rename(.iCloud, Self.a, to: "Work/a.pdf")
        let plan = world.plan()
        #expect(plan.matches.iCloud.files[1] == .movedOut(world.item(.iCloud, "Work/a.pdf")!))
        #expect(plan.actions == [.moveToRemoved(dropboxPath: Self.a, cause: .movedOutInICloud(to: "Work/a.pdf"))])
        #expect(plan.window.changes.map(\.kind) == [.deletedOrMovedOut])
        #expect(plan.unsyncedICloudFolders == ["Work"])
    }

    @Test func movedIntoASharedFolderCountsAsMovedOut() {
        var world = OneWayWorld(files: [Self.a])
        world.update(.iCloud, Self.a) { $0.path = "Finance/Shared/a.pdf"; $0.isExcluded = true }
        #expect(world.plan().actions == [.moveToRemoved(dropboxPath: Self.a, cause: .movedOutInICloud(to: "Finance/Shared/a.pdf"))])
    }

    @Test func anUnrecordedIDInASyncedFolderIsCopied() {
        // A file moved in from a folder that isn't synced: its ID was never recorded.
        var world = OneWayWorld(files: [Self.a])
        world.add(.iCloud, OneWayWorld.file("Finance/in.pdf", id: 40, hash: "in"))
        #expect(world.plan().actions == [.copy(from: "Finance/in.pdf", to: "Finance/in.pdf", needsDownload: false)])
    }

    @Test func aNewFileOnADropboxOnlyFilesName() {
        var world = OneWayWorld(files: [Self.a])
        world.add(.dropbox, OneWayWorld.file("Finance/z.pdf", id: 80, size: 5000, hash: "z"))

        var same = world
        same.add(.iCloud, OneWayWorld.file("Finance/z.pdf", id: 81, size: 5000, hash: "z"))
        #expect(same.plan().actions == [.adopt(iCloudPath: "Finance/z.pdf", dropboxPath: "Finance/z.pdf")])

        var other = world
        other.add(.iCloud, OneWayWorld.file("Finance/z.pdf", id: 81, size: 6000, hash: "y"))
        let plan = other.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.waitReasons == [.nameTakenByDropboxOnlyFile("Finance/z.pdf")])
    }

    @Test func aRenameOntoADropboxOnlyFilesName() {
        var world = OneWayWorld(files: [Self.a])
        world.rename(.iCloud, Self.a, to: "Finance/z.pdf")

        var same = world
        same.add(.dropbox, OneWayWorld.file("Finance/z.pdf", id: 80, hash: "h1"))
        let adopted = same.plan()
        #expect(adopted.steps == [
            OneWaySyncStep(action: .moveToRemoved(dropboxPath: Self.a, cause: .duplicateOfAdoptedFile("Finance/z.pdf")), record: 1),
            OneWaySyncStep(action: .adopt(iCloudPath: "Finance/z.pdf", dropboxPath: "Finance/z.pdf"), record: 1),
        ])
        #expect(adopted.dropboxOnly.isEmpty)

        // Edited as well, to exactly what the Dropbox-only file holds: nothing left to replace.
        var edited = world
        edited.edit(.iCloud, "Finance/z.pdf", hash: "z")
        edited.add(.dropbox, OneWayWorld.file("Finance/z.pdf", id: 80, size: 3000, hash: "z"))
        #expect(edited.plan().actions == [
            .moveToRemoved(dropboxPath: Self.a, cause: .duplicateOfAdoptedFile("Finance/z.pdf")),
            .adopt(iCloudPath: "Finance/z.pdf", dropboxPath: "Finance/z.pdf"),
        ])

        #expect(edited.plan().window.changes.isEmpty)

        // Same size, contents not read: waits for them, and asks for them.
        var unread = world
        unread.add(.dropbox, OneWayWorld.file("Finance/z.pdf", id: 80, hash: nil))
        let asked = unread.plan()
        #expect(asked.actions.isEmpty)
        #expect(asked.waitReasons == [.contentsNotRead])
        #expect(asked.dropboxContentsToRead == ["Finance/z.pdf"])

        var other = world
        other.add(.dropbox, OneWayWorld.file("Finance/z.pdf", id: 80, hash: "other"))
        let plan = other.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.waitReasons == [.nameTakenByDropboxOnlyFile("Finance/z.pdf")])
    }

    @Test func twoICloudNamesForOneDropboxName() {
        var world = OneWayWorld(files: [])
        world.add(.iCloud, OneWayWorld.file("Finance/Tax.pdf", id: 1, hash: "x"))
        world.add(.iCloud, OneWayWorld.file("Finance/tax.pdf", id: 2, hash: "y"))
        let plan = world.plan()
        #expect(plan.actions == [.copy(from: "Finance/Tax.pdf", to: "Finance/Tax.pdf", needsDownload: false)])
        #expect(plan.waitReasons == [.nameTaken("Finance/Tax.pdf")])
    }
}

/// A synced folder itself renamed, moved or deleted waits as a whole.
@Suite struct OneWaySyncSyncedFolderTests {

    @Test func renamedInICloudWaitsWithNothingCopiedOrRemoved() {
        var world = OneWayWorld(folders: ["Health"], files: ["Health/a.pdf"])
        world.rename(.iCloud, "Health", to: "Medical")
        world.add(.iCloud, OneWayWorld.file("Medical/new.pdf", id: 40, hash: "n"))
        let plan = world.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.goneSince.isEmpty)
        #expect(plan.waits == [OneWaySyncWait(subject: .folder("Health"), reason: .syncedFolderRenamedInICloud(to: "Medical"))])
    }

    @Test func deletedInICloudWaits() {
        var world = OneWayWorld(files: ["Finance/a.pdf"])
        world.delete(.iCloud, "Finance")
        let plan = world.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.waitReasons == [.syncedFolderMovedOrDeletedInICloud])
        // Its files wait with it: no deletion clock starts.
        #expect(plan.goneSince.isEmpty)
    }

    @Test func movedDeeperInICloudWaits() {
        var world = OneWayWorld(folders: ["Finance", "Legal"], files: ["Finance/a.pdf"])
        world.rename(.iCloud, "Finance", to: "Legal/Finance")
        let plan = world.plan()
        #expect(plan.matches.iCloud.folders[1001].map { if case .movedOut = $0 { return true } else { return false } } == true)
        #expect(plan.actions.isEmpty)
        #expect(plan.waitReasons == [.syncedFolderMovedOrDeletedInICloud])
    }

    @Test func deletedInDropboxWaits() {
        var world = OneWayWorld(files: ["Finance/a.pdf"])
        world.delete(.dropbox, "Finance")
        let plan = world.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.waitReasons == [.syncedFolderChangedInDropbox])
    }

    @Test func changedInDropboxWaits() {
        var world = OneWayWorld(files: ["Finance/a.pdf"])
        world.rename(.dropbox, "Finance", to: "Money")
        world.add(.dropbox, OneWayWorld.file("Money/extra.pdf", id: 90, hash: "x"))
        let plan = world.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.waitReasons == [.syncedFolderChangedInDropbox])
        #expect(plan.dropboxOnly.isEmpty)
    }

    @Test func otherFoldersKeepSyncing() {
        var world = OneWayWorld(folders: ["Finance", "Legal"], files: ["Finance/a.pdf", "Legal/l.pdf"])
        world.delete(.iCloud, "Finance")
        world.edit(.iCloud, "Legal/l.pdf")
        #expect(world.plan().actions == [
            .replace(dropboxPath: "Legal/l.pdf", with: "Legal/l.pdf", needsDownload: false, previousIsDropboxEdit: false)
        ])
    }

    @Test func aFolderNotFullyListedIsLeftAlone() {
        var world = OneWayWorld(folders: ["Finance", "Legal"], files: ["Finance/a.pdf", "Legal/l.pdf"])
        world.dropboxIncomplete = ["Finance"]
        world.edit(.iCloud, "Finance/a.pdf")
        world.add(.iCloud, OneWayWorld.file("Finance/new.pdf", id: 40, hash: "n"))
        world.edit(.iCloud, "Legal/l.pdf")
        #expect(world.plan().actions == [
            .replace(dropboxPath: "Legal/l.pdf", with: "Legal/l.pdf", needsDownload: false, previousIsDropboxEdit: false)
        ])
    }

    @Test func aNewFolderInTheICloudParentIsListedNotSynced() {
        var world = OneWayWorld(files: ["Finance/a.pdf"])
        world.add(.iCloud, OneWayWorld.folder("Taxes", inode: 9))
        world.add(.iCloud, OneWayWorld.file("Taxes/t.pdf", id: 40, hash: "t"))
        let plan = world.plan()
        #expect(plan.actions.isEmpty)
        #expect(plan.unsyncedICloudFolders == ["Taxes"])
    }
}
