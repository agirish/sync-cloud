import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// **An item the Trash took without reporting where is moved to the Trash, not deleted** (RD2).
///
/// `deleteItems` used to tell the two apart by the Trash location alone, so an item the platform
/// trashed with a nil `resultingItemURL` — or `trashAfterReregistering`'s `.trashed(nil)` — was
/// recorded, logged and announced as permanently deleted: Sync History labelled it "Delete", which
/// Help says has no way back, the banner said "Deleted", and the log said "unrecoverable". It is
/// in the Trash; only ⌘Z, which needs the location, cannot bring it back.
@MainActor
@Suite struct DeleteTrashedWithoutLocationTests {

    /// Deletes one file, named for this case alone: `LogCapture` sees every case's lines, so an
    /// assertion has to name a sentence only this case can log.
    private func run(reportsLocation: Bool) async throws -> (FileSyncManager, LogCapture, String, DeleteOutcome) {
        let log = LogCapture()
        let manager = FileSyncManager()
        manager.syncHistoryStore = makeTempHistoryStore(prefix: "DeleteTrashedWithoutLocation")
        manager.undoManager = UndoManager()
        manager.permanentDeleteConfirmer = { _ in false }
        let fm = MockFileManager()
        fm.trashReportsNoLocation = !reportsLocation
        let name = "\(reportsLocation ? "located" : "unlocated")-\(UUID().uuidString).txt"
        try fm.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        fm.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [FileAttributeKey.size: 100], contents: nil)
        let outcome = await manager.deleteItems(at: ["/src/\(name)"], fileManager: fm)
        try #require(fm.trashedPaths.count == 1, "the fixture did not reach the Trash")
        return (manager, log, name, outcome)
    }

    private static let noLocation = "Moved 1 item(s) to Trash, but the system reported no Trash location, "
        + "so Undo cannot restore them (recover them from the Trash): "

    @Test func itIsRecordedAnnouncedAndLoggedAsAMoveToTheTrash() async throws {
        let (manager, log, name, outcome) = try await run(reportsLocation: false)
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }

        // Counted as what it is (L3): not deleted, which a merge's log then claimed, and not
        // undoable, which is what the callers' ⌘Z offer reads.
        #expect(outcome == DeleteOutcome(trashedWithoutLocation: 1), "\(outcome)")
        #expect(outcome.removed == 1)
        #expect(!outcome.isUndoable)

        let record = try #require(manager.syncHistoryStore.records.first { $0.sourcePath == "/src/\(name)" })
        #expect(record.backupPath == nil, "the premise: no location came back")
        #expect(record.reachedTrash == true)
        #expect(record.actionLabel == "Move to Trash")
        #expect(manager.banner?.message == "Moved “\(name)” to the Trash", "\(String(describing: manager.banner))")
        let messages = await log.entries.map(\.message)
        #expect(messages.contains { $0.hasPrefix(Self.noLocation + name) }, "\(messages)")
        #expect(!messages.contains { $0.hasPrefix("Permanently deleted") && $0.contains(name) }, "\(messages)")
    }

    /// The control: with a location reported, the same delete records it, and logs no
    /// no-location line for it.
    @Test func withALocationItIsTheOrdinaryMove() async throws {
        let (manager, log, name, outcome) = try await run(reportsLocation: true)
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        #expect(outcome == DeleteOutcome(trashed: 1), "\(outcome)")
        #expect(outcome.isUndoable)

        let record = try #require(manager.syncHistoryStore.records.first { $0.sourcePath == "/src/\(name)" })
        #expect(record.backupPath != nil)
        #expect(record.reachedTrash == true)
        #expect(manager.banner?.message == "Moved “\(name)” to the Trash")
        let messages = await log.entries.map(\.message)
        #expect(!messages.contains { $0.hasPrefix(Self.noLocation + name) }, "\(messages)")
    }
}
