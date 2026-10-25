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

        #expect(throws: FileSyncManager.FileOperationError.originalPartlyRemoved(name: "Photos")) {
            try FileSyncManager.safeMoveItem(at: source, to: destination, fileManager: disk,
                                             caseSensitiveVolume: false, crossVolume: true)
        }
        #expect(names(in: destination) == ["a.txt", "b.txt"],
                "the revert put the old destination back over the only complete copy")
        // The item it replaced is kept too — no Trash here, so as the hidden backup beside it.
        let backups = names(in: destination.deletingLastPathComponent()).filter { $0.hasPrefix(".rollback_") }
        #expect(backups.count == 1)
        if let backup = backups.first {
            #expect(names(in: destination.deletingLastPathComponent().appendingPathComponent(backup)) == ["old.txt"])
        }
    }

    /// The other half: a locked entry anywhere inside is refused before anything is copied — the
    /// original could not be removed after the copy lands.
    @Test func aMoveByCopyOfAFolderHoldingALockedFileIsRefusedFirst() throws {
        let base = try makeCanonicalTempRoot(prefix: "p2-locked")
        let source = base.appendingPathComponent("src/Photos")
        let locked = source.appendingPathComponent("deep/b.txt")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: base)
        }
        try folder(at: source.appendingPathComponent("deep"), files: ["b.txt": "b"])
        try Data("a".utf8).write(to: source.appendingPathComponent("a.txt"))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        let destination = base.appendingPathComponent("dst/Photos")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        #expect(throws: FileSyncManager.FileOperationError.itemIsLocked(name: "b.txt")) {
            try FileSyncManager.safeMoveItem(at: source, to: destination, fileManager: FileManager.default,
                                             caseSensitiveVolume: false, crossVolume: true)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(names(in: destination.deletingLastPathComponent()).isEmpty, "a staging copy was left behind")
        #expect(names(in: source) == ["a.txt", "deep"])
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
