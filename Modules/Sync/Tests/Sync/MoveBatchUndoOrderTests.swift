import Foundation
import Testing
@testable import Sync

/// **A move batch is undone last item first** (M2). A later item can write into an earlier one —
/// merge `B/f` into the `D/f` that `A/f` just became — so undoing front to back sent `D/f` home to
/// `A/f` with B's children inside, put back an empty `B/f`, and then refused those children as
/// "changed since" because they were no longer at `D/f`.
///
/// Real disk with a `ScratchTrash`: the claim is about where the items end up.
@Suite struct MoveBatchUndoOrderTests {

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func entryExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    @MainActor
    @Test func aBatchThatMergedIntoAFolderItAlsoMovedUndoesEachItemToItsOwnPlace() async throws {
        let root = try makeCanonicalTempRoot(prefix: "move-batch-undo-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let a = root.appendingPathComponent("A/f"), b = root.appendingPathComponent("B/f")
        try write("a", a.appendingPathComponent("a.txt"))
        try write("y", b.appendingPathComponent("y.txt"))
        let landing = root.appendingPathComponent("D")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        let m = FileSyncManager()
        m.undoManager = UndoManager()
        m.collisionResolver = { _ in .merge }
        m.bulkCollisionResolver = { _ in (.skip, false) }
        m.permanentDeleteConfirmer = { _ in false }
        m.syncHistoryStore = makeTempHistoryStore(prefix: "MoveBatchUndoOrder")
        defer { removeHistoryStoreFiles(m.syncHistoryStore) }
        let nodes = [a, b].map { FileNode(id: $0.path, name: "f", isDirectory: true) }

        _ = await m.moveItems(nodes: nodes, toPath: landing.path, fileManager: trash)
        try #require(read(landing.appendingPathComponent("f/a.txt")) == "a")
        try #require(read(landing.appendingPathComponent("f/y.txt")) == "y", "premise: the second item merged into the first")

        m.undoManager?.undo()
        await waitUntil("the undo drains") { m.activeFileOperationsCount == 0 }

        #expect(read(a.appendingPathComponent("a.txt")) == "a")
        #expect(!entryExists(a.appendingPathComponent("y.txt")), "B's child went home inside A's folder")
        #expect(read(b.appendingPathComponent("y.txt")) == "y", "B's child is not back in B/f")
        #expect(!entryExists(landing.appendingPathComponent("f")))
        #expect(m.banner == nil, "banner: \(String(describing: m.banner?.message))")

        // And ⌘⇧Z replays the batch as it was applied.
        m.undoManager?.redo()
        await waitUntil("the redo drains") { m.activeFileOperationsCount == 0 }
        #expect(read(landing.appendingPathComponent("f/a.txt")) == "a")
        #expect(read(landing.appendingPathComponent("f/y.txt")) == "y")
        #expect(!entryExists(a) && !entryExists(b))
        #expect(m.banner == nil, "banner: \(String(describing: m.banner?.message))")
    }

    /// The order on its own, pinned: items last first, and inside one item each emptied folder
    /// ahead of its merge's children.
    @Test func undoItemsTakesTheLaterItemFirstAndKeepsEachFolderAheadOfItsChildren() {
        func u(_ p: String) -> URL { URL(fileURLWithPath: p) }
        let first: FileSyncManager.MoveItemState = (from: u("/A/f"), to: u("/D/f"), overwritten: nil)
        let child: FileSyncManager.MoveItemState = (from: u("/B/f/y"), to: u("/D/f/y"), overwritten: nil)
        let folder: FileSyncManager.MoveItemState = (from: u("/B/f"), to: u("/T/f"), overwritten: nil)
        let items = FileSyncManager.undoItems([first, child], nodeStarts: [0, 1],
                                              restoringFirst: [(node: 1, before: 1, item: folder)])
        #expect(items.map(\.from.path) == ["/B/f", "/B/f/y", "/A/f"])
    }
}
