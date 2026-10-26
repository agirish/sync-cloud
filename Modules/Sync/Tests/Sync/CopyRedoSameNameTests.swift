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

    /// **L3.** The same batch with two spellings of one name, `F.txt` then `f.txt`, on a volume
    /// that folds case: the redo re-copies B's file under the spelling the batch ended with, not
    /// the first registration's.
    @MainActor
    @Test func redoingACopyThatLandedTwiceUnderTwoSpellingsUsesTheLaterSpelling() async throws {
        let base = try makeCanonicalTempRoot(prefix: "l3")
        defer { try? FileManager.default.removeItem(at: base) }
        try #require(!FileSyncManager.volumeSupportsCaseSensitiveNames(for: base), "needs a volume that folds case")
        let a = base.appendingPathComponent("A/F.txt"), b = base.appendingPathComponent("B/f.txt")
        for (url, text) in [(a, "from A"), (b, "from B")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let landing = base.appendingPathComponent("D")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        func names() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: landing.path)) ?? [] }
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.permanentDeleteConfirmer = { _ in false }
        let disk = ScratchTrash(in: base)
        let nodes = [(a, "F.txt"), (b, "f.txt")].map { FileNode(id: $0.0.path, name: $0.1, isDirectory: false) }

        await manager.copyItems(nodes: nodes, toPath: landing.path, fileManager: disk)
        manager.undoManager?.undo()
        await waitUntil("the undo clears the destination") { names().isEmpty }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }

        manager.undoManager?.redo()
        await waitUntil("the redo re-copies") { !names().isEmpty }
        await waitUntil("redo op drains") { manager.activeFileOperationsCount == 0 }
        #expect(names() == ["f.txt"], "the redo used the first registration's spelling")
        #expect((try? String(contentsOf: landing.appendingPathComponent("f.txt"), encoding: .utf8)) == "from B")
    }
}
