import Foundation
import Testing
@testable import Sync

/// **A file locked in Finder can be copied, and leaves nothing behind when it cannot** (FR31).
///
/// `copyItem` and `copyfile` carry `uchg`/`uappnd` onto the copy, and a locked staging `.tmp_` can
/// be neither renamed into place, nor swapped over a destination, nor removed. So a locked file was
/// never copied, and each attempt left a hidden full-size copy beside the destination that no
/// removal and no Trash could clear. Real files throughout: the claim is about what the kernel
/// refuses, which no double models.
@Suite struct LockedFileTransferTests {

    private static let locks: [FileAttributeKey] = [.immutable, .appendOnly]

    /// A scratch folder whose cleanup lifts every lock first, or the folder could not be removed.
    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("locked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("dst"), withIntermediateDirectories: true)
        return url
    }

    private func removeUnlocking(_ base: URL) {
        let fm = FileManager.default
        var entries = [base]
        if let walk = fm.enumerator(at: base, includingPropertiesForKeys: nil) {
            for case let entry as URL in walk { entries.append(entry) }
        }
        for entry in entries {
            try? fm.setAttributes([.immutable: false, .appendOnly: false], ofItemAtPath: entry.path)
        }
        try? fm.removeItem(at: base)
    }

    private func isLocked(_ url: URL, by key: FileAttributeKey) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[key] as? Bool == true
    }

    private func staging(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".tmp_") }
    }

    /// A locked file copies to a new name: the copy has its content and its lock, the original
    /// keeps its own, and no staging copy is left. Observed (`copyfile`, as a pane transfer copies)
    /// and plain (`copyItem`) both carry the lock onto the copy.
    @Test(arguments: Self.locks, [false, true])
    func aLockedFileCopiesAndItsCopyIsLockedLikeIt(lock: FileAttributeKey, observed: Bool) throws {
        let base = try scratch()
        defer { removeUnlocking(base) }
        let source = base.appendingPathComponent("src/locked.txt")
        let destination = base.appendingPathComponent("dst/locked.txt")
        try Data("locked".utf8).write(to: source)
        try FileManager.default.setAttributes([lock: true], ofItemAtPath: source.path)

        try FileSyncManager.safeCopyItem(at: source, to: destination, fileManager: ScratchTrash(in: base),
                                         observer: observed ? CopyObserver(shouldContinue: { true }) : nil)

        #expect(try String(contentsOf: destination, encoding: .utf8) == "locked")
        #expect(isLocked(destination, by: lock), "the copy lost the lock its original carries")
        #expect(isLocked(source, by: lock), "the original's lock was lifted")
        #expect(staging(in: destination.deletingLastPathComponent()).isEmpty)
    }

    /// The same over an existing file: the swap installs the copy, locked, and the old file is kept.
    @Test func aLockedFileReplacesAnUnlockedOne() throws {
        let base = try scratch()
        defer { removeUnlocking(base) }
        let source = base.appendingPathComponent("src/report.txt")
        let destination = base.appendingPathComponent("dst/report.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: source.path)

        let kept = try FileSyncManager.safeCopyItem(at: source, to: destination, fileManager: ScratchTrash(in: base))

        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        #expect(isLocked(destination, by: .immutable))
        #expect(try String(contentsOf: try #require(kept), encoding: .utf8) == "old")
        #expect(staging(in: destination.deletingLastPathComponent()).isEmpty)
    }

    /// A move must rename or Trash the original, which a lock forbids, so it is refused before
    /// anything is written — not attempted, half-done and reverted.
    @Test(arguments: Self.locks)
    func movingALockedFileIsRefusedBeforeAnythingIsWritten(lock: FileAttributeKey) throws {
        let base = try scratch()
        defer { removeUnlocking(base) }
        let source = base.appendingPathComponent("src/locked.txt")
        let destination = base.appendingPathComponent("dst/locked.txt")
        try Data("locked".utf8).write(to: source)
        try FileManager.default.setAttributes([lock: true], ofItemAtPath: source.path)

        #expect(throws: FileSyncManager.FileOperationError.itemIsLocked(name: "locked.txt")) {
            try FileSyncManager.safeMoveItem(at: source, to: destination, fileManager: ScratchTrash(in: base))
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "locked")
        #expect(isLocked(source, by: lock))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).isEmpty,
                "the refused move left something at the destination")
    }

    /// Refuses the install step — the rename of a `.tmp_` into place — as a full disk or a racing
    /// writer would.
    private final class InstallRefusingDisk: FileManager, @unchecked Sendable {
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if srcURL.lastPathComponent.hasPrefix(".tmp_") { throw CocoaError(.fileWriteNoPermission) }
            try super.moveItem(at: srcURL, to: dstURL)
        }
    }

    /// A folder's copy keeps the locks of the files inside it. When its install fails, the staging
    /// folder is still removed — its locked files and all — rather than left beside the destination.
    @Test func aFailedInstallLeavesNoStagingEvenWithALockedFileInside() throws {
        let base = try scratch()
        defer { removeUnlocking(base) }
        let folder = base.appendingPathComponent("src/Folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        let lockedChild = folder.appendingPathComponent("inner/locked.txt")
        try Data("locked".utf8).write(to: lockedChild)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: lockedChild.path)
        let destination = base.appendingPathComponent("dst/Folder")

        #expect(throws: (any Error).self) {
            try FileSyncManager.safeCopyItem(at: folder, to: destination, fileManager: InstallRefusingDisk())
        }
        #expect(staging(in: destination.deletingLastPathComponent()).isEmpty,
                "the abandoned staging copy is still there, holding a locked file")
        #expect(isLocked(lockedChild, by: .immutable), "the original's lock was lifted")
    }

    /// An orphaned staging copy that carries a lock — what every attempt left before this fix — is
    /// swept like any other, rather than refused by the Trash forever.
    @Test func theSweepClearsALockedOrphanedStagingCopy() throws {
        let base = try scratch()
        defer { removeUnlocking(base) }
        let orphan = base.appendingPathComponent("dst/.tmp_\(UUID().uuidString)")
        try Data("old copy".utf8).write(to: orphan)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: orphan.path)
        let trash = ScratchTrash(in: base)

        let removed = OrphanSweeper.removeTempArtifacts(atPaths: [orphan.path], fileManager: trash)

        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(trash.names == [orphan.lastPathComponent])
    }
}
