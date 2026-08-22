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
    /// straight over the bytes the undo just restored. `bulkCopyDifferencesLeftToRight` now
    /// re-checks the same two terms before it orders its write, but only this guard keeps the
    /// offer and the banner honest at click time — a refusal the user can see and act on.
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

    /// The empty case that is actually COMMON: a pass whose candidates filter to nothing.
    ///
    /// The retraction above lives past the `toVerify.isEmpty` early return, so this pass used to
    /// exit in front of it and leave the standing offer — with its old stamp — completely
    /// untouched. And this is the reachable one: Verify All is always invoked with a subset in
    /// production (the current selection), so "the selection holds no date-only same-size row"
    /// is one stray click, while an eligible set that verifies nothing identical needs a real
    /// hashing pass. Verify writes nothing, so the confirm-time guards see an unmoved epoch and
    /// a zero count, and the old list goes through to a bulk disk write.
    @MainActor
    @Test func testAPassWithNoEligibleCandidatesRetractsTheStandingOffer() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
        let epochAtOffer = manager.fileOperationsEpoch

        // A selection holding one row that Verify cannot act on: not a same-size date-only pair,
        // so the eligible set is empty before a single byte is hashed.
        let ineligible = FileDifference(
            relativePath: "onlyLeft.txt",
            leftItemPath: fixture.rightIdenticalURL.deletingLastPathComponent()
                .appendingPathComponent("onlyLeft.txt").path,
            rightItemPath: fixture.rightIdenticalURL.deletingLastPathComponent()
                .appendingPathComponent("onlyLeft.txt").path,
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right"
        )
        try #require(!(ineligible.type == .differentDates && ineligible.sizesMatch),
                     "the fixture row must really be filtered out, or this tests nothing")

        await manager.verifyAllWithChecksum(subset: [ineligible])

        // Nothing wrote, so the confirm-time guards cannot be what saves this.
        try #require(manager.fileOperationsEpoch == epochAtOffer)
        try #require(manager.activeFileOperationsCount == 0)
        #expect(manager.verifiedIdenticalForCopy == nil,
                "a pass with nothing eligible to verify must not leave the previous offer standing")
        #expect(manager.confirmVerifiedCopy() == nil)
    }

    /// A CANCELLED Verify All must offer nothing — not the partial set that happened to drain
    /// before the click.
    ///
    /// `processInParallel` stops pulling items once the progress is cancelled, so the collector
    /// keeps whatever finished first. The publish branch carried a generation term and an epoch
    /// term but no cancellation term, and verify is read-only — so neither of those moves and
    /// the partial set published. The user who just cancelled a slow pass was then shown a
    /// one-permission bulk-write dialog over however many pairs got hashed, behind a banner
    /// reading "Verify All cancelled": the two surfaces contradicted each other and the
    /// expensive one won. The verdicts are sound; nobody asked for them.
    ///
    /// The cancel button is reachable — `verifyAllWithChecksum` sets `isCancellable`, and the
    /// progress overlay renders the button off exactly that, which is what the `#require` below
    /// pins before pulling the trigger.
    @MainActor
    @Test func testACancelledVerifyPassOffersNothingAndRetractsAStandingOffer() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeRaceFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        // An offer standing from an earlier pass. Assigned directly rather than hashed: the gate
        // parks the first stat of the FIRST pass, and this test needs that park for the one
        // under test.
        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(
            differences: [fixture.identical], asOf: manager.fileOperationsEpoch
        )

        let pass = Task { @MainActor in
            await manager.verifyAllWithChecksum(subset: [fixture.identical])
        }
        await awaitSignal(gate.entered)

        // The user hits Cancel on the progress overlay while the pass is mid-hash.
        let progress = try #require(manager.activeProgress)
        try #require(progress.isCancellable, "the overlay only renders Cancel while this holds")
        progress.cancel()
        gate.release.signal()
        await pass.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the pass was never actually held mid-hash")

        // The pass really did verify a pair identical before stopping — this is a PARTIAL
        // result, not an empty one, so it is the cancellation term being tested and not the
        // pre-existing empty-verdict retraction. (The parked item was already past the loop's
        // cancellation check, so it ran to completion and reached the collector; the fixture
        // pair is identical, as the un-cancelled control on this same gated fixture shows.)
        try #require(progress.isCancelled)
        try #require(progress.completedUnitCount == 1,
                     "the verdict must have been collected, or this passes through the empty branch")

        #expect(manager.banner?.message == "Verify All cancelled")
        #expect(manager.verifiedIdenticalForCopy == nil,
                "a cancelled pass must not offer the partial set it happened to drain")
        #expect(manager.confirmVerifiedCopy() == nil)
        // Cancelling offers nothing and also resolves nothing: no row may be hidden on the way out.
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.differences.count == 2)
    }

    /// Cancel on the offer dialog hides the verified rows — the ordinary path, and the control
    /// that keeps the two refusal tests below from passing for the wrong reason.
    @MainActor
    @Test func testDismissingTheDialogHidesTheVerifiedRows() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])

        manager.dismissVerifiedCopyDialogWithoutCopy()

        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id],
                "an untroubled dismissal must still hide the pair it verified identical")
    }

    /// Cancel must not hide rows the confirm path would refuse to trust.
    ///
    /// Hiding is a claim about the files, resting on the same verdicts the copy would use. The
    /// dismissal took no epoch or count reading at all, so an undo landing while the dialog was
    /// up — restoring a verified file so it genuinely differs again — was followed by Cancel
    /// hiding all of them, the changed one included. That is precisely what a refusal is not
    /// allowed to do: quietly resolve what it declined to act on. The undo's rescan does
    /// re-derive the row, but only if it completes and is not superseded, so the hide can
    /// outlive its justification until a manual rescan.
    @MainActor
    @Test func testDismissAfterAFileOperationHidesNothing() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])

        // ⌘Z while the dialog is up: same size, different bytes — the pair genuinely differs now.
        let restored = Data("restored!".utf8)   // 9 bytes, like "identical"
        let rightURL = fixture.rightIdenticalURL
        await manager.enqueueFileOperation {
            try? restored.write(to: rightURL)
        }
        try #require(manager.fileOperationsEpoch != manager.verifiedIdenticalForCopy?.asOf)

        manager.dismissVerifiedCopyDialogWithoutCopy()

        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.verifiedSameDifferenceIds.isEmpty,
                "Cancel must not hide rows on verdicts the confirm path refuses to trust")
        #expect(manager.differences.count == 2)
    }

    /// The count half of the same guard: an operation pre-counted but not yet enqueued. The
    /// epoch has not moved yet — that gap is the whole window — so the stamp still matches and
    /// only the count can refuse the hide.
    @MainActor
    @Test func testDismissWhileAnOperationIsPendingHidesNothing() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
        let stampedEpoch = manager.fileOperationsEpoch

        manager.preCountFileOperation()
        try #require(manager.activeFileOperationsCount == 1)
        try #require(manager.fileOperationsEpoch == stampedEpoch,
                     "the epoch must still be unmoved — only the count can refuse here")

        manager.dismissVerifiedCopyDialogWithoutCopy()

        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.verifiedSameDifferenceIds.isEmpty,
                "a write already claimed may be about to change these very files")

        manager.cancelPreCountedFileOperation()
    }

    /// The bulk run re-checks the stamp where the write is ORDERED, not where it was confirmed.
    ///
    /// `confirmVerifiedCopy` reads the epoch and count, then hands off to a `Task`; three
    /// main-actor hops later `enqueueFileOperation` bumps the epoch and claims the operation
    /// chain. An undo delivered into that gap claims the chain first and restores the bytes, and
    /// this run would then queue behind it and overwrite them. Driven here through the run's own
    /// parameter — the gap itself is sub-millisecond and keystroke-only — so what is pinned is
    /// that the run refuses a stamp that no longer matches instead of writing on the strength of
    /// a reading taken before a suspension point.
    @MainActor
    @Test func testTheBulkRunRefusesAStampThatMovedBeforeItCouldOrderTheWrite() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        // The DIFFERING pair on purpose: copying it left→right rewrites the destination, so
        // "did not write" is an observable claim about the bytes. Handing the run the identical
        // pair would make a write and a refusal look the same on disk.
        let rightURL = URL(fileURLWithPath: fixture.differed.rightItemPath)
        let before = try Data(contentsOf: rightURL)
        try #require(before != (try Data(contentsOf: URL(fileURLWithPath: fixture.differed.leftItemPath))),
                     "the copy must be detectable, or the byte assertion below proves nothing")

        await manager.enqueueFileOperation { }
        let liveEpoch = manager.fileOperationsEpoch
        try #require(liveEpoch > 0)

        await manager.bulkCopyDifferencesLeftToRight([fixture.differed], asOf: liveEpoch - 1)

        #expect(try Data(contentsOf: rightURL) == before,
                "a run whose stamp went stale before the enqueue must not write")
        #expect(manager.banner?.message == "A file operation ran or is pending — run Verify All again")
        #expect(manager.banner?.severity == .warning)
        // The refused run must leave no exclusion or overlay behind.
        #expect(!manager.isBulkSyncRunning)
        #expect(manager.bulkSyncProgress == nil)
        #expect(manager.activeProgress == nil)
        #expect(manager.syncingDifferenceIds.isEmpty)
    }

    // MARK: Out-of-app writes while the offer's dialog is open

    /// The offer's existing guards count only in-app writes. A cloud daemon syncing a new
    /// right-side version down while the dialog sits open moves neither `fileOperationsEpoch`
    /// nor `activeFileOperationsCount` nor `scanRequestGeneration` — nothing in the path had
    /// looked at the files themselves since they were hashed, so Confirm ran a bulk overwrite
    /// with no per-file prompt and put the stale left copy over bytes that arrived after the
    /// hash.
    ///
    /// Driven with a plain `Data.write` — NOT `enqueueFileOperation` — because going through
    /// the queue is exactly what this failure does not do; an out-of-app writer is the whole
    /// point.
    @MainActor
    @Test func testConfirmRefusesWhenTheRightSideChangedOutsideTheApp() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
        let stampedEpoch = manager.fileOperationsEpoch

        // The daemon lands a new version: same 9 bytes as "identical", different content, so a
        // size-only check could not see it and a write over it is observable.
        let arrived = Data("cloud-new".utf8)
        try #require(arrived.count == Data("identical".utf8).count)
        try arrived.write(to: fixture.rightIdenticalURL)

        try #require(manager.fileOperationsEpoch == stampedEpoch,
                     "an out-of-app write moves no epoch — that is the hole being closed")
        try #require(manager.activeFileOperationsCount == 0)

        let task = manager.confirmVerifiedCopy()
        await task?.value

        #expect(try Data(contentsOf: fixture.rightIdenticalURL) == arrived,
                "the bulk copy must not overwrite bytes that arrived after the hash")
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.banner?.severity == .warning)
    }

    /// The other end of the same pair. The left side is what gets WRITTEN, and the offer says
    /// "these two are byte-identical" — a left file rewritten after the hash makes the bulk copy
    /// push bytes nobody verified onto the right, silently replacing a file the user was told
    /// was already the same.
    @MainActor
    @Test func testConfirmRefusesWhenTheLeftSideChangedOutsideTheApp() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let leftURL = URL(fileURLWithPath: fixture.identical.leftItemPath)
        let rightBefore = try Data(contentsOf: fixture.rightIdenticalURL)

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
        let stampedEpoch = manager.fileOperationsEpoch

        let arrived = Data("left-new!".utf8)
        try #require(arrived.count == rightBefore.count)
        try arrived.write(to: leftURL)

        try #require(manager.fileOperationsEpoch == stampedEpoch)

        let task = manager.confirmVerifiedCopy()
        await task?.value

        #expect(try Data(contentsOf: fixture.rightIdenticalURL) == rightBefore,
                "unverified left bytes must not reach the right side")
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.banner?.severity == .warning)
    }

    /// The control the two refusals above need: with neither end touched, Confirm still runs the
    /// bulk copy through to resolving the row. Without this, both refusal tests would pass just
    /// as well against a guard that refuses everything.
    @MainActor
    @Test func testConfirmStillCopiesWhenNeitherEndChanged() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])

        let task = manager.confirmVerifiedCopy()
        try #require(task != nil, "an untroubled offer must start its copy")
        await task?.value

        // The run completed and resolved its row; only the differing pair is left.
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
        #expect(manager.banner?.severity != .warning)
    }

    /// Cancel rests on the same verdicts (see `testDismissAfterAFileOperationHidesNothing`), so
    /// an out-of-app write has to stop the hide too — otherwise a refusal quietly resolves the
    /// very row it declined to act on.
    @MainActor
    @Test func testDismissAfterAnOutOfAppWriteHidesNothing() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])

        try Data("cloud-new".utf8).write(to: fixture.rightIdenticalURL)

        manager.dismissVerifiedCopyDialogWithoutCopy()

        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.verifiedSameDifferenceIds.isEmpty,
                "the pair no longer verifies identical, so it must not be hidden as if it did")
    }

    /// The size half of the stamp, which no same-size fixture can reach. A writer that restores
    /// the timestamp it found — `rsync -t`, a restore-from-backup, a provider client preserving
    /// the server's mtime — leaves the modification date matching and only the length differing.
    /// Done as real filesystem operations (write, then `setAttributes`), not by reaching into
    /// the guard.
    @MainActor
    @Test func testConfirmRefusesAMtimePreservingRewriteOfADifferentLength() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let fm = FileManager.default
        // Pinned to a whole second before the pass stamps it: a timestamp written by
        // `Data.write` carries sub-second precision that does not survive being handed back
        // through `setAttributes`, so restoring an unpinned one would move the mtime slightly
        // and the test would pass on the wrong term.
        let originalMtime = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: originalMtime],
                             ofItemAtPath: fixture.rightIdenticalURL.path)

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])

        let arrived = Data("a much longer replacement".utf8)
        try #require(arrived.count != Data("identical".utf8).count)
        try arrived.write(to: fixture.rightIdenticalURL)
        try fm.setAttributes([.modificationDate: originalMtime],
                             ofItemAtPath: fixture.rightIdenticalURL.path)
        try #require(
            (try fm.attributesOfItem(atPath: fixture.rightIdenticalURL.path)[.modificationDate] as? Date)
                == originalMtime,
            "the timestamp must really be back, or the size term is not what is under test")

        let task = manager.confirmVerifiedCopy()
        await task?.value

        #expect(try Data(contentsOf: fixture.rightIdenticalURL) == arrived,
                "a rewrite that preserves the timestamp still changes the size — and must refuse")
        #expect(manager.banner?.severity == .warning)
    }

    /// An offer that carries no stamps for its pairs cannot substantiate its own verdicts, and
    /// must cost a re-verify rather than an unchecked bulk write. Same direction as `asOf`: the
    /// guard fails CLOSED on a caller who supplies the wrong thing.
    @MainActor
    @Test func testConfirmRefusesAnOfferWithNoStampsToReCheckAgainst() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let rightURL = URL(fileURLWithPath: fixture.differed.rightItemPath)
        let before = try Data(contentsOf: rightURL)

        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(
            differences: [fixture.differed], asOf: manager.fileOperationsEpoch, stamps: [:])

        let task = manager.confirmVerifiedCopy()

        #expect(task == nil, "an unsubstantiated offer must not start a copy")
        #expect(try Data(contentsOf: rightURL) == before)
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.banner?.message
                == "\"diff.txt\" cannot be re-checked against its verification — run Verify All again")
    }
}
