import Testing
import Foundation
import Darwin
@testable import Sync

/// RD24: a copy that can be abandoned part-way. Two claims, and both are about real disks — the
/// mock file manager copies whole, which is why none of this can be pinned against it:
///
/// 1. **`observedCopyItem` is `copyItem`** when nobody cancels — the same tree, down to the
///    folder mtime `copyfile(3)` alone gets wrong beside a symlink.
/// 2. **A cancel stops inside the item** and leaves nothing behind: no destination, no `.tmp_`,
///    no alert, and a replaced destination still holding what it held.
///
/// Clones write no data, so every mid-data test passes `allowClone: false` to force the byte path
/// a cross-volume copy takes.
@Suite struct ObservedCopyTests {

    private func write(_ url: URL, bytes count: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = Data(repeating: 0xA5, count: 1 << 20)
        var left = count
        while left > 0 {
            let n = min(left, chunk.count)
            try handle.write(contentsOf: chunk.prefix(n))
            left -= n
        }
    }

    /// What `copyItem` preserves, per entry: enough to catch a lost mode, time, xattr or link.
    private func signature(of root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let entries = [""] + (FileManager.default.subpaths(atPath: root.path) ?? [])
        for rel in entries {
            let path = rel.isEmpty ? root.path : root.appendingPathComponent(rel).path
            var st = stat()
            try #require(lstat(path, &st) == 0)
            let isLink = (st.st_mode & S_IFMT) == S_IFLNK
            let names = (try? listXattrs(path)) ?? []
            let link = isLink ? ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "?") : ""
            result[rel] = "mode=\(st.st_mode) mtime=\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec) size=\(isLink ? 0 : st.st_size) flags=\(st.st_flags) xattrs=\(names.sorted()) link=\(link)"
        }
        return result
    }

    private func listXattrs(_ path: String) throws -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        _ = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        return buffer.split(separator: 0).map { String(cString: Array($0) + [0]) }
    }

    // MARK: Equivalence

    @Test func anUncancelledObservedCopyLandsTheSameTreeCopyItemDoes() throws {
        let root = try makeCanonicalTempRoot(prefix: "observed-copy-equivalence")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let src = root.appendingPathComponent("src")
        try write(src.appendingPathComponent("a.txt"), bytes: 12)
        try fm.setAttributes([.posixPermissions: 0o600, .modificationDate: Date(timeIntervalSince1970: 1_577_836_800)], ofItemAtPath: src.appendingPathComponent("a.txt").path)
        _ = setxattr(src.appendingPathComponent("a.txt").path, "com.example.rd24", "v", 1, 0, 0)
        try write(src.appendingPathComponent("sub/b.md"), bytes: 3 << 20)
        // The shape copyfile gets wrong on its own: a symlink inside a folder whose mtime is old.
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("sub/link").path, withDestinationPath: "../a.txt")
        try fm.createDirectory(at: src.appendingPathComponent("empty"), withIntermediateDirectories: true)
        for folder in ["sub", "empty", ""] {
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: src.appendingPathComponent(folder).path)
        }

        let viaCopyItem = root.appendingPathComponent("copyItem")
        let viaObserved = root.appendingPathComponent("observed")
        let viaUnclonedObserved = root.appendingPathComponent("observed-no-clone")
        try fm.copyItem(at: src, to: viaCopyItem)
        try fm.observedCopyItem(at: src, to: viaObserved, observer: CopyObserver(shouldContinue: { true }))
        try fm.observedCopyItem(at: src, to: viaUnclonedObserved, observer: CopyObserver(shouldContinue: { true }), allowClone: false)

        let expected = try signature(of: viaCopyItem)
        #expect(expected.count == 6)
        #expect(try signature(of: viaObserved) == expected)
        #expect(try signature(of: viaUnclonedObserved) == expected)
        #expect(fm.contents(atPath: viaUnclonedObserved.appendingPathComponent("sub/b.md").path) == fm.contents(atPath: src.appendingPathComponent("sub/b.md").path))
    }

    @Test func aFailureOtherThanCancelKeepsCopyItemsOwnError() throws {
        let root = try makeCanonicalTempRoot(prefix: "observed-copy-error")
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("nope.txt")
        var plain: Error?
        var observed: Error?
        do { try FileManager.default.copyItem(at: missing, to: root.appendingPathComponent("a")) } catch { plain = error }
        do { try FileManager.default.observedCopyItem(at: missing, to: root.appendingPathComponent("b"), observer: CopyObserver(shouldContinue: { true })) } catch { observed = error }
        let p = try #require(plain as NSError?)
        let o = try #require(observed as NSError?)
        #expect(o.domain == p.domain)
        #expect(o.code == p.code)
    }

    // MARK: Cancellation

    @Test func aCancelMidFileThrowsAndLeavesNoDestination() throws {
        let root = try makeCanonicalTempRoot(prefix: "observed-copy-cancel-file")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("big.bin")
        try write(src, bytes: 64 << 20)
        let dst = root.appendingPathComponent("copy.bin")
        let seen = LockedBox<Int64>(0)
        let observer = CopyObserver(shouldContinue: { seen.withLock { $0 } == 0 }, bytesCopied: { bytes in seen.withLock { $0 = bytes } })

        var thrown: Error?
        do { try FileManager.default.observedCopyItem(at: src, to: dst, observer: observer, allowClone: false) } catch { thrown = error }

        #expect(CopyObserver.isCancellation(try #require(thrown)))
        // Stopped inside the file, not after it.
        let stoppedAt = seen.withLock { $0 }
        #expect(stoppedAt > 0 && stoppedAt < 64 << 20)
        #expect(!FileManager.default.fileExists(atPath: dst.path))
    }

    @Test func aCancelMidFolderRemovesThePartialTree() throws {
        let root = try makeCanonicalTempRoot(prefix: "observed-copy-cancel-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("folder")
        for i in 0..<40 { try write(src.appendingPathComponent("f\(i).txt"), bytes: 4096) }
        try write(src.appendingPathComponent("zz/big.bin"), bytes: 32 << 20)
        let dst = root.appendingPathComponent("copy")
        let polls = LockedBox<Int>(0)
        // Let the first few entries land, so there IS a partial tree to clean up.
        let observer = CopyObserver(shouldContinue: {
            polls.withLock { $0 += 1; return $0 } < 60
        })

        var thrown: Error?
        do { try FileManager.default.observedCopyItem(at: src, to: dst, observer: observer, allowClone: false) } catch { thrown = error }

        #expect(CopyObserver.isCancellation(try #require(thrown)))
        #expect(!FileManager.default.fileExists(atPath: dst.path))
    }

    @Test func aCancelledReplaceLeavesTheDestinationAsItWasAndNoStagingFile() throws {
        let root = try makeCanonicalTempRoot(prefix: "observed-copy-cancel-replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src/report.txt")
        let dst = root.appendingPathComponent("dst/report.txt")
        try write(src, bytes: 1 << 20)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the destination's own work".utf8).write(to: dst)
        let polls = LockedBox<Int>(0)
        let observer = CopyObserver(shouldContinue: {
            polls.withLock { $0 += 1; return $0 } < 2
        })

        var thrown: Error?
        do { try FileSyncManager.safeCopyItem(at: src, to: dst, fileManager: FileManager.default, observer: observer) } catch { thrown = error }

        #expect(CopyObserver.isCancellation(try #require(thrown)))
        #expect(try String(contentsOf: dst, encoding: .utf8) == "the destination's own work")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dst.deletingLastPathComponent().path)
        #expect(siblings == ["report.txt"])
    }

    /// Delegates to the real disk, but forces the byte path and presses Cancel on the operation's own
    /// Progress once the first bytes of the first item have moved — the button, not the observer.
    private final class CancelOnFirstBytes: FileManaging, @unchecked Sendable {
        let fm = FileManager.default
        let cancel: @Sendable () -> Void
        init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }

        func copyItem(at s: URL, to d: URL, observer: CopyObserver) throws {
            let cancel = self.cancel
            let pressed = LockedBox(false)
            let pressing = CopyObserver(shouldContinue: observer.shouldContinue, bytesCopied: { bytes in
                if pressed.withLock({ let first = !$0; $0 = true; return first }) { cancel() }
                observer.bytesCopied(bytes)
            })
            try fm.observedCopyItem(at: s, to: d, observer: pressing, allowClone: false)
        }
        func copyItem(at s: URL, to d: URL) throws { try fm.copyItem(at: s, to: d) }
        func moveItem(at s: URL, to d: URL) throws { try fm.moveItem(at: s, to: d) }
        func trashItem(at u: URL, resultingItemURL o: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws { try fm.trashItem(at: u, resultingItemURL: o) }
        func replaceItem(at d: URL, withItemAt s: URL, backupItemName n: String) throws -> URL? { try fm.replaceItem(at: d, withItemAt: s, backupItemName: n) }
        func removeItem(at u: URL) throws { try fm.removeItem(at: u) }
        func fileExists(atPath p: String) -> Bool { fm.fileExists(atPath: p) }
        func fileExists(atPath p: String, isDirectory d: UnsafeMutablePointer<ObjCBool>?) -> Bool { fm.fileExists(atPath: p, isDirectory: d) }
        func attributesOfItem(atPath p: String) throws -> [FileAttributeKey: Any] { try fm.attributesOfItem(atPath: p) }
        func setAttributes(_ a: [FileAttributeKey: Any], ofItemAtPath p: String) throws { try fm.setAttributes(a, ofItemAtPath: p) }
        func createDirectory(at u: URL, withIntermediateDirectories c: Bool, attributes a: [FileAttributeKey: Any]?) throws {
            try fm.createDirectory(at: u, withIntermediateDirectories: c, attributes: a)
        }
        func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?, options m: FileManager.DirectoryEnumerationOptions, errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            fm.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h)
        }
    }

    @MainActor
    @Test func cancelDuringOneLargeCopyStopsInsideItWithNoAlertAndNothingLanded() async throws {
        let root = try makeCanonicalTempRoot(prefix: "observed-copy-transfer")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src")
        let dst = root.appendingPathComponent("dst")
        try write(src.appendingPathComponent("Archive 2019.zip"), bytes: 96 << 20)
        try write(src.appendingPathComponent("notes.txt"), bytes: 10)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let m = FileSyncManager()
        m.collisionResolver = { _ in .replace }
        // The copy runs off the main actor, which is parked in the await below, so the press can
        // hop onto it synchronously and reach the same Progress the dialog's Cancel button does.
        let manager = m
        let pressedProgress = LockedBox<Progress?>(nil)
        let fm = CancelOnFirstBytes(cancel: {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    manager.activeProgress?.cancel()
                    pressedProgress.withLock { $0 = manager.activeProgress }
                }
            }
        })
        let nodes = ["Archive 2019.zip", "notes.txt"].map { FileNode(id: src.appendingPathComponent($0).path, name: $0, isDirectory: false) }
        let transferred = await m.copyItems(nodes: nodes, toPath: dst.path, fileManager: fm)

        #expect(pressedProgress.withLock { $0 }?.isCancelled == true)
        #expect(transferred.isEmpty)
        #expect(m.currentError == nil)
        // Nothing landed, the second item never started, and no staging file survived.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dst.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: src.path).sorted() == ["Archive 2019.zip", "notes.txt"])
    }

    // MARK: The dialog's item line

    @Test func theByteLineReadsCopiedOfTotalAndEstimatesOnlyOnceThereIsARate() {
        let gb: Int64 = 1_000_000_000
        #expect(FileSyncManager.byteProgressText(itemName: "Archive 2019.zip", copied: 4_200_000_000, total: 12_800_000_000, elapsed: 1.5)
            == "Archive 2019.zip — 4.2 GB of 12.8 GB")
        // 4.2 GB in 60 s leaves 8.6 GB at 70 MB/s: about 123 s.
        #expect(FileSyncManager.byteProgressText(itemName: "Archive 2019.zip", copied: 4_200_000_000, total: 12_800_000_000, elapsed: 60)
            == "Archive 2019.zip — 4.2 GB of 12.8 GB · about 2 min left")
        #expect(FileSyncManager.byteProgressText(itemName: "Photos", copied: 3 * gb, total: nil, elapsed: 60)
            == "Photos — 3 GB copied")
        #expect(FileSyncManager.remainingText(seconds: 20) == "less than a minute left")
        #expect(FileSyncManager.remainingText(seconds: 89 * 60) == "about 89 min left")
        #expect(FileSyncManager.remainingText(seconds: 3 * 3600) == "about 3 hr left")
    }
}

/// A mock disk whose OBSERVED copy of one named file does something scripted: press Cancel on the
/// operation's Progress first (so the abandonment is the button's), or throw `userCancelled` with no
/// Cancel pressed at all (a provider's refusal, which must read as a failure). Every other call is
/// the mock's own. Shared by the transfer and bulk-sync tests of RD24's cancellation scoping.
final class ScriptedObservedCopy: FileManaging, @unchecked Sendable {
    enum Script { case pressCancel, throwForeignCancellation }
    let inner: MockFileManager
    private let trigger: String
    private let script: Script
    private let progressBox = LockedBox<Progress?>(nil)

    init(inner: MockFileManager, trigger: String, script: Script) {
        self.inner = inner; self.trigger = trigger; self.script = script
    }

    func installProgress(_ progress: Progress) { progressBox.withLock { $0 = progress } }

    func copyItem(at s: URL, to d: URL, observer: CopyObserver) throws {
        guard s.lastPathComponent == trigger else { return try inner.copyItem(at: s, to: d) }
        switch script {
        case .pressCancel:
            let deadline = Date().addingTimeInterval(30)   // bounded: a mis-wire fails, never hangs
            while progressBox.withLock({ $0 }) == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            progressBox.withLock { $0 }?.cancel()
            guard observer.shouldContinue() else { throw CocoaError(.userCancelled) }
            try inner.copyItem(at: s, to: d)
        case .throwForeignCancellation:
            throw CocoaError(.userCancelled)
        }
    }
    func copyItem(at s: URL, to d: URL) throws { try inner.copyItem(at: s, to: d) }
    func moveItem(at s: URL, to d: URL) throws { try inner.moveItem(at: s, to: d) }
    func trashItem(at u: URL, resultingItemURL o: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws { try inner.trashItem(at: u, resultingItemURL: o) }
    func replaceItem(at d: URL, withItemAt s: URL, backupItemName n: String) throws -> URL? { try inner.replaceItem(at: d, withItemAt: s, backupItemName: n) }
    func removeItem(at u: URL) throws { try inner.removeItem(at: u) }
    func fileExists(atPath p: String) -> Bool { inner.fileExists(atPath: p) }
    func fileExists(atPath p: String, isDirectory d: UnsafeMutablePointer<ObjCBool>?) -> Bool { inner.fileExists(atPath: p, isDirectory: d) }
    func attributesOfItem(atPath p: String) throws -> [FileAttributeKey: Any] { try inner.attributesOfItem(atPath: p) }
    func setAttributes(_ a: [FileAttributeKey: Any], ofItemAtPath p: String) throws { try inner.setAttributes(a, ofItemAtPath: p) }
    func createDirectory(at u: URL, withIntermediateDirectories c: Bool, attributes a: [FileAttributeKey: Any]?) throws {
        try inner.createDirectory(at: u, withIntermediateDirectories: c, attributes: a)
    }
    func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?, options m: FileManager.DirectoryEnumerationOptions, errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h)
    }
}

@Suite struct ObservedCopyCancellationScopeTests {
    private func seeded(_ names: [String]) throws -> MockFileManager {
        let disk = MockFileManager()
        try disk.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try disk.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        for name in names {
            disk.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: 10], contents: nil)
        }
        return disk
    }

    /// A `userCancelled` nobody asked for is a failure: it is reported, and the batch goes on. Before
    /// the scoping, it ended the loop silently — every later item dropped, no alert, no log.
    @MainActor
    @Test func aCancellationTheUserDidNotAskForIsReportedAndTheBatchContinues() async throws {
        let disk = try seeded(["a.txt", "b.txt"])
        let fm = ScriptedObservedCopy(inner: disk, trigger: "a.txt", script: .throwForeignCancellation)
        let m = FileSyncManager()
        m.collisionResolver = { _ in .replace }
        let nodes = ["a.txt", "b.txt"].map { FileNode(id: "/src/\($0)", name: $0, isDirectory: false) }

        let transferred = await m.copyItems(nodes: nodes, toPath: "/dst", fileManager: fm)

        #expect(transferred.map(\.name) == ["b.txt"])
        #expect(m.currentError != nil)
        #expect(disk.virtualDisk["/dst/b.txt"] != nil)
        #expect(disk.virtualDisk["/dst/a.txt"] == nil)
    }

    /// Bulk sync: Cancel pressed inside an item abandons it without an alert and leaves its row.
    @MainActor
    @Test(.parksAThread) func bulkSyncCancelledInsideAnItemReportsNoFailureAndKeepsTheRow() async throws {
        let disk = try seeded(["big.txt"])
        let fm = ScriptedObservedCopy(inner: disk, trigger: "big.txt", script: .pressCancel)
        let m = FileSyncManager(fileManager: fm)
        let diff = FileDifference(relativePath: "big.txt", leftItemPath: "/src/big.txt", rightItemPath: "/dst/big.txt",
                                  type: .missingOnRight, action: .copyToRight, description: "Missing on right", leftFileSize: 10)
        m.rawDifferences = [diff]
        m.differences = [diff]

        let run = Task { await m.syncAll(direction: .copyToRight) }
        await waitUntil("the run publishes a cancellable Progress") { m.activeProgress != nil }
        fm.installProgress(try #require(m.activeProgress))
        await run.value

        #expect(m.currentError == nil)
        #expect(disk.virtualDisk["/dst/big.txt"] == nil)
        #expect(disk.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
        #expect(m.differences.map(\.relativePath) == ["big.txt"])
        #expect(m.banner?.severity != .warning)
    }

    /// Bulk sync: the same `userCancelled` WITHOUT Cancel is a failure, alerted like any other.
    @MainActor
    @Test func bulkSyncReportsACancellationTheUserDidNotAskFor() async throws {
        let disk = try seeded(["big.txt"])
        let fm = ScriptedObservedCopy(inner: disk, trigger: "big.txt", script: .throwForeignCancellation)
        let m = FileSyncManager(fileManager: fm)
        let diff = FileDifference(relativePath: "big.txt", leftItemPath: "/src/big.txt", rightItemPath: "/dst/big.txt",
                                  type: .missingOnRight, action: .copyToRight, description: "Missing on right", leftFileSize: 10)
        m.rawDifferences = [diff]
        m.differences = [diff]

        await m.syncAll(direction: .copyToRight)

        #expect(m.currentError != nil)
        #expect(m.differences.map(\.relativePath) == ["big.txt"])
    }
}
