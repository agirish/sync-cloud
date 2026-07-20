import Testing
import Foundation
@testable import Sync

/// Finding 1 (data-corruption review): `safeCopyItem`/`safeMoveItem` used to replace an existing
/// destination in two non-atomic steps — trash the old destination, THEN rename the staged item
/// into its place. Between those the destination path was momentarily ABSENT, so a crash or
/// "Quit Anyway" there left the file only in Trash. These tests pin the fix: the destination-exists
/// replace now routes through the atomic `replaceItem` primitive, so the destination is never
/// absent and is never trashed directly (only the post-swap `.rollback_` backup is).
@Suite struct AtomicReplaceTests {

    /// Wraps MockFileManager at the FileManaging seam, recording which primitive each replacement
    /// used. The window bug shows up here as a `trashItem` on the destination path itself.
    private final class ReplaceRecordingFileManager: FileManaging, @unchecked Sendable {
        private let inner: MockFileManager
        private(set) var replaceCalls: [(destination: String, staged: String)] = []
        private(set) var trashedPaths: [String] = []

        init(inner: MockFileManager) { self.inner = inner }

        func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
            replaceCalls.append((destination: destinationURL.path, staged: stagedURL.path))
            return try inner.replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName)
        }
        func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            trashedPaths.append(url.path)
            try inner.trashItem(at: url, resultingItemURL: outResultingURL)
        }
        func moveItem(at srcURL: URL, to dstURL: URL) throws { try inner.moveItem(at: srcURL, to: dstURL) }
        func copyItem(at srcURL: URL, to dstURL: URL) throws { try inner.copyItem(at: srcURL, to: dstURL) }
        func removeItem(at URL: URL) throws { try inner.removeItem(at: URL) }
        func fileExists(atPath path: String) -> Bool { inner.fileExists(atPath: path) }
        func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            inner.fileExists(atPath: path, isDirectory: isDirectory)
        }
        func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            try inner.attributesOfItem(atPath: path)
        }
        func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
            try inner.setAttributes(attributes, ofItemAtPath: path)
        }
        func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws {
            try inner.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        }
        func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            inner.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler)
        }
    }

    private func seed(_ inner: MockFileManager, path: String, size: Int) {
        inner.virtualDisk[path] = MockFileManager.FileStub(isDirectory: false, attributes: [FileAttributeKey.size: size], contents: nil)
    }

    // MARK: - Parity: the dest-exists replace goes through the atomic primitive, no trash-then-move

    @Test func testSafeCopyReplaceRoutesThroughAtomicReplaceWithoutTrashingDestination() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seed(inner, path: "/src/f.txt", size: 100)
        seed(inner, path: "/dst/f.txt", size: 5) // pre-existing destination → replacement
        let spy = ReplaceRecordingFileManager(inner: inner)

        let overwritten = try FileSyncManager.safeCopyItem(
            at: URL(fileURLWithPath: "/src/f.txt"),
            to: URL(fileURLWithPath: "/dst/f.txt"),
            fileManager: spy
        )

        // The replacement went through the atomic primitive, staging a temp into the destination.
        #expect(spy.replaceCalls.count == 1)
        #expect(spy.replaceCalls.first?.destination == "/dst/f.txt")
        #expect(spy.replaceCalls.first?.staged.contains(".tmp_") == true)

        // The destination path itself is NEVER trashed — that direct trash was the window.
        #expect(spy.trashedPaths.contains("/dst/f.txt") == false)

        // New content landed; the source is intact; the old content is recoverable (Trash here).
        #expect(inner.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        #expect(inner.virtualDisk["/src/f.txt"] != nil)
        let backup = try #require(overwritten)
        #expect(inner.virtualDisk[backup.path]?.attributes?[FileAttributeKey.size] as? Int == 5)
        // The happy path leaves no artifacts behind in the destination directory: the staged temp
        // was consumed and the backup was trashed out of `/dst`.
        #expect(inner.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
        #expect(inner.virtualDisk.keys.contains { $0.hasPrefix("/dst/.rollback_") } == false)
    }

    @Test func testSafeMoveReplaceRoutesThroughAtomicReplaceWithoutTrashingDestination() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seed(inner, path: "/src/f.txt", size: 100)
        seed(inner, path: "/dst/f.txt", size: 5)
        let spy = ReplaceRecordingFileManager(inner: inner)

        let overwritten = try FileSyncManager.safeMoveItem(
            at: URL(fileURLWithPath: "/src/f.txt"),
            to: URL(fileURLWithPath: "/dst/f.txt"),
            fileManager: spy
        )

        #expect(spy.replaceCalls.count == 1)
        #expect(spy.replaceCalls.first?.destination == "/dst/f.txt")
        #expect(spy.replaceCalls.first?.staged.contains(".tmp_") == true)
        #expect(spy.trashedPaths.contains("/dst/f.txt") == false)

        // Move semantics: source gone, new content at destination, old content recoverable.
        #expect(inner.virtualDisk["/src/f.txt"] == nil)
        #expect(inner.virtualDisk["/dst/f.txt"]?.attributes?[FileAttributeKey.size] as? Int == 100)
        let backup = try #require(overwritten)
        #expect(inner.virtualDisk[backup.path]?.attributes?[FileAttributeKey.size] as? Int == 5)
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
    /// no data lost. (The existing rollback pins also set `shouldFailMove`, which routes through the
    /// cross-volume copy path where the source is never consumed; this isolates the rename path.)
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
        // ALSO failed (a cloud daemon re-materializing the source path, or holding the temp
        // busy, does exactly this). The staged `.tmp_` now holds the ONLY copy of the source's
        // content — cleanup must leave it on disk. Removing it (the old unconditional defer)
        // permanently destroyed the source, not even via the Trash.
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
        // The preservation reset the sweeper's age clock: the staging RENAME kept the
        // original's mtime, which would have made an hour-old source sweep-eligible on the
        // very next refresh — stranding the "preserved at" pointer within minutes.
        let touchedDate = tempSurvivor?.value.attributes?[FileAttributeKey.modificationDate] as? Date
        #expect(touchedDate != nil && abs(touchedDate!.timeIntervalSinceNow) < 60)
        // And the failure the user sees names the preservation — a bare "Move Failed" reads
        // as "nothing changed" while the source is in fact gone from its path.
        #expect(thrown?.localizedDescription.contains("preserved in the hidden file") == true)
    }

    /// Cross-volume move (EXDEV on the staging rename) that REPLACES an existing destination and
    /// SUCCEEDS: the source is copied onto the destination's volume, atomically swapped in, then the
    /// original is cleaned from its own volume. Realistic case — moving a file off an external drive
    /// over an existing cloud file. Every other dest-exists rollback pin also fails the temp rename,
    /// so this is the only coverage of the cross-volume replace success path.
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
    /// replace and throws — consistent with the dest-absent cross-volume path, and avoiding a
    /// "moved" undo entry for a source still on disk. The revert goes back through the atomic
    /// primitive, so the destination is never left absent, and no data is lost on any side.
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
    /// leaves the destination untouched with NO stray backup artifact. (Without the atomic-on-
    /// failure cleanup this second case leaks a half-made `.rollback_` copy.)
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

    /// The crash-window itself is not unit-testable (a mock cannot kill the process mid-replace),
    /// so this drives the REAL primitive on a real temp directory to catch replaceItemAt quirks
    /// the RAM mock can't model (directories, metadata, backup placement).
    @Test func testRealDiskCopyReplaceOverExistingFilePreservesOldContent() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AtomicReplace-\(UUID().uuidString)")
        let src = base.appendingPathComponent("src")
        let dst = base.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        // The backup can land in the real ~/.Trash (outside `base`), so clean it explicitly.
        var backupToClean: URL?
        defer {
            if let b = backupToClean { try? fm.removeItem(at: b) }
            try? fm.removeItem(at: base)
        }

        let srcFile = src.appendingPathComponent("f.txt")
        let dstFile = dst.appendingPathComponent("f.txt")
        try "NEW".data(using: .utf8)!.write(to: srcFile)
        try "OLD".data(using: .utf8)!.write(to: dstFile)

        let overwritten = try FileSyncManager.safeCopyItem(at: srcFile, to: dstFile)
        backupToClean = overwritten

        // Destination now holds the new content; the source is untouched (copy).
        #expect(try String(contentsOf: dstFile, encoding: .utf8) == "NEW")
        #expect(fm.fileExists(atPath: srcFile.path))
        // The old content is recoverable at the returned handle (Trash on a Trash-capable volume,
        // otherwise the in-place `.rollback_` backup).
        let backup = try #require(overwritten)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "OLD")
        // At no point is the destination absent, and no stray temp is left behind.
        let leftovers = try fm.contentsOfDirectory(atPath: dst.path).filter { $0.hasPrefix(".tmp_") }
        #expect(leftovers.isEmpty)
    }

    @Test func testRealDiskMoveReplaceOverExistingFilePreservesOldContent() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AtomicReplace-\(UUID().uuidString)")
        let src = base.appendingPathComponent("src")
        let dst = base.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var backupToClean: URL?
        defer {
            if let b = backupToClean { try? fm.removeItem(at: b) }
            try? fm.removeItem(at: base)
        }

        let srcFile = src.appendingPathComponent("f.txt")
        let dstFile = dst.appendingPathComponent("f.txt")
        try "NEW".data(using: .utf8)!.write(to: srcFile)
        try "OLD".data(using: .utf8)!.write(to: dstFile)

        let overwritten = try FileSyncManager.safeMoveItem(at: srcFile, to: dstFile)
        backupToClean = overwritten

        #expect(try String(contentsOf: dstFile, encoding: .utf8) == "NEW")
        #expect(fm.fileExists(atPath: srcFile.path) == false) // move removes the source
        let backup = try #require(overwritten)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "OLD")
        let leftovers = try fm.contentsOfDirectory(atPath: dst.path).filter { $0.hasPrefix(".tmp_") }
        #expect(leftovers.isEmpty)
    }

    /// Directory replace on real disk: replaceItemAt must swap a whole subtree in atomically and
    /// keep the replaced directory's contents recoverable in the backup.
    @Test func testRealDiskCopyReplaceOverExistingDirectoryKeepsOldTreeInBackup() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AtomicReplace-\(UUID().uuidString)")
        let src = base.appendingPathComponent("src")
        let dst = base.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var backupToClean: URL?
        defer {
            if let b = backupToClean { try? fm.removeItem(at: b) }
            try? fm.removeItem(at: base)
        }

        let srcDir = src.appendingPathComponent("folder")
        let dstDir = dst.appendingPathComponent("folder")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        try "new".data(using: .utf8)!.write(to: srcDir.appendingPathComponent("new.txt"))
        try "old".data(using: .utf8)!.write(to: dstDir.appendingPathComponent("old.txt"))

        let overwritten = try FileSyncManager.safeCopyItem(at: srcDir, to: dstDir)
        backupToClean = overwritten

        // The destination folder now mirrors the source (new.txt present, old.txt gone from it).
        #expect(fm.fileExists(atPath: dstDir.appendingPathComponent("new.txt").path))
        #expect(fm.fileExists(atPath: dstDir.appendingPathComponent("old.txt").path) == false)
        // The replaced directory's contents survive in the backup handle.
        let backup = try #require(overwritten)
        #expect(fm.fileExists(atPath: backup.appendingPathComponent("old.txt").path))
    }

    /// Type-mismatch replace on real disk (reachable via a manual "Replace" of a folder with a
    /// same-named file, or vice versa). The old trash-then-move was type-agnostic; this pins that
    /// `replaceItemAt` is too — the destination takes the source's type and the old item is
    /// recoverable in the backup — so the atomic swap didn't regress that behavior.
    @Test func testRealDiskReplaceAcrossTypesSwapsTypeAndKeepsBackup() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AtomicReplace-\(UUID().uuidString)")
        let src = base.appendingPathComponent("src")
        let dst = base.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var backups: [URL] = []
        defer {
            for b in backups { try? fm.removeItem(at: b) }
            try? fm.removeItem(at: base)
        }

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

        let b1 = try FileSyncManager.safeCopyItem(at: srcFile, to: dstDir)
        if let b1 { backups.append(b1) }
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

        let b2 = try FileSyncManager.safeCopyItem(at: srcDir2, to: dstFile2)
        if let b2 { backups.append(b2) }
        #expect(isDir(dstFile2))                                          // dest is now a directory
        #expect(fm.fileExists(atPath: dstFile2.appendingPathComponent("in.txt").path))
        let backupFile = try #require(b2)
        #expect(try String(contentsOf: backupFile, encoding: .utf8) == "OLDFILE") // old file recoverable
    }

    /// Sync convergence guard: after a copy replace, the destination must carry the SOURCE's
    /// modification date, not the old destination's — otherwise a re-scan would still flag the two
    /// as different and the sync would never "take". `replaceItemAt`'s default combined metadata
    /// happens to take the modification date from the staged item; this pins that so a future
    /// `.usingNewMetadataOnly`/options change can't silently break convergence.
    @Test func testRealDiskCopyReplacePreservesSourceModificationDate() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AtomicReplace-\(UUID().uuidString)")
        let src = base.appendingPathComponent("src")
        let dst = base.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var backupToClean: URL?
        defer {
            if let b = backupToClean { try? fm.removeItem(at: b) }
            try? fm.removeItem(at: base)
        }

        let srcFile = src.appendingPathComponent("f.txt")
        let dstFile = dst.appendingPathComponent("f.txt")
        try "NEW".data(using: .utf8)!.write(to: srcFile)
        try "OLD".data(using: .utf8)!.write(to: dstFile)
        let srcDate = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: srcDate], ofItemAtPath: srcFile.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: dstFile.path)

        backupToClean = try FileSyncManager.safeCopyItem(at: srcFile, to: dstFile)

        let dstDate = try #require(try fm.attributesOfItem(atPath: dstFile.path)[.modificationDate] as? Date)
        #expect(abs(dstDate.timeIntervalSince(srcDate)) < 1)
    }
}
