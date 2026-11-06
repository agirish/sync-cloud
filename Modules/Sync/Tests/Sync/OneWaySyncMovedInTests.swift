import Darwin
import Foundation
import Testing
@testable import Sync

/// A file moved into a synced folder from one that isn't is copied, its History step says where it
/// came from, and *Reverse in iCloud* moves it back there when the folder is still there, the name
/// is free and nothing changed since; otherwise it is listed as unavailable, with why.
@Suite struct OneWaySyncMovedInTests {
    typealias Sync = OneWaySyncRunTests.Sync
    let run = OneWaySyncRunTests()

    /// Finance synced, Work not; Invoice.pdf moved from Work into Finance after a first pass.
    func movedIn() async throws -> (OneWayDiskWorld, Sync, OneWaySyncHistoryEntry) {
        let world = try OneWayDiskWorld()
        try run.write(world, .iCloud, "Work/2026/Invoice.pdf", "invoice", modified: OneWaySyncRunTests.earlier)
        try run.write(world, .iCloud, "Finance/W-2.pdf", "w2", modified: OneWaySyncRunTests.earlier)
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        #expect(sync.store.loadOutside().files.map(\.path) == ["Work/2026/Invoice.pdf"])

        try run.move(world, .iCloud, "Work/2026/Invoice.pdf", "Finance/Invoice.pdf")
        sync.now = sync.now.addingTimeInterval(60)
        let look = sync.look()
        #expect(look.plan.steps.map(\.movedInFrom) == ["Work/2026/Invoice.pdf"])
        try await sync.run()
        #expect(world.read(.dropbox, "Finance/Invoice.pdf") == "invoice")
        let entry = try #require(sync.store.history.entries().first)
        return (world, sync, entry)
    }

    func reversals(_ sync: Sync, _ entry: OneWaySyncHistoryEntry, _ world: OneWayDiskWorld) throws -> [OneWaySyncReversal] {
        OneWaySyncAnswers.reversals(of: entry, look: sync.look(), removed: try world.writer().removed.items())
    }

    @Test func aFileMovedInGoesBackAndItsDropboxCopyThenMovesOut() async throws {
        let (world, sync, entry) = try await movedIn()
        defer { world.remove() }
        let step = try #require(entry.steps.first)
        #expect(step.step.movedInFrom == "Work/2026/Invoice.pdf")
        #expect(step.status == .confirmed)
        #expect(step.recorded?.iCloudPath == "Finance/Invoice.pdf")

        let offered = try reversals(sync, entry, world)
        #expect(offered == [OneWaySyncReversal(step: 0, kind: .moveBackOut(from: "Finance/Invoice.pdf", to: "Work/2026/Invoice.pdf"))])
        #expect(offered.first?.summary == "move back to Work/2026/")
        #expect(OneWaySyncAnswers.reverse(offered, writer: try world.writer()).isEmpty)
        #expect(world.read(.iCloud, "Work/2026/Invoice.pdf") == "invoice")
        #expect(world.read(.iCloud, "Finance/Invoice.pdf") == nil)

        // The next sync: a move out, Dropbox's copy to SyncCloud Removed.
        #expect(sync.look().plan.actions == [.moveToRemoved(dropboxPath: "Finance/Invoice.pdf",
                                                            cause: .movedOutInICloud(to: "Work/2026/Invoice.pdf"))])
        try await sync.run()
        #expect(world.read(.dropbox, "Finance/Invoice.pdf") == nil)
        #expect(sync.record.removed.map(\.file.iCloudPath) == ["Finance/Invoice.pdf"])
    }

    @Test func itIsUnavailableWhenTheFolderIsGone() async throws {
        let (world, sync, entry) = try await movedIn()
        defer { world.remove() }
        try FileManager.default.removeItem(at: world.iCloud.appendingPathComponent("Work/2026"))
        let offered = try reversals(sync, entry, world)
        #expect(offered.map(\.unavailable) == ["Work/2026 isn’t in iCloud any more"])
        // Asked anyway, it does nothing: the folder isn't made again.
        let failed = OneWaySyncAnswers.reverse(offered, writer: try world.writer())
        #expect(failed.count == 1)
        #expect(world.read(.iCloud, "Finance/Invoice.pdf") == "invoice")
        #expect(OneWaySyncDisk.kind(at: world.iCloud.appendingPathComponent("Work/2026").path) == nil)
    }

    @Test func itIsUnavailableWhenTheNameIsTaken() async throws {
        let (world, sync, entry) = try await movedIn()
        defer { world.remove() }
        try run.write(world, .iCloud, "Work/2026/invoice.PDF", "another")
        #expect(try reversals(sync, entry, world).map(\.unavailable) == ["Invoice.pdf is taken in Work/2026"])
    }

    @Test func itIsUnavailableWhenItChangedSince() async throws {
        let (world, sync, entry) = try await movedIn()
        defer { world.remove() }
        try run.write(world, .iCloud, "Finance/Invoice.pdf", "invoice, paid", modified: OneWayDiskWorld.day0)
        #expect(try reversals(sync, entry, world).map(\.unavailable) == ["it changed in iCloud since"])
    }

    /// Asked to go back after the folder went (the sheet's look was older): the folder isn't made again.
    @Test func goingBackNeverMakesTheFolderAgain() async throws {
        let (world, sync, entry) = try await movedIn()
        defer { world.remove() }
        let offered = try reversals(sync, entry, world)
        #expect(offered.map(\.unavailable) == [nil])
        try FileManager.default.removeItem(at: world.iCloud.appendingPathComponent("Work/2026"))
        #expect(OneWaySyncAnswers.reverse(offered, writer: try world.writer()).count == 1)
        #expect(world.read(.iCloud, "Finance/Invoice.pdf") == "invoice")
        #expect(OneWaySyncDisk.kind(at: world.iCloud.appendingPathComponent("Work/2026").path) == nil)
    }

    /// Renamed after it came in: it goes back under its old name, and says so.
    @Test func aRenamedFileGoesBackUnderItsOldName() {
        let reversal = OneWaySyncReversal(step: 0, kind: .moveBackOut(from: "Finance/Invoice 2026.pdf", to: "Work/Invoice.pdf"))
        #expect(reversal.summary == "move back to Work/ as Invoice.pdf")
    }

    /// A pass that stopped before the copy landed keeps where the file came from, for the next.
    @Test func aCopyThatDidntLandKeepsWhereItCameFrom() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        try run.write(world, .iCloud, "Work/Invoice.pdf", "invoice")
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try run.move(world, .iCloud, "Work/Invoice.pdf", "Finance/Invoice.pdf")
        let look = sync.look()
        #expect(look.plan.steps.map(\.movedInFrom) == ["Work/Invoice.pdf"])
        _ = try await OneWaySyncRun.apply(
            look, state: sync.state, firstRun: sync.firstRun, store: sync.store, writer: try world.writer(at: sync.now),
            marker: nil, hardwareID: "HW-1", macName: "Test Mac", isCancelled: { true },
            confirmUploads: { _ in [:] }, now: { OneWayDiskWorld.day0 })
        #expect(world.read(.dropbox, "Finance/Invoice.pdf") == nil)
        #expect(sync.look().plan.steps.map(\.movedInFrom) == ["Work/Invoice.pdf"])
    }

    /// A folder synced since (ticked, or Create in Dropbox & Sync): its own files are copied, not moved in.
    @Test func aFolderSyncedSinceCopiesItsFilesAsNew() {
        var world = OneWayWorld(folders: ["Finance", "Taxes"])
        world.add(.iCloud, OneWayWorld.file("Taxes/a.pdf", id: 7, hash: nil))
        world.add(.iCloud, OneWayWorld.file("Finance/b.pdf", id: 8, hash: nil))
        var pass = world.pass()
        pass.outside = [7: "Taxes/a.pdf", 8: "Work/b.pdf"]
        let steps = OneWaySyncPlanner.plan(pass).steps
        #expect(Dictionary(uniqueKeysWithValues: steps.map { (OneWaySyncRun.dropboxPaths(of: $0.action)[0], $0.movedInFrom) })
                == ["Taxes/a.pdf": nil, "Finance/b.pdf": "Work/b.pdf"])
    }

    /// A file new in a synced folder that was never seen outside it is a plain copy.
    @Test func aNewFileIsNotMovedIn() async throws {
        let world = try OneWayDiskWorld()
        defer { world.remove() }
        let sync = try Sync(world: world, folders: ["Finance"])
        try await sync.run()
        try run.write(world, .iCloud, "Finance/New.pdf", "new")
        #expect(sync.look().plan.steps.map(\.movedInFrom) == [nil])
    }
}
