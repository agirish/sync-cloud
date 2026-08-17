import Testing
import Foundation
import Events
@testable import Sync

/// The three drift gaps the size-based snapshot could not close.
///
/// `fileSizeSnapshot` answered `Int?`, and the guards read `if let expected = …`, so the two
/// states it could not express both took the destroy path:
///
/// 1. **A copied FOLDER had no drift guard at all.** Directories return nil by design — a folder's
///    stat size is not its content size — and nil skipped the check rather than falling back to
///    another one.
/// 2. **A file was compared by size alone**, so a same-length rewrite (2025→2026) read as
///    untouched and was trashed.
/// 3. **The move-undo never checked the destination**, only that the source path was free. The
///    doc comment claiming a "still the same item?" guard described the occupancy check, which
///    answers a different question.
///
/// Each test below drives the real undo through `FileSyncManager` rather than asserting on
/// `ItemIdentity` in isolation: the seam already has its own tests, and a rule that is only proven
/// where it is defined is one revert away from being unused.
@Suite struct UndoDriftIdentityTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, false) }
        manager.permanentDeleteConfirmer = { _ in false }
        return manager
    }

    private func file(_ size: Int, modified: Date = Date(timeIntervalSince1970: 1_000)) -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false,
                                 attributes: [FileAttributeKey.size: size,
                                              FileAttributeKey.modificationDate: modified],
                                 contents: nil)
    }

    // MARK: 1 — a copied folder is now guarded

    /// The sharpest of the three. Copy a folder, let files land in it, press ⌘Z: before this, the
    /// nil size snapshot skipped the guard and the folder was trashed with everything in it.
    @MainActor
    @Test func copyUndoOfAFolderRefusesOnceItsContentsChanged() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/photos"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/photos/a.jpg"] = file(10)

        let node = FileNode(id: "/src/photos", name: "photos", isDirectory: true)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/photos"] != nil)

        // Finder drops two more files into the copy. Finder never touches the undo stack.
        mockFM.virtualDisk["/dst/photos/new1.jpg"] = file(20)
        mockFM.virtualDisk["/dst/photos/new2.jpg"] = file(30)
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("the folder undo refuses") { manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message.contains("changed since") == true)
        #expect(mockFM.virtualDisk["/dst/photos"] != nil, "the copied folder must still be on disk")
        #expect(mockFM.virtualDisk["/dst/photos/new1.jpg"] != nil, "the files added since must survive")
        #expect(mockFM.virtualDisk["/dst/photos/new2.jpg"] != nil)
    }

    /// The other half of the same guard: an untouched copied folder must still undo cleanly, or
    /// the fix would simply have broken folder undo. A guard that refuses everything is not a
    /// guard.
    @MainActor
    @Test func copyUndoOfAnUntouchedFolderStillRemovesIt() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/photos"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/photos/a.jpg"] = file(10)

        let node = FileNode(id: "/src/photos", name: "photos", isDirectory: true)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/photos"] != nil)

        manager.undoManager?.undo()
        await waitUntil("the untouched folder is removed") { mockFM.virtualDisk["/dst/photos"] == nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(mockFM.virtualDisk["/src/photos"] != nil, "the source is untouched by an undo")
    }

    // MARK: 2 — a same-size edit is drift

    /// `2025` → `2026`: identical length, different content. The size-only comparison read this as
    /// the copy it produced and trashed it.
    @MainActor
    @Test func copyUndoRefusesASameSizeEditOfTheCopy() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/bill.txt"] = file(4, modified: Date(timeIntervalSince1970: 1_000))

        let node = FileNode(id: "/src/bill.txt", name: "bill.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/bill.txt"] != nil)

        // Edited in place: same four bytes, later timestamp. Size alone cannot see this.
        mockFM.virtualDisk["/dst/bill.txt"] = file(4, modified: Date(timeIntervalSince1970: 9_999))
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("the same-size edit is refused") { manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message.contains("changed since") == true)
        #expect(mockFM.virtualDisk["/dst/bill.txt"]?.attributes?[FileAttributeKey.modificationDate] as? Date
                == Date(timeIntervalSince1970: 9_999), "the edited copy must be left exactly as it is")
    }

    // MARK: 3 — the move-undo checks the destination

    /// The move-undo's only guard was that the SOURCE path is free. Drop a different file at the
    /// destination and press ⌘Z: that file was moved away to the source path and the older version
    /// restored over it, reported as a clean success.
    @MainActor
    @Test func moveUndoRefusesWhenTheDestinationIsNoLongerWhatItMoved() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/doc.txt"] = file(100, modified: Date(timeIntervalSince1970: 1_000))

        let node = FileNode(id: "/src/doc.txt", name: "doc.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/doc.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/doc.txt"] == nil)

        // A newer v2 replaces the moved file at the destination.
        mockFM.virtualDisk["/dst/doc.txt"] = file(555, modified: Date(timeIntervalSince1970: 9_999))
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("the move undo refuses the replaced destination") { manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message.contains("changed since") == true)
        #expect(mockFM.virtualDisk["/dst/doc.txt"]?.attributes?[FileAttributeKey.size] as? Int == 555,
                "v2 must still be at the destination, not dragged back to the source")
        #expect(mockFM.virtualDisk["/src/doc.txt"] == nil,
                "nothing may be restored to the source while the destination is unverified")
    }

    /// Both directions again: an untouched move must still undo, or the guard is just an outage.
    @MainActor
    @Test func moveUndoOfAnUntouchedItemStillMovesItBack() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/doc.txt"] = file(100)

        let node = FileNode(id: "/src/doc.txt", name: "doc.txt", isDirectory: false)
        await manager.moveItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/doc.txt"] != nil)

        manager.undoManager?.undo()
        await waitUntil("the move is reversed") { mockFM.virtualDisk["/src/doc.txt"] != nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(mockFM.virtualDisk["/dst/doc.txt"] == nil)
    }

    // MARK: The third verdict

    /// An item whose state cannot be read is refused, not destroyed. This is the state the old
    /// `Int?` could not express at all: nil meant "no guard", so an unreadable item took the same
    /// path as a verified one.
    @MainActor
    @Test func copyUndoRefusesWhenTheDestinationCannotBeRead() async throws {
        let manager = makeManager()
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/photos"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/photos/a.jpg"] = file(10)

        let node = FileNode(id: "/src/photos", name: "photos", isDirectory: true)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/photos"] != nil)

        // The copy is still there but can no longer be listed — permissions changed, volume
        // trouble. Nothing can be concluded about whether it is still the copy.
        mockFM.unlistableDirectories = ["/dst/photos"]
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("the unreadable copy is refused") { manager.banner?.severity == .warning }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        #expect(manager.banner?.message.contains("couldn't be checked") == true,
                "an unverifiable item reports as unverifiable, not as changed")
        #expect(mockFM.virtualDisk["/dst/photos"] != nil, "an item that cannot be checked is not destroyed")
    }
}
