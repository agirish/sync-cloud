import Foundation
import Testing
@testable import Sync

@Suite struct StorageLensRestoreTests {

    private func storeURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "StorageRestore-\(name)")
        return dir.appendingPathComponent("storage-lens.json")
    }

    private func write(_ url: URL, bytes: Int, fill: UInt8 = 0x41) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    private func report(totalBytes: Int = 1234) -> StorageLensReport {
        StorageLensReport(
            treemap: [TreemapNode(name: "Docs", path: "/root/Docs", bytes: totalBytes)],
            largest: [StorageEntry(path: "/root/Docs/big.bin", name: "big.bin",
                                   bytes: totalBytes, modified: Date(timeIntervalSince1970: 1000))],
            stale: [], reclaimCandidates: [], totalBytes: totalBytes,
            fileCount: 1, staleCount: 0, reclaimCount: 0, reclaimableBytes: 0)
    }

    // MARK: The store

    @Test func aSnapshotRoundTripsAndIsFoundByRoot() throws {
        let url = try storeURL("roundtrip")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let at = Date(timeIntervalSince1970: 1_800_000_000)

        StorageLensStore.saveInBackground(
            StorageLensSnapshot(root: "/root", report: report(), completedAt: at), to: url)
        StorageLensStore.waitForPendingWrites()

        let found = try #require(StorageLensStore.snapshot(for: "/root", from: url))
        #expect(found.report == report())
        #expect(found.completedAt == at)
        #expect(StorageLensStore.snapshot(for: "/elsewhere", from: url) == nil)
    }

    @Test func savingTheSameRootReplacesRatherThanAccumulates() throws {
        let url = try storeURL("replace")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let early = Date(timeIntervalSince1970: 1_800_000_000)

        StorageLensStore.saveInBackground(
            StorageLensSnapshot(root: "/root", report: report(totalBytes: 1), completedAt: early), to: url)
        StorageLensStore.saveInBackground(
            StorageLensSnapshot(root: "/root", report: report(totalBytes: 2),
                                completedAt: early.addingTimeInterval(60)), to: url)
        StorageLensStore.waitForPendingWrites()

        let all = StorageLensStore.load(from: url)
        #expect(all.count == 1)
        #expect(all.first?.report.totalBytes == 2)
    }

    @Test func onlyTheMostRecentRootsAreKept() throws {
        let url = try storeURL("cap")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        for i in 0...(StorageLensStore.maxRoots) {
            StorageLensStore.saveInBackground(
                StorageLensSnapshot(root: "/root\(i)", report: report(totalBytes: i),
                                    completedAt: base.addingTimeInterval(Double(i))), to: url)
        }
        StorageLensStore.waitForPendingWrites()

        let all = StorageLensStore.load(from: url)
        #expect(all.count == StorageLensStore.maxRoots)
        #expect(StorageLensStore.snapshot(for: "/root0", from: url) == nil)          // oldest dropped
        #expect(StorageLensStore.snapshot(for: "/root\(StorageLensStore.maxRoots)", from: url) != nil)
    }

    @Test func aCorruptOrForeignSchemaFileLoadsAsEmpty() throws {
        let url = try storeURL("corrupt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        #expect(StorageLensStore.load(from: url).isEmpty)
        try Data("{not json".utf8).write(to: url)
        #expect(StorageLensStore.load(from: url).isEmpty)
        try Data(#"{"schema":999,"snapshots":[]}"#.utf8).write(to: url)
        #expect(StorageLensStore.load(from: url).isEmpty)
    }

    // MARK: The decode memo

    /// A second read is answered from memory, not the file. `restoreStorageLens` has several
    /// triggers, and its "nothing displayed yet" guard never engages for a root with no saved
    /// snapshot, so without the memo every pane move would re-decode every saved root on the main
    /// actor. Proved by removing read permission, which leaves the stamp (date and size) unchanged:
    /// an answer that still names the snapshot came from the memo. The control at the end drops the
    /// memo and the same call answers empty.
    @Test func aSecondLoadIsAnsweredFromTheMemoRatherThanTheFile() throws {
        let url = try storeURL("memo")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        StorageLensStore.forgetDecodeMemo(for: url)
        StorageLensStore.saveInBackground(
            StorageLensSnapshot(root: "/root", report: report(),
                                completedAt: Date(timeIntervalSince1970: 1_800_000_000)), to: url)
        StorageLensStore.waitForPendingWrites()
        #expect(StorageLensStore.load(from: url).count == 1,
                "the fixture never saved, so nothing below is measuring anything")

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect(StorageLensStore.load(from: url).count == 1,
                "the second read went back to the file — the decode is not memoised, and a root with no snapshot re-reads on every trigger forever")

        StorageLensStore.forgetDecodeMemo(for: url)
        #expect(StorageLensStore.load(from: url).isEmpty,
                "the file is still readable, so the check above proved nothing about the memo")
    }

    /// A save invalidates the memo unprompted. The memo is keyed on the file's modification date and
    /// size, and `write(_:to:)` is atomic, so the replacement carries a fresh date. The two payloads
    /// differ by one digit, so the size is unchanged and only the date separates them: a memo keyed
    /// on path and size alone fails here.
    @Test func aSaveInvalidatesTheMemoWithoutBeingTold() throws {
        let url = try storeURL("memo-invalidate")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        StorageLensStore.forgetDecodeMemo(for: url)

        StorageLensStore.saveInBackground(
            StorageLensSnapshot(root: "/root", report: report(totalBytes: 1), completedAt: at), to: url)
        StorageLensStore.waitForPendingWrites()
        #expect(StorageLensStore.load(from: url).first?.report.totalBytes == 1)

        StorageLensStore.saveInBackground(
            StorageLensSnapshot(root: "/root", report: report(totalBytes: 2), completedAt: at), to: url)
        StorageLensStore.waitForPendingWrites()
        #expect(StorageLensStore.load(from: url).first?.report.totalBytes == 2,
                "the memo outlived the write that replaced the file underneath it")
    }

    /// The absent case memoises too, and matters most: a root nobody has analysed shows nothing, so
    /// the "already showing something" guard never engages and the read would repeat all session.
    @Test func anAbsentFileMemoisesAndStillNoticesOneAppearing() throws {
        let url = try storeURL("memo-absent")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StorageLensStore.forgetDecodeMemo(for: url)

        #expect(StorageLensStore.load(from: url).isEmpty)
        #expect(StorageLensStore.load(from: url).isEmpty)

        StorageLensStore.saveInBackground(
            StorageLensSnapshot(root: "/root", report: report(),
                                completedAt: Date(timeIntervalSince1970: 1_800_000_000)), to: url)
        StorageLensStore.waitForPendingWrites()
        #expect(StorageLensStore.load(from: url).count == 1,
                "the memo of an ABSENT file outlived the file appearing, so a saved report could never be restored")
    }

    // MARK: Through the manager

    /// A manager saving to its own store, that has scanned a root holding a 40 KB file once, with
    /// the save awaited. `prepare` runs before the scan, given the root and the store. `remove()`
    /// deletes both.
    @MainActor
    private func scannedManager(_ name: String, prepare: (URL, URL) throws -> Void = { _, _ in }) async throws
    -> (manager: FileSyncManager, root: URL, url: URL, remove: () -> Void) {
        let root = try makeCanonicalTempRoot(prefix: "StorageRestoreScan-\(name)")
        let url = try storeURL(name)
        let remove = {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        try write(root.appendingPathComponent("a/big.bin"), bytes: 40_000)
        try prepare(root, url)
        let manager = FileSyncManager()
        manager.storageLensStoreURL = url
        await manager.buildStorageLens(root: root)
        // The build saves in the background; awaited so the write can't land after `remove` has
        // deleted the store's folder and recreate it.
        StorageLensStore.waitForPendingWrites()
        return (manager, root, url, remove)
    }

    @MainActor
    @Test func abuildSavesAndAFreshManagerRestoresIt() async throws {
        let (first, root, url, remove) = try await scannedManager("manager")
        defer { remove() }
        let scanned = try #require(first.storageLensReport)
        #expect(!first.storageLensLifecycle.isRestored)               // it was scanned, not restored
        #expect(first.storageLensLifecycle.completedAt != nil)

        // A fresh manager, standing in for the next launch.
        let second = FileSyncManager()
        second.storageLensStoreURL = url
        #expect(second.restoreStorageLens(root: root))
        #expect(second.storageLensReport == scanned)                  // same numbers
        #expect(second.storageLensLifecycle.hasCompleted)
        #expect(second.storageLensLifecycle.isRestored)               // …and it says so
        #expect(second.storageLensLifecycle.completedAt == first.storageLensLifecycle.completedAt)
    }

    @MainActor
    @Test func restoringStampsTheORIGINALScanTimeNotTheReloadTime() async throws {
        // The freshness marker says how old the reading is. Stamping it at reload would make every
        // relaunch claim the numbers were current.
        let url = try storeURL("stamp")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let longAgo = Date(timeIntervalSince1970: 1_700_000_000)
        StorageLensStore.saveInBackground(
            StorageLensSnapshot(root: "/root", report: report(), completedAt: longAgo), to: url)
        StorageLensStore.waitForPendingWrites()

        let manager = FileSyncManager()
        manager.storageLensStoreURL = url
        #expect(manager.restoreStorageLens(root: URL(fileURLWithPath: "/root")))
        #expect(manager.storageLensLifecycle.completedAt == longAgo)
    }

    @MainActor
    @Test func restoringNeverReplacesResultsAlreadyOnScreen() async throws {
        // A saved snapshot for this root whose numbers differ from what a scan would produce, then
        // the scan, so fresh results are on screen.
        let (manager, root, _, remove) = try await scannedManager("guard") { root, url in
            StorageLensStore.saveInBackground(
                StorageLensSnapshot(root: root.path, report: report(totalBytes: 999),
                                    completedAt: Date(timeIntervalSince1970: 1_700_000_000)), to: url)
            StorageLensStore.waitForPendingWrites()
        }
        defer { remove() }
        let fresh = try #require(manager.storageLensReport)

        #expect(!manager.restoreStorageLens(root: root))               // declines
        #expect(manager.storageLensReport == fresh)                    // and changes nothing
        #expect(!manager.storageLensLifecycle.isRestored)
    }

    @MainActor
    @Test func withNoStoreURLNothingIsSavedOrRestored() async throws {
        // The default for the CLI and every other Storage test, which is why none of them reach the
        // real file.
        let root = try makeCanonicalTempRoot(prefix: "StorageRestoreNoURL")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("a/big.bin"), bytes: 40_000)

        let manager = FileSyncManager()
        #expect(manager.storageLensStoreURL == nil)
        await manager.buildStorageLens(root: root)
        StorageLensStore.waitForPendingWrites()
        #expect(manager.storageLensReport != nil)                      // the scan still works

        manager.clearStorageLens()
        #expect(!manager.restoreStorageLens(root: root))                // nothing to restore
    }

    @MainActor
    @Test func aProviderSwitchClearsTheScreenButKeepsTheSavedReport() async throws {
        // `clearStorageLens` runs on an ordinary provider switch. Deleting the saved snapshot there
        // would lose the other provider's report every time you glanced at this one.
        let (manager, root, _, remove) = try await scannedManager("switch")
        defer { remove() }

        manager.clearStorageLens()
        #expect(manager.storageLensReport == nil)                      // screen cleared
        #expect(manager.storageLensLifecycle.completedAt == nil)
        #expect(manager.restoreStorageLens(root: root))                 // saved report survived
        #expect(manager.storageLensLifecycle.isRestored)
    }

    @MainActor
    @Test func forgettingErasesTheSavedReport() async throws {
        let (manager, root, _, remove) = try await scannedManager("forget")
        defer { remove() }

        manager.forgetStoredStorageLens(root: root.path)
        StorageLensStore.waitForPendingWrites()
        manager.clearStorageLens()
        #expect(!manager.restoreStorageLens(root: root))
    }

    @MainActor
    @Test func forgettingEverythingLeavesNoFileBehind() async throws {
        // The Settings readout asks what this store occupies, and must answer "nothing" after a
        // Clear. An empty list writes no file: even `{"schema":1,"snapshots":[]}` reads as `[]` to
        // `load` but shows in a size readout as a Clear that hadn't worked.
        let (manager, root, url, remove) = try await scannedManager("forget-all")
        defer { remove() }
        #expect(manager.storedStorageLensSizeOnDisk() != nil)

        manager.forgetStoredStorageLens()
        StorageLensStore.waitForPendingWrites()
        #expect(manager.storedStorageLensSizeOnDisk() == nil, "a cleared store must occupy nothing")
        #expect(StorageLensStore.load(from: url).isEmpty)
    }

    @MainActor
    @Test func aRescanClearsTheRestoredFlag() async throws {
        // Once you re-analyze, the numbers are live again and the "from your last scan" marker
        // must stop claiming otherwise.
        let (manager, root, _, remove) = try await scannedManager("rescan")
        defer { remove() }
        manager.clearStorageLens()
        #expect(manager.restoreStorageLens(root: root))
        #expect(manager.storageLensLifecycle.isRestored)

        await manager.buildStorageLens(root: root)
        StorageLensStore.waitForPendingWrites()     // the rescan saves too — see the guard test
        #expect(!manager.storageLensLifecycle.isRestored)
    }
}

/// Forget-all and provider switches clear every saved and displayed Storage result.
@Suite struct StorageLensAuditTests {

    @MainActor
    @Test func forgettingEverythingClearsAllRootsNotJustOne() async throws {
        // `forgetStoredStorageLens()` with no argument is the forget-all path, which an "erase saved
        // data" control would call, so it must not quietly clear a single root.
        let url = try makeCanonicalTempRoot(prefix: "StorageAuditForgetAll")
            .appendingPathComponent("storage-lens.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        for r in ["/one", "/two", "/three"] {
            StorageLensStore.saveInBackground(
                StorageLensSnapshot(root: r,
                                    report: StorageLensReport(treemap: [], largest: [], stale: [],
                                                              reclaimCandidates: [], totalBytes: 1,
                                                              fileCount: 0, staleCount: 0,
                                                              reclaimCount: 0, reclaimableBytes: 0),
                                    completedAt: at), to: url)
        }
        StorageLensStore.waitForPendingWrites()
        #expect(StorageLensStore.load(from: url).count == 3)

        let manager = FileSyncManager()
        manager.storageLensStoreURL = url
        manager.forgetStoredStorageLens()
        StorageLensStore.waitForPendingWrites()

        #expect(StorageLensStore.load(from: url).isEmpty)
    }

    @MainActor
    @Test func aProviderSwitchClearsTheStorageReport() async throws {
        // `clearLensResultsForProviderSwitch` clears every lens result belonging to the provider
        // being left, Storage included. Otherwise the previous account's report stays on screen with
        // a folder chip naming a root the window no longer shows, under a freshness marker.
        let root = try makeCanonicalTempRoot(prefix: "StorageAuditSwitch")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 40_000).write(to: root.appendingPathComponent("a/big.bin"))

        let manager = FileSyncManager()
        await manager.buildStorageLens(root: root)
        #expect(manager.storageLensReport != nil)

        manager.clearLensResultsForProviderSwitch()

        #expect(manager.storageLensReport == nil)
        #expect(manager.storageLensRoot == nil)
        #expect(!manager.storageLensLifecycle.hasCompleted)
        #expect(manager.storageLensLifecycle.completedAt == nil)
        #expect(!manager.storageLensLifecycle.isRestored)
    }
}
