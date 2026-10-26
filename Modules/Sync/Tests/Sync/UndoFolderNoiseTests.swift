import Foundation
import Testing
@testable import Sync

/// **Opening a folder in Finder is not an edit** — the undo and redo guards that read a FOLDER
/// read it the deep way, which leaves the `.DS_Store` Finder writes out (final review U2, U3).
///
/// A shallow folder identity is the folder's own date and child count, and Finder moves both just
/// by showing the folder. So each guard below refused an untouched folder once the user had looked
/// at it. Real folders, and a Trash of the test's own, so the `.DS_Store` really moves the
/// folder's date and nothing lands in the user's Trash.
@Suite struct UndoFolderNoiseTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, false) }
        manager.permanentDeleteConfirmer = { _ in false }
        manager.syncHistoryStore = makeTempHistoryStore(prefix: "UndoFolderNoise")
        return manager
    }

    private func folder(_ url: URL, holding name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url.appendingPathComponent(name))
    }

    private func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// What Finder does to a folder it shows: a new `.DS_Store`, so the folder's child count moves
    /// (and its date, at the file system's resolution) — enough to change a shallow identity.
    private func openInFinder(_ folder: URL) throws {
        try Data("finder".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
    }

    /// **U2.** Copy or move a folder over `Shared/Photos` with Replace, ⌘Z — the original is back —
    /// open it in Finder, ⌘⇧Z. The redo replaces it again: it is still the item the undo put back.
    @MainActor
    @Test(arguments: [false, true])
    func aRedoStillReplacesAFolderOriginalTheUserOnlyOpened(isMove: Bool) async throws {
        let base = try makeCanonicalTempRoot(prefix: "u2-\(isMove ? "move" : "copy")")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("src/Photos")
        let destination = base.appendingPathComponent("Shared/Photos")
        try folder(source, holding: "new.txt", "new")
        try folder(destination, holding: "old.txt", "old")
        let manager = makeManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let disk = ScratchTrash(in: base)
        let node = FileNode(id: source.path, name: "Photos", isDirectory: true)
        if isMove {
            await manager.moveItems(nodes: [node], toPath: destination.deletingLastPathComponent().path, fileManager: disk)
        } else {
            await manager.copyItems(nodes: [node], toPath: destination.deletingLastPathComponent().path, fileManager: disk)
        }
        try #require(text(destination.appendingPathComponent("new.txt")) == "new")

        manager.undoManager?.undo()
        await waitUntil("the undo puts the original back") { self.text(destination.appendingPathComponent("old.txt")) == "old" }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        try openInFinder(destination)
        manager.banner = nil

        manager.undoManager?.redo()
        await waitUntil("the redo re-applies") { self.text(destination.appendingPathComponent("new.txt")) == "new" }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(manager.banner == nil, "got \(String(describing: manager.banner?.message))")
    }

    /// **U3.** Move `A/f` and `B/f` into `D` with Replace: B's replaces A's, which FR23's record now
    /// finds in the Trash. Look at it there, then ⌘Z: both go home.
    @MainActor
    @Test func undoingAMoveThatReplacedItsOwnEarlierItemSurvivesALookInTheTrash() async throws {
        let base = try makeCanonicalTempRoot(prefix: "u3")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = base.appendingPathComponent("A/f"), b = base.appendingPathComponent("B/f")
        try folder(a, holding: "x.txt", "from A")
        try folder(b, holding: "x.txt", "from B")
        let landing = base.appendingPathComponent("D")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        let manager = makeManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let disk = ScratchTrash(in: base)
        let nodes = [a, b].map { FileNode(id: $0.path, name: "f", isDirectory: true) }

        await manager.moveItems(nodes: nodes, toPath: landing.path, fileManager: disk)
        try #require(text(landing.appendingPathComponent("f/x.txt")) == "from B", "premise: the second move replaced the first")
        let slot = try #require(try FileManager.default.contentsOfDirectory(at: disk.folder, includingPropertiesForKeys: nil).first,
                                "premise: the replaced item is not in the Trash")
        let inTrash = try #require(try FileManager.default.contentsOfDirectory(at: slot, includingPropertiesForKeys: nil).first)
        try openInFinder(inTrash)
        await Task.yield()

        manager.undoManager?.undo()
        await waitUntil("the undo drains") { manager.activeFileOperationsCount == 0 }
        #expect(text(a.appendingPathComponent("x.txt")) == "from A", "banner: \(String(describing: manager.banner?.message))")
        #expect(text(b.appendingPathComponent("x.txt")) == "from B")
    }

    /// **L1.** The same as U2, with a folder inside the original that cannot be read: the redo
    /// still replaces it. Deep alone, the occupant the undo put back was `.indeterminate`, and the
    /// redo refused it as "couldn’t be checked" for as long as it lived.
    @MainActor
    @Test(arguments: [false, true])
    func aRedoStillReplacesAnOriginalWithAnUnreadableFolderInside(isMove: Bool) async throws {
        let base = try makeCanonicalTempRoot(prefix: "l1-\(isMove ? "move" : "copy")")
        let locked = base.appendingPathComponent("Shared/Photos/private")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: base)
        }
        let source = base.appendingPathComponent("src/Photos")
        let destination = base.appendingPathComponent("Shared/Photos")
        try folder(source, holding: "new.txt", "new")
        try folder(destination, holding: "old.txt", "old")
        try folder(locked, holding: "secret.txt", "s")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let manager = makeManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let disk = ScratchTrash(in: base)
        let node = FileNode(id: source.path, name: "Photos", isDirectory: true)
        if isMove {
            await manager.moveItems(nodes: [node], toPath: destination.deletingLastPathComponent().path, fileManager: disk)
        } else {
            await manager.copyItems(nodes: [node], toPath: destination.deletingLastPathComponent().path, fileManager: disk)
        }
        try #require(text(destination.appendingPathComponent("new.txt")) == "new")

        manager.undoManager?.undo()
        await waitUntil("the undo puts the original back") { self.text(destination.appendingPathComponent("old.txt")) == "old" }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        manager.banner = nil

        manager.undoManager?.redo()
        await waitUntil("the redo re-applies") { self.text(destination.appendingPathComponent("new.txt")) == "new" }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(manager.banner == nil, "got \(String(describing: manager.banner?.message))")
    }

    /// **M3.** The same batch, ⌘Z, ⌘⇧Z — the redo puts A's folder back in the Trash — a look at it
    /// there, and ⌘Z again: both go home. The redo used to record that folder shallow, so the
    /// `.DS_Store` refused the second ⌘Z.
    @MainActor
    @Test func aRedoneRedirectedMoveStillSurvivesALookInTheTrash() async throws {
        let base = try makeCanonicalTempRoot(prefix: "m3")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = base.appendingPathComponent("A/f"), b = base.appendingPathComponent("B/f")
        try folder(a, holding: "x.txt", "from A")
        try folder(b, holding: "x.txt", "from B")
        let landing = base.appendingPathComponent("D")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        let manager = makeManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let disk = ScratchTrash(in: base)
        let nodes = [a, b].map { FileNode(id: $0.path, name: "f", isDirectory: true) }

        await manager.moveItems(nodes: nodes, toPath: landing.path, fileManager: disk)
        let slot = try #require(try FileManager.default.contentsOfDirectory(at: disk.folder, includingPropertiesForKeys: nil).first,
                                "premise: the replaced item is not in the Trash")
        let inTrash = try #require(try FileManager.default.contentsOfDirectory(at: slot, includingPropertiesForKeys: nil).first)
        manager.undoManager?.undo()
        await waitUntil("the undo drains") { manager.activeFileOperationsCount == 0 }
        try #require(text(a.appendingPathComponent("x.txt")) == "from A", "premise: the first undo")
        manager.undoManager?.redo()
        await waitUntil("the redo puts A's folder back in the Trash") { self.text(inTrash.appendingPathComponent("x.txt")) == "from A" }
        await waitUntil("the redo drains") { manager.activeFileOperationsCount == 0 }
        try openInFinder(inTrash)
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("the second undo drains") { manager.activeFileOperationsCount == 0 }
        #expect(text(a.appendingPathComponent("x.txt")) == "from A", "banner: \(String(describing: manager.banner?.message))")
        #expect(text(b.appendingPathComponent("x.txt")) == "from B")
    }

    /// **M4.** Move a folder, open it in Finder where it landed, ⌘Z: it goes back. Then open it
    /// again where it went back to, ⌘⇧Z: it moves again. The shallow identity both guards record
    /// was the folder's date and raw child count, and the `.DS_Store` moved both.
    @MainActor
    @Test func aMovedFolderTheUserOnlyOpenedStillMovesBackAndForth() async throws {
        let base = try makeCanonicalTempRoot(prefix: "m4-move")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("src/Photos")
        try folder(source, holding: "a.txt", "a")
        let landing = base.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        let moved = landing.appendingPathComponent("Photos")
        let manager = makeManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let disk = ScratchTrash(in: base)

        await manager.moveItems(nodes: [FileNode(id: source.path, name: "Photos", isDirectory: true)],
                                toPath: landing.path, fileManager: disk)
        try #require(text(moved.appendingPathComponent("a.txt")) == "a")
        try openInFinder(moved)

        manager.undoManager?.undo()
        await waitUntil("the undo drains") { manager.activeFileOperationsCount == 0 }
        #expect(text(source.appendingPathComponent("a.txt")) == "a", "banner: \(String(describing: manager.banner?.message))")
        try openInFinder(source)
        manager.banner = nil

        manager.undoManager?.redo()
        await waitUntil("the redo drains") { manager.activeFileOperationsCount == 0 }
        #expect(text(moved.appendingPathComponent("a.txt")) == "a", "banner: \(String(describing: manager.banner?.message))")
    }

    /// **M4.** Delete a folder, ⌘Z, open it in Finder, ⌘⇧Z: it goes to the Trash again.
    @MainActor
    @Test func aRestoredFolderTheUserOnlyOpenedIsTrashedAgainByTheRedo() async throws {
        let base = try makeCanonicalTempRoot(prefix: "m4-delete")
        defer { try? FileManager.default.removeItem(at: base) }
        let original = base.appendingPathComponent("Photos")
        try folder(original, holding: "a.txt", "a")
        let manager = makeManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let disk = ScratchTrash(in: base)
        var trashed: NSURL?
        try disk.trashItem(at: original, resultingItemURL: &trashed)
        // Not "Move to Trash": `UndoRedoLogLabelTests` pins that label's Redo line against the
        // shared Logger, and this redo would land in its window.
        await manager.registerRestoreItems(urls: [original], trashedItems: [trashed as URL?],
                                           actionName: "Delete Photos (M4)", fileManager: disk).value

        manager.undoManager?.undo()
        await waitUntil("the undo drains") { manager.activeFileOperationsCount == 0 }
        try #require(text(original.appendingPathComponent("a.txt")) == "a")
        try openInFinder(original)

        manager.undoManager?.redo()
        await waitUntil("the redo drains") { manager.activeFileOperationsCount == 0 }
        #expect(!FileManager.default.fileExists(atPath: original.path), "banner: \(String(describing: manager.banner?.message))")
    }

    /// **M4.** What the shallow folder identity still tells apart: another folder with the same
    /// names at the path, and a child renamed — while a `.DS_Store` is not a change.
    @Test func theShallowFolderIdentityIgnoresFinderButNotAnotherFolder() throws {
        let base = try makeCanonicalTempRoot(prefix: "m4-identity")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let photos = base.appendingPathComponent("Photos")
        try folder(photos, holding: "a.txt", "a")
        let recorded = ItemIdentity.snapshot(at: photos, fileManager: fm)

        try openInFinder(photos)
        #expect(recorded.drift(at: photos, fileManager: fm) == .unchanged)

        try fm.moveItem(at: photos.appendingPathComponent("a.txt"), to: photos.appendingPathComponent("b.txt"))
        #expect(recorded.drift(at: photos, fileManager: fm) == .changed, "a renamed child")
        try fm.moveItem(at: photos.appendingPathComponent("b.txt"), to: photos.appendingPathComponent("a.txt"))
        #expect(recorded.drift(at: photos, fileManager: fm) == .unchanged)

        try fm.moveItem(at: photos, to: base.appendingPathComponent("Old"))
        try folder(photos, holding: "a.txt", "a")
        #expect(recorded.drift(at: photos, fileManager: fm) == .changed, "a different folder with the same names")
    }

    /// **U8.** The same batch's Sync History names where the user moved the earlier item — not the
    /// Trash, where the batch's own Replace put it.
    @MainActor
    @Test func aRedirectedMoveIsRecordedAtItsDestination() async throws {
        let base = try makeCanonicalTempRoot(prefix: "u8")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = base.appendingPathComponent("A/f.txt"), b = base.appendingPathComponent("B/f.txt")
        for (url, text) in [(a, "from A"), (b, "from B")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let landing = base.appendingPathComponent("D")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        let manager = makeManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let disk = ScratchTrash(in: base)
        let nodes = [a, b].map { FileNode(id: $0.path, name: "f.txt", isDirectory: false) }

        await manager.moveItems(nodes: nodes, toPath: landing.path, fileManager: disk)

        let run = try #require(manager.syncHistoryStore.lastRunId)
        let records = manager.syncHistoryStore.recordsForRun(run)
        #expect(records.map(\.sourcePath) == [a.path, b.path])
        #expect(records.map(\.destPath) == [landing.appendingPathComponent("f.txt").path,
                                            landing.appendingPathComponent("f.txt").path],
                "got \(records.map(\.destPath))")
    }
}
