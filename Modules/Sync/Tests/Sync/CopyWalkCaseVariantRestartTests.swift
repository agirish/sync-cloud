import Testing
import Foundation
import Events
@testable import Sync

/// **The case-variant half of the duplicate-destination walk restart, on a volume that actually
/// folds case.**
///
/// `transferItems` restarts an earlier item's identity walk when a later copy in the same batch
/// lands on the destination that item already produced. Two spellings can name one on-disk file —
/// "F.txt" then "f.txt" through the replace prompt — so the restart's hit test is
///
///     exact-precomposed-match  ||  !volumeSupportsCaseSensitiveNames(for: targetURL)
///
/// and the second clause is the whole case-variant half.
///
/// **`MockFileManager` cannot pin it, and the reason is the mock's DISK rather than its volume
/// answers.** `volumeSupportsCaseSensitiveNames` is `(try? resourceValues(…)) ?? false`, so every
/// mock path already reports "folds case" and the clause is unconditionally true there — but the
/// mock's `virtualDisk` is a `[String: FileStub]`, an exactly-cased dictionary, so "/dst/F.txt" and
/// "/dst/f.txt" are two separate files on it. The second copy never replaces the first, so
/// restarting the first walk and not restarting it record the identical identity, and mutating the
/// clause to `|| false` changes nothing any mock test can observe. Injecting the case-sensitivity
/// answer does not fix that: the answer is already the one this needs. Only a disk that really
/// folds does, which is what this suite uses.
///
/// The exact-path half is pinned separately, on the mock, by
/// `CopyUndoDriftAndTransientTests.copyUndoDuplicateRegistrationOnTrashlessVolumeRemovesOnce`.
@MainActor
@Suite struct CopyWalkCaseVariantRestartTests {

    /// Two sources whose NAMES differ only by case, copied into one destination in a single batch,
    /// then ⌘Z. On a folding volume the second copy replaces the first, so the first item's walk
    /// describes a file this batch itself superseded — not user drift. Restarted, both
    /// registrations record the FINAL state, the undo's folded duplicate gate recognizes them as
    /// one file, removes it once, and the destination is back to empty.
    ///
    /// Left stale, item 0's registration reads `.changed` and is refused; item 1 then trashes the
    /// file and RESTORES ITS BACKUP — which is item 0's copy — so ⌘Z leaves the intermediate copy
    /// sitting in a folder that was empty before the batch, under a banner blaming the user for a
    /// change they did not make.
    ///
    /// The source directories are deliberately different lengths: `pruneNestedNodes` sorts by
    /// `id.utf8.count` and Swift's sort is not stable, so equal-length paths would leave the batch
    /// order — which is what "earlier item" means here — to chance.
    @Test func aLaterCaseVariantCopyRestartsTheEarlierItemsIdentityWalk() async throws {
        let root = try makeCanonicalTempRoot(prefix: "CaseWalkRestart")
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        // The destination's own volume is the one the clause asks about, and the whole test is
        // about what it answers. On a case-sensitive volume the two names are two files and there
        // is nothing to restart — say so rather than passing vacuously.
        let dst = root.appendingPathComponent("dst")
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        try #require(FileSyncManager.volumeSupportsCaseSensitiveNames(for: dst) == false,
                     "this machine's temp volume distinguishes names by case, so the two spellings below are two real files and this test cannot exercise the case-variant restart")

        // Names differing ONLY by case, unique so the Trash cleanup below is exact.
        let stem = "CaseWalk-\(UUID().uuidString)"
        let upperName = stem + ".txt"
        let lowerName = stem.lowercased() + ".txt"
        try #require(upperName != lowerName && upperName.lowercased() == lowerName,
                     "the fixture's two names do not differ only by case")
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        defer {
            for n in [upperName, lowerName] { try? fm.removeItem(at: trash.appendingPathComponent(n)) }
        }

        // Shorter source path first, so the upper-case item is item 0 of the batch.
        let srcA = root.appendingPathComponent("a")
        let srcB = root.appendingPathComponent("bb")
        try fm.createDirectory(at: srcA, withIntermediateDirectories: true)
        try fm.createDirectory(at: srcB, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 10).write(to: srcA.appendingPathComponent(upperName))
        try Data(repeating: 0x42, count: 20).write(to: srcB.appendingPathComponent(lowerName))

        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        manager.collisionResolver = { _ in .replace }
        manager.permanentDeleteConfirmer = { _ in false }

        let transferred = await manager.copyItems(
            nodes: [FileNode(id: srcA.appendingPathComponent(upperName).path, name: upperName, isDirectory: false),
                    FileNode(id: srcB.appendingPathComponent(lowerName).path, name: lowerName, isDirectory: false)],
            toPath: dst.path, fileManager: fm)

        // Premises: both items copied, in that order, and the folding volume left ONE file holding
        // the second item's bytes.
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
    }
}
