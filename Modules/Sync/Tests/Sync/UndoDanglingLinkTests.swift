import Events
import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// **A dangling link is something at its path** (final review U6, FR28's rule at three more sites).
///
/// `fileExists` follows a link, so a link whose target is gone reads as nothing there. The delete's
/// redo skipped a dangling link its undo had just restored ("trashed 0 of 1"), and the delete- and
/// move-undo's "is the original's place taken?" read one as free, then failed under a banner
/// blaming the Trash. Real links in real folders; a Trash of the test's own.
@Suite struct UndoDanglingLinkTests {

    @MainActor
    private func makeManager() -> FileSyncManager {
        let m = FileSyncManager()
        m.undoManager = UndoManager()
        m.collisionResolver = { _ in .replace }
        m.permanentDeleteConfirmer = { _ in false }
        return m
    }

    private func entryExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func danglingLink(at url: URL, in base: URL) throws {
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: base.appendingPathComponent("gone"))
    }

    @MainActor
    @Test func aDeleteRedoTrashesTheDanglingLinkItsUndoRestored() async throws {
        let base = try makeCanonicalTempRoot(prefix: "u6-redo")
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("Shared")
        try danglingLink(at: link, in: base)
        // Two items, so this redo's log line ("Delete 2 Items") is not the one a sibling suite's
        // LogCapture counts as a one-item delete redo.
        let plain = base.appendingPathComponent("plain.txt")
        try Data("p".utf8).write(to: plain)
        let trash = ScratchTrash(in: base)
        let m = makeManager()

        await m.deleteItems(at: [link.path, plain.path], fileManager: trash)
        try #require(!entryExists(link))
        m.undoManager?.undo()
        await waitUntil("the undo restores the link") { self.entryExists(link) }
        await waitUntil("undo op drains") { m.activeFileOperationsCount == 0 }

        m.undoManager?.redo()
        await waitUntil("the redo trashes the link again") { !self.entryExists(link) }
        await waitUntil("redo op drains") { m.activeFileOperationsCount == 0 }
    }

    @MainActor
    @Test func aDeleteUndoLeavesADanglingLinkThatTookTheOriginalsPlace() async throws {
        let base = try makeCanonicalTempRoot(prefix: "u6-delete")
        defer { try? FileManager.default.removeItem(at: base) }
        let original = base.appendingPathComponent("f.txt")
        try Data("mine".utf8).write(to: original)
        let trash = ScratchTrash(in: base)
        let m = makeManager()
        let log = LogCapture()

        await m.deleteItems(at: [original.path], fileManager: trash)
        try danglingLink(at: original, in: base)
        m.undoManager?.undo()
        await waitUntil("undo op drains") { m.activeFileOperationsCount == 0 }

        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: original.path)) != nil,
                "the link that took the place was replaced")
        #expect(trash.names == ["f.txt"], "the original left the Trash: \(trash.names)")
        #expect(await occupied(original, in: log))
    }

    @MainActor
    @Test func aMoveUndoLeavesADanglingLinkThatTookTheSourcesPlace() async throws {
        let base = try makeCanonicalTempRoot(prefix: "u6-move")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("A/f.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: source)
        let landing = base.appendingPathComponent("D")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        let trash = ScratchTrash(in: base)
        let m = makeManager()
        let log = LogCapture()

        await m.moveItems(nodes: [FileNode(id: source.path, name: "f.txt", isDirectory: false)],
                          toPath: landing.path, fileManager: trash)
        try #require(entryExists(landing.appendingPathComponent("f.txt")))
        try danglingLink(at: source, in: base)
        m.undoManager?.undo()
        await waitUntil("undo op drains") { m.activeFileOperationsCount == 0 }

        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: source.path)) != nil,
                "the link that took the place was replaced")
        #expect(entryExists(landing.appendingPathComponent("f.txt")), "the moved file left its destination")
        #expect(await occupied(source, in: log))
    }

    /// The refusal for THIS path — a sibling case's refusal names its own.
    @MainActor
    private func occupied(_ url: URL, in log: LogCapture) async -> Bool {
        await log.entries.contains { $0.message.contains("at \(url.path) from backup") && $0.message.contains("already occupied by another item") }
    }
}
