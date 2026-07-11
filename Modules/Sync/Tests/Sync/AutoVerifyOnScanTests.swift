import Testing
import Foundation
@testable import Sync

/// Pins the scan-time checksum pass (`autoVerifySameSizePairs`): identical same-size pairs are
/// hidden via `verifiedSameDifferenceIds`, differing pairs stay, and stale or unsafe passes
/// (superseded scan, operations in flight) publish nothing. Real temp files — the checksummer
/// reads from the real filesystem.
@Suite struct AutoVerifyOnScanTests {

    @MainActor
    private func makeFixture() throws -> (manager: FileSyncManager, identical: FileDifference, differed: FileDifference, cleanup: () -> Void) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AutoVerify-\(UUID().uuidString)")
        let left = base.appendingPathComponent("left")
        let right = base.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)

        try Data("identical".utf8).write(to: left.appendingPathComponent("same.txt"))
        try Data("identical".utf8).write(to: right.appendingPathComponent("same.txt"))
        try Data("aaaa".utf8).write(to: left.appendingPathComponent("diff.txt"))
        try Data("bbbb".utf8).write(to: right.appendingPathComponent("diff.txt"))

        func dateDiff(_ name: String, size: Int) -> FileDifference {
            FileDifference(
                relativePath: name,
                leftItemPath: left.appendingPathComponent(name).path,
                rightItemPath: right.appendingPathComponent(name).path,
                type: .differentDates,
                action: .copyToRight,
                description: "Different dates",
                leftFileSize: size,
                rightFileSize: size
            )
        }
        let identical = dateDiff("same.txt", size: 9)
        let differed = dateDiff("diff.txt", size: 4)

        let manager = FileSyncManager()
        manager.autoVerifySameSizeDuringScan = true
        manager.rawDifferences = [identical, differed]
        manager.differences = [identical, differed]
        return (manager, identical, differed, { try? fm.removeItem(at: base) })
    }

    @MainActor
    @Test func testIdenticalPairsAreHiddenAndDifferingPairsStay() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)

        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id])
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
        // Silent by design: no progress UI, no copy-identical offer, no banner.
        #expect(manager.verifyAllProgress == nil)
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.banner == nil)
    }

    @MainActor
    @Test func testSupersededScanPublishesNothing() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        let staleGeneration = manager.scanRequestGeneration
        manager.scanRequestGeneration += 1
        await manager.autoVerifySameSizePairs(scanGeneration: staleGeneration)

        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.differences.count == 2)
    }

    @MainActor
    @Test func testSkipsWhileOperationsAreInFlight() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        manager.activeFileOperationsCount = 1
        await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
    }

    @MainActor
    @Test func testDisabledToggleIsANoOp() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        manager.autoVerifySameSizeDuringScan = false
        await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
    }
}
