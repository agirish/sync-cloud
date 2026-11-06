import Darwin
import Foundation
import Testing
@testable import Sync

/// What a pass leaves behind for the next one, on scratch folders: the record stays true after
/// dates that differ, uploads Dropbox hasn't reported, a quit mid-pass, a step whose file isn't
/// what was checked, a swap cut short, and SyncCloud Removed emptied; and the pass leaves what
/// others saved (the settings, another Mac's marker) alone.
@Suite struct OneWaySyncPassSafetyTests {
    typealias Sync = OneWaySyncRunTests.Sync
    let run = OneWaySyncRunTests()

    // MARK: The record

    /// A pair adopted as identical whose two files carry different dates is recorded with each
    /// side's own date: the next pass finds nothing edited in Dropbox, under either setting.
    @Test(arguments: [OneWaySyncSettings.WhenEdited.askMe, .useICloud])
    func anAdoptedPairWithTwoDatesIsNotReadAsEditedNextTime(_ whenEdited: OneWaySyncSettings.WhenEdited) async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/a.pdf", "the same on both", modified: OneWaySyncRunTests.earlier)
        try run.write(world, .dropbox, "Finance/a.pdf", "the same on both", modified: OneWaySyncRunTests.earliest)
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.state.settings.whenEdited = whenEdited
        #expect(sync.look().plan.actions == [.adopt(iCloudPath: "Finance/a.pdf", dropboxPath: "Finance/a.pdf")])
        try await sync.run()
        let again = sync.look()
        #expect(again.plan.steps.isEmpty)
        #expect(again.plan.waits.isEmpty)
        #expect(try world.writer().removed.items().isEmpty)
    }

    // MARK: Uploads Dropbox hadn't reported

    func recheck(_ sync: Sync, _ world: OneWayDiskWorld, _ outcome: OneWaySyncUploadOutcome) async throws -> OneWaySyncRun.PendingCheck {
        let check = await OneWaySyncRun.recheckPending(sync.record, dropboxParent: world.dropbox, now: sync.now) { paths in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, outcome) })
        }
        sync.record = check.record
        try sync.store.saveRecord(check.record, firstRun: sync.firstRun)
        return check
    }

    /// A copy Dropbox refuses after the deadline is heard at the next sync: it leaves the synced
    /// files, is listed as skipped, and isn't written again until it changes in iCloud.
    @Test func aCopyRefusedAfterTheDeadlineIsSkippedNextSync() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/CON.pdf", "late", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.neverReport = ["CON.pdf"]
        try await sync.run()
        #expect(sync.record.pendingUploads.map(\.dropboxPath) == ["Finance/CON.pdf"])
        #expect(sync.record.pendingUploads.first?.wasNew == true)

        let check = try await recheck(sync, world, .refused("excluded from sync"))
        #expect(check.refused == ["Finance/CON.pdf"])
        #expect(sync.record.files.isEmpty)
        #expect(sync.record.pendingUploads.isEmpty)
        let next = sync.look()
        #expect(next.plan.steps.isEmpty)
        #expect(next.skipped.map(\.path) == ["Finance/CON.pdf"])
    }

    /// An edit's replace refused late keeps the file's record, and waits as refused.
    @Test func aReplaceRefusedAfterTheDeadlineKeepsItsRecord() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/a.pdf", "one", modified: OneWaySyncRunTests.earliest)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        sync.neverReport = ["a.pdf"]
        try run.write(world, .iCloud, "Finance/a.pdf", "two, longer", modified: OneWaySyncRunTests.earlier)
        try await sync.run()
        #expect(sync.record.pendingUploads.first?.wasNew == false)
        _ = try await recheck(sync, world, .refused("Dropbox won’t take it"))
        #expect(sync.record.files.map(\.iCloudPath) == ["Finance/a.pdf"])
        #expect(sync.record.refused.first?.record == sync.record.files.first?.key)
        #expect(sync.look().plan.waits.map(\.reason) == [.refusedByDropbox])
    }

    /// Uploaded since, or changed in Dropbox since: nothing more to hear. Still full: the pass
    /// stops before writing, and asks again next time.
    @Test func pendingUploadsSettleOrStayFull() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.full = ["a.pdf"]
        try await sync.run()
        #expect(sync.record.pendingUploads.count == 1)
        let full = try await recheck(sync, world, .dropboxFull)
        #expect(full.stillFull)
        #expect(sync.record.pendingUploads.count == 1)
        let uploaded = try await recheck(sync, world, .uploaded(documentID: 77))
        #expect(!uploaded.stillFull)
        #expect(uploaded.settled == 1)
        #expect(sync.record.pendingUploads.isEmpty)
        #expect(sync.record.files.first?.dropboxID == world.documentID(.dropbox, "Finance/a.pdf") ?? 77)

        sync.neverReport = ["b.pdf"]
        try run.write(world, .iCloud, "Finance/b.pdf", "b", modified: OneWaySyncRunTests.earlier)
        try await sync.run()
        try world.write(.dropbox, "Finance/b.pdf", "edited in Dropbox since, longer")
        let changed = try await recheck(sync, world, .refused("never asked"))
        #expect(changed.refused.isEmpty)
        #expect(sync.record.pendingUploads.isEmpty)
    }

    /// The same for a recorded file edited the same way on both sides, each with its own date.
    @Test func theSameEditOnBothSidesWithTwoDatesIsNotReadAsEditedNextTime() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/a.pdf", "one", modified: OneWaySyncRunTests.earliest)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try run.write(world, .iCloud, "Finance/a.pdf", "the same edit", modified: OneWaySyncRunTests.earlier)
        try run.write(world, .dropbox, "Finance/a.pdf", "the same edit", modified: OneWayDiskWorld.day0)
        try await sync.run()
        let again = sync.look()
        #expect(again.plan.steps.isEmpty)
        #expect(again.plan.waits.isEmpty)
    }

    /// Match iCloud on a pair recorded as identical but dated apart only puts the name back:
    /// nothing is replaced, and nothing goes to SyncCloud Removed.
    @Test func matchICloudOnAPairDatedApartOnlyRenames() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Legal/Will.pdf", "the same on both", modified: OneWaySyncRunTests.earlier)
        try run.write(world, .dropbox, "Legal/Will.pdf", "the same on both", modified: OneWaySyncRunTests.earliest)
        let sync = try Sync(world: world, folders: ["Legal"])
        sync.state.settings.whenDeletedRenamedOrMoved = .askMe
        try await sync.run()
        try run.move(world, .dropbox, "Legal/Will.pdf", "Legal/Renamed.pdf")
        let look = sync.look()
        let wait = try #require(look.plan.waits.first)
        #expect(wait.reason == .deletedOrMovedInDropbox)
        let versions = try #require(OneWaySyncAnswers.versions(for: wait.subject, in: look))
        #expect(versions.sameAsRecorded)
        try OneWaySyncAnswers.matchICloud(versions, writer: world.writer())
        #expect(world.read(.dropbox, "Legal/Will.pdf") == "the same on both")
        #expect(try world.writer().removed.items().isEmpty)
        try await sync.run()
        #expect(sync.look().plan.waits.isEmpty)
    }

    /// What the steps did is saved before the wait for Dropbox's uploads: a quit during it leaves
    /// a record from which a renamed folder's files don't read as moved in Dropbox.
    @Test func aQuitDuringTheUploadWaitKeepsWhatTheStepsDid() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/2025/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        try run.write(world, .iCloud, "Finance/2025/b.pdf", "b", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.state.settings.whenDeletedRenamedOrMoved = .askMe
        try await sync.run()
        try run.move(world, .iCloud, "Finance/2025", "Finance/2025 Taxes")
        try run.write(world, .iCloud, "Finance/2025 Taxes/a.pdf", "a, edited", modified: OneWayDiskWorld.day0)

        // The app quits while Dropbox uploads: what was saved by then is all the next launch has.
        let store = sync.store
        let seen = Locked<OneWaySyncRecord?>(nil)
        sync.duringUploadWait = {
            if case .ready(let record, _, _) = store.loadRecord(on: OneWayWorld.binding) { seen.set(record) }
        }
        try await sync.run()
        let saved = try #require(seen.value)
        #expect(Set(saved.files.map(\.dropboxPath)) == ["Finance/2025 Taxes/a.pdf", "Finance/2025 Taxes/b.pdf"])
        sync.record = saved
        let next = sync.look()
        #expect(next.plan.waits.isEmpty)
        #expect(next.plan.steps.isEmpty)
    }

    /// A removed file whose copy in SyncCloud Removed was emptied since syncs as a new file when
    /// its ID comes back to a synced folder; it isn't moved back from a place it isn't.
    @Test func aRemovedFileEmptiedFromSyncCloudRemovedIsCopiedWhenItComesBack() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try FileManager.default.createDirectory(at: world.iCloud.appendingPathComponent("Work"), withIntermediateDirectories: true)
        try run.write(world, .iCloud, "Finance/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try run.move(world, .iCloud, "Finance/a.pdf", "Work/a.pdf")
        try await sync.run()
        #expect(sync.record.removed.count == 1)
        let writer = try world.writer()
        _ = writer.removed.empty(writer.removed.items())

        try run.move(world, .iCloud, "Work/a.pdf", "Finance/a.pdf")
        let look = sync.look()
        #expect(look.plan.actions == [.copy(from: "Finance/a.pdf", to: "Finance/a.pdf", needsDownload: false)])
        try await sync.run()
        #expect(world.read(.dropbox, "Finance/a.pdf") == "a")
        #expect(sync.record.removed.isEmpty)
        #expect(sync.record.files.map(\.iCloudPath) == ["Finance/a.pdf"])
    }

    /// A replace writes only over the file the sync checked: when the move back from SyncCloud
    /// Removed before it doesn't land and something else holds the name, it leaves that alone.
    @Test func aReplaceAfterAMoveBackThatFailedLeavesTheNameAlone() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try FileManager.default.createDirectory(at: world.iCloud.appendingPathComponent("Work"), withIntermediateDirectories: true)
        try run.write(world, .iCloud, "Finance/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try run.move(world, .iCloud, "Finance/a.pdf", "Work/a.pdf")
        try await sync.run()
        try run.move(world, .iCloud, "Work/a.pdf", "Finance/a.pdf")
        try run.write(world, .iCloud, "Finance/a.pdf", "a, edited while away", modified: OneWayDiskWorld.day0)
        let look = sync.look()
        #expect(look.plan.steps.count == 2)

        // Between the look and the apply: the kept copy goes, and a file takes the name.
        let writer = try world.writer()
        _ = writer.removed.empty(writer.removed.items())
        try world.write(.dropbox, "Finance/a.pdf", "someone else's, just made")
        let result = try await OneWaySyncRun.apply(
            look, state: sync.state, firstRun: sync.firstRun, store: sync.store, writer: writer, marker: nil,
            hardwareID: "HW-1", macName: "Test Mac", confirmUploads: { _ in [:] }, now: { OneWayDiskWorld.day0 })
        #expect(world.read(.dropbox, "Finance/a.pdf") == "someone else's, just made")
        #expect(result.notDone.count == 2)
    }

    /// A Dropbox copy moved by hand into a synced folder held this pass isn't recorded where it
    /// went: the move still reads as one made in Dropbox once the folder is decided.
    @Test func aDropboxMoveIntoAHeldFolderIsNotTakenAsAgreed() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        try run.write(world, .iCloud, "Health/h.pdf", "h", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance", "Health"])
        try await sync.run()
        // Health waits as a whole: renamed in iCloud.
        try run.move(world, .iCloud, "Health", "Medical")
        try run.move(world, .dropbox, "Finance/a.pdf", "Health/a.pdf")
        try await sync.run()
        #expect(sync.file("Finance/a.pdf")?.dropboxPath == "Finance/a.pdf")
        #expect(world.read(.dropbox, "Health/a.pdf") == "a")
    }

    // MARK: Conflicted copies

    /// A conflicted copy waits on its own: the synced file it was made from goes on syncing, and
    /// its record follows iCloud's edits, so a second edit is a plain replace.
    @Test func aConflictedCopyDoesNotHoldTheSyncedFilesRecord() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Legal/Report.pdf", "one", modified: OneWaySyncRunTests.earliest)
        let sync = try Sync(world: world, folders: ["Legal"])
        try await sync.run()
        try world.write(.dropbox, "Legal/Report (Ann's conflicted copy 2026-10-30).pdf", "Ann's")
        try run.write(world, .iCloud, "Legal/Report.pdf", "two, longer", modified: OneWaySyncRunTests.earlier)
        try await sync.run()
        #expect(sync.file("Legal/Report.pdf")?.size == Int64("two, longer".utf8.count))
        try run.write(world, .iCloud, "Legal/Report.pdf", "three, longer still", modified: OneWayDiskWorld.day0)
        let next = sync.look()
        #expect(next.plan.actions == [.replace(dropboxPath: "Legal/Report.pdf", with: "Legal/Report.pdf", needsDownload: false,
                                               previousIsDropboxEdit: false)])
        #expect(next.plan.waits.map(\.reason) == [.conflictedCopy(of: "Legal/Report.pdf")])
    }

    /// A conflicted copy and an edit of the same file are two rows, and the copy's row is about
    /// the copy.
    @Test func aConflictedCopyAndAnEditOfItsFileAreTwoRows() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Legal/Report.pdf", "one", modified: OneWaySyncRunTests.earliest)
        let sync = try Sync(world: world, folders: ["Legal"])
        try await sync.run()
        let copy = "Legal/Report (Ann's conflicted copy 2026-10-30).pdf"
        try world.write(.dropbox, copy, "Ann's")
        try run.write(world, .dropbox, "Legal/Report.pdf", "edited in Dropbox", modified: OneWayDiskWorld.day0)
        let look = sync.look()
        let rows = OneWaySyncRows.rows(for: look, knownUnsynced: [], at: OneWayDiskWorld.day0).filter { $0.kind == .needsYou }
        #expect(rows.map(\.id).sorted() == ["ows:file:\(copy)", "ows:file:Legal/Report.pdf"])
        let copyRow = try #require(rows.first { $0.id == "ows:file:\(copy)" })
        #expect(copyRow.title == "Dropbox made a conflicted copy of Report.pdf")
        let subject = try #require(look.plan.waits.first { $0.reason == .conflictedCopy(of: "Legal/Report.pdf") }?.subject)
        let versions = try #require(OneWaySyncAnswers.versions(for: subject, in: look))
        #expect(versions.isConflictedCopy)
        #expect(versions.dropbox?.path == copy)
    }

    /// A synced file whose own name says "conflicted copy" is still the synced file: Use iCloud's
    /// replaces it in place.
    @Test func aSyncedFileNamedLikeAConflictedCopyIsReplacedInPlace() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let path = "Legal/Notes (conflicted copy).txt"
        try run.write(world, .iCloud, path, "iCloud's", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Legal"])
        try await sync.run()
        try run.write(world, .dropbox, path, "edited in Dropbox", modified: OneWayDiskWorld.day0)
        let look = sync.look()
        let wait = try #require(look.plan.waits.first)
        #expect(wait.reason == .editedInDropbox)
        let versions = try #require(OneWaySyncAnswers.versions(for: wait.subject, in: look))
        #expect(!versions.isConflictedCopy)
        let idBefore = world.documentID(.dropbox, path)
        try OneWaySyncAnswers.useICloudsVersion(versions, writer: world.writer())
        #expect(world.read(.dropbox, path) == "iCloud's")
        #expect(world.documentID(.dropbox, path) == idBefore)
        #expect(try world.writer().removed.items().map(\.origin.kind) == [.replacedDropboxVersion])
    }

    // MARK: What others saved

    /// A setting changed while the pass waited for Dropbox is kept: the pass saves only its own
    /// fields.
    @Test func aSettingChangedDuringThePassIsKept() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.state.settings.whenEdited = .useICloud
        let atStart = sync.state
        let look = sync.look()
        var changed = atStart
        changed.settings.whenEdited = .askMe
        changed.pausedSince = 1_793_000_000
        try sync.store.saveState(changed)
        _ = try await OneWaySyncRun.apply(
            look, state: atStart, firstRun: sync.firstRun, store: sync.store, writer: world.writer(), marker: nil,
            hardwareID: "HW-1", macName: "Test Mac", confirmUploads: { _ in [:] }, now: { OneWayDiskWorld.day0 })
        let saved = try #require(sync.store.loadState().value)
        #expect(saved.settings.whenEdited == .askMe)
        #expect(saved.pausedSince == 1_793_000_000)
        #expect(saved.lastSyncAt == OneWaySyncHistoryStore.seconds(OneWayDiskWorld.day0))
    }

    /// The marker is written at the end of a pass only while it names this Mac: another Mac that
    /// took the sync over meanwhile keeps it.
    @Test func aPassLeavesAnotherMacsMarkerAlone() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        let marker = OneWaySyncMarkerFile(folder: world.dropbox)
        try marker.claim(OneWaySyncMacMarker(hardwareID: "HW-1", macName: "Test Mac", claimedAt: 1_793_000_000))
        sync.marker = marker
        try await sync.run()
        guard case .thisMac(let mine) = marker.check(hardwareID: "HW-1") else { Issue.record("this Mac's marker"); return }
        #expect(mine.lastSyncAt == OneWaySyncHistoryStore.seconds(OneWayDiskWorld.day0))

        try marker.claim(OneWaySyncMacMarker(hardwareID: "HW-2", macName: "Other Mac", claimedAt: 1_793_100_000))
        try run.write(world, .iCloud, "Finance/b.pdf", "b", modified: OneWaySyncRunTests.earlier)
        try await sync.run()
        guard case .thisMac(let theirs) = marker.check(hardwareID: "HW-2") else { Issue.record("the other Mac's marker"); return }
        #expect(theirs.macName == "Other Mac")
        #expect(theirs.lastSyncAt == nil)
    }

    /// Dropbox saying the account is full is told apart from a slow upload: the pass says so, and
    /// SyncCloud's copy is its own next time.
    @Test func dropboxReportingFullIsTold() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.full = ["a.pdf"]
        let result = try await sync.run()
        #expect(result.dropboxFull)
        #expect(result.synced == 0)
        #expect(sync.look().plan.steps.isEmpty)
    }

    // MARK: A swap cut short

    /// A file a swap of names parked when the app quit is listed, and put back under its own name
    /// when that is free, or where the swap was taking it when it isn't.
    @Test func aParkedSwapIsPutBack() throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try FileManager.default.createDirectory(at: world.dropbox.appendingPathComponent("Finance"), withIntermediateDirectories: true)
        try world.write(.dropbox, "Finance/.SyncCloud-swap-1-a.pdf", "a's copy")
        try world.write(.dropbox, "Finance/.SyncCloud-swap-2-c.pdf", "c's copy")
        try world.write(.dropbox, "Finance/c.pdf", "b's copy, moved to c")
        let listing = OneWaySyncLister(side: .dropbox, parent: world.dropbox).list(syncedFolders: ["Finance"])
        #expect(listing.parked == ["Finance/.SyncCloud-swap-1-a.pdf", "Finance/.SyncCloud-swap-2-c.pdf"])
        #expect(!listing.listing.items.contains { $0.path.contains(".SyncCloud-") })

        let steps = [OneWaySyncStep(action: .moveInDropbox(from: "Finance/.SyncCloud-swap-2-c.pdf", to: "Finance/b.pdf"))]
        let back = OneWaySyncRun.putBackParked(listing.parked, steps: steps, writer: try world.writer())
        #expect(back.putBack == ["Finance/a.pdf", "Finance/b.pdf"])
        #expect(back.left.isEmpty)
        #expect(world.read(.dropbox, "Finance/a.pdf") == "a's copy")
        #expect(world.read(.dropbox, "Finance/b.pdf") == "c's copy")
        #expect(world.read(.dropbox, "Finance/c.pdf") == "b's copy, moved to c")
    }

    @Test func parkedNamesAreReadBack() {
        #expect(OneWaySyncPlanner.parkedOriginal(".SyncCloud-swap-12-My file-2.pdf") == "My file-2.pdf")
        #expect(OneWaySyncPlanner.parkedOriginal(".SyncCloud-swap--a.pdf") == nil)
        #expect(OneWaySyncPlanner.parkedOriginal(".SyncCloud-swap-x-a.pdf") == nil)
        #expect(OneWaySyncPlanner.parkedOriginal(".SyncCloud-stage-1") == nil)
        #expect(OneWaySyncPlanner.parkedOriginal("a.pdf") == nil)
    }

    // MARK: Branches the other suites don't reach

    /// A file Dropbox is still changing on its own is left alone this pass.
    @Test func aFileStillChangingInDropboxIsLeftThisPass() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/a.pdf", "one", modified: OneWaySyncRunTests.earliest)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try run.write(world, .iCloud, "Finance/a.pdf", "two, longer", modified: OneWaySyncRunTests.earlier)
        let result = try await OneWaySyncRun.apply(
            sync.look(), state: sync.state, firstRun: sync.firstRun, store: sync.store, writer: world.writer(), marker: nil,
            hardwareID: "HW-1", macName: "Test Mac", holdingBack: ["finance/A.PDF"],
            confirmUploads: { _ in [:] }, now: { OneWayDiskWorld.day0 })
        #expect(world.read(.dropbox, "Finance/a.pdf") == "one")
        #expect(result.notDone.map(\.why) == ["it is still changing in Dropbox"])
        #expect(result.record.files.first?.size == 3)
    }

    /// A package Dropbox is still saving into is left alone too: the changes arrive on the files
    /// inside it, not on the package.
    @Test func aPackageStillChangingInsideInDropboxIsLeftThisPass() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/Brief.rtfd/TXT.rtf", "one", modified: OneWaySyncRunTests.earliest)
        let sync = try Sync(world: world, folders: ["Finance"])
        // A replace whatever Dropbox's copy reads as: this is about the hold, not the dates.
        sync.state.settings.whenEdited = .useICloud
        try await sync.run()
        try run.write(world, .iCloud, "Finance/Brief.rtfd/TXT.rtf", "two, longer", modified: OneWaySyncRunTests.earlier)
        let look = sync.look()
        #expect(look.plan.actions.first.map { if case .replace = $0 { true } else { false } } == true,
                "\(look.plan.actions) \(look.plan.waits)")
        let result = try await OneWaySyncRun.apply(
            look, state: sync.state, firstRun: sync.firstRun, store: sync.store, writer: world.writer(), marker: nil,
            hardwareID: "HW-1", macName: "Test Mac", holdingBack: ["finance/Brief.rtfd/TXT.rtf"],
            confirmUploads: { _ in [:] }, now: { OneWayDiskWorld.day0 })
        #expect(world.read(.dropbox, "Finance/Brief.rtfd/TXT.rtf") == "one")
        #expect(result.notDone.map(\.why) == ["it is still changing in Dropbox"])
    }

    /// A folder move in Dropbox that doesn't go through leaves its files recorded where they were,
    /// so the next pass moves the folder again rather than reading its files as moved in Dropbox.
    @Test func aFolderMoveThatFailsLeavesTheRecordAsItWas() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/2025/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try run.move(world, .iCloud, "Finance/2025", "Finance/2025 Taxes")
        let look = sync.look()
        #expect(look.plan.actions.first == .moveFolderInDropbox(from: "Finance/2025", to: "Finance/2025 Taxes"))
        // The name is taken between the look and the move.
        try world.write(.dropbox, "Finance/2025 Taxes/someone's.txt", "someone's")
        let result = try await OneWaySyncRun.apply(
            look, state: sync.state, firstRun: sync.firstRun, store: sync.store, writer: world.writer(), marker: nil,
            hardwareID: "HW-1", macName: "Test Mac", confirmUploads: { _ in [:] }, now: { OneWayDiskWorld.day0 })
        #expect(result.record.files.map(\.dropboxPath) == ["Finance/2025/a.pdf"])
        #expect(result.record.files.map(\.iCloudPath) == ["Finance/2025/a.pdf"])
        #expect(world.read(.dropbox, "Finance/2025/a.pdf") == "a")
        // Once the name is free again, the next pass carries the file to iCloud's new folder.
        try FileManager.default.removeItem(at: world.dropbox.appendingPathComponent("Finance/2025 Taxes"))
        sync.record = result.record
        try await sync.run()
        #expect(world.read(.dropbox, "Finance/2025 Taxes/a.pdf") == "a")
        #expect(sync.file("Finance/2025 Taxes/a.pdf")?.dropboxPath == "Finance/2025 Taxes/a.pdf")
        // The folder it left, empty now and gone from iCloud, goes too.
        #expect(OneWaySyncDisk.kind(at: world.dropbox.appendingPathComponent("Finance/2025").path) == nil)
        #expect(OneWaySyncDisk.kind(at: world.dropbox.appendingPathComponent("Finance").path) == .folder)
    }

    /// A folder a move left with something of yours in it stays.
    @Test func aFolderAMoveLeftWithAFileInItStays() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/Old/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try world.write(.dropbox, "Finance/Old/mine.txt", "only in Dropbox")
        try world.write(.dropbox, "Finance/Old/.DS_Store", "Finder's")
        try run.move(world, .iCloud, "Finance/Old/a.pdf", "Finance/a.pdf")
        try FileManager.default.removeItem(at: world.iCloud.appendingPathComponent("Finance/Old"))
        try await sync.run()
        #expect(world.read(.dropbox, "Finance/a.pdf") == "a")
        #expect(world.read(.dropbox, "Finance/Old/mine.txt") == "only in Dropbox")
        // Not even Finder's file in it is touched.
        #expect(world.read(.dropbox, "Finance/Old/.DS_Store") == "Finder's")
    }

    /// A folder iCloud still has stays in Dropbox once a move empties it, though the synced folder
    /// is spelled in another case there ("Family" in iCloud, "family" in Dropbox).
    @Test func aFolderICloudStillHasStaysWhenTheSyncedFolderIsSpelledInAnotherCase() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try FileManager.default.createDirectory(at: world.iCloud.appendingPathComponent("Family"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: world.dropbox.appendingPathComponent("family"), withIntermediateDirectories: true)
        try run.write(world, .iCloud, "Family/Sub/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Family"])
        #expect(sync.record.syncedFolders.map(\.dropboxPath) == ["family"])
        try await sync.run()
        #expect(world.read(.dropbox, "family/Sub/a.pdf") == "a")
        try run.move(world, .iCloud, "Family/Sub/a.pdf", "Family/a.pdf")
        try await sync.run()
        #expect(world.read(.dropbox, "family/a.pdf") == "a")
        // iCloud keeps Family/Sub, empty: so does Dropbox.
        #expect(OneWaySyncDisk.kind(at: world.dropbox.appendingPathComponent("family/Sub").path) == .folder)
    }

    /// A file you stopped syncing stays out by its ID after a rename in iCloud.
    @Test func aFileYouStoppedSyncingStaysOutAfterARename() {
        var listing = OneWaySyncListing(items: [
            OneWaySyncItem(path: "Legal/renamed.pdf", documentID: 42), OneWaySyncItem(path: "Legal/other.pdf", documentID: 43),
        ])
        let exclusions = OneWaySyncExclusions(files: [
            OneWaySyncExclusion(iCloudPath: "Legal/old.pdf", dropboxPath: "Legal/old.pdf", iCloudID: 42, stoppedAt: 0),
        ])
        OneWaySyncRun.exclude(exclusions, from: &listing, side: .iCloud)
        #expect(listing.items.map(\.path) == ["Legal/other.pdf"])
    }

    /// A folder ticked later starts with a first run of its own; one not in both, or already
    /// synced, isn't added.
    @Test func aFolderTickedLaterHasItsOwnFirstRun() throws {
        var record = OneWayWorld(folders: ["Finance"]).record
        record.nextKey = 50
        let folder = OneWaySyncFolderID(inode: 9)
        let iCloud = OneWaySyncSideListing(listing: OneWaySyncListing(items: [
            OneWaySyncItem(path: "Finance", kind: .folder), OneWaySyncItem(path: "Legal", kind: .folder, folderID: folder),
            OneWaySyncItem(path: "Notes", kind: .folder),
        ]))
        let dropbox = OneWaySyncSideListing(listing: OneWaySyncListing(items: [
            OneWaySyncItem(path: "Finance", kind: .folder), OneWaySyncItem(path: "legal", kind: .folder),
        ]))
        let added = try #require(OneWaySyncSetup.adding("Legal", to: record, iCloud: iCloud, dropbox: dropbox))
        let legal = try #require(added.syncedFolders.last)
        #expect((legal.iCloudPath, legal.dropboxPath, legal.key) == ("Legal", "legal", 50))
        #expect(legal.firstRunCompleted == false)
        #expect(legal.iCloudID == folder)
        #expect(added.nextKey == 51)
        #expect(OneWaySyncSetup.adding("Notes", to: record, iCloud: iCloud, dropbox: dropbox) == nil)
        #expect(OneWaySyncSetup.adding("Finance", to: record, iCloud: iCloud, dropbox: dropbox) == nil)
    }

    /// Match iCloud for a synced folder gone from Dropbox makes it again and copies its files in;
    /// what can't be copied is returned, not swallowed.
    @Test func matchICloudForAFolderSaysWhatItCouldNotCopy() async throws {
        let world = try OneWayDiskWorld()
        defer {
            chmod(world.iCloud.appendingPathComponent("Legal/b.pdf").path, 0o644)
            world.remove()
        }
        try run.write(world, .iCloud, "Legal/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        try run.write(world, .iCloud, "Legal/b.pdf", "b", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Legal"])
        try await sync.run()
        try FileManager.default.removeItem(at: world.dropbox.appendingPathComponent("Legal"))
        chmod(world.iCloud.appendingPathComponent("Legal/b.pdf").path, 0)
        let failed = try OneWaySyncAnswers.matchICloudFolder("Legal", look: sync.look(), writer: world.writer())
        #expect(world.read(.dropbox, "Legal/a.pdf") == "a")
        #expect(failed.count == 1)
        #expect(failed.first?.hasPrefix("Legal/b.pdf (") == true)
    }

    // MARK: After a takeover

    /// A takeover's first run offers its Dropbox-only files as one group; the ones chosen go to
    /// SyncCloud Removed as deleted in iCloud, and the rest stay.
    @Test func aTakeoverOffersDropboxOnlyFilesAsOneGroup() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Legal/kept.pdf", "kept", modified: OneWaySyncRunTests.earlier)
        try run.write(world, .dropbox, "Legal/deleted on the other Mac.pdf", "gone in iCloud")
        try run.write(world, .dropbox, "Legal/mine.pdf", "only ever in Dropbox")
        let sync = try Sync(world: world, folders: ["Legal"])
        try await sync.run()
        let look = sync.look()
        let rows = OneWaySyncRows.rows(for: look, knownUnsynced: [], takenOver: true, at: sync.now)
        #expect(rows.map(\.id) == [OneWaySyncRows.takeoverID])
        #expect(rows.first?.title == "2 files are only in Dropbox — deleted in iCloud?")
        #expect(rows.first?.buttons == [.reviewDropboxOnly])
        // Without a takeover, the same files are only for your information.
        #expect(OneWaySyncRows.rows(for: look, knownUnsynced: [], at: sync.now).map(\.id) == ["ows:info:dropbox-only"])

        let failed = OneWaySyncAnswers.removeDropboxOnly(["Legal/deleted on the other Mac.pdf", "Legal/kept.pdf"], look: look,
                                                         writer: try world.writer())
        #expect(failed == ["Legal/kept.pdf (it isn’t only in Dropbox now)"])
        #expect(world.read(.dropbox, "Legal/deleted on the other Mac.pdf") == nil)
        #expect(world.read(.dropbox, "Legal/mine.pdf") == "only ever in Dropbox")
        #expect(try world.writer().removed.items().map(\.origin.kind) == [.deletedInICloud])
    }

    // MARK: The log

    /// A pass's log names what it replaced, what Dropbox refused and why, and what waits, by kind.
    @Test func aPassLogsWhatItReplacedRefusedAndHeld() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/a.pdf", "one", modified: OneWaySyncRunTests.earliest)
        try run.write(world, .iCloud, "Finance/b.pdf", "b", modified: OneWaySyncRunTests.earliest)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try run.write(world, .iCloud, "Finance/a.pdf", "two, longer", modified: OneWaySyncRunTests.earlier)
        try run.write(world, .dropbox, "Finance/b.pdf", "b, edited in Dropbox", modified: OneWayDiskWorld.day0)
        try run.write(world, .iCloud, "Finance/CON.pdf", "refused", modified: OneWaySyncRunTests.earlier)
        sync.refuse = ["CON.pdf"]
        let details = try await sync.run().logDetails
        #expect(details == [
            "replaced with iCloud’s version, the old one kept: Finance/a.pdf",
            "Dropbox won’t take: Finance/CON.pdf (Dropbox won’t take it)",
            "waits: 1 edited in Dropbox",
        ])
    }

    // MARK: History

    /// An eighth kept version of one file sends the oldest to Dropbox's deleted files, and
    /// History's step says which.
    @Test func anEighthKeptVersionIsNamedInHistory() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/a.pdf", "v0", modified: OneWaySyncRunTests.earliest)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        for day in 1...8 {
            sync.now = OneWayDiskWorld.day0.addingTimeInterval(TimeInterval(day) * 86_400)
            try run.write(world, .iCloud, "Finance/a.pdf", "v\(day)" + String(repeating: ".", count: day), modified: sync.now.addingTimeInterval(-60))
            try await sync.run()
        }
        let newest = try #require(sync.store.history.entries().first)
        let replace = try #require(newest.steps.first { if case .replace = $0.step.action { return true } else { return false } })
        #expect(replace.emptied?.count == 1)
        #expect(try world.writer().removed.items().count == 7)
    }

    /// History keeps 90 days: a pass prunes what is older.
    @Test func aPassPrunesHistoryOlderThan90Days() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/a.pdf", "a", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        let old = try #require(try sync.store.history.begin(
            steps: [OneWaySyncStep(action: .copy(from: "Finance/x.pdf", to: "Finance/x.pdf", needsDownload: false))], held: [],
            firstRun: sync.firstRun, now: OneWayDiskWorld.day0.addingTimeInterval(-91 * 86_400)))
        try sync.store.history.finish(old.id, now: OneWayDiskWorld.day0.addingTimeInterval(-91 * 86_400))
        try await sync.run()
        let ids = sync.store.history.entries().map(\.id)
        #expect(ids.count == 1)
        #expect(!ids.contains(old.id))
    }
}

/// A value a `@Sendable` closure sets and a test reads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
}
