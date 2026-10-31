import Darwin
import Foundation
import Testing
@testable import Sync

/// ES: a file whose copy Dropbox refuses never counts as synced. It stays listed as skipped, is
/// never adopted however alike the two copies look, and is written again only once it changes in
/// iCloud. Dropbox's refusal is stood in for by the upload reading (`Sync.refuse`).
@Suite struct OneWaySyncRefusedTests {
    typealias Sync = OneWaySyncRunTests.Sync
    let run = OneWaySyncRunTests()

    static func refusals(_ look: OneWaySyncLook) -> [OneWaySyncWait] { look.plan.waits.filter { $0.reason == .refusedByDropbox } }

    @Test func aRefusedCopyIsNeverAdoptedAndIsWrittenAgainOnceItChanges() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/bad.pdf", "refused", modified: OneWaySyncRunTests.earlier)
        try run.write(world, .iCloud, "Finance/fine.pdf", "taken", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.refuse = ["bad.pdf"]
        let first = try await sync.run()
        #expect(first.refused == [OneWaySyncSkippedItem(path: "Finance/bad.pdf", reason: OneWaySyncSkippedItem.dropboxWontTakeIt)])
        #expect(sync.record.files.map(\.iCloudPath) == ["Finance/fine.pdf"])
        #expect(sync.record.refused.map(\.iCloudPath) == ["Finance/bad.pdf"])
        #expect(sync.record.refused.first?.why == "Dropbox won’t take it")

        // Dropbox would take it now; the copies are identical; still nothing is adopted, because
        // nothing changed in iCloud.
        sync.refuse = []
        sync.now = sync.now.addingTimeInterval(60)
        let look = sync.look()
        #expect(look.plan.steps.isEmpty)
        #expect(Self.refusals(look).map(\.subject) == [.file(iCloudPath: "Finance/bad.pdf", dropboxPath: "Finance/bad.pdf")])
        #expect(look.plan.dropboxOnly.isEmpty)
        #expect(look.skipped == [OneWaySyncSkippedItem(path: "Finance/bad.pdf", reason: OneWaySyncSkippedItem.dropboxWontTakeIt)])
        // Now's information row names it; nothing under Needs you.
        let rows = OneWaySyncRows.rows(for: look, knownUnsynced: [], at: sync.now)
        #expect(rows.map(\.id) == ["ows:info:skipped"])
        #expect(rows.first?.title == "1 item skipped")
        #expect(rows.first?.detail == "bad.pdf (Dropbox won’t take it) · nothing else waits")
        try await sync.run()
        #expect(sync.record.files.map(\.iCloudPath) == ["Finance/fine.pdf"])
        #expect(sync.record.refused.map(\.iCloudPath) == ["Finance/bad.pdf"])
        // No History entry for a pass that only found the refusal standing.
        #expect(sync.store.history.entries().count == 1)

        // Changed in iCloud: iCloud's file is written over SyncCloud's refused copy, and recorded
        // once Dropbox reports it.
        try run.write(world, .iCloud, "Finance/bad.pdf", "edited, longer", modified: OneWayDiskWorld.day0)
        let retry = sync.look()
        #expect(retry.plan.actions == [.replace(dropboxPath: "Finance/bad.pdf", with: "Finance/bad.pdf", needsDownload: false,
                                                previousIsDropboxEdit: false)])
        #expect(retry.plan.waits.isEmpty)
        let result = try await sync.run()
        #expect(result.notDone.isEmpty)
        #expect(world.read(.dropbox, "Finance/bad.pdf") == "edited, longer")
        #expect(Set(sync.record.files.map(\.iCloudPath)) == ["Finance/fine.pdf", "Finance/bad.pdf"])
        #expect(sync.record.refused.isEmpty)
        #expect(sync.look().plan.steps.isEmpty)
        #expect(sync.look().plan.waits.isEmpty)
    }

    /// Renamed in iCloud (a name Dropbox refused, fixed): the refused copy takes the new name, is
    /// written over there, and its upload is read where it now is.
    @Test func aRefusedFileRenamedInICloudMovesItsCopyAndIsWrittenThere() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/Report.pdf", "report", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.refuse = ["Report.pdf"]
        try await sync.run()
        #expect(sync.record.refused.map(\.dropboxPath) == ["Finance/Report.pdf"])

        sync.refuse = []
        try run.move(world, .iCloud, "Finance/Report.pdf", "Finance/Report 2026.pdf")
        let look = sync.look()
        #expect(look.plan.actions == [
            .replace(dropboxPath: "Finance/Report.pdf", with: "Finance/Report 2026.pdf", needsDownload: false, previousIsDropboxEdit: false),
            .moveInDropbox(from: "Finance/Report.pdf", to: "Finance/Report 2026.pdf"),
        ])
        let result = try await sync.run()
        #expect(result.notDone.isEmpty)
        #expect(result.unconfirmed.isEmpty)
        #expect(world.read(.dropbox, "Finance/Report 2026.pdf") == "report")
        #expect(world.read(.dropbox, "Finance/Report.pdf") == nil)
        #expect(sync.record.files.map(\.dropboxPath) == ["Finance/Report 2026.pdf"])
        #expect(sync.record.refused.isEmpty)
        let after = sync.look()
        #expect(after.plan.steps.isEmpty)
        #expect(after.plan.waits.isEmpty)
        #expect(after.plan.dropboxOnly.isEmpty)
    }

    /// An edit whose replace Dropbox refused: the record keeps the version both sides last agreed
    /// on, and Dropbox's copy, being SyncCloud's own, is never read as an edit made in Dropbox.
    @Test func aRefusedEditWaitsAsSkippedNotAsAnEditInDropbox() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Legal/Will.pdf", "will", modified: OneWaySyncRunTests.earliest)
        let sync = try Sync(world: world, folders: ["Legal"])
        try await sync.run()
        let recorded = try #require(sync.file("Legal/Will.pdf"))

        try run.write(world, .iCloud, "Legal/Will.pdf", "will, signed", modified: OneWaySyncRunTests.earlier)
        sync.refuse = ["Will.pdf"]
        sync.now = sync.now.addingTimeInterval(60)
        let refused = try await sync.run()
        #expect(refused.refused.map(\.path) == ["Legal/Will.pdf"])
        #expect(sync.file("Legal/Will.pdf")?.size == recorded.size)
        #expect(sync.record.refused.map(\.record) == [recorded.key])

        sync.refuse = []
        let look = sync.look()
        #expect(look.plan.steps.isEmpty)
        #expect(look.plan.waits.map(\.reason) == [.refusedByDropbox])
        #expect(look.skipped.map(\.path) == ["Legal/Will.pdf"])

        // Edited again in iCloud: written over the refused copy, under any setting for Dropbox edits.
        try run.write(world, .iCloud, "Legal/Will.pdf", "will, signed twice", modified: OneWayDiskWorld.day0)
        #expect(sync.look().plan.actions == [.replace(dropboxPath: "Legal/Will.pdf", with: "Legal/Will.pdf", needsDownload: false,
                                                      previousIsDropboxEdit: false)])
        try await sync.run()
        #expect(world.read(.dropbox, "Legal/Will.pdf") == "will, signed twice")
        #expect(sync.file("Legal/Will.pdf")?.size == Int64("will, signed twice".utf8.count))
        #expect(sync.record.refused.isEmpty)
        #expect(sync.look().plan.steps.isEmpty)
        #expect(sync.look().plan.waits.isEmpty)
    }

    /// A retry that wrote nothing (the pass stopped) keeps the refusal, so the next pass still
    /// writes over SyncCloud's copy rather than calling iCloud's name taken by a Dropbox-only file.
    @Test func aRetryThatWroteNothingKeepsTheRefusal() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/bad.pdf", "refused", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.refuse = ["bad.pdf"]
        try await sync.run()
        sync.refuse = []
        try run.write(world, .iCloud, "Finance/bad.pdf", "edited, longer", modified: OneWayDiskWorld.day0)
        let stopped = try await OneWaySyncRun.apply(
            sync.look(), state: sync.state, firstRun: sync.firstRun, store: sync.store, writer: try world.writer(at: sync.now),
            marker: nil, hardwareID: "HW-1", macName: "Test Mac", isCancelled: { true },
            confirmUploads: { _ in [:] }, now: { OneWayDiskWorld.day0 })
        #expect(stopped.record.refused.map(\.iCloudPath) == ["Finance/bad.pdf"])
        sync.record = stopped.record
        #expect(sync.look().plan.actions == [.replace(dropboxPath: "Finance/bad.pdf", with: "Finance/bad.pdf", needsDownload: false,
                                                      previousIsDropboxEdit: false)])
        try await sync.run()
        #expect(sync.record.files.map(\.iCloudPath) == ["Finance/bad.pdf"])
        #expect(sync.record.refused.isEmpty)
    }

    /// A retry written but not yet reported uploaded is no longer the copy Dropbox refused: it is
    /// recorded as SyncCloud's own copy, like any other unreported upload, and the refusal goes.
    @Test func anUnreportedRetryIsComparedLikeAnyUnreportedUpload() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/bad.pdf", "refused", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.refuse = ["bad.pdf"]
        try await sync.run()
        sync.refuse = []
        sync.neverReport = ["bad.pdf"]
        try run.write(world, .iCloud, "Finance/bad.pdf", "edited, longer", modified: OneWayDiskWorld.day0)
        let unreported = try await sync.run()
        #expect(unreported.unconfirmed == ["Finance/bad.pdf"])
        #expect(sync.record.refused.isEmpty)
        #expect(sync.record.files.map(\.iCloudPath) == ["Finance/bad.pdf"])
        #expect(sync.look().plan.steps.isEmpty)
    }

    /// A refused copy is matched by its own size and date as written, not iCloud's at the look.
    @Test func aRefusalKeepsTheCopysOwnSizeAndDate() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/bad.pdf", "refused", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.refuse = ["bad.pdf"]
        let look = sync.look()
        // Edited after the look, before the copy: the copy is the newer file.
        try run.write(world, .iCloud, "Finance/bad.pdf", "refused, newer", modified: OneWayDiskWorld.day0)
        let refuse = sync.refuse
        let result = try await OneWaySyncRun.apply(
            look, state: sync.state, firstRun: sync.firstRun, store: sync.store, writer: try world.writer(at: sync.now),
            marker: nil, hardwareID: "HW-1", macName: "Test Mac",
            confirmUploads: { paths in Dictionary(uniqueKeysWithValues: paths.map { ($0, refuse.isEmpty ? .notConfirmed : OneWaySyncUploadOutcome.refused("no")) }) },
            now: { OneWayDiskWorld.day0 })
        let refusal = try #require(result.record.refused.first)
        #expect(refusal.size == Int64("refused".utf8.count))
        #expect(refusal.copySize == Int64("refused, newer".utf8.count))
        #expect(refusal.copyModified == Int64(OneWayDiskWorld.day0.timeIntervalSince1970))
        sync.record = result.record
        sync.refuse = []
        // iCloud's file differs from the refusal: written over SyncCloud's copy, not a name taken.
        #expect(sync.look().plan.actions == [.replace(dropboxPath: "Finance/bad.pdf", with: "Finance/bad.pdf", needsDownload: false,
                                                      previousIsDropboxEdit: false)])
    }

    /// Renamed in iCloud by letter case alone (the fix for a name collision): paired with the
    /// refused copy by Dropbox's caseless names, it is still written, never adopted.
    @Test func aCaseOnlyRenameIsWrittenNotAdopted() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/Report.pdf", "report", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.refuse = ["Report.pdf"]
        try await sync.run()
        sync.refuse = []
        try run.move(world, .iCloud, "Finance/Report.pdf", "Finance/report-tmp.pdf")
        try run.move(world, .iCloud, "Finance/report-tmp.pdf", "Finance/report.pdf")
        let look = sync.look()
        #expect(look.plan.actions == [
            .replace(dropboxPath: "Finance/Report.pdf", with: "Finance/report.pdf", needsDownload: false, previousIsDropboxEdit: false),
            .moveInDropbox(from: "Finance/Report.pdf", to: "Finance/report.pdf"),
        ])
        let result = try await sync.run()
        #expect(result.notDone.isEmpty)
        #expect(sync.record.files.map(\.dropboxPath) == ["Finance/report.pdf"])
        #expect(sync.record.refused.isEmpty)
    }

    /// Gone from iCloud: the refusal goes with it, and SyncCloud's refused copy goes to SyncCloud
    /// Removed rather than staying as a file only in Dropbox.
    @Test func aRefusedFileDeletedInICloudTakesItsCopyWithIt() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/bad.pdf", "refused")
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.refuse = ["bad.pdf"]
        try await sync.run()
        try FileManager.default.removeItem(at: world.iCloud.appendingPathComponent("Finance/bad.pdf"))
        let look = sync.look()
        #expect(look.skipped.isEmpty)
        #expect(look.plan.actions == [.moveToRemoved(dropboxPath: "Finance/bad.pdf", cause: .refusedCopy)])
        try await sync.run()
        #expect(sync.record.refused.isEmpty)
        #expect(world.read(.dropbox, "Finance/bad.pdf") == nil)
        #expect(try world.writer().removed.items().map(\.origin.kind) == [.refusedCopy])
        #expect(sync.look().plan.dropboxOnly.isEmpty)
        #expect(sync.look().plan.steps.isEmpty)
    }

    /// A removal of the refused copy that doesn't go through keeps the refusal: the copy is never
    /// left behind as a file of Dropbox's own.
    @Test func aRefusedCopyNotYetRemovedKeepsItsRefusal() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/bad.pdf", "refused")
        let sync = try Sync(world: world, folders: ["Finance"])
        sync.refuse = ["bad.pdf"]
        try await sync.run()
        try FileManager.default.removeItem(at: world.iCloud.appendingPathComponent("Finance/bad.pdf"))
        let stopped = try await OneWaySyncRun.apply(
            sync.look(), state: sync.state, firstRun: sync.firstRun, store: sync.store, writer: try world.writer(at: sync.now),
            marker: nil, hardwareID: "HW-1", macName: "Test Mac", isCancelled: { true },
            confirmUploads: { _ in [:] }, now: { OneWayDiskWorld.day0 })
        #expect(stopped.record.refused.map(\.iCloudPath) == ["Finance/bad.pdf"])
        sync.record = stopped.record
        #expect(sync.look().plan.actions == [.moveToRemoved(dropboxPath: "Finance/bad.pdf", cause: .refusedCopy)])
        #expect(sync.look().plan.dropboxOnly.isEmpty)
    }

    /// Refused while offloaded: the change time found once it is downloaded is the one kept.
    @Test func aRefusalTakesTheChangeTimeOnceDownloaded() {
        var world = OneWayWorld()
        world.add(.iCloud, OneWayWorld.file("Finance/bad.pdf", id: 5, hash: nil))
        world.update(.iCloud, "Finance/bad.pdf") { $0.changed = 7_000 }
        world.record.refused = [OneWaySyncRefusedFile(
            iCloudPath: "Finance/bad.pdf", iCloudID: 5, size: 2000, modified: Int64(OneWayWorld.t0.timeIntervalSince1970),
            changed: nil, dropboxPath: "Finance/bad.pdf", record: nil, why: "no", refusedAt: 0)]
        let plan = world.plan()
        #expect(plan.waitReasons == [.refusedByDropbox])
        #expect(plan.refused.map(\.changed) == [7_000])
    }
}
