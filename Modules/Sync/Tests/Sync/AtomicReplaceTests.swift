import Testing
import Foundation
import EventsTestSupport
@testable import Sync

/// `safeCopyItem`/`safeMoveItem` replace an existing destination through the atomic `replaceItem`
/// primitive, so the destination is never absent and never trashed directly (only the post-swap
/// `.rollback_` backup is). Trash-then-rename would leave a window where a crash or "Quit Anyway"
/// leaves the file only in the Trash.
@Suite struct AtomicReplaceTests {

    /// Wraps MockFileManager at the FileManaging seam, recording which primitive each replacement
    /// used. A non-atomic replace shows up as a `trashItem` on the destination path itself.
    private final class ReplaceRecordingFileManager: ForwardingFileManaging<MockFileManager>, @unchecked Sendable {
        private(set) var replaceCalls: [(destination: String, staged: String)] = []
        private(set) var trashedPaths: [String] = []

        override func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
            replaceCalls.append((destination: destinationURL.path, staged: stagedURL.path))
            return try inner.replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName)
        }
        override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            trashedPaths.append(url.path)
            try inner.trashItem(at: url, resultingItemURL: outResultingURL)
        }
    }

    private func seed(_ inner: MockFileManager, path: String, size: Int) {
        inner.virtualDisk[path] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: size], contents: nil)
    }

    /// Trashes as asked but, like a Trash that can't say where it put the item, reports no location.
    private final class SilentTrashFileManager: ForwardingFileManaging<MockFileManager>, @unchecked Sendable {
        override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try inner.trashItem(at: url, resultingItemURL: nil)
            outResultingURL?.pointee = nil
        }
    }

    /// A Replace is recorded at Info even when the Trash names no location for the old version:
    /// the collision line a Replace writes is Debug, so this line is the only record.
    @MainActor
    @Test func aReplaceWhoseBackupTheTrashCannotPlaceIsStillLogged() async throws {
        let log = LogCapture()
        let inner = MockFileManager()
        let folder = "/dst-\(UUID().uuidString)"
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: folder), withIntermediateDirectories: true)
        seed(inner, path: "/src/f.txt", size: 100)
        seed(inner, path: "\(folder)/f.txt", size: 5)

        _ = try FileSyncManager.safeCopyItem(at: URL(fileURLWithPath: "/src/f.txt"), to: URL(fileURLWithPath: "\(folder)/f.txt"),
                                             fileManager: SilentTrashFileManager(inner: inner))

        #expect(await log.holds(.info, containing: "Replaced \(folder)/f.txt — previous version moved to the Trash"))
    }

    // MARK: - Parity: the dest-exists replace goes through the atomic primitive, no trash-then-move

    @Test(arguments: [false, true])
    func testSafeReplaceRoutesThroughAtomicReplaceWithoutTrashingDestination(isMove: Bool) async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seed(inner, path: "/src/f.txt", size: 100)
        seed(inner, path: "/dst/f.txt", size: 5) // pre-existing destination → replacement
        let spy = ReplaceRecordingFileManager(inner: inner)

        let src = URL(fileURLWithPath: "/src/f.txt"), dst = URL(fileURLWithPath: "/dst/f.txt")
        let overwritten = isMove
            ? try FileSyncManager.safeMoveItem(at: src, to: dst, fileManager: spy)
            : try FileSyncManager.safeCopyItem(at: src, to: dst, fileManager: spy)

        // The replacement went through the atomic primitive, staging a temp into the destination.
        #expect(spy.replaceCalls.count == 1)
        #expect(spy.replaceCalls.first?.destination == "/dst/f.txt")
        #expect(spy.replaceCalls.first?.staged.contains(".tmp_") == true)

        // The destination path itself is never trashed: that would open the absent window.
        #expect(spy.trashedPaths.contains("/dst/f.txt") == false)

        // New content landed; the source is intact for a copy and gone for a move; the old content
        // is recoverable (Trash here).
        #expect(inner.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect((inner.virtualDisk["/src/f.txt"] != nil) == !isMove)
        let backup = try #require(overwritten)
        #expect(inner.virtualDisk[backup.path]?.attributes?[FileAttributeKey.size] as? Int == 5)
        // The happy path leaves no artifacts behind in the destination directory: the staged temp
        // was consumed and the backup was trashed out of `/dst`.
        #expect(inner.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
        #expect(inner.virtualDisk.keys.contains { $0.hasPrefix("/dst/.rollback_") } == false)
    }

    /// A brand-new destination has no prior item to protect, so it must NOT pay for a backup: the
    /// copy path stays a plain single rename of the staged temp (no replaceItem, no trash).
    @Test func testSafeCopyToAbsentDestinationDoesNotBackUpOrTrash() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seed(inner, path: "/src/f.txt", size: 100)
        let spy = ReplaceRecordingFileManager(inner: inner)

        let overwritten = try FileSyncManager.safeCopyItem(
            at: URL(fileURLWithPath: "/src/f.txt"),
            to: URL(fileURLWithPath: "/dst/f.txt"),
            fileManager: spy
        )

        #expect(overwritten == nil)
        #expect(spy.replaceCalls.isEmpty)
        #expect(spy.trashedPaths.isEmpty)
        #expect(inner.virtualDisk["/dst/f.txt"] != nil)
        #expect(inner.virtualDisk["/src/f.txt"] != nil)
    }

    /// Same-volume move replace whose atomic swap fails mid-flight: the staging rename already
    /// consumed the source, so the restore path must put BOTH back — source and destination — with
    /// no data lost. (The other rollback pins set `shouldFailMove`, which takes the cross-volume
    /// copy path where the source is never consumed; this isolates the rename path.)
    @Test func testSafeMoveSameVolumeReplaceFailureRestoresSourceAndDestination() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seed(inner, path: "/src/data.bin", size: 100)
        seed(inner, path: "/dst/data.bin", size: 5)

        // Only the staged `.tmp_` swap-into-place fails; the same-volume staging rename succeeds,
        // so the source is consumed before the replace throws.
        inner.shouldFailMoveOnTempRename = true

        #expect(throws: (any Error).self) {
            try FileSyncManager.safeMoveItem(
                at: URL(fileURLWithPath: "/src/data.bin"),
                to: URL(fileURLWithPath: "/dst/data.bin"),
                fileManager: inner
            )
        }

        // Neither side lost data: the destination keeps its old content and the source is restored.
        #expect(inner.virtualDisk["/dst/data.bin"]?.attributes?[FileAttributeKey.size] as? Int == 5)
        #expect(inner.virtualDisk["/src/data.bin"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect(inner.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
        #expect(inner.virtualDisk.keys.contains { $0.contains(".rollback_") } == false)
    }

    @Test func testSafeMoveDoubleFailurePreservesConsumedSourceInTemp() async throws {
        // Same-volume staging consumed the source; the replace failed; the restoring move-back
        // also failed (as when a cloud daemon re-materializes the source path or holds the temp
        // busy). The staged `.tmp_` now holds the only copy of the source's content, so cleanup
        // must leave it on disk: removing it would destroy the source, not even via the Trash.
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seed(inner, path: "/src/data.bin", size: 100)
        seed(inner, path: "/dst/data.bin", size: 5)

        inner.tempRenameFailuresRemaining = 2   // the swap-in fails, then the move-back fails

        var thrown: Error?
        do {
            _ = try FileSyncManager.safeMoveItem(
                at: URL(fileURLWithPath: "/src/data.bin"),
                to: URL(fileURLWithPath: "/dst/data.bin"),
                fileManager: inner
            )
        } catch { thrown = error }

        // The destination is untouched, and the consumed source's bytes survive in the
        // preserved temp (the source path itself could not be restored).
        #expect(inner.virtualDisk["/dst/data.bin"]?.attributes?[FileAttributeKey.size] as? Int == 5)
        let tempSurvivor = inner.virtualDisk.first { $0.key.contains(".tmp_") }
        #expect(tempSurvivor?.value.attributes?[FileAttributeKey.size] as? Int == 100)
        // The preservation resets the sweeper's age clock: the staging rename keeps the original's
        // mtime, which would make an hour-old source sweep-eligible on the next refresh and strand
        // the "preserved at" pointer.
        let touchedDate = tempSurvivor?.value.attributes?[FileAttributeKey.modificationDate] as? Date
        #expect(touchedDate != nil && abs(touchedDate!.timeIntervalSinceNow) < 60)
        // And the failure the user sees names the preservation: a bare "Move Failed" reads as
        // "nothing changed" while the source is gone from its path.
        #expect(thrown?.localizedDescription.contains("preserved in the hidden file") == true)
    }

    /// Cross-volume move (EXDEV on the staging rename) that replaces an existing destination and
    /// succeeds: the source is copied onto the destination's volume, swapped in atomically, then
    /// cleaned from its own volume, as when moving a file off an external drive over a cloud file.
    /// The only coverage of the cross-volume replace success path.
    @Test func testSafeMoveCrossVolumeReplaceOverExistingSucceedsAndCleansSource() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seed(inner, path: "/src/data.bin", size: 100)
        seed(inner, path: "/dst/data.bin", size: 5)
        inner.shouldFailMove = true // EXDEV on the same-volume staging rename → copy fallback

        let overwritten = try FileSyncManager.safeMoveItem(
            at: URL(fileURLWithPath: "/src/data.bin"),
            to: URL(fileURLWithPath: "/dst/data.bin"),
            fileManager: inner
        )

        // `shouldFailMove` forced the EXDEV copy-staging fallback (the cross-volume path); the
        // replace still went through the atomic primitive. (calledCopyItem is not asserted: the
        // mock's trashItem and finalizeBackup both call copyItem, so it is true even same-volume.)
        #expect(inner.calledReplaceItem)
        #expect(inner.virtualDisk["/src/data.bin"] == nil)   // source cleaned up (trashed)
        #expect(inner.virtualDisk["/dst/data.bin"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        let backup = try #require(overwritten)               // old content recoverable in Trash
        #expect(inner.virtualDisk[backup.path]?.attributes?[FileAttributeKey.size] as? Int == 5)
        #expect(inner.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
    }

    /// Cross-volume replace where the source volume has no Trash but the permanent remove SUCCEEDS —
    /// the middle outcome between "trash the source" and "both cleanups fail → revert". The source is
    /// permanently deleted, the replace stands, and the overwritten content comes back as the
    /// in-place `.rollback_` backup (Trash is unavailable on this volume, so finalizeBackup keeps it).
    /// Uniquely exercises finalizeBackup's trash-fallback within the cross-volume replace.
    @Test func testSafeMoveCrossVolumeReplaceRemovesSourcePermanentlyWhenTrashUnsupported() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seed(inner, path: "/src/data.bin", size: 100)
        seed(inner, path: "/dst/data.bin", size: 5)
        inner.shouldFailMove = true   // EXDEV staging → copy, source not consumed
        inner.shouldFailTrash = true  // source volume has no Trash; the permanent remove still works

        let overwritten = try FileSyncManager.safeMoveItem(
            at: URL(fileURLWithPath: "/src/data.bin"),
            to: URL(fileURLWithPath: "/dst/data.bin"),
            fileManager: inner
        )

        // Source permanently removed, destination holds the new content, op completes (no throw).
        #expect(inner.virtualDisk["/src/data.bin"] == nil)
        #expect(inner.virtualDisk["/dst/data.bin"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        // The overwritten old content survives as the in-place `.rollback_` backup.
        let backup = try #require(overwritten)
        #expect(backup.lastPathComponent.hasPrefix(".rollback_"))
        #expect(inner.virtualDisk[backup.path]?.attributes?[FileAttributeKey.size] as? Int == 5)
        #expect(inner.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
    }

    /// Cross-volume replace where BOTH source-cleanup steps fail (no Trash on the source volume and
    /// the permanent remove is denied). The move can't complete, so it reverts the (successful)
    /// replace and throws, like the dest-absent cross-volume path, so no "moved" undo entry exists
    /// for a source still on disk. The revert goes back through the atomic primitive, so the
    /// destination is never left absent, and no data is lost on any side.
    @Test func testSafeMoveCrossVolumeReplaceRevertsWhenSourceCleanupFails() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seed(inner, path: "/src/data.bin", size: 100)
        seed(inner, path: "/dst/data.bin", size: 5)
        inner.shouldFailMove = true                   // EXDEV staging → copy, source not consumed
        inner.shouldFailTrash = true                  // source volume has no Trash
        inner.failRemovePathsOnce = ["/src/data.bin"] // and the permanent remove is denied

        #expect(throws: (any Error).self) {
            try FileSyncManager.safeMoveItem(
                at: URL(fileURLWithPath: "/src/data.bin"),
                to: URL(fileURLWithPath: "/dst/data.bin"),
                fileManager: inner
            )
        }

        // Clean revert: the destination is back to its original content and the source is intact —
        // exactly the pre-op state, with no stray temp or rollback artifacts left behind.
        #expect(inner.virtualDisk["/dst/data.bin"]?.attributes?[FileAttributeKey.size] as? Int == 5)
        #expect(inner.virtualDisk["/src/data.bin"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect(inner.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
        #expect(inner.virtualDisk.keys.contains { $0.contains(".rollback_") } == false)
    }

    /// Pins the mock `replaceItem`'s contract as an atomicity oracle: a brand-new destination is a
    /// plain install returning no backup, and a failure while backing up the prior destination
    /// leaves the destination untouched with no stray half-made `.rollback_` copy.
    @Test func testMockReplaceItemPrimitiveContract() throws {
        // (1) No prior destination → plain install, nil backup.
        let a = MockFileManager()
        try a.createDirectory(at: URL(fileURLWithPath: "/d"), withIntermediateDirectories: true)
        seed(a, path: "/d/.tmp_staged", size: 42)
        let backup = try a.replaceItem(
            at: URL(fileURLWithPath: "/d/new.txt"),
            withItemAt: URL(fileURLWithPath: "/d/.tmp_staged"),
            backupItemName: ".rollback_x"
        )
        #expect(backup == nil)
        #expect(a.virtualDisk["/d/new.txt"]?.attributes?[FileAttributeKey.size] as? Int == 42)
        #expect(a.virtualDisk["/d/.tmp_staged"] == nil)

        // (2) Prior destination, but backing it up fails → destination untouched, no stray backup.
        let b = MockFileManager()
        try b.createDirectory(at: URL(fileURLWithPath: "/d"), withIntermediateDirectories: true)
        seed(b, path: "/d/f.txt", size: 5)
        seed(b, path: "/d/.tmp_staged", size: 100)
        b.failRemovePathsOnce = ["/d/f.txt"] // the backup move is copy+remove; the remove fails
        #expect(throws: (any Error).self) {
            try b.replaceItem(
                at: URL(fileURLWithPath: "/d/f.txt"),
                withItemAt: URL(fileURLWithPath: "/d/.tmp_staged"),
                backupItemName: ".rollback_y"
            )
        }
        #expect(b.virtualDisk["/d/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 5) // untouched
        #expect(b.virtualDisk.keys.contains { $0.hasPrefix("/d/.rollback_") } == false)     // no stray backup
    }

    // MARK: - Real-disk smoke: exercises the real FileManager.replaceItemAt, not the mock

    // The crash-window itself is not unit-testable (a mock cannot kill the process mid-replace),
    // so these drive the REAL primitive on a real temp directory to catch replaceItemAt quirks
    // the RAM mock can't model (directories, metadata, backup placement).

    /// Directory replace on real disk: replaceItemAt must swap a whole subtree in atomically and
    /// keep the replaced directory's contents recoverable in the backup.
    @Test func testRealDiskCopyReplaceOverExistingDirectoryKeepsOldTreeInBackup() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AtomicReplace-\(UUID().uuidString)")
        let src = base.appendingPathComponent("src")
        let dst = base.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let trash = ScratchTrash(in: base)

        let srcDir = src.appendingPathComponent("folder")
        let dstDir = dst.appendingPathComponent("folder")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        try "new".data(using: .utf8)!.write(to: srcDir.appendingPathComponent("new.txt"))
        try "old".data(using: .utf8)!.write(to: dstDir.appendingPathComponent("old.txt"))

        let overwritten = try FileSyncManager.safeCopyItem(at: srcDir, to: dstDir, fileManager: trash)

        // The destination folder now mirrors the source (new.txt present, old.txt gone from it).
        #expect(fm.fileExists(atPath: dstDir.appendingPathComponent("new.txt").path))
        #expect(fm.fileExists(atPath: dstDir.appendingPathComponent("old.txt").path) == false)
        // The replaced directory's contents survive in the backup handle.
        let backup = try #require(overwritten)
        #expect(fm.fileExists(atPath: backup.appendingPathComponent("old.txt").path))
    }

    /// Type-mismatch replace on real disk (a manual "Replace" of a folder with a same-named file,
    /// or vice versa): `replaceItemAt` is type-agnostic, so the destination takes the source's type
    /// and the old item is recoverable in the backup.
    @Test func testRealDiskReplaceAcrossTypesSwapsTypeAndKeepsBackup() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AtomicReplace-\(UUID().uuidString)")
        let src = base.appendingPathComponent("src")
        let dst = base.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let trash = ScratchTrash(in: base)

        func isDir(_ url: URL) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
        }

        // (1) A file replaces an existing directory.
        let srcFile = src.appendingPathComponent("item")
        let dstDir = dst.appendingPathComponent("item")
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        try "child".data(using: .utf8)!.write(to: dstDir.appendingPathComponent("c.txt"))
        try "FILE".data(using: .utf8)!.write(to: srcFile)

        let b1 = try FileSyncManager.safeCopyItem(at: srcFile, to: dstDir, fileManager: trash)
        #expect(isDir(dstDir) == false)                                   // dest is now a file
        #expect(try String(contentsOf: dstDir, encoding: .utf8) == "FILE")
        let backupDir = try #require(b1)
        #expect(fm.fileExists(atPath: backupDir.appendingPathComponent("c.txt").path)) // old dir recoverable

        // (2) A directory replaces an existing file.
        let srcDir2 = src.appendingPathComponent("item2")
        let dstFile2 = dst.appendingPathComponent("item2")
        try fm.createDirectory(at: srcDir2, withIntermediateDirectories: true)
        try "in".data(using: .utf8)!.write(to: srcDir2.appendingPathComponent("in.txt"))
        try "OLDFILE".data(using: .utf8)!.write(to: dstFile2)

        let b2 = try FileSyncManager.safeCopyItem(at: srcDir2, to: dstFile2, fileManager: trash)
        #expect(isDir(dstFile2))                                          // dest is now a directory
        #expect(fm.fileExists(atPath: dstFile2.appendingPathComponent("in.txt").path))
        let backupFile = try #require(b2)
        #expect(try String(contentsOf: backupFile, encoding: .utf8) == "OLDFILE") // old file recoverable
    }

    /// A Replace lands the source's permissions, creation date and modification date, not the old
    /// file's, for copy and move: `replaceItemAt`'s default merge keeps the destination's, so a 0755
    /// script replacing a 0600 one would stay 0600. The modification date is the sync convergence
    /// guard: with the old one, a re-scan would still flag the two as different and the sync would
    /// never "take". The old content stays recoverable in the test's own Trash, the source stays
    /// for a copy and goes for a move, and no stray temp is left behind.
    @Test(arguments: [false, true])
    func realDiskReplaceTakesTheSourcesPermissionsAndCreationDate(isMove: Bool) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AtomicReplace-meta-\(UUID().uuidString)")
        let src = base.appendingPathComponent("src")
        let dst = base.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let trash = ScratchTrash(in: base)

        let srcFile = src.appendingPathComponent("run.sh")
        let dstFile = dst.appendingPathComponent("run.sh")
        try "NEW".data(using: .utf8)!.write(to: srcFile)
        try "OLD".data(using: .utf8)!.write(to: dstFile)
        let srcBorn = Date(timeIntervalSince1970: 1_600_000_000)
        let srcDate = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.posixPermissions: 0o755, .creationDate: srcBorn, .modificationDate: srcDate],
                             ofItemAtPath: srcFile.path)
        try fm.setAttributes([.posixPermissions: 0o600, .creationDate: Date(timeIntervalSince1970: 1_000_000_000),
                              .modificationDate: Date(timeIntervalSince1970: 1_100_000_000)],
                             ofItemAtPath: dstFile.path)

        let backup = isMove
            ? try FileSyncManager.safeMoveItem(at: srcFile, to: dstFile, fileManager: trash)
            : try FileSyncManager.safeCopyItem(at: srcFile, to: dstFile, fileManager: trash)

        let attributes = try fm.attributesOfItem(atPath: dstFile.path)
        #expect(try String(contentsOf: dstFile, encoding: .utf8) == "NEW")
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755,
                "the replaced file kept the old file's permissions")
        let creation = try #require(attributes[.creationDate] as? Date)
        #expect(abs(creation.timeIntervalSince(srcBorn)) < 1, "the replaced file kept the old file's creation date")
        let modified = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(modified.timeIntervalSince(srcDate)) < 1, "the replaced file kept the old file's modification date")
        #expect(fm.fileExists(atPath: srcFile.path) == !isMove)
        // The old file is still recoverable, with its own content.
        let kept = try #require(backup)
        #expect(try String(contentsOf: kept, encoding: .utf8) == "OLD")
        #expect(kept.path.hasPrefix(trash.folder.path),
                "the replaced file's backup never reached the test's own Trash: \(kept.path)")
        // At no point is the destination absent, and no stray temp is left behind.
        let leftovers = try fm.contentsOfDirectory(atPath: dst.path).filter { $0.hasPrefix(".tmp_") }
        #expect(leftovers.isEmpty)
    }
}
