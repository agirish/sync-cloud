import Testing
import Foundation
@testable import Sync

/// Pins the scan-time checksum pass (`autoVerifySameSizePairs`): identical same-size pairs are
/// hidden via `verifiedSameDifferenceIds`, differing pairs stay, and stale or unsafe passes
/// (superseded scan, operations in flight) publish nothing. Real temp files — the checksummer
/// reads from the real filesystem.
@Suite struct AutoVerifyOnScanTests {

    // The mid-hash gate lives in TestSupport.swift (`FirstStatGate`) — shared with
    // VerifyAllWithChecksumTests, which stages the same race against the manual pass.

    @MainActor
    private func makeFixture(fileManager: FileManaging = FileManager.default) throws -> (manager: FileSyncManager, identical: FileDifference, differed: FileDifference, cleanup: () -> Void) {
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

        let manager = FileSyncManager(fileManager: fileManager)
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

    /// A file operation that starts — and even FINISHES — while the pass is hashing must void
    /// the whole batch: the pre-operation "identical" verdicts describe bytes the operation may
    /// have rewritten, and if the hash drains before the operation's rescan bumps
    /// `scanRequestGeneration`, folding them into `verifiedSameDifferenceIds` would silently
    /// show a real difference as in-sync until the next scan. The entry guard can't see this
    /// (`activeFileOperationsCount` is back to 0 by commit time) — only the operations epoch can.
    @MainActor
    @Test(.parksAThread) func testOperationRunningMidHashDiscardsTheBatch() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        // Start the pass; its first checksum stat parks on the gate.
        let pass = Task { @MainActor in
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }
        await awaitSignal(gate.entered)

        // A complete file operation runs while the hash is parked: count goes 1 → 0, the epoch
        // moves, and — the exact race — `scanRequestGeneration` has NOT been bumped yet.
        let generationBefore = manager.scanRequestGeneration
        let epochBefore = manager.fileOperationsEpoch
        await manager.enqueueFileOperation { }
        #expect(manager.activeFileOperationsCount == 0)
        #expect(manager.scanRequestGeneration == generationBefore)

        gate.release.signal()
        await pass.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the pass was never actually held mid-hash")

        #expect(manager.verifiedSameDifferenceIds.isEmpty, "verdicts hashed across a file operation must be discarded")
        #expect(manager.differences.count == 2)
        #expect(manager.fileOperationsEpoch > epochBefore, "the operation must have moved the epoch")
    }

    /// The positive control for the test above, on the SAME gated fixture. `isEmpty` is also
    /// what you see if the gate broke hashing outright or the candidate filter matched nothing,
    /// so without this the discard assertion could pass vacuously: park the pass, run NO
    /// operation, release, and the identical pair must be hidden exactly as on a plain fixture.
    @MainActor
    @Test(.parksAThread) func testGatedFixtureStillVerifiesWhenNoOperationRuns() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        let pass = Task { @MainActor in
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }
        await awaitSignal(gate.entered)
        let epochBefore = manager.fileOperationsEpoch
        gate.release.signal()
        await pass.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the pass was never actually held mid-hash")

        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id],
                "the gated fixture must still hash and hide the identical pair")
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
        #expect(manager.fileOperationsEpoch == epochBefore)
    }

    /// A DECLINED confirmation must not void the batch. `preCountFileOperation()` runs before
    /// the transfer confirmer so the quit guard and the hashing exclusions see the pending
    /// transfer, and `cancelPreCountedFileOperation()` puts the count back when the user says
    /// no — but a monotonic epoch cannot be un-bumped. Bumping it at pre-count time therefore
    /// discarded a whole pass's verdicts for an operation that never touched the disk, and
    /// because nothing ran, nothing sent `refreshSubject`: no rescan re-ran the pass, so those
    /// rows stayed listed as differences until the user rescanned by hand. The epoch moves at
    /// enqueue time instead, so a decline leaves the batch alone.
    @MainActor
    @Test(.parksAThread) func testDeclinedConfirmationDoesNotVoidTheBatch() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        // A separate mock disk for the transfer: the decline means nothing is ever read from it,
        // and the fixture's real files stay the checksummer's business alone.
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let pass = Task { @MainActor in
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }
        await awaitSignal(gate.entered)

        // The user opens a copy and declines its confirmation while the hash is parked.
        var prompted = false
        manager.transferConfirmer = { _ in prompted = true; return false }
        let copied = await manager.copyItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            toPath: "/dst",
            fileManager: mockFM
        )
        #expect(prompted, "the transfer must actually have reached the confirmation prompt")
        #expect(copied.isEmpty)
        #expect(manager.activeFileOperationsCount == 0)

        gate.release.signal()
        await pass.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the pass was never actually held mid-hash")

        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id],
                "a declined confirmation runs no I/O, so it must not discard the batch")
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
    }

    /// The counterpart to the test above, and the pin on a deliberate asymmetry: the orphaned-temp
    /// sweep writes to the filesystem mid-hash without going through `enqueueFileOperation` and
    /// without moving the epoch, and the batch must still commit. That is not an oversight —
    /// `sweepOrphanedTempArtifacts` only ever REMOVES age-gated `.tmp_<UUID>` artifacts, and a
    /// removal cannot make a differing pair hash identical (it can only fail the read). Making it
    /// bump the epoch would void the checksum batch on essentially every refresh, since the sweep
    /// runs at the tail of the same refresh that spawned the pass. This test fails if someone
    /// "fixes" the sweep into the epoch blind.
    @MainActor
    @Test(.parksAThread) func testOrphanSweepDuringTheHashDoesNotDiscardTheBatch() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        // A real orphaned staging artifact, old enough to reap, under its own root — so the thing
        // the sweep trashes is never one of the files being hashed.
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "AutoVerifySweep")
        defer { try? fm.removeItem(at: root) }
        let orphan = root.appendingPathComponent(".tmp_\(UUID().uuidString)")
        try "partial".write(to: orphan, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(OrphanSweeper.minimumAge + 60))],
            ofItemAtPath: orphan.path
        )
        manager.rawLeftTree = await FileSyncManager.buildTree(url: root, sortOption: .name)

        // Start the pass; its first checksum stat parks on the gate.
        let pass = Task { @MainActor in
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }
        await awaitSignal(gate.entered)

        let epochBefore = manager.fileOperationsEpoch
        #expect(manager.sweepOrphanedTempArtifacts(), "the sweep must have been allowed to look")

        // Bounded premise-wait: the removal is detached, and the whole point of the test is that it
        // lands INSIDE the hash window. Require it rather than carrying on against a maybe — an
        // un-required wait would leave the assertions below passing for the wrong reason forever.
        var trashed = false
        for _ in 0..<200 {
            if !fm.fileExists(atPath: orphan.path) { trashed = true; break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try #require(trashed, "the sweep must have trashed the artifact while the hash was parked")

        // It took part in neither mechanism: not the epoch, not the operation queue.
        #expect(manager.fileOperationsEpoch == epochBefore)
        #expect(manager.activeFileOperationsCount == 0)

        gate.release.signal()
        await pass.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the pass was never actually held mid-hash")

        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id],
                "a removal-only sweep cannot falsify an identical verdict, so the batch must commit")
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
    }

    /// A transfer whose confirmation modal is STILL PENDING at commit time (pre-counted, epoch
    /// unmoved) must not void the batch. No I/O has run — the epoch bump in
    /// `enqueueFileOperation` still stands between the prompt and the first byte written — so
    /// the verdicts are sound; and if the user then DECLINES, nothing runs, nothing refreshes,
    /// and a discarded batch would leave hashed-identical rows listed until a manual rescan
    /// (the stuck-rows symptom the commit-time count term re-admitted). If the user ACCEPTS,
    /// the operation's own completion rescan clears `verifiedSameDifferenceIds` and regenerates
    /// every row id, superseding whatever committed here.
    @MainActor
    @Test(.parksAThread) func testPendingPreCountedPromptAtCommitDoesNotVoidTheBatch() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        let pass = Task { @MainActor in
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }
        await awaitSignal(gate.entered)

        // The prompt goes up mid-hash and is still up at commit: counted, epoch unmoved.
        let epochBefore = manager.fileOperationsEpoch
        manager.preCountFileOperation()
        #expect(manager.activeFileOperationsCount == 1)
        #expect(manager.fileOperationsEpoch == epochBefore)

        gate.release.signal()
        await pass.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the pass was never actually held mid-hash")

        // The user declines after the pass committed; the batch must already be in place.
        manager.cancelPreCountedFileOperation()
        #expect(manager.activeFileOperationsCount == 0)
        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id],
                "a pending prompt has written nothing, so the batch must commit")
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
    }

    /// Same shape for `syncAll`'s prepare phase: the bulk flag is latched before the batch
    /// stat pass and the collision prompts, all read-only — every write goes through the
    /// single `enqueueFileOperation` afterwards, which bumps the epoch first. A commit that
    /// beats that bump commits sound pre-write verdicts (and the run's completion rescan
    /// supersedes them); a commit after it is discarded on the epoch.
    @MainActor
    @Test(.parksAThread) func testBulkSyncPreparePhaseAtCommitDoesNotVoidTheBatch() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        let pass = Task { @MainActor in
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }
        await awaitSignal(gate.entered)

        // syncAll latches the flag before its read-only prepare work; nothing written yet.
        let epochBefore = manager.fileOperationsEpoch
        manager.isBulkSyncRunning = true
        defer { manager.isBulkSyncRunning = false }
        #expect(manager.fileOperationsEpoch == epochBefore)

        gate.release.signal()
        await pass.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the pass was never actually held mid-hash")

        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id],
                "the prepare phase has written nothing, so the batch must commit")
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
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
