import Events
import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// **A move-by-copy never deletes the only complete copy** (final review P2).
///
/// On a volume with no Trash the original is removed outright once its copy has landed, and a
/// folder's `removeItem` deletes what it can before it throws — a locked file inside is enough,
/// verified. The cleanup then "reverted" by removing the copy, so part of the original and all of
/// the copy were gone. Real folders here, because the defect is in what is left on disk; the double
/// stands in only for the Trash-less volume and the removal that stops part-way.
@Suite struct CrossVolumeCleanupTests {

    /// The real disk with no Trash, whose removal of `partial` deletes one file inside and then
    /// throws — what a locked or busy entry does to a real `removeItem`.
    private final class TrashlessPartialRemoveDisk: FileManager, @unchecked Sendable {
        let partial: String
        init(partial: String) { self.partial = partial; super.init() }

        override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            throw CocoaError(.featureUnsupported, userInfo: [NSFilePathErrorKey: url.path])
        }

        override func removeItem(at url: URL) throws {
            guard url.path == partial else { return try super.removeItem(at: url) }
            try super.removeItem(at: url.appendingPathComponent("a.txt"))
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.appendingPathComponent("b.txt").path])
        }
    }

    private func folder(at url: URL, files: [String: String]) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: url.appendingPathComponent(name)) }
    }

    private func names(in url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    @Test func aPartlyRemovedOriginalKeepsItsCopy() throws {
        let base = try makeCanonicalTempRoot(prefix: "p2-move")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("src/Photos")
        let destination = base.appendingPathComponent("dst/Photos")
        try folder(at: source, files: ["a.txt": "a", "b.txt": "b"])
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let disk = TrashlessPartialRemoveDisk(partial: source.path)

        #expect(throws: FileSyncManager.FileOperationError.originalPartlyRemoved(name: "Photos")) {
            try FileSyncManager.safeMoveItem(at: source, to: destination, fileManager: disk,
                                             caseSensitiveVolume: false, crossVolume: true)
        }
        #expect(names(in: destination) == ["a.txt", "b.txt"], "the only complete copy was removed")
        #expect(names(in: source) == ["b.txt"], "premise: the removal stopped part-way")
    }

    @Test func aPartlyRemovedOriginalKeepsTheCopyThatReplacedTheDestination() throws {
        let base = try makeCanonicalTempRoot(prefix: "p2-replace")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("src/Photos")
        let destination = base.appendingPathComponent("dst/Photos")
        try folder(at: source, files: ["a.txt": "a", "b.txt": "b"])
        try folder(at: destination, files: ["old.txt": "old"])
        let disk = TrashlessPartialRemoveDisk(partial: source.path)

        let thrown = #expect(throws: FileSyncManager.FileOperationError.self) {
            try FileSyncManager.safeMoveItem(at: source, to: destination, fileManager: disk,
                                             caseSensitiveVolume: false, crossVolume: true)
        }
        #expect(names(in: destination) == ["a.txt", "b.txt"],
                "the revert put the old destination back over the only complete copy")
        // The item it replaced is kept too — no Trash here, so as the hidden backup beside it.
        let backups = names(in: destination.deletingLastPathComponent()).filter { $0.hasPrefix(".rollback_") }
        let backup = try #require(backups.first)
        #expect(backups.count == 1)
        #expect(names(in: destination.deletingLastPathComponent().appendingPathComponent(backup)) == ["old.txt"])
        // **B2: and the alert says where** — the hidden backup is the one place it is, and nothing
        // sweeps it.
        #expect(thrown == .originalPartlyRemoved(name: "Photos", replacedItemKeptAt: .hiddenBesideDestination(name: backup)))
        #expect(thrown?.errorDescription?.contains("“\(backup)”") == true, "\(String(describing: thrown?.errorDescription))")
    }

    /// The Trash-less, part-way-removing disk, on which a rename of `from` fails as across
    /// volumes — so an undo's or redo's own move takes the copy-and-remove path.
    private final class CrossVolumePartialRemoveDisk: FileManager, @unchecked Sendable {
        let partial: String
        init(partial: String) { self.partial = partial; super.init() }

        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if srcURL.path == partial { throw POSIXError(.EXDEV) }
            try super.moveItem(at: srcURL, to: dstURL)
        }

        override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            throw CocoaError(.featureUnsupported, userInfo: [NSFilePathErrorKey: url.path])
        }

        override func removeItem(at url: URL) throws {
            guard url.path == partial else { return try super.removeItem(at: url) }
            try super.removeItem(at: url.appendingPathComponent("a.txt"))
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.appendingPathComponent("b.txt").path])
        }
    }

    /// **B3.** A ⌘Z whose move back runs across volumes puts the folder back WHOLE and then cannot
    /// fully remove what is left where it was. That is not a failed restore: the old banner said
    /// the original "may have been removed from the Trash".
    @MainActor
    @Test func anUndoThatMovedBackWholeButLeftRemainsSaysSo() async throws {
        let base = try makeCanonicalTempRoot(prefix: "b3")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("src/Photos")
        let moved = base.appendingPathComponent("dst/Photos")
        try folder(at: moved, files: ["a.txt": "a", "b.txt": "b"])
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let disk = CrossVolumePartialRemoveDisk(partial: moved.path)
        let m = FileSyncManager()
        m.undoManager = UndoManager()
        m.permanentDeleteConfirmer = { _ in false }
        await m.registerMoveUndo(items: [(from: source, to: moved, overwritten: nil)], actionName: "Move 1 Item",
                                 fileManager: disk).value

        m.undoManager?.undo()
        await waitUntil("the undo drains") { m.activeFileOperationsCount == 0 }

        #expect(names(in: source) == ["a.txt", "b.txt"], "premise: the folder went back whole")
        #expect(names(in: moved) == ["b.txt"], "premise: the removal stopped part-way")
        let banner = try #require(m.banner?.message)
        #expect(banner == "Undo moved “Photos” back, but the copy where it was couldn’t be fully removed", "\(banner)")
    }

    /// **P8: a staging item that will not go is logged, with its path.** The last removal was a
    /// `try?`, so a hidden full-size copy left beside the destination left no line anywhere.
    @MainActor
    @Test func aStagingItemThatCannotBeRemovedIsLogged() async throws {
        final class UnremovableDisk: FileManager, @unchecked Sendable {
            override func removeItem(at url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
        }
        let base = try makeCanonicalTempRoot(prefix: "p8")
        defer { try? FileManager.default.removeItem(at: base) }
        let staging = base.appendingPathComponent(".tmp_\(UUID().uuidString)")
        try Data("x".utf8).write(to: staging)
        let log = LogCapture()

        FileSyncManager.removeStaging(staging, fileManager: UnremovableDisk())

        #expect(FileManager.default.fileExists(atPath: staging.path), "premise: the double removed it")
        #expect(await log.holds(.warning, containing: "staging item at \(staging.path)"))
    }
}
