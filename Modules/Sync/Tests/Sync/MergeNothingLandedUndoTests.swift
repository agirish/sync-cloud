import Foundation
import Testing
@testable import Sync

/// A move's merge that moved nothing out still puts its emptied source in the Trash and registers
/// an undo for that. What that undo is called, and what "Undo Last Run" may pair with it.
///
/// Real disk with a `ScratchTrash`: the merge decides by what is in the folders.
@Suite struct MergeNothingLandedUndoTests {

    @MainActor
    private func manager() -> FileSyncManager {
        FileSyncManager.forTests(collision: .merge, bulk: (.skip, false), historyPrefix: "MergeNothingLanded")
    }

    /// A paired "Move 1 Item" run, then a merge that moved nothing out: also "Move 1 Item", with no
    /// history of its own. The earlier run's pairing must not survive it, or the name gate would
    /// pass and Undo Last Run would list the earlier move while `undo()` reversed the merge.
    @MainActor
    @Test func aMergeThatMovedNothingOutEndsTheEarlierRunsPairing() async throws {
        let root = try makeCanonicalTempRoot(prefix: "merge-nothing-pairing")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let m = manager()
        defer { removeHistoryStoreFiles(m.syncHistoryStore) }

        let file = root.appendingPathComponent("a/x.txt")
        try writeText("x", file)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        _ = await m.moveItems(nodes: [FileNode(id: file.path, name: "x.txt", isDirectory: false)],
                              toPath: root.appendingPathComponent("b").path, fileManager: trash)
        try #require(m.lastSyncRunUndoPreview?.actionName == "Move 1 Item", "premise: the first move is paired")

        let src = root.appendingPathComponent("src/Reports")
        let dst = root.appendingPathComponent("dst/Reports")
        try writeText("finder", src.appendingPathComponent(".DS_Store"))
        try writeText("its own", dst.appendingPathComponent(".DS_Store"))
        _ = await m.moveItems(nodes: [FileNode(id: src.path, name: "Reports", isDirectory: true)],
                              toPath: dst.deletingLastPathComponent().path, fileManager: trash)
        try #require(!entryExists(src), "premise: the merge trashed its emptied source")
        try #require(m.undoManager?.undoActionName == "Move 1 Item", "premise: the two groups share a name")

        #expect(m.lastSyncRunUndoPreview == nil,
                "Undo Last Run still describes the first move, over the merge's group")
    }

    /// A merge that moved nothing out of `Reports`, nor out of the `sub` folder merged inside it,
    /// trashed two folders for one item the user moved: its undo is "Move 1 Item".
    @MainActor
    @Test func aNestedMergeThatMovedNothingOutIsNamedForTheOneItemMoved() async throws {
        let root = try makeCanonicalTempRoot(prefix: "merge-nothing-name")
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = ScratchTrash(in: root)
        let m = manager()
        defer { removeHistoryStoreFiles(m.syncHistoryStore) }

        let src = root.appendingPathComponent("src/Reports")
        let dst = root.appendingPathComponent("dst/Reports")
        try writeText("finder", src.appendingPathComponent(".DS_Store"))
        try writeText("finder", src.appendingPathComponent("sub/.DS_Store"))
        try writeText("its own", dst.appendingPathComponent(".DS_Store"))
        try writeText("its own", dst.appendingPathComponent("sub/.DS_Store"))
        _ = await m.moveItems(nodes: [FileNode(id: src.path, name: "Reports", isDirectory: true)],
                              toPath: dst.deletingLastPathComponent().path, fileManager: trash)
        try #require(trash.names.contains("Reports") && trash.names.contains("sub"),
                     "premise: both emptied folders went to the Trash: \(trash.names)")

        #expect(m.undoManager?.undoActionName == "Move 1 Item")
    }
}
