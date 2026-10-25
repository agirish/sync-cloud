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
        let bin = base.appendingPathComponent(".Trash")
        let manager = makeManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let disk = LocalTrashFileManager(bin: bin)
        let nodes = [a, b].map { FileNode(id: $0.path, name: "f", isDirectory: true) }

        await manager.moveItems(nodes: nodes, toPath: landing.path, fileManager: disk)
        try #require(text(landing.appendingPathComponent("f/x.txt")) == "from B", "premise: the second move replaced the first")
        let inTrash = try #require(try FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil).first,
                                   "premise: the replaced item is not in the Trash")
        try openInFinder(inTrash)
        await Task.yield()

        manager.undoManager?.undo()
        await waitUntil("the undo drains") { manager.activeFileOperationsCount == 0 }
        #expect(text(a.appendingPathComponent("x.txt")) == "from A", "banner: \(String(describing: manager.banner?.message))")
        #expect(text(b.appendingPathComponent("x.txt")) == "from B")
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
        let disk = LocalTrashFileManager(bin: base.appendingPathComponent(".Trash"))
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

/// The real disk, with a Trash of the test's own: `trashItem` moves the item into `bin` under a
/// unique name and hands that location back, as the real one does — so an undo can restore from it,
/// and nothing reaches the user's Trash.
final class LocalTrashFileManager: FileManager, @unchecked Sendable {
    let bin: URL
    init(bin: URL) { self.bin = bin; super.init() }

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try createDirectory(at: bin, withIntermediateDirectories: true)
        let target = bin.appendingPathComponent("\(UUID().uuidString.prefix(8)) \(url.lastPathComponent)")
        try moveItem(at: url, to: target)
        outResultingURL?.pointee = target as NSURL
    }
}
