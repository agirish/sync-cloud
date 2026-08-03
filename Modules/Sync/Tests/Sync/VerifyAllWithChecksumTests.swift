import Testing
import Foundation
@testable import Sync

/// Pins `verifyAllWithChecksum` end-to-end ahead of refactoring its parallel-worker scaffolding:
/// identical / differed / skipped classification, the summary banner wording, the
/// verified-identical hand-off to the copy dialog, and progress cleanup. Uses real temp files —
/// the checksummer reads file contents from the real filesystem.
@Suite struct VerifyAllWithChecksumTests {

    @MainActor
    @Test func testVerifyAllClassifiesAndReportsResults() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("VerifyAllPin-\(UUID().uuidString)")
        let left = base.appendingPathComponent("left")
        let right = base.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // same.txt: identical content on both sides. diff.txt: same size, different bytes.
        // gone.txt: right side missing, so hashing fails and the item counts as skipped.
        try Data("identical".utf8).write(to: left.appendingPathComponent("same.txt"))
        try Data("identical".utf8).write(to: right.appendingPathComponent("same.txt"))
        try Data("aaaa".utf8).write(to: left.appendingPathComponent("diff.txt"))
        try Data("bbbb".utf8).write(to: right.appendingPathComponent("diff.txt"))
        try Data("orphan".utf8).write(to: left.appendingPathComponent("gone.txt"))

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
        let skipped = dateDiff("gone.txt", size: 6)

        let manager = FileSyncManager()
        // No collision or delete prompt can fire here, but the seams stay mocked so no NSAlert
        // could ever appear if that changes.
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, true) }
        manager.permanentDeleteConfirmer = { _ in false }
        manager.rawDifferences = [identical, differed, skipped]
        manager.differences = [identical, differed, skipped]

        await manager.verifyAllWithChecksum()

        // Only the identical item is offered for the follow-up copy.
        #expect(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [identical.id])
        // Differed/skipped items make the summary a warning, not a success.
        // (Field comparison — banner equality includes a per-publish id.)
        #expect(manager.banner?.message == "Verify All: 1 identical; 1 differed; 1 skipped")
        #expect(manager.banner?.severity == .warning)
        // Progress state is fully torn down.
        #expect(manager.verifyAllProgress == nil)
        #expect(manager.activeProgress == nil)
        // Verification alone resolves nothing; the list still holds all three.
        #expect(manager.differences.count == 3)
    }

    /// same.txt identical on both sides, diff.txt same size but different bytes — the minimal
    /// fixture for staging a file operation against the manual pass. Exposes the right-side
    /// URL of the identical pair so a test can overwrite it the way an undo would.
    @MainActor
    private func makeRaceFixture(fileManager: FileManaging = FileManager.default) throws -> (
        manager: FileSyncManager,
        identical: FileDifference,
        differed: FileDifference,
        rightIdenticalURL: URL,
        cleanup: () -> Void
    ) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("VerifyAllRace-\(UUID().uuidString)")
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
        // No prompt can fire in these tests, but the seams stay mocked so no NSAlert could
        // ever appear if that changes.
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, true) }
        manager.permanentDeleteConfirmer = { _ in false }
        manager.rawDifferences = [identical, differed]
        manager.differences = [identical, differed]
        return (manager, identical, differed, right.appendingPathComponent("same.txt"), { try? fm.removeItem(at: base) })
    }

    /// A file operation that starts — and even FINISHES — while Verify All is hashing must
    /// discard the copy offer: the "identical" verdicts describe bytes the operation may have
    /// rewritten, and if the hash drains before the operation's refresh-triggered rescan bumps
    /// `scanRequestGeneration`, the generation guard alone passes and the stale offer feeds
    /// `bulkCopyDifferencesLeftToRight` — a bulk disk write over the just-changed files. Undo
    /// is the live route here (⌘Z has no `isVerifyAllRunning` gate), and every undo runs
    /// through `enqueueFileOperation`, which is exactly what this stages.
    @MainActor
    @Test func testOperationRunningMidHashDiscardsTheCopyOffer() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeRaceFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        // Start the manual pass; its first checksum stat parks on the gate.
        let pass = Task { @MainActor in
            await manager.verifyAllWithChecksum()
        }
        await awaitSignal(gate.entered)

        // A complete file operation runs while the hash is parked: count goes 1 → 0, the epoch
        // moves, and — the exact race — `scanRequestGeneration` has NOT been bumped yet.
        let generationBefore = manager.scanRequestGeneration
        let epochBefore = manager.fileOperationsEpoch
        await manager.enqueueFileOperation { }
        #expect(manager.activeFileOperationsCount == 0)
        #expect(manager.scanRequestGeneration == generationBefore)
        #expect(manager.fileOperationsEpoch > epochBefore, "the operation must have moved the epoch")

        gate.release.signal()
        await pass.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the pass was never actually held mid-hash")

        #expect(manager.verifiedIdenticalForCopy == nil,
                "verdicts hashed across a file operation must not become a bulk-copy offer")
    }

    /// The positive control for the test above, on the SAME gated fixture. A nil offer is also
    /// what you see if the gate broke hashing outright, so without this the discard assertion
    /// could pass vacuously: park the pass, run NO operation, release, and the identical pair
    /// must be offered exactly as on a plain fixture.
    @MainActor
    @Test func testGatedFixtureStillPublishesTheOfferWhenNoOperationRuns() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeRaceFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        let pass = Task { @MainActor in
            await manager.verifyAllWithChecksum()
        }
        await awaitSignal(gate.entered)
        let epochBefore = manager.fileOperationsEpoch
        gate.release.signal()
        await pass.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the pass was never actually held mid-hash")

        #expect(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id],
                "the gated fixture must still hash and offer the identical pair")
        #expect(manager.fileOperationsEpoch == epochBefore)
    }

    /// The window AFTER publish: the offer dialog is up, the user hits ⌘Z, and the undo
    /// overwrites a verified file before its refresh-triggered rescan clears the offer
    /// (`scanDirectories` does nil it — but only when the rescan completes, seconds later on a
    /// large tree). Confirming inside that window must refuse: the verdicts predate the write.
    /// The overwrite here is byte-for-byte what an undo does — same size, different content —
    /// so if the stale copy ran anyway it would demonstrably clobber the restored bytes.
    @MainActor
    @Test func testConfirmAfterAFileOperationRefusesTheStaleCopy() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])

        // An undo lands while the dialog is up: same size, different bytes — restored content.
        let restored = Data("restored!".utf8)   // 9 bytes, like "identical"
        let rightURL = fixture.rightIdenticalURL
        await manager.enqueueFileOperation {
            try? restored.write(to: rightURL)
        }

        let copyTask = manager.confirmVerifiedCopy()
        await copyTask?.value
        #expect(copyTask == nil, "a confirm after a file operation must not start the bulk copy")
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(try Data(contentsOf: rightURL) == restored,
                "the stale copy must not overwrite the bytes the operation just wrote")
        // The banner is the entire user-facing contract of this path: the click did nothing,
        // and without it the user is left staring at a dialog that closed for no stated reason.
        // (Field comparison — banner equality includes a per-publish id.)
        #expect(manager.banner?.message == "A file operation ran or is pending — run Verify All again")
        #expect(manager.banner?.severity == .warning)
        // A refusal is not a resolution: nothing may be hidden as verified-same, and no row may
        // disappear from the list on the way out.
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.differences.count == 2)
    }

    /// The window the epoch comparison alone cannot see: an operation that has been PRE-COUNTED
    /// but has not yet reached `enqueueFileOperation`, where the epoch is bumped.
    ///
    /// Every undo/redo path runs `preCountFileOperation()` synchronously and enqueues from
    /// inside a `Task`; `FileSyncManager` is `@MainActor`, so `enqueueFileOperation`'s
    /// `await MainActor.run` is a real suspension point and the epoch moves strictly later.
    /// So "epoch unmoved" does NOT mean "nothing is about to be written" — and if the confirm
    /// passes here, the undo's task claims the serial queue first and the bulk copy runs
    /// straight over the bytes the undo just restored. `bulkCopyDifferencesLeftToRight`
    /// deliberately does not refuse on the count, so nothing downstream catches it.
    @MainActor
    @Test func testConfirmRefusesWhileAPreCountedOperationHasNotYetEnqueued() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
        let stampedEpoch = manager.fileOperationsEpoch

        // ⌘Z: the undo handler's pre-count lands, its Task has not hopped to the main actor yet.
        manager.preCountFileOperation()
        try #require(manager.activeFileOperationsCount == 1)
        try #require(manager.fileOperationsEpoch == stampedEpoch,
                     "the epoch must still be unmoved — that gap is the whole window under test")

        let copyTask = manager.confirmVerifiedCopy()
        await copyTask?.value

        #expect(copyTask == nil, "a confirm with a write already pending must not start the bulk copy")
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.banner?.message == "A file operation ran or is pending — run Verify All again")
        #expect(manager.banner?.severity == .warning)
        // A refusal resolves nothing and hides nothing: the rows stay exactly as they were.
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.differences.count == 2)

        manager.cancelPreCountedFileOperation()
    }

    /// The epoch term on its own, and the seam that makes it reachable from a test at all.
    ///
    /// An offer stamped BEHIND the live epoch is the state the confirm guard exists for, and
    /// while the stamp lived in a separate property maintained by a `didSet`, no test could
    /// build it: every direct assignment re-certified itself as current, so the only route was
    /// to drive a whole verify pass across a real file operation and exactly one test did. Now
    /// the stamp is part of the value, a stale one is a constructor argument, and the guard can
    /// be exercised without staging the race that produces it.
    @MainActor
    @Test func testConfirmRefusesAnOfferStampedBeforeTheLiveEpoch() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.enqueueFileOperation { }
        let liveEpoch = manager.fileOperationsEpoch
        try #require(liveEpoch > 0)
        try #require(manager.activeFileOperationsCount == 0, "only the stamp may be stale here")

        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(
            differences: [fixture.identical], asOf: liveEpoch - 1
        )
        let copyTask = manager.confirmVerifiedCopy()
        await copyTask?.value

        #expect(copyTask == nil)
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.banner?.message == "A file operation ran or is pending — run Verify All again")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.differences.count == 2)
    }

    /// A Verify All that finds NOTHING identical must retract a standing offer, not leave it be.
    ///
    /// The publish is conditional on `!verifiedIdentical.isEmpty`, so an empty pass used to fall
    /// straight through and the previous pass's offer survived with its old stamp. Nothing
    /// downstream catches that: verify is read-only, so the epoch has NOT moved and the count is
    /// zero — `confirmVerifiedCopy`'s guards both pass, and the bulk copy runs over a list this
    /// pass just declined to stand behind.
    ///
    /// Not reachable from today's UI (Verify All is only invokable from the in-view action bar,
    /// with no shortcut or menu item, and the offer's dialog is window-modal, so no second pass
    /// can run while an offer stands) — one keyboard shortcut away from being reachable, and the
    /// failure it opens is a bulk disk write.
    @MainActor
    @Test func testAVerifyPassFindingNothingIdenticalRetractsTheStandingOffer() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
        let epochAtOffer = manager.fileOperationsEpoch

        // A second pass over only the pair that genuinely differs: nothing verifies identical.
        await manager.verifyAllWithChecksum(subset: [fixture.differed])

        // The epoch is untouched — verify writes nothing — so the confirm-time guards cannot be
        // what saves this. The offer itself has to go.
        try #require(manager.fileOperationsEpoch == epochAtOffer)
        try #require(manager.activeFileOperationsCount == 0)
        #expect(manager.verifiedIdenticalForCopy == nil,
                "a pass that verified nothing identical must not leave the previous offer standing")
        #expect(manager.confirmVerifiedCopy() == nil)
    }
}
