import Foundation
import Testing
@testable import Sync

/// **A redo re-applies the copy batch as it ended** (final review U5).
///
/// Copying `A/f.txt` and `B/f.txt` into `D` with Replace lands two copies on one name, and B's
/// is what `D/f.txt` holds when the batch ends. The undo handles that destination once and skips
/// the duplicate registration — and the redo param it kept named the source of the one it
/// handled, so ⌘⇧Z re-copied A's file where B's had been.
@Suite struct CopyRedoSameNameTests {

    @MainActor
    @Test func redoingACopyThatLandedTwiceOnOneNameEndsWithTheLaterSource() async throws {
        let base = try makeCanonicalTempRoot(prefix: "u5")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = base.appendingPathComponent("A/f.txt"), b = base.appendingPathComponent("B/f.txt")
        for (url, text) in [(a, "from A"), (b, "from B")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let landing = base.appendingPathComponent("D")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        let target = landing.appendingPathComponent("f.txt")
        func text() -> String? { (try? Data(contentsOf: target)).map { String(decoding: $0, as: UTF8.self) } }
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.permanentDeleteConfirmer = { _ in false }
        let disk = ScratchTrash(in: base)
        let nodes = [a, b].map { FileNode(id: $0.path, name: "f.txt", isDirectory: false) }

        await manager.copyItems(nodes: nodes, toPath: landing.path, fileManager: disk)
        try #require(text() == "from B", "premise: the second copy replaced the first")

        manager.undoManager?.undo()
        await waitUntil("the undo clears the destination") { text() == nil }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        manager.undoManager?.redo()
        await waitUntil("the redo re-copies") { text() != nil }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(text() == "from B", "the redo re-copied the source the batch did not end with")
    }
}
