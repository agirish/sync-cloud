import Testing
import Foundation
import Events
@testable import Sync

/// The case-variant half of the duplicate-destination walk restart, on a volume that folds case.
/// `transferItems` restarts an earlier item's identity walk when a later copy in the batch lands
/// on the destination that item produced. Two spellings ("F.txt", "f.txt") can name one file, so
/// the restart's hit test is
///
///     exact-precomposed-match  ||  !volumeSupportsCaseSensitiveNames(for: targetURL)
///
/// and the second clause is the case-variant half.
///
/// Only a disk that really folds can pin it: the mock's `virtualDisk` is an exactly-cased
/// dictionary, so the two spellings stay two files there. Mutation: the clause as `|| false`.
/// The exact-path half is pinned on the mock by
/// `CopyUndoDriftAndTransientTests.copyUndoDuplicateRegistrationOnTrashlessVolumeRemovesOnce`.
@MainActor
@Suite struct CopyWalkCaseVariantRestartTests {

    /// Two sources whose names differ only by case, copied into one destination in one batch, then
    /// ⌘Z. On a folding volume the second copy replaces the first, so the first item's walk
    /// describes a file the batch itself superseded. Restarted, both registrations record the final
    /// state, the folded duplicate gate sees one file, removes it once, and the folder is empty.
    /// Left stale, ⌘Z leaves item 0's copy in a folder that was empty, under a banner blaming the
    /// user for a change they didn't make.
    ///
    /// The source folders differ in length on purpose: `pruneNestedNodes` sorts by `id.utf8.count`
    /// and Swift's sort isn't stable, so equal lengths would leave the batch order to chance.
    @Test func aLaterCaseVariantCopyRestartsTheEarlierItemsIdentityWalk() async throws {
        let root = try makeCanonicalTempRoot(prefix: "CaseWalkRestart")
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        // The clause asks about the destination's volume. On a case-sensitive one the two names
        // are two files and there is nothing to restart, so say so rather than pass vacuously.
        let dst = root.appendingPathComponent("dst")
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        try #require(FileSyncManager.volumeSupportsCaseSensitiveNames(for: dst) == false,
                     "this machine's temp volume distinguishes names by case, so the two spellings below are two real files and this test cannot exercise the case-variant restart")

        // Names differing only by case.
        let stem = "CaseWalk-\(UUID().uuidString)"
        let upperName = stem + ".txt"
        let lowerName = stem.lowercased() + ".txt"
        try #require(upperName != lowerName && upperName.lowercased() == lowerName,
                     "the fixture's two names do not differ only by case")
        // Shorter source path first, so the upper-case item is item 0 of the batch.
        let srcA = root.appendingPathComponent("a")
        let srcB = root.appendingPathComponent("bb")
        try fm.createDirectory(at: srcA, withIntermediateDirectories: true)
        try fm.createDirectory(at: srcB, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 10).write(to: srcA.appendingPathComponent(upperName))
        try Data(repeating: 0x42, count: 20).write(to: srcB.appendingPathComponent(lowerName))

        let trash = ScratchTrash(in: root)
        let manager = FileSyncManager(fileManager: trash)
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.permanentDeleteConfirmer = { _ in false }

        let transferred = await manager.copyItems(
            nodes: [FileNode(id: srcA.appendingPathComponent(upperName).path, name: upperName, isDirectory: false),
                    FileNode(id: srcB.appendingPathComponent(lowerName).path, name: lowerName, isDirectory: false)],
            toPath: dst.path, fileManager: trash)

        // Premises: both items copied, in order, and the volume left one file with the second's
        // bytes.
        try #require(transferred.map(\.name) == [upperName, lowerName],
                     "the batch did not run in the order this test's “earlier item” depends on: \(transferred.map(\.name))")
        let landed = try fm.contentsOfDirectory(atPath: dst.path)
        try #require(landed.count == 1,
                     "the destination holds \(landed.count) files — the volume did not fold the two spellings into one: \(landed)")
        try #require((try fm.attributesOfItem(atPath: dst.appendingPathComponent(lowerName).path)[.size] as? Int) == 20,
                     "the second copy did not replace the first")
        manager.banner = nil

        manager.undoManager?.undo()
        await waitUntil("the undo's operations drain") { manager.activeFileOperationsCount == 0 }

        let after = (try? fm.contentsOfDirectory(atPath: dst.path)) ?? []
        #expect(after.isEmpty,
                "⌘Z left \(after) in a folder that was empty before the batch — the earlier item's walk still described the copy this batch superseded, so its registration was refused as drift and the later item restored it as a backup")
        #expect(manager.banner?.severity != .warning,
                "the undo blamed the user for a change the batch itself made: “\(manager.banner?.message ?? "nil")”")
        #expect(trash.names.contains { $0.lowercased() == lowerName },
                "the copy the undo removed never reached the test's own Trash: \(trash.names)")
    }
}
