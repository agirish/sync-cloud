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
        let pair = try makeSameSizePairFixture(prefix: "AutoVerify")
        let manager = FileSyncManager(fileManager: fileManager)
        manager.autoVerifySameSizeDuringScan = true
        manager.rawDifferences = [pair.identical, pair.differed]
        manager.differences = [pair.identical, pair.differed]
        return (manager, pair.identical, pair.differed, pair.cleanup)
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

    /// The scan-time pass keeps a 100 MB limit the hasher itself doesn't have: it runs unasked
    /// after every scan, so a pair over it stays listed for Verify All. Judged on the scan's
    /// recorded size: identical files recorded one byte over stay listed; at the limit, hidden.
    @MainActor
    @Test func pairsOverTheScanTimeLimitAreLeftForVerifyAll() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        func recorded(_ size: Int) -> FileDifference {
            FileDifference(relativePath: fixture.identical.relativePath,
                           leftItemPath: fixture.identical.leftItemPath,
                           rightItemPath: fixture.identical.rightItemPath,
                           type: .differentDates, action: .copyToRight, description: "Different dates",
                           leftFileSize: size, rightFileSize: size)
        }
        let atLimit = recorded(FileSyncManager.unaskedPassMaxFileBytes)
        let overLimit = recorded(FileSyncManager.unaskedPassMaxFileBytes + 1)
        manager.rawDifferences = [atLimit, overLimit]
        manager.differences = [atLimit, overLimit]

        await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)

        #expect(manager.verifiedSameDifferenceIds == [atLimit.id])
        #expect(manager.differences.map(\.id) == [overLimit.id])
    }

    /// The limit is checked against the files as they are when the pass reaches them, not only
    /// the size the scan recorded: a pair recorded at 9 bytes that has since grown one byte past
    /// the limit — a download still landing — is left listed, not read whole. The identical
    /// 9-byte pair in the test above, hidden, is the control.
    @MainActor
    @Test func aPairThatGrewPastTheLimitSinceTheScanIsNotRead() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        for path in [fixture.identical.leftItemPath, fixture.identical.rightItemPath] {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.truncate(atOffset: UInt64(FileSyncManager.unaskedPassMaxFileBytes + 1))
            try handle.close()
        }
        manager.rawDifferences = [fixture.identical]
        manager.differences = [fixture.identical]

        await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)

        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.differences.map(\.id) == [fixture.identical.id])
    }

    /// The limit is 100,000,000 bytes because the app shows sizes in decimal units, so the Settings
    /// help's "100 MB" is the limit as the user reads any file's size. A binary 100 MiB would format
    /// as "104.9 MB".
    @Test func theUnaskedLimitReadsAsTheHundredMegabytesTheHelpSays() {
        #expect(FileSyncManager.formatBytes(FileSyncManager.unaskedPassMaxFileBytes) == "100 MB")
        #expect(FileSyncManager.formatBytes(FileSyncManager.unaskedPassMaxFileBytes + 1_000_000) != "100 MB")
    }

    /// What keeps a scan-time pass from publishing.
    enum Spoiler: Sendable { case supersededScan, operationsInFlight, disabledToggle }

    /// A superseded scan's pass publishes nothing, the pass skips while operations are in flight,
    /// and the toggle off makes it a no-op.
    @MainActor
    @Test(arguments: [Spoiler.supersededScan, .operationsInFlight, .disabledToggle])
    func testASpoiledPassPublishesNothing(_ spoiler: Spoiler) async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        let generation = manager.scanRequestGeneration
        switch spoiler {
        case .supersededScan: manager.scanRequestGeneration += 1   // `generation` is now stale
        case .operationsInFlight: manager.activeFileOperationsCount = 1
        case .disabledToggle: manager.autoVerifySameSizeDuringScan = false
        }
        await manager.autoVerifySameSizePairs(scanGeneration: generation)

        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.differences.count == 2)
    }

    /// A file operation that starts, and even finishes, while the pass is hashing must void the
    /// batch: its "identical" verdicts describe bytes the operation may have rewritten, and if the
    /// hash drains before the rescan bumps `scanRequestGeneration` a real difference would show as
    /// in-sync. `activeFileOperationsCount` is back to 0 by commit time; only the operations epoch
    /// sees it.
    @MainActor
    @Test(.parksAThread) func testOperationRunningMidHashDiscardsTheBatch() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        // Start the pass; its first checksum stat parks on the gate.
        let epochBefore = try await withParkedPass(gate, pass: {
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }) {
            // A complete file operation runs while the hash is parked: count goes 1 → 0, the epoch
            // moves, and `scanRequestGeneration` has not been bumped yet.
            let generationBefore = manager.scanRequestGeneration
            let epochBefore = manager.fileOperationsEpoch
            await manager.enqueueFileOperation { }
            #expect(manager.activeFileOperationsCount == 0)
            #expect(manager.scanRequestGeneration == generationBefore)
            return epochBefore
        }

        #expect(manager.verifiedSameDifferenceIds.isEmpty, "verdicts hashed across a file operation must be discarded")
        #expect(manager.differences.count == 2)
        #expect(manager.fileOperationsEpoch > epochBefore, "the operation must have moved the epoch")
    }

    /// The positive control for the test above, on the same gated fixture, so its `isEmpty` can't
    /// pass vacuously (a broken gate or an empty candidate filter): park the pass, run no
    /// operation, release, and the identical pair must be hidden as on a plain fixture.
    @MainActor
    @Test(.parksAThread) func testGatedFixtureStillVerifiesWhenNoOperationRuns() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        let epochBefore = try await withParkedPass(gate, pass: {
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }) { manager.fileOperationsEpoch }

        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id],
                "the gated fixture must still hash and hide the identical pair")
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
        #expect(manager.fileOperationsEpoch == epochBefore)
    }

    /// A declined confirmation must not void the batch. `cancelPreCountedFileOperation()` puts the
    /// count back, but a monotonic epoch can't be un-bumped, and with nothing run no rescan would
    /// re-run the pass, leaving rows listed until a manual rescan. So the epoch moves at enqueue
    /// time, not at `preCountFileOperation()`.
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

        try await withParkedPass(gate, pass: {
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }) {
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
        }

        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id],
                "a declined confirmation runs no I/O, so it must not discard the batch")
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
    }

    /// A deliberate asymmetry: the orphaned-temp sweep writes mid-hash without
    /// `enqueueFileOperation` or the epoch, and the batch must still commit.
    /// `sweepOrphanedTempArtifacts` only removes age-gated `.tmp_<UUID>` artifacts, which can't
    /// make a differing pair hash identical, and it runs in the same refresh that spawned the
    /// pass, so bumping the epoch would void nearly every batch. Fails if the sweep moves the epoch.
    @MainActor
    @Test(.parksAThread) func testOrphanSweepDuringTheHashDoesNotDiscardTheBatch() async throws {
        // A real orphaned staging artifact, old enough to reap, under its own root, so the sweep
        // never trashes one of the files being hashed.
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "AutoVerifySweep")
        defer { try? fm.removeItem(at: root) }
        let trash = ScratchTrash(in: root)

        let gate = FirstStatGate(inner: trash)
        let fixture = try makeFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        let orphan = root.appendingPathComponent(".tmp_\(UUID().uuidString)")
        try "partial".write(to: orphan, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(OrphanSweeper.minimumAge + 60))],
            ofItemAtPath: orphan.path
        )
        manager.rawLeftTree = await FileSyncManager.buildTree(url: root, sortOption: .name)

        // Start the pass; its first checksum stat parks on the gate.
        try await withParkedPass(gate, pass: {
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }) {
            let epochBefore = manager.fileOperationsEpoch
            #expect(manager.sweepOrphanedTempArtifacts(), "the sweep must have been allowed to look")

            // Bounded premise-wait: the removal is detached, and the test needs it inside the hash
            // window. Required, or the assertions below could pass for the wrong reason.
            var trashed = false
            for _ in 0..<200 {
                if !fm.fileExists(atPath: orphan.path) { trashed = true; break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            try #require(trashed, "the sweep must have trashed the artifact while the hash was parked")
            #expect(trash.names == [orphan.lastPathComponent],
                    "the artifact left the tree but never reached the test's own Trash")

            // It took part in neither mechanism: not the epoch, not the operation queue.
            #expect(manager.fileOperationsEpoch == epochBefore)
            #expect(manager.activeFileOperationsCount == 0)
        }

        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id],
                "a removal-only sweep cannot falsify an identical verdict, so the batch must commit")
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
    }

    /// A transfer whose confirmation is still pending at commit time (pre-counted, epoch unmoved)
    /// must not void the batch. No I/O has run (the epoch bump in `enqueueFileOperation` comes
    /// before the first byte), so the verdicts are sound, and a decline would refresh nothing and
    /// leave rows listed until a manual rescan. An accept's completion rescan clears
    /// `verifiedSameDifferenceIds` and regenerates every row id, superseding this commit.
    @MainActor
    @Test(.parksAThread) func testPendingPreCountedPromptAtCommitDoesNotVoidTheBatch() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        try await withParkedPass(gate, pass: {
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }) {
            // The prompt goes up mid-hash and is still up at commit: counted, epoch unmoved.
            let epochBefore = manager.fileOperationsEpoch
            manager.preCountFileOperation()
            #expect(manager.activeFileOperationsCount == 1)
            #expect(manager.fileOperationsEpoch == epochBefore)
        }

        // The user declines after the pass committed; the batch must already be in place.
        manager.cancelPreCountedFileOperation()
        #expect(manager.activeFileOperationsCount == 0)
        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id],
                "a pending prompt has written nothing, so the batch must commit")
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
    }

    /// Same shape for `syncAll`'s prepare phase: the bulk flag is latched before the read-only
    /// stat pass and collision prompts, and every write goes through one `enqueueFileOperation`
    /// afterwards, which bumps the epoch first. A commit before that bump keeps sound verdicts (the
    /// run's rescan supersedes them); one after it is discarded on the epoch.
    @MainActor
    @Test(.parksAThread) func testBulkSyncPreparePhaseAtCommitDoesNotVoidTheBatch() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        // Lowered at the end of the test, after the commit has been read.
        defer { manager.isBulkSyncRunning = false }
        try await withParkedPass(gate, pass: {
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }) {
            // syncAll latches the flag before its read-only prepare work; nothing written yet.
            let epochBefore = manager.fileOperationsEpoch
            manager.isBulkSyncRunning = true
            #expect(manager.fileOperationsEpoch == epochBefore)
        }

        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id],
                "the prepare phase has written nothing, so the batch must commit")
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
    }
}
