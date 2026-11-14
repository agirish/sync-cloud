import Testing
import Foundation
import Events
@testable import Sync

/// Pins `verifyAllWithChecksum` end to end: identical / differed / skipped classification, the
/// summary banner wording, the verified-identical offer to the copy dialog and the guards that
/// keep it from writing over changed files, the date match, and progress cleanup. Real temp
/// files: the checksummer reads contents from the real filesystem.
@Suite struct VerifyAllWithChecksumTests {

    @MainActor
    @Test func testVerifyAllClassifiesAndReportsResults() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let identical = fixture.identical

        // gone.txt: right side missing, so hashing fails and the item counts as skipped.
        let left = URL(fileURLWithPath: identical.leftItemPath).deletingLastPathComponent()
        let right = URL(fileURLWithPath: identical.rightItemPath).deletingLastPathComponent()
        try Data("orphan".utf8).write(to: left.appendingPathComponent("gone.txt"))
        let skipped = FileDifference(relativePath: "gone.txt",
                                     leftItemPath: left.appendingPathComponent("gone.txt").path,
                                     rightItemPath: right.appendingPathComponent("gone.txt").path,
                                     type: .differentDates, action: .copyToRight, description: "Different dates",
                                     leftFileSize: 6, rightFileSize: 6)
        manager.rawDifferences.append(skipped)
        manager.differences.append(skipped)

        await manager.verifyAllWithChecksum()

        // Only the identical item is offered for the follow-up copy.
        #expect(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [identical.id])
        // Differed/skipped items make the summary a warning, not a success.
        // (Field comparison: banner equality includes a per-publish id.)
        #expect(manager.banner?.message == "Verify All: 1 identical; 1 differed; 1 skipped")
        #expect(manager.banner?.severity == .warning)
        // Progress state is fully torn down.
        #expect(manager.verifyAllProgress == nil)
        #expect(manager.activeProgress == nil)
        // Verification alone resolves nothing; the list still holds all three.
        #expect(manager.differences.count == 3)
    }

    /// same.txt identical on both sides, diff.txt the same size with different bytes: the minimal
    /// fixture for staging a file operation against the pass. Exposes the identical pair's
    /// right-side URL so a test can overwrite it as an undo would.
    @MainActor
    private func makeRaceFixture(fileManager: FileManaging? = nil) throws -> (
        manager: FileSyncManager,
        identical: FileDifference,
        differed: FileDifference,
        rightIdenticalURL: URL,
        cleanup: () -> Void
    ) {
        let pair = try makeSameSizePairFixture(prefix: "VerifyAllRace")
        // Without a file manager of its own, the fixture's Trash is a folder inside it.
        let manager = FileSyncManager(fileManager: fileManager ?? ScratchTrash(in: pair.base))
        // No prompt can fire in these tests, but the seams stay mocked so no NSAlert could
        // ever appear if that changes.
        manager.collisionResolver = { _ in .replace }
        manager.bulkCollisionResolver = { _ in (.replace, true) }
        manager.permanentDeleteConfirmer = { _ in false }
        manager.rawDifferences = [pair.identical, pair.differed]
        manager.differences = [pair.identical, pair.differed]
        return (manager, pair.identical, pair.differed, pair.rightIdenticalURL, pair.cleanup)
    }

    /// A file operation that starts, and even finishes, while Verify All is hashing discards the
    /// copy offer: the verdicts describe bytes it may have rewritten. If the hash drains before
    /// the operation's rescan bumps `scanRequestGeneration`, the generation guard alone passes and
    /// the stale offer would feed a bulk write over the changed files. Undo is the live route
    /// (⌘Z has no `isVerifyAllRunning` gate) and runs through `enqueueFileOperation`, as staged here.
    @MainActor
    @Test(.parksAThread) func testOperationRunningMidHashDiscardsTheCopyOffer() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeRaceFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        // Start the manual pass; its first checksum stat parks on the gate.
        try await withParkedPass(gate, pass: { await manager.verifyAllWithChecksum() }) {
            // A complete file operation runs while the hash is parked: count goes 1 → 0, the epoch
            // moves, and (the race) `scanRequestGeneration` has not been bumped yet.
            let generationBefore = manager.scanRequestGeneration
            let epochBefore = manager.fileOperationsEpoch
            await manager.enqueueFileOperation { }
            #expect(manager.activeFileOperationsCount == 0)
            #expect(manager.scanRequestGeneration == generationBefore)
            #expect(manager.fileOperationsEpoch > epochBefore, "the operation must have moved the epoch")
        }

        #expect(manager.verifiedIdenticalForCopy == nil,
                "verdicts hashed across a file operation must not become a bulk-copy offer")
    }

    /// Stop reaches a read already under way. Stop is a `Progress` cancel, which the hash checks
    /// before the open and every chunk. One pair, parked at the pass's first stat (the pair stamp,
    /// before either read), cancelled, then released: neither file is read, so neither digest
    /// reaches the cache. Unwired, both would be hashed in full after the Stop.
    @MainActor
    @Test(.parksAThread) func stopReachesTheHashAlreadyUnderWay() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeRaceFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        try await withParkedPass(gate, pass: { await manager.verifyAllWithChecksum(subset: [fixture.identical]) }) {
            try #require(manager.activeProgress != nil, "the pass published no progress to stop")
            manager.activeProgress?.cancel()
        }

        for path in [fixture.identical.leftItemPath, fixture.identical.rightItemPath] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = try #require((attributes[.size] as? NSNumber)?.intValue)
            let key = try #require(FileContentVerifier.cacheKey(statPath: path, attributes: attributes, size: size))
            #expect(await ContentHashCache.shared.hash(for: key) == nil, "read after Stop: \(path)")
        }
        #expect(manager.verifiedIdenticalForCopy == nil)
    }

    /// The positive control for the discard test, on the same gated fixture: a nil offer is also
    /// what a gate that broke hashing would give. Park the pass, run no operation, release, and the
    /// identical pair must be offered as on a plain fixture.
    @MainActor
    @Test(.parksAThread) func testGatedFixtureStillPublishesTheOfferWhenNoOperationRuns() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeRaceFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        let epochBefore = try await withParkedPass(gate, pass: { await manager.verifyAllWithChecksum() }) {
            manager.fileOperationsEpoch
        }

        #expect(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id],
                "the gated fixture must still hash and offer the identical pair")
        #expect(manager.fileOperationsEpoch == epochBefore)
    }

    /// What makes an offer stale by the time the user confirms it.
    enum StaleConfirm: Sendable { case fileOperation, pendingOperation, staleStamp }

    /// Confirming a stale offer must refuse: the verdicts predate a write.
    /// - `fileOperation`: the dialog is up, the user hits ⌘Z, and the undo overwrites a verified
    ///   file before its rescan clears the offer (`scanDirectories` does, but only when the rescan
    ///   completes, seconds later on a large tree). Same size, different content, so a stale copy
    ///   would show.
    /// - `pendingOperation`: the window the epoch alone can't see, an operation pre-counted but not
    ///   yet at `enqueueFileOperation`, where the epoch is bumped. Undo/redo pre-count synchronously
    ///   and enqueue from a `Task`, and `enqueueFileOperation`'s `await MainActor.run` suspends, so
    ///   "epoch unmoved" doesn't mean "nothing is about to be written". Passing here, the bulk copy
    ///   would queue behind the undo and overwrite what it restored. `bulkCopyDifferencesLeftToRight`
    ///   re-checks both terms too, but only this guard refuses visibly at click time.
    /// - `staleStamp`: the epoch term on its own, an offer stamped behind the live epoch. The stamp
    ///   is part of `VerifiedCopyOffer`, so a stale one is a constructor argument.
    @MainActor
    @Test(arguments: [StaleConfirm.fileOperation, .pendingOperation, .staleStamp])
    func testConfirmRefusesAStaleOffer(_ stale: StaleConfirm) async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        let restored = Data("restored!".utf8)   // 9 bytes, like "identical"
        switch stale {
        case .fileOperation:
            await manager.verifyAllWithChecksum()
            try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
            // An undo lands while the dialog is up: same size, different bytes (restored content).
            let rightURL = fixture.rightIdenticalURL
            await manager.enqueueFileOperation {
                try? restored.write(to: rightURL)
            }
        case .pendingOperation:
            await manager.verifyAllWithChecksum()
            try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
            let stampedEpoch = manager.fileOperationsEpoch
            // ⌘Z: the undo handler's pre-count lands, its Task has not hopped to the main actor yet.
            manager.preCountFileOperation()
            try #require(manager.activeFileOperationsCount == 1)
            try #require(manager.fileOperationsEpoch == stampedEpoch,
                         "the epoch must still be unmoved — that gap is the whole window under test")
        case .staleStamp:
            await manager.enqueueFileOperation { }
            let liveEpoch = manager.fileOperationsEpoch
            try #require(liveEpoch > 0)
            try #require(manager.activeFileOperationsCount == 0, "only the stamp may be stale here")
            manager.verifiedIdenticalForCopy = VerifiedCopyOffer(
                differences: [fixture.identical], asOf: liveEpoch - 1
            )
        }

        let copyTask = manager.confirmVerifiedCopy()
        await copyTask?.value
        #expect(copyTask == nil, "a confirm on a stale offer must not start the bulk copy")
        #expect(manager.verifiedIdenticalForCopy == nil)
        if stale == .fileOperation {
            #expect(try Data(contentsOf: fixture.rightIdenticalURL) == restored,
                    "the stale copy must not overwrite the bytes the operation just wrote")
        }
        // The banner is this path's whole user-facing contract: the click did nothing, and
        // without it the dialog would close for no stated reason.
        // (Field comparison: banner equality includes a per-publish id.)
        #expect(manager.banner?.message == "A file operation ran or is pending — run Verify All again")
        #expect(manager.banner?.severity == .warning)
        // A refusal resolves nothing: nothing hidden as verified-same, no row dropped.
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.differences.count == 2)

        if stale == .pendingOperation { manager.cancelPreCountedFileOperation() }
    }

    /// A Verify All that finds nothing identical retracts a standing offer. Nothing downstream
    /// would catch a leftover: verify is read-only, so the epoch is unmoved and the count zero,
    /// both `confirmVerifiedCopy` guards pass, and the bulk copy would run over a list this pass
    /// declined to stand behind. The UI can't reach this today (the dialog is window-modal), but
    /// one shortcut would, and the failure is a bulk disk write.
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

        // Verify writes nothing, so the epoch is untouched and the confirm-time guards can't save
        // this. The offer itself has to go.
        try #require(manager.fileOperationsEpoch == epochAtOffer)
        try #require(manager.activeFileOperationsCount == 0)
        #expect(manager.verifiedIdenticalForCopy == nil,
                "a pass that verified nothing identical must not leave the previous offer standing")
        #expect(manager.confirmVerifiedCopy() == nil)
    }

    /// The common empty case: a pass whose candidates filter to nothing, which must retract too,
    /// even though it returns before hashing anything. Verify All runs on the current selection,
    /// so a selection with no same-size date-only row is one stray click away, and the confirm
    /// guards would see an unmoved epoch and a zero count.
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

        // Nothing wrote, so the confirm-time guards can't be what saves this.
        try #require(manager.fileOperationsEpoch == epochAtOffer)
        try #require(manager.activeFileOperationsCount == 0)
        #expect(manager.verifiedIdenticalForCopy == nil,
                "a pass with nothing eligible to verify must not leave the previous offer standing")
        #expect(manager.confirmVerifiedCopy() == nil)
    }

    /// A cancelled Verify All offers nothing, not the partial set that drained before the click,
    /// and retracts a standing offer. `processInParallel` stops pulling items on cancel, so the
    /// collector keeps what finished first, and verify moves neither the generation nor the
    /// epoch. Publishing would put a bulk-write dialog behind a "canceled" banner.
    ///
    /// The overlay renders Cancel only while `isCancellable` holds, which the `#require` pins.
    @MainActor
    @Test(.parksAThread) func testACancelledVerifyPassOffersNothingAndRetractsAStandingOffer() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeRaceFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        // An offer standing from an earlier pass, assigned rather than hashed: the gate parks
        // only the first pass's first stat, and the pass under test needs it.
        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(
            differences: [fixture.identical], asOf: manager.fileOperationsEpoch
        )

        let progress = try await withParkedPass(gate, pass: { await manager.verifyAllWithChecksum(subset: [fixture.identical]) }) {
            // The user hits Cancel on the progress overlay while the pass is mid-hash.
            let progress = try #require(manager.activeProgress)
            try #require(progress.isCancellable, "the overlay only renders Cancel while this holds")
            progress.cancel()
            return progress
        }

        // The pass did verify a pair before stopping: a partial result, not an empty one, so
        // this tests the cancellation term, not the empty-verdict retraction. (The parked item
        // was past the loop's cancel check, so it completed and reached the collector.)
        try #require(progress.isCancelled)
        try #require(progress.completedUnitCount == 1,
                     "the verdict must have been collected, or this passes through the empty branch")

        #expect(manager.banner?.message == "Verify All canceled")
        #expect(manager.verifiedIdenticalForCopy == nil,
                "a cancelled pass must not offer the partial set it happened to drain")
        #expect(manager.confirmVerifiedCopy() == nil)
        // Cancelling offers nothing and resolves nothing: no row is hidden on the way out.
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.differences.count == 2)
    }

    /// Cancel on the offer dialog hides the verified rows: the ordinary path, and the control that
    /// keeps the dismissal refusal tests from passing for the wrong reason.
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

    /// What lands on a verified pair while the offer's dialog is up.
    enum Disturbance: Sendable { case fileOperation, pendingOperation, outOfAppWrite }

    /// Cancel must not hide rows the confirm path would refuse to trust. Hiding is a claim about
    /// the files, resting on the same verdicts as the copy, so an undo landing while the dialog is
    /// up stops the hide. The undo's rescan re-derives the row only if it completes and isn't
    /// superseded, so a wrong hide could last until a manual rescan.
    ///
    /// The count half of the same guard (`pendingOperation`): an operation pre-counted but not yet
    /// enqueued. The epoch hasn't moved, so the stamp still matches and only the count can refuse
    /// the hide. And an out-of-app write stops the hide too, or a refusal would resolve the row it
    /// declined to act on.
    @MainActor
    @Test(arguments: [Disturbance.fileOperation, .pendingOperation, .outOfAppWrite])
    func testDismissAfterADisturbanceHidesNothing(_ disturbance: Disturbance) async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
        let stampedEpoch = manager.fileOperationsEpoch

        switch disturbance {
        case .fileOperation:
            // ⌘Z while the dialog is up: same size, different bytes, so the pair differs now.
            let restored = Data("restored!".utf8)   // 9 bytes, like "identical"
            let rightURL = fixture.rightIdenticalURL
            await manager.enqueueFileOperation {
                try? restored.write(to: rightURL)
            }
            try #require(manager.fileOperationsEpoch != manager.verifiedIdenticalForCopy?.asOf)
        case .pendingOperation:
            manager.preCountFileOperation()
            try #require(manager.activeFileOperationsCount == 1)
            try #require(manager.fileOperationsEpoch == stampedEpoch,
                         "the epoch must still be unmoved — only the count can refuse here")
        case .outOfAppWrite:
            try Data("cloud-new".utf8).write(to: fixture.rightIdenticalURL)
        }

        manager.dismissVerifiedCopyDialogWithoutCopy()

        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.verifiedSameDifferenceIds.isEmpty,
                "Cancel must not hide rows on verdicts the confirm path refuses to trust")
        #expect(manager.differences.count == 2)

        if disturbance == .pendingOperation { manager.cancelPreCountedFileOperation() }
    }

    /// The bulk run re-checks the stamp where the write is ordered, not where it was confirmed.
    /// `confirmVerifiedCopy` hands off to a `Task`, and a few main-actor hops pass before
    /// `enqueueFileOperation` claims the chain; an undo in that gap would claim it first, and the
    /// run would overwrite what it restored. The gap is sub-millisecond, so this drives the run's
    /// `asOf` directly: a stamp that no longer matches must refuse.
    @MainActor
    @Test func testTheBulkRunRefusesAStampThatMovedBeforeItCouldOrderTheWrite() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        // The differing pair on purpose: copying it rewrites the destination, so "did not write"
        // shows in the bytes. With the identical pair, a write and a refusal look the same.
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

    /// Which end of a verified pair an out-of-app writer changes.
    enum PairSide: Sendable { case right, left }

    /// The epoch, count and generation guards see only in-app writes. A cloud daemon syncing a
    /// new right-side version while the dialog is open moves none of them, so Confirm re-checks
    /// each pair's stamp and refuses rather than put the stale left copy over the new bytes.
    /// Driven with a plain `Data.write`, not `enqueueFileOperation`: an out-of-app writer is the
    /// point. The left side is what gets written, so a left file rewritten after the hash would
    /// push unverified bytes onto the right, replacing a file the user was told was already the
    /// same.
    @MainActor
    @Test(arguments: [PairSide.right, .left])
    func testConfirmRefusesWhenASideChangedOutsideTheApp(_ side: PairSide) async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let leftURL = URL(fileURLWithPath: fixture.identical.leftItemPath)
        let rightBefore = try Data(contentsOf: fixture.rightIdenticalURL)

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
        let stampedEpoch = manager.fileOperationsEpoch

        // The daemon lands a new version: 9 bytes like "identical", different content, so a
        // size-only check can't see it and a write over it shows.
        let arrived = Data((side == .right ? "cloud-new" : "left-new!").utf8)
        try #require(arrived.count == rightBefore.count)
        try arrived.write(to: side == .right ? fixture.rightIdenticalURL : leftURL)

        try #require(manager.fileOperationsEpoch == stampedEpoch,
                     "an out-of-app write moves no epoch — that is the hole being closed")
        try #require(manager.activeFileOperationsCount == 0)

        let task = manager.confirmVerifiedCopy()
        await task?.value

        if side == .right {
            #expect(try Data(contentsOf: fixture.rightIdenticalURL) == arrived,
                    "the bulk copy must not overwrite bytes that arrived after the hash")
        } else {
            #expect(try Data(contentsOf: fixture.rightIdenticalURL) == rightBefore,
                    "unverified left bytes must not reach the right side")
        }
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.banner?.severity == .warning)
    }

    /// The control for the two refusals above: with neither end touched, Confirm still runs the
    /// bulk copy and resolves the row, so a guard that refuses everything would fail here.
    @MainActor
    @Test func testConfirmStillCopiesWhenNeitherEndChanged() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        manager.undoManager = UndoManager()
        // Dates a whole day apart, so "matched" cannot be an accident of the fixture's timing.
        let leftURL = URL(fileURLWithPath: fixture.identical.leftItemPath)
        let leftDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: leftDate], ofItemAtPath: leftURL.path)
        try FileManager.default.setAttributes([.modificationDate: leftDate.addingTimeInterval(86_400)],
                                              ofItemAtPath: fixture.rightIdenticalURL.path)

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])

        let task = manager.confirmVerifiedCopy()
        try #require(task != nil, "an untroubled offer must start its copy")
        await task?.value

        // The run completed and resolved its row; only the differing pair is left.
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
        #expect(manager.banner?.severity != .warning)
        // The pair was proven identical, so the right file took the left's date and nothing
        // else: no copy over it, so no backup of an identical original in the Trash.
        let rightDate = try FileManager.default.attributesOfItem(atPath: fixture.rightIdenticalURL.path)[.modificationDate] as? Date
        #expect(rightDate == leftDate, "the right file's date was not matched to the left's")
        #expect(try Data(contentsOf: fixture.rightIdenticalURL) == Data("identical".utf8))
        let trash = try #require(manager.fileManager as? ScratchTrash)
        #expect(!trash.names.contains { $0.hasPrefix(".rollback_") },
                "a byte-identical file was copied over, sending a backup to the Trash: \(trash.names)")

        // And one ⌘Z gives the right file its own date back.
        try #require(manager.undoManager?.canUndo == true, "matching the dates registered no undo")
        manager.undoManager?.undo()
        await waitUntil("the date-match undo drains") { manager.activeFileOperationsCount == 0 }
        let restored = try FileManager.default.attributesOfItem(atPath: fixture.rightIdenticalURL.path)[.modificationDate] as? Date
        #expect(restored == leftDate.addingTimeInterval(86_400), "⌘Z did not restore the right file's own date")
    }

    /// "Copy to match dates" at the "Exact match" tolerance, with sub-microsecond dates, as any file
    /// saved on APFS has. `setAttributes` rounds to the microsecond, so a date set that way would
    /// read back off the left's, the pair would return on the next scan, and the Undo would land
    /// as far off, making the Redo find the file "changed since". Match, undo and redo exactly.
    @MainActor
    @Test func testMatchedDatesFinerThanAMicrosecondStayMatchedThroughUndoAndRedo() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        manager.undoManager = UndoManager()
        let leftURL = URL(fileURLWithPath: fixture.identical.leftItemPath)
        func setTimespec(_ url: URL, seconds: Int, nanoseconds: Int) throws {
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
            try #require(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
        }
        func date(_ url: URL) throws -> Date {
            try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        }
        // What the next scan sees: the pair's row at the exact tolerance, if any.
        func exactRescan() throws -> [String] {
            let leftRoot = leftURL.deletingLastPathComponent(), rightRoot = fixture.rightIdenticalURL.deletingLastPathComponent()
            let provider = { (path: String) in CloudProvider(id: path, displayName: path, imageName: "folder", rootPath: path, type: .iCloud) }
            return FileDiffEngine.computeDifferences(
                left: provider(leftRoot.path), leftURL: leftRoot, right: provider(rightRoot.path), rightURL: rightRoot,
                leftFilesInfo: try FileDiffEngine.getFilesInDirectory(leftRoot),
                rightFilesInfo: try FileDiffEngine.getFilesInDirectory(rightRoot),
                dateToleranceSeconds: 0
            ).map(\.relativePath).filter { $0 == "same.txt" }
        }
        try setTimespec(leftURL, seconds: 1_600_000_000, nanoseconds: 123_456_789)
        try setTimespec(fixture.rightIdenticalURL, seconds: 1_600_086_400, nanoseconds: 987_654_321)
        let leftDate = try date(leftURL)
        let rightDateBefore = try date(fixture.rightIdenticalURL)
        try #require(try exactRescan() == ["same.txt"], "the premise: the pair differs at the exact tolerance")

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
        await manager.confirmVerifiedCopy()?.value

        #expect(try date(fixture.rightIdenticalURL) == leftDate, "the matched date did not land exactly")
        #expect(try exactRescan().isEmpty, "the matched pair comes back on the next exact scan")

        try #require(manager.undoManager?.canUndo == true)
        manager.undoManager?.undo()
        await waitUntil("the date-match undo drains") { manager.activeFileOperationsCount == 0 }
        #expect(try date(fixture.rightIdenticalURL) == rightDateBefore, "⌘Z did not put the right file's own date back exactly")

        try #require(manager.undoManager?.canRedo == true)
        manager.undoManager?.redo()
        await waitUntil("the date-match redo drains") { manager.activeFileOperationsCount == 0 }
        #expect(try date(fixture.rightIdenticalURL) == leftDate, "Redo left the right file alone as “changed since”")
        #expect(try exactRescan().isEmpty, "the redone pair comes back on the next exact scan")
    }

    /// An Undo that puts back no date says so. A right file saved after the match is not the step's
    /// to re-date, so it is left alone, and the banner must say that rather than keep the match's
    /// success.
    @MainActor
    @Test func testADateMatchUndoThatLeavesAChangedFileAloneSaysSo() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        manager.undoManager = UndoManager()
        let leftDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: leftDate], ofItemAtPath: fixture.identical.leftItemPath)
        try FileManager.default.setAttributes([.modificationDate: leftDate.addingTimeInterval(86_400)],
                                              ofItemAtPath: fixture.rightIdenticalURL.path)
        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
        await manager.confirmVerifiedCopy()?.value
        try #require(manager.banner?.severity == .success, "the premise: the match succeeded")

        // Saved since: a new size, so the undo must leave it alone.
        try Data("edited after the match".utf8).write(to: fixture.rightIdenticalURL)
        manager.undoManager?.undo()
        await waitUntil("the date-match undo posts its outcome") { manager.banner?.severity == .warning }

        #expect(manager.banner?.message == "Undo left 1 file’s date alone — it changed since")
        #expect(try Data(contentsOf: fixture.rightIdenticalURL) == Data("edited after the match".utf8))
    }

    /// A date match that matched some pairs and left others out registers its undo step for the
    /// ones it matched, and its warning banner still offers Undo.
    @MainActor
    @Test func testAPartialDateMatchKeepsItsUndo() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        manager.undoManager = UndoManager()
        let held = FileDifference(
            relativePath: fixture.differed.relativePath, leftItemPath: fixture.differed.leftItemPath,
            rightItemPath: fixture.differed.rightItemPath, type: .differentDates, action: .copyToRight,
            description: "Sizes differ", leftFileSize: 4, rightFileSize: 5, heldBack: .sizesDifferWithoutANewerSide)
        let stamp = FilePairStamp.read(fixture.identical, fileManager: manager.fileManager)
        try #require(stamp.left != nil && stamp.right != nil)

        await manager.bulkCopyDifferencesLeftToRight([fixture.identical, held], asOf: manager.fileOperationsEpoch,
                                                     stamps: [fixture.identical.id: stamp])

        let banner = try #require(manager.banner)
        #expect(banner.message
                == "1 date matched; 1 item needs your decision and was left out — right-click its row to choose which to keep")
        #expect(banner.severity == .warning)
        #expect(banner.isUndoable, "the dates it matched are undoable, and the banner hid it")
        #expect(manager.undoManager?.canUndo == true)
    }

    /// A date match is a run in Sync History, and Undo Last Run reverses it, as ⌘Z does. The
    /// record names the date it replaced. Dates a day apart, so the restore can't be an accident
    /// of the fixture's timing.
    @MainActor
    @Test func testADateMatchIsRecordedInSyncHistoryAndUndoneByUndoLastRun() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let store = makeTempHistoryStore(prefix: "DateMatchHistory")
        defer { removeHistoryStoreFiles(store) }
        manager.syncHistoryStore = store
        manager.undoManager = UndoManager()
        let leftPath = fixture.identical.leftItemPath
        let leftDate = Date(timeIntervalSince1970: 1_600_000_000)
        let rightDate = leftDate.addingTimeInterval(86_400)
        try FileManager.default.setAttributes([.modificationDate: leftDate], ofItemAtPath: leftPath)
        try FileManager.default.setAttributes([.modificationDate: rightDate], ofItemAtPath: fixture.rightIdenticalURL.path)
        func date() throws -> Date? {
            try FileManager.default.attributesOfItem(atPath: fixture.rightIdenticalURL.path)[.modificationDate] as? Date
        }

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id])
        await manager.confirmVerifiedCopy()?.value
        try #require(try date() == leftDate, "the premise: the dates were matched")

        #expect(store.records.count == 1, "\(store.records.map(\.action))")
        let record = try #require(store.records.first, "the date match left nothing in Sync History")
        #expect(record.action == .matchDates)
        #expect(record.sourcePath == leftPath)
        #expect(record.destPath == fixture.rightIdenticalURL.path)
        #expect(record.direction == "→ Right")
        #expect(record.sizeBytes == 9)
        #expect(record.previousModificationDate == rightDate, "the record does not say which date the match replaced (E11)")

        let preview = try #require(manager.lastSyncRunUndoPreview, "Undo Last Run refused the date match: \(manager.lastSyncRunUndoRefusal ?? "nil")")
        #expect(preview.actionName == "Match 1 Date")
        #expect(preview.records.map(\.id) == [record.id])
        #expect(preview.confirmationDetail() == """
            This reverses 1 operation from the last run (1 date match):
              •  Put back the date of “same.txt”

            Files whose dates were matched get their own dates back, unless changed since. You can redo this afterward.
            """)

        var asked = false
        let refusal = manager.undoLastSyncRunAskingFirst { _ in asked = true; return true }
        #expect(refusal == nil)
        #expect(asked)
        await waitUntil("the date-match undo drains") { manager.activeFileOperationsCount == 0 }
        #expect(try date() == rightDate, "Undo Last Run did not give the right file its own date back")
    }

    /// A pair whose left is a symbolic link verifies identical (Verify reads the file it points
    /// to), but the left-to-right run must never write the link over the real file on the right,
    /// nor re-date anything through it. Left out, and said so.
    @MainActor
    @Test func testAVerifiedPairWhoseLeftIsALinkIsLeftOutOfTheRun() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let leftURL = URL(fileURLWithPath: fixture.identical.leftItemPath)
        let target = leftURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("target.txt")
        try Data("identical".utf8).write(to: target)
        try FileManager.default.removeItem(at: leftURL)
        try FileManager.default.createSymbolicLink(at: leftURL, withDestinationURL: target)
        let rightDateBefore = try FileManager.default.attributesOfItem(atPath: fixture.rightIdenticalURL.path)[.modificationDate] as? Date

        await manager.verifyAllWithChecksum()
        try #require(manager.verifiedIdenticalForCopy?.differences.map(\.id) == [fixture.identical.id],
                     "the premise: Verify reads through the link and finds the pair identical")

        await manager.confirmVerifiedCopy()?.value

        let rightAttributes = try FileManager.default.attributesOfItem(atPath: fixture.rightIdenticalURL.path)
        #expect(rightAttributes[.type] as? FileAttributeType == .typeRegular, "the link was written over the real file")
        #expect(rightAttributes[.modificationDate] as? Date == rightDateBefore)
        #expect(try Data(contentsOf: fixture.rightIdenticalURL) == Data("identical".utf8))
        #expect(manager.differences.map(\.id).contains(fixture.identical.id), "the held row was resolved anyway")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("left out") == true, "banner: \(manager.banner?.message ?? "nil")")
    }

    /// The size half of the stamp, which no same-size fixture reaches. A writer that restores the
    /// timestamp it found (`rsync -t`, a backup restore, a provider keeping the server's mtime)
    /// leaves only the length differing. Done with real filesystem operations, not by reaching
    /// into the guard.
    @MainActor
    @Test func testConfirmRefusesAMtimePreservingRewriteOfADifferentLength() async throws {
        let fixture = try makeRaceFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let fm = FileManager.default
        // Pinned to a whole second before the pass stamps it: `Data.write`'s sub-second mtime
        // doesn't survive `setAttributes`, so restoring it would move the mtime slightly and the
        // test would pass on the wrong term.
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

    /// An offer with no stamps for its pairs can't substantiate its verdicts, so it costs a
    /// re-verify, not an unchecked bulk write. Like `asOf`, the guard fails closed.
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
                == "“diff.txt” cannot be re-checked against its verification — run Verify All again")
    }
}
