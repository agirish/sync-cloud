import Testing
import Foundation
@testable import Sync

/// Manager-level coverage for the Storage Lens lifecycle (`FileSyncManager+StorageLens.swift`):
/// start / cancel / clear / restart against real temp trees, mirroring the duplicates lifecycle
/// tests. The pure analyzer already has its own suite (`StorageLensTests`); these pin the glue —
/// task replacement, the stale-report guard, and the publish-with-results discipline.
@Suite struct FileSyncManagerStorageLensTests {

    private func write(_ url: URL, bytes: Int, fill: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    @MainActor
    @Test func buildPublishesReportForScannedTree() async throws {
        let root = try makeCanonicalTempRoot(prefix: "LensTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Docs/a.pdf"), bytes: 5000, fill: 0x41)
        try write(root.appendingPathComponent("Docs/b.pdf"), bytes: 3000, fill: 0x42)
        try write(root.appendingPathComponent("loose.txt"), bytes: 100, fill: 0x43)

        let manager = FileSyncManager()
        manager.startBuildStorageLens(root: root)
        await manager.storageLensTask?.value

        let report = try #require(manager.storageLensReport)
        #expect(report.totalBytes == 8100)
        // Folder rolled up bottom-up plus the synthetic "Files" bucket for the loose file.
        #expect(report.treemap.map(\.name) == ["Docs", "Files"])
        #expect(report.treemap.first?.bytes == 8000)
        #expect(report.largest.first?.name == "a.pdf")
        // Completion labels: root + has-completed publish WITH the results.
        #expect(manager.storageLensRoot == root)
        #expect(manager.hasBuiltStorageLens)
        #expect(manager.isBuildingStorageLens == false)
        #expect(manager.storageLensStatus == "")
        #expect(manager.storageLensProgress == 0)
    }

    @MainActor
    @Test func buildThreadsOptionsThroughToTheAnalyzer() async throws {
        let root = try makeCanonicalTempRoot(prefix: "LensTest")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old-big.bin")
        try write(old, bytes: 5000, fill: 0x4F)
        try write(root.appendingPathComponent("new-small.txt"), bytes: 10, fill: 0x4E)
        // Age the big file well past the (tightened) thresholds below.
        let monthsAgo = Date().addingTimeInterval(-40 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: monthsAgo], ofItemAtPath: old.path)

        let manager = FileSyncManager()
        let options = StorageLensOptions(staleThresholdDays: 30, reclaimStaleDays: 30, minReclaimBytes: 1000)
        manager.startBuildStorageLens(root: root, options: options)
        await manager.storageLensTask?.value

        let report = try #require(manager.storageLensReport)
        #expect(report.stale.map(\.name) == ["old-big.bin"])
        #expect(report.reclaimCandidates.map(\.name) == ["old-big.bin"])
    }

    /// The stale-report guard's core promise: a cancelled rebuild of a DIFFERENT folder must
    /// neither replace the on-screen report nor relabel it with the new root.
    @MainActor
    @Test func cancelMidBuildLeavesPriorReportAndLabelsIntact() async throws {
        let rootA = try makeCanonicalTempRoot(prefix: "LensTest")
        defer { try? FileManager.default.removeItem(at: rootA) }
        try write(rootA.appendingPathComponent("Docs/a.bin"), bytes: 4000, fill: 0x41)
        let rootB = try makeCanonicalTempRoot(prefix: "LensTest")
        defer { try? FileManager.default.removeItem(at: rootB) }
        try write(rootB.appendingPathComponent("Other/b.bin"), bytes: 9000, fill: 0x42)

        let manager = FileSyncManager()
        manager.startBuildStorageLens(root: rootA)
        await manager.storageLensTask?.value
        let before = try #require(manager.storageLensReport)

        // Rebuild of a different folder, cancelled before it can publish.
        manager.startBuildStorageLens(root: rootB)
        manager.cancelBuildStorageLens()
        await manager.storageLensTask?.value

        #expect(manager.storageLensReport == before, "a cancelled build must not replace the prior report")
        #expect(manager.storageLensRoot == rootA, "the label must still match the on-screen results")
        #expect(manager.hasBuiltStorageLens, "hasCompleted flips only on completion")
        #expect(manager.isBuildingStorageLens == false)
        #expect(manager.storageLensStatus == "")
        #expect(manager.storageLensProgress == 0)
    }

    @MainActor
    @Test func cancelWithNoRunningBuildIsSafe() {
        let manager = FileSyncManager()
        manager.cancelBuildStorageLens()   // no task in flight
        #expect(manager.isBuildingStorageLens == false)
        #expect(manager.hasBuiltStorageLens == false)
        #expect(manager.storageLensReport == nil)
    }

    /// Provider switch: clearStorageLens wipes the report AND its labels, so a report built for
    /// one provider can never be shown under another.
    @MainActor
    @Test func clearStorageLensWipesReportAndLabels() async throws {
        let root = try makeCanonicalTempRoot(prefix: "LensTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Docs/a.bin"), bytes: 4000, fill: 0x41)

        let manager = FileSyncManager()
        manager.startBuildStorageLens(root: root)
        await manager.storageLensTask?.value
        #expect(manager.storageLensReport != nil)

        manager.clearStorageLens()

        #expect(manager.storageLensReport == nil)
        #expect(manager.storageLensRoot == nil)
        #expect(manager.hasBuiltStorageLens == false)
    }

    @MainActor
    @Test func clearStorageLensCancelsAnInFlightBuild() async throws {
        let root = try makeCanonicalTempRoot(prefix: "LensTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Docs/a.bin"), bytes: 4000, fill: 0x41)

        let manager = FileSyncManager()
        manager.startBuildStorageLens(root: root)
        manager.clearStorageLens()                 // simulate a provider switch mid-build
        await manager.storageLensTask?.value       // let the cancelled build unwind

        #expect(manager.storageLensReport == nil, "the cancelled build must not republish")
        #expect(manager.hasBuiltStorageLens == false)
        #expect(manager.storageLensRoot == nil)
        #expect(manager.isBuildingStorageLens == false)
    }

    /// Restart supersedes: starting a new build cancels the in-flight one (restartedScanTask), and
    /// only the NEWEST build's report and root land — never the superseded one's.
    @MainActor
    @Test func restartSupersedesTheInFlightBuild() async throws {
        let rootA = try makeCanonicalTempRoot(prefix: "LensTest")
        defer { try? FileManager.default.removeItem(at: rootA) }
        try write(rootA.appendingPathComponent("Docs/a.bin"), bytes: 4000, fill: 0x41)
        let rootB = try makeCanonicalTempRoot(prefix: "LensTest")
        defer { try? FileManager.default.removeItem(at: rootB) }
        try write(rootB.appendingPathComponent("Other/b.bin"), bytes: 9000, fill: 0x42)

        let manager = FileSyncManager()
        manager.startBuildStorageLens(root: rootA)   // superseded before it can publish
        manager.startBuildStorageLens(root: rootB)
        await manager.storageLensTask?.value

        let report = try #require(manager.storageLensReport)
        #expect(report.totalBytes == 9000, "only the newest build's report may land")
        #expect(manager.storageLensRoot == rootB)
        #expect(manager.hasBuiltStorageLens)
        #expect(manager.isBuildingStorageLens == false)
    }

    /// Re-entry guard: a direct build call while another build is (still) marked running drops
    /// itself — restartedScanTask is the only sanctioned way to replace an in-flight build.
    @MainActor
    @Test func buildIsDroppedWhileAnotherBuildIsMarkedRunning() async throws {
        let root = try makeCanonicalTempRoot(prefix: "LensTest")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Docs/a.bin"), bytes: 4000, fill: 0x41)

        let manager = FileSyncManager()
        manager.isBuildingStorageLens = true
        await manager.buildStorageLens(root: root)

        #expect(manager.storageLensReport == nil, "the dropped build must not publish")
        #expect(manager.hasBuiltStorageLens == false)
        #expect(manager.isBuildingStorageLens, "the dropped call must not clear the real build's running flag")
    }
}
