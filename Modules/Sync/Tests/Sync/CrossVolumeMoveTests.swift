import Foundation
import Testing
@testable import Sync

/// **A move onto another volume takes the staged, cancellable, Trash-first path** (FR33).
///
/// That path — copy into a `.tmp_` that watches Cancel, rename into place, original to the Trash —
/// used to run only when `moveItem` threw. Foundation's `moveItem` does not throw across volumes:
/// measured, it copied a file from the Data volume onto a disk image and unlinked the original by
/// itself. Every double here throws EXDEV on cue, which is why no test saw it. So the double in this
/// suite does NOT throw: a `moveItem` it is asked for succeeds, and the test reads which primitive
/// the move used.
@Suite struct CrossVolumeMoveTests {

    /// Records every `moveItem` and how often the copy's observer was consulted; everything else is
    /// the mock's. Its `moveItem` succeeds, as Foundation's does across volumes.
    private final class MoveRecordingDisk: FileManaging, @unchecked Sendable {
        let inner = MockFileManager()
        private let lock = NSLock()
        private var moves: [(from: String, to: String)] = []

        var movedSources: [String] { lock.lock(); defer { lock.unlock() }; return moves.map(\.from) }

        func moveItem(at s: URL, to d: URL) throws {
            lock.lock(); moves.append((s.path, d.path)); lock.unlock()
            try inner.moveItem(at: s, to: d)
        }
        func copyItem(at s: URL, to d: URL) throws { try inner.copyItem(at: s, to: d) }
        func copyItem(at s: URL, to d: URL, observer: CopyObserver) throws {
            guard observer.shouldContinue() else { throw CocoaError(.userCancelled) }
            try inner.copyItem(at: s, to: d)
        }
        func fileExists(atPath p: String) -> Bool { inner.fileExists(atPath: p) }
        func fileExists(atPath p: String, isDirectory d: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            inner.fileExists(atPath: p, isDirectory: d)
        }
        func attributesOfItem(atPath p: String) throws -> [FileAttributeKey: Any] { try inner.attributesOfItem(atPath: p) }
        func setAttributes(_ a: [FileAttributeKey: Any], ofItemAtPath p: String) throws { try inner.setAttributes(a, ofItemAtPath: p) }
        func createDirectory(at u: URL, withIntermediateDirectories c: Bool, attributes a: [FileAttributeKey: Any]?) throws {
            try inner.createDirectory(at: u, withIntermediateDirectories: c, attributes: a)
        }
        func trashItem(at u: URL, resultingItemURL o: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try inner.trashItem(at: u, resultingItemURL: o)
        }
        func removeItem(at u: URL) throws { try inner.removeItem(at: u) }
        func replaceItem(at d: URL, withItemAt s: URL, backupItemName n: String) throws -> URL? {
            try inner.replaceItem(at: d, withItemAt: s, backupItemName: n)
        }
        func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?, options m: FileManager.DirectoryEnumerationOptions,
                        errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h)
        }
    }

    private func disk(destinationTaken: Bool) throws -> MoveRecordingDisk {
        let disk = MoveRecordingDisk()
        try disk.inner.createDirectory(at: URL(fileURLWithPath: "/ext"), withIntermediateDirectories: true)
        try disk.inner.createDirectory(at: URL(fileURLWithPath: "/home"), withIntermediateDirectories: true)
        disk.inner.virtualDisk["/ext/a.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 100], contents: nil)
        if destinationTaken {
            disk.inner.virtualDisk["/home/a.bin"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 5], contents: nil)
        }
        return disk
    }

    /// The source is never renamed: it is copied into staging, the copy lands, and the original
    /// goes to the Trash — whether or not something was at the destination.
    @Test(arguments: [false, true])
    func aMoveToAnotherVolumeStagesACopyAndTrashesTheOriginal(destinationTaken: Bool) throws {
        let disk = try disk(destinationTaken: destinationTaken)
        let consulted = LockedBox(0)
        let observer = CopyObserver(shouldContinue: { consulted.withLock { $0 += 1 }; return true })

        let overwritten = try FileSyncManager.safeMoveItem(
            at: URL(fileURLWithPath: "/ext/a.bin"), to: URL(fileURLWithPath: "/home/a.bin"),
            fileManager: disk, caseSensitiveVolume: false, observer: observer, crossVolume: true)

        #expect(!disk.movedSources.contains("/ext/a.bin"),
                "the original was handed to moveItem, which copies and unlinks it by itself across volumes")
        #expect(consulted.withLock { $0 } > 0, "the copy never asked whether to keep going, so Cancel could not stop it")
        #expect(disk.inner.trashedPaths.contains { $0.hasSuffix("/a.bin") }, "the original did not go to the Trash")
        #expect(disk.inner.virtualDisk["/ext/a.bin"] == nil)
        #expect(disk.inner.virtualDisk["/home/a.bin"]?.attributes?[.size] as? Int == 100)
        #expect(!disk.inner.virtualDisk.keys.contains { $0.contains(".tmp_") })
        #expect((overwritten != nil) == destinationTaken)
    }

    /// Cancel during the copy leaves both sides as they were.
    @Test(arguments: [false, true])
    func cancelDuringAMoveToAnotherVolumeLeavesBothSidesAlone(destinationTaken: Bool) throws {
        let disk = try disk(destinationTaken: destinationTaken)
        let observer = CopyObserver(shouldContinue: { false })

        #expect(throws: CocoaError.self) {
            try FileSyncManager.safeMoveItem(
                at: URL(fileURLWithPath: "/ext/a.bin"), to: URL(fileURLWithPath: "/home/a.bin"),
                fileManager: disk, caseSensitiveVolume: false, observer: observer, crossVolume: true)
        }
        #expect(disk.inner.virtualDisk["/ext/a.bin"]?.attributes?[.size] as? Int == 100, "the original was touched")
        #expect(disk.inner.virtualDisk["/home/a.bin"]?.attributes?[.size] as? Int == (destinationTaken ? 5 : nil))
        #expect(disk.inner.trashedPaths.isEmpty)
        #expect(!disk.inner.virtualDisk.keys.contains { $0.contains(".tmp_") })
    }

    /// P6. A double's paths are not on the real disk, but the decision read them there: a mock
    /// folder that happens to sit under `/dev` on this Mac (devfs, a volume of its own) moving to one
    /// that does not was judged two volumes, and the mock took the staged copy path, not its rename.
    @Test func aDoublesMoveIsNotJudgedByTheRealDisksVolumes() throws {
        let source = URL(fileURLWithPath: "/dev/p6-src/a.bin"), destination = URL(fileURLWithPath: "/p6-dst/a.bin")
        try #require(FileSyncManager.isCrossVolumeMove(from: source, to: destination),
                     "premise: on this Mac `/dev` is not a volume of its own")
        let fm = MockFileManager()
        for dir in ["/dev/p6-src", "/p6-dst"] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        fm.virtualDisk[source.path] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 3], contents: nil)

        try FileSyncManager.safeMoveItem(at: source, to: destination, fileManager: fm)

        // The staged path copies and then puts the original in the Trash; the rename does neither
        // (the mock's own `moveItem` copies inside, so `calledCopyItem` cannot tell them apart).
        #expect(fm.trashedPaths.isEmpty, "a rename on the double was staged as a cross-volume copy")
        #expect(!fm.virtualDisk.keys.contains { $0.contains(".tmp_") })
        #expect(fm.virtualDisk[destination.path] != nil)
    }

    /// The control: on one volume a move is still a rename.
    @Test func aMoveOnOneVolumeIsStillARename() throws {
        let disk = try disk(destinationTaken: false)
        try FileSyncManager.safeMoveItem(
            at: URL(fileURLWithPath: "/ext/a.bin"), to: URL(fileURLWithPath: "/home/a.bin"),
            fileManager: disk, caseSensitiveVolume: false, crossVolume: false)
        #expect(disk.movedSources == ["/ext/a.bin"])
        #expect(disk.inner.trashedPaths.isEmpty)
    }

    /// The decision itself, on the real disk: two folders under the temporary directory share a
    /// volume — one not created yet included, which is asked through its nearest existing folder —
    /// and `/dev`, a volume of its own, does not share it.
    @Test func theVolumeDecisionReadsTheRealDisk() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cross-volume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)

        #expect(!FileSyncManager.isCrossVolumeMove(from: file, to: base.appendingPathComponent("b.txt")))
        #expect(!FileSyncManager.isCrossVolumeMove(from: file, to: base.appendingPathComponent("not/yet/here/b.txt")))
        #expect(FileSyncManager.isCrossVolumeMove(from: URL(fileURLWithPath: "/dev/null"), to: base.appendingPathComponent("b.txt")))
    }

    /// **End to end on a real second volume**, when one is named: `SYNCCLOUD_SECOND_VOLUME` is a
    /// writable folder on another volume (a disk image: `hdiutil create -size 20m -fs APFS …`,
    /// `hdiutil attach -nobrowse`). The original must reach the Trash — here a scratch Trash — rather
    /// than be unlinked by `moveItem`. Off without the variable, so CI does not run it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SYNCCLOUD_SECOND_VOLUME"] != nil))
    func aMoveOntoARealSecondVolumeTrashesTheOriginal() throws {
        let volume = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SYNCCLOUD_SECOND_VOLUME"]))
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cross-volume-\(UUID().uuidString)")
        let landing = volume.appendingPathComponent("cross-volume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: landing)
        }
        let source = base.appendingPathComponent("a.txt")
        try Data("moved".utf8).write(to: source)
        let disk = ScratchTrash(in: base)
        #expect(FileSyncManager.isCrossVolumeMove(from: source, to: landing.appendingPathComponent("a.txt")))

        try FileSyncManager.safeMoveItem(at: source, to: landing.appendingPathComponent("a.txt"), fileManager: disk)

        #expect(try String(contentsOf: landing.appendingPathComponent("a.txt"), encoding: .utf8) == "moved")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(disk.names == ["a.txt"], "the original was not put in the Trash — moveItem unlinked it")
    }
}
