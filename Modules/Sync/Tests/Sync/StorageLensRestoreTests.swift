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
            stale: [], reclaimCandidates: [], totalBytes: totalBytes)
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

    // MARK: Through the manager

    @MainActor
    @Test func abuildSavesAndAFreshManagerRestoresIt() async throws {
        let root = try makeCanonicalTempRoot(prefix: "StorageRestoreScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try storeURL("manager")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write(root.appendingPathComponent("a/big.bin"), bytes: 40_000)

        let first = FileSyncManager()
        first.storageLensStoreURL = url
        await first.buildStorageLens(root: root)
        StorageLensStore.waitForPendingWrites()
        let scanned = try #require(first.storageLensReport)
        #expect(!first.storageLensLifecycle.isRestored)               // it was scanned, not restored
        #expect(first.storageLensLifecycle.completedAt != nil)

        // A fresh manager, standing in for the next launch.
        let second = FileSyncManager()
        second.storageLensStoreURL = url
        #expect(second.restoreStorageLens(root: root))
        #expect(second.storageLensReport == scanned)                  // same numbers
        #expect(second.hasBuiltStorageLens)
        #expect(second.storageLensLifecycle.isRestored)               // …and it says so
        #expect(second.storageLensLifecycle.completedAt == first.storageLensLifecycle.completedAt)
    }

    @MainActor
    @Test func restoringStampsTheORIGINALScanTimeNotTheReloadTime() async throws {
        // The freshness marker exists to say how old the READING is. Stamping it at reload would
        // make every relaunch claim the numbers were current, which is the one thing restoring
        // must not do.
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
        let root = try makeCanonicalTempRoot(prefix: "StorageRestoreGuard")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try storeURL("guard")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write(root.appendingPathComponent("a/big.bin"), bytes: 40_000)

        // A saved snapshot for this root whose numbers differ from what a scan would produce.
        StorageLensStore.saveInBackground(
            StorageLensSnapshot(root: root.path, report: report(totalBytes: 999),
                                completedAt: Date(timeIntervalSince1970: 1_700_000_000)), to: url)
        StorageLensStore.waitForPendingWrites()

        let manager = FileSyncManager()
        manager.storageLensStoreURL = url
        await manager.buildStorageLens(root: root)                     // fresh results on screen
        let fresh = try #require(manager.storageLensReport)

        #expect(!manager.restoreStorageLens(root: root))               // declines
        #expect(manager.storageLensReport == fresh)                    // and changes nothing
        #expect(!manager.storageLensLifecycle.isRestored)
    }

    @MainActor
    @Test func withNoStoreURLNothingIsSavedOrRestored() async throws {
        // The default for the CLI and every existing Storage test — and the reason none of them
        // reach the real file.
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
        // would make restoring nearly useless — you would lose the other provider's report every
        // time you glanced at this one.
        let root = try makeCanonicalTempRoot(prefix: "StorageRestoreSwitch")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try storeURL("switch")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write(root.appendingPathComponent("a/big.bin"), bytes: 40_000)

        let manager = FileSyncManager()
        manager.storageLensStoreURL = url
        await manager.buildStorageLens(root: root)
        StorageLensStore.waitForPendingWrites()

        manager.clearStorageLens()
        #expect(manager.storageLensReport == nil)                      // screen cleared
        #expect(manager.storageLensLifecycle.completedAt == nil)
        #expect(manager.restoreStorageLens(root: root))                 // saved report survived
        #expect(manager.storageLensLifecycle.isRestored)
    }

    @MainActor
    @Test func forgettingErasesTheSavedReport() async throws {
        let root = try makeCanonicalTempRoot(prefix: "StorageRestoreForget")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try storeURL("forget")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write(root.appendingPathComponent("a/big.bin"), bytes: 40_000)

        let manager = FileSyncManager()
        manager.storageLensStoreURL = url
        await manager.buildStorageLens(root: root)
        StorageLensStore.waitForPendingWrites()

        manager.forgetStoredStorageLens(root: root.path)
        StorageLensStore.waitForPendingWrites()
        manager.clearStorageLens()
        #expect(!manager.restoreStorageLens(root: root))
    }

    @MainActor
    @Test func aRescanClearsTheRestoredFlag() async throws {
        // Once you re-analyze, the numbers are live again and the "from your last scan" marker
        // must stop claiming otherwise.
        let root = try makeCanonicalTempRoot(prefix: "StorageRestoreRescan")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try storeURL("rescan")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write(root.appendingPathComponent("a/big.bin"), bytes: 40_000)

        let manager = FileSyncManager()
        manager.storageLensStoreURL = url
        await manager.buildStorageLens(root: root)
        StorageLensStore.waitForPendingWrites()
        manager.clearStorageLens()
        #expect(manager.restoreStorageLens(root: root))
        #expect(manager.storageLensLifecycle.isRestored)

        await manager.buildStorageLens(root: root)
        #expect(!manager.storageLensLifecycle.isRestored)
    }
}
