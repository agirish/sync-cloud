import Events
import Foundation

/// A "copy the verified-identical files left→right" offer, together with the
/// `fileOperationsEpoch` its verdicts were hashed under.
///
/// The two are ONE value on purpose. `confirmVerifiedCopy()` compares `asOf` against the live
/// epoch and refuses the bulk copy if a file operation has intervened, so the stamp is the
/// difference between a checked write and an unchecked one. Kept as a separate property it was
/// maintained by a `didSet` on the list, which certified whatever anyone assigned as current —
/// and that made a data-integrity guard fail OPEN. A writer that publishes a STALE list (a
/// stashed offer, a restored one, a future caller reusing the property) got it waved through
/// into a silent bulk overwrite, which is the expensive direction. Making the stamp part of the
/// value means it cannot be forgotten rather than being supplied wrongly by default; and a
/// caller who supplies the wrong one now fails CLOSED — one refused copy and a banner saying
/// so, which is visible and recoverable.
///
/// It also restores the state space to tests. While every assignment auto-certified itself, an
/// offer stamped BEHIND the live epoch could not be constructed at all except by driving a real
/// verify pass across a real file operation, so exactly one test covered the guard and every
/// other test of this path was blind to it.
public struct VerifiedCopyOffer: Equatable, Sendable {
    /// The differences that verified byte-identical.
    public let differences: [FileDifference]
    /// `fileOperationsEpoch` as it stood when these verdicts were taken.
    public let asOf: Int

    public init(differences: [FileDifference], asOf: Int) {
        self.differences = differences
        self.asOf = asOf
    }
}

extension FileSyncManager {

    /// Runs checksum verification on the differences that meet the Verify criteria (newer/older but same size).
    /// Pass `subset` to scope verification to specific differences (e.g. the current table selection or
    /// filtered set); `nil` verifies every eligible difference. Runs up to 4 verifications in parallel.
    /// Cancellable via activeProgress.
    ///
    /// When done it publishes `verifiedIdenticalForCopy` — the offer the UI turns into a
    /// copy-left→right dialog — stamped with the file-operations epoch its verdicts were hashed
    /// under, and only while nothing has superseded them.
    ///
    /// A pass that ends with nothing to offer RETRACTS any offer still standing rather than
    /// leaving it, and that covers all three ways of getting there: no ELIGIBLE candidates, no
    /// pair verifying identical, or CANCELLATION — which keeps only the partial set that
    /// happened to drain before the click, and is the one the user actively asked to stop.
    /// Retracting matters because this pass is read-only: the confirm-time guards would see an
    /// unmoved epoch and a zero count, and let the old list through to a bulk disk write.
    public func verifyAllWithChecksum(subset: [FileDifference]? = nil) async {
        // Refuse to start while anything is writing — or is about to write — the files this
        // run would hash: a file mid-overwrite can checksum as "identical" and poison
        // `verifiedIdenticalForCopy` with a wrong bulk-copy offer. `isBulkSyncRunning` covers
        // both bulk runs — syncAll from its prepare phase (stat pass + collision prompts,
        // before any operation is enqueued) and the verified-copy bulk copy;
        // `syncingDifferenceIds` covers a single syncFile parked at its collision
        // prompt; `activeFileOperationsCount` covers every queued file operation (copy, move,
        // delete, undo). Verify is read-only, so this is purely about result validity — and
        // the user gets a banner, not a silent no-op.
        guard !isVerifyAllRunning, !isBulkSyncRunning,
              activeFileOperationsCount == 0, syncingDifferenceIds.isEmpty else {
            banner = .warning("Wait for the current operation to finish before verifying")
            return
        }
        isVerifyAllRunning = true
        defer { isVerifyAllRunning = false }

        let candidates = subset ?? differences
        let toVerify = candidates.filter { $0.type == .differentDates && $0.sizesMatch }
        // Retract here too, not only at the empty-verdict branch below: this early return is in
        // FRONT of it, so a pass with no eligible candidates used to leave a standing offer
        // untouched — and that is the COMMON empty case, not the rare one. Verify All is always
        // invoked with a subset in production (the current selection), so "the selection holds
        // no date-only same-size row" is one stray click away, while an eligible set that
        // verifies nothing identical takes a real hashing pass to reach. Same reasoning as
        // below: this pass has nothing to offer, so the standing offer is no better supported
        // than it was, and verify writes nothing — the confirm-time guards would see an unmoved
        // epoch and wave the old list through.
        guard !toVerify.isEmpty else {
            verifiedIdenticalForCopy = nil
            return
        }

        // The differences being hashed belong to this scan generation. A rescan can complete
        // during the long parallel hashing (a finished file op fires refreshSubject), replacing
        // `differences` with regenerated rows; publishing the copy offer then would point it at a
        // superseded set. Capture the generation now and re-check before publishing (same guard
        // autoVerifySameSizePairs uses).
        let startGeneration = scanRequestGeneration
        // A rescan is not the only way the hashed bytes go stale. A file operation can overwrite
        // a candidate mid-hash and FINISH before its refresh-triggered rescan bumps the
        // generation, so the generation guard alone still publishes verdicts that predate the
        // write — and this offer feeds a bulk disk write on confirm. Undo is the live route:
        // every write path is gated on `isVerifyAllRunning` EXCEPT ⌘Z, deliberately (see the
        // commit body — blocking undo during a long verify would be its own regression), and it
        // reaches the disk through `enqueueFileOperation` like everything else. Capture the
        // operations epoch (bumped there before any I/O runs) and re-check it before publishing,
        // mirroring `autoVerifySameSizePairs`.
        let startOperationsEpoch = fileOperationsEpoch

        let progress = Progress(totalUnitCount: Int64(toVerify.count))
        progress.localizedDescription = "Verifying \(toVerify.count) files"
        progress.isCancellable = true
        activeProgress = progress
        verifyAllProgress = (0, toVerify.count)

        defer {
            verifyAllProgress = nil
            // Clear only if still ours: a queued operation may have published its own by now.
            if activeProgress === progress { activeProgress = nil }
        }

        let activeFM = fileManager
        let collector = VerifyResultsCollector()
        let weakRef = WeakSyncManagerRef(self)
        let totalCount = toVerify.count
        // One @Published write per whole percent instead of one per file — see
        // `ProgressPublishGate` for what the ungated version cost the window.
        let publishGate = ProgressPublishGateBox()

        await Self.processInParallel(
            items: toVerify,
            concurrency: min(4, max(1, toVerify.count)),
            progress: ProgressRef(progress),
            reportCompleted: { completed in
                guard publishGate.admits(completed: completed, total: totalCount) else { return }
                weakRef.value?.verifyAllProgress = (completed, totalCount)
            }
        ) { diff in
            let same = await FileContentVerifier.filesHaveSameContent(
                leftPath: diff.leftItemPath,
                rightPath: diff.rightItemPath,
                fileManager: activeFM,
                cache: ContentHashCache.shared
            )
            if same == true {
                await collector.addIdentical(diff)
            } else if same == false {
                await collector.addDiffered()
            } else {
                await collector.addSkipped()
            }
        }

        let (verifiedIdentical, differed, skipped) = await collector.get()
        if progress.isCancelled || verifiedIdentical.isEmpty {
            // Nothing this pass stands behind, so retract any offer a previous pass left standing.
            // Falling through instead — which is what the publish condition alone did — leaves
            // the old list AND its old stamp in place, and nothing downstream would catch it:
            // verify writes nothing, so the epoch has not moved and the count is zero, and
            // `confirmVerifiedCopy`'s guards both pass. The user would confirm a bulk copy over
            // a list this very pass declined to stand behind.
            //
            // Deliberately unconditional on the two supersedence checks below. Whatever the
            // reason this pass has nothing to offer, the standing offer is no better supported
            // than it was — and the cost of dropping it is one re-verify, against a bulk disk
            // write for keeping it.
            //
            // Cancellation lands here for the same reason, and it is the branch's live case.
            // `processInParallel` stops pulling items once the progress is cancelled, so the
            // collector holds whatever happened to drain first — a PARTIAL result the user
            // never asked to have completed. Publishing it offered someone who had just hit
            // Cancel a one-permission bulk write over however many pairs got hashed before the
            // click ("180 files verified identical… No per-file confirmation"), behind a banner
            // reading "Verify All cancelled". The two surfaces contradicted each other, and the
            // expensive one won. Those partial verdicts are sound, but nobody asked for them:
            // re-run Verify All to get an offer.
            verifiedIdenticalForCopy = nil
        } else if scanRequestGeneration == startGeneration,
                  fileOperationsEpoch == startOperationsEpoch {
            // Publish only if no rescan superseded these differences while we hashed AND no file
            // operation started since the hash began (see `startOperationsEpoch` above — an
            // operation that ran start-to-finish mid-hash may have rewritten the very bytes
            // these verdicts describe, before its rescan could move the generation).
            //
            // Stamped with the epoch the verdicts were actually hashed under, not with whatever
            // the live epoch happens to read at this instant. The guard above has just
            // established the two are the same, so this is the honest one of the pair.
            verifiedIdenticalForCopy = VerifiedCopyOffer(
                differences: verifiedIdentical, asOf: startOperationsEpoch
            )
        }
        var parts: [String] = []
        if !verifiedIdentical.isEmpty { parts.append("\(verifiedIdentical.count) identical") }
        if differed > 0 { parts.append("\(differed) differed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if progress.isCancelled {
            banner = .warning("Verify All cancelled")
        } else if parts.isEmpty {
            banner = nil
        } else {
            let message = "Verify All: " + parts.joined(separator: "; ")
            // Anything that differed or couldn't be verified needs the user's attention.
            banner = (differed > 0 || skipped > 0) ? .warning(message) : .success(message)
        }
    }

    /// Dismisses the "copy verified" dialog without copying; hides the verified identical items
    /// from the list — but only on verdicts still worth acting on.
    ///
    /// Hiding a row is a claim about the files ("these two are byte-identical, stop showing me"),
    /// so it rests on the same verdicts the copy would have. `confirmVerifiedCopy` refuses
    /// outright once the epoch has moved or an operation is pending; dismissing under those same
    /// conditions used to hide every row in the offer regardless, which is the one thing a
    /// refusal is not allowed to do — quietly resolve what it declined to act on. An undo landing
    /// while the dialog is up makes a verified pair genuinely differ again, and Cancel would hide
    /// it along with the rest; the undo's own rescan re-derives the row, but only if it completes
    /// and is not superseded, so the hide could outlive its justification until a manual rescan.
    ///
    /// Same terms as the confirm guard, for the same reasons (see there). Dropping the offer is
    /// unconditional either way — it is the hiding that has to be earned.
    public func dismissVerifiedCopyDialogWithoutCopy() {
        guard let offer = verifiedIdenticalForCopy else { return }
        verifiedIdenticalForCopy = nil
        guard fileOperationsEpoch == offer.asOf, activeFileOperationsCount == 0 else { return }
        for diff in offer.differences {
            verifiedSameDifferenceIds.insert(diff.id)
        }
        Task { await self.applyFilters() }
    }

    /// For the dialog's `isPresented` binding: defers the "dismissed without copy" cleanup by one
    /// main-actor turn. SwiftUI writes `false` into the binding on ANY dismissal — including the
    /// confirm button — and the order of the setter vs. the button action is not guaranteed, so
    /// cleaning up synchronously here could destroy the list before `confirmVerifiedCopy()` claims
    /// it. Both button paths run synchronously in the same turn; whichever claimed the list first
    /// wins and this deferred cleanup becomes a no-op.
    /// - Returns: The deferred cleanup task, so tests can await the turn instead of sleeping for a
    ///   guessed duration (same reason `confirmVerifiedCopy()` hands back its copy task).
    @discardableResult
    public func verifiedCopyDialogDismissed() -> Task<Void, Never> {
        Task { @MainActor in
            self.dismissVerifiedCopyDialogWithoutCopy()
        }
    }

    /// Claims the verified-identical list synchronously and starts the bulk copy left→right.
    /// Must be called directly from the confirm button (not inside a `Task`) so the claim happens
    /// before `verifiedCopyDialogDismissed()`'s deferred cleanup can hide the list.
    /// - Returns: The copy task, so tests can await completion. `nil` if there was nothing to copy.
    @discardableResult
    public func confirmVerifiedCopy() -> Task<Void, Never>? {
        guard let offer = verifiedIdenticalForCopy, !offer.differences.isEmpty else { return nil }
        // The offer can outlive its verdicts: a file operation (an unguarded ⌘Z undo, most
        // directly) landing while the dialog is up rewrites verified bytes, and the rescan that
        // would clear the offer only does so when it COMPLETES — seconds later on a large tree.
        // A confirm inside that window would bulk-overwrite the bytes the operation just wrote.
        // Refuse it: the operation's rescan is already on its way to re-derive fresh rows.
        //
        // BOTH terms are load-bearing, because they answer different questions. The epoch says
        // an operation already RAN. The count says one is already claimed and about to run:
        // every undo/redo path calls `preCountFileOperation()` synchronously and only reaches
        // `enqueueFileOperation` — where the epoch is bumped — from inside a `Task`, and since
        // this type is `@MainActor` that hop is a real suspension point. On the epoch alone a
        // confirm placed in that gap passes, the undo's task then claims the serial queue
        // first, and the bulk copy queues behind it and overwrites the bytes the undo just
        // restored. The count term is the one this file's entry guard and
        // `sweepOrphanedTempArtifactsNow` also carry; the PAIRING is unique to here, since
        // neither of those looks at the epoch at all.
        //
        // Checked again inside `bulkCopyDifferencesLeftToRight`, on the same two terms, because
        // these readings age: the run is several main-actor hops from ordering its write. This
        // guard is still the one that keeps the offer and the banner honest at click time — the
        // one downstream refuses a run that is already under way.
        //
        // Not in tension with the scan-checksum pass, which is epoch-ONLY at commit time on
        // purpose (see `autoVerifySameSizePairs`): there, a pre-counted operation the user then
        // DECLINES ran no I/O, so voiding a whole hashed batch for it cost real coverage and
        // bought nothing. Here the cost of refusing a pre-counted operation is one re-verify,
        // and the cost of allowing it is a bulk disk write over bytes nobody verified. Do not
        // simplify one guard into the other.
        //
        // The wording says only what the guard OBSERVED — "an operation ran, or one is pending".
        // It cannot tell whether any VERIFIED file was touched: a filing move on the other pane,
        // an undo of a folder rename, an unrelated delete all land here too.
        guard fileOperationsEpoch == offer.asOf, activeFileOperationsCount == 0 else {
            verifiedIdenticalForCopy = nil
            banner = .warning("A file operation ran or is pending — run Verify All again")
            return nil
        }
        verifiedIdenticalForCopy = nil
        // Hand the stamp on so the run can re-check it at the moment it orders the write; these
        // readings are already several main-actor hops old by the time that happens.
        return Task { await self.bulkCopyDifferencesLeftToRight(offer.differences, asOf: offer.asOf) }
    }

    /// The scan-time checksum pass behind `autoVerifySameSizeDuringScan`: hashes each pair that
    /// only differs by date (same size, both sides present) and silently hides the identical
    /// ones via `verifiedSameDifferenceIds` — the same mechanism as a dismissed Verify All, so
    /// the rows reappear if a later scan finds them genuinely changed.
    ///
    /// Unlike Verify All this never publishes progress or offers the copy-to-match-dates
    /// dialog, and it does not claim `isVerifyAllRunning` — blocking a bulk sync behind an
    /// automatic pass the user didn't ask for would be worse than re-hashing. Validity is
    /// protected the other way: the pass skips entirely while anything is writing, skips
    /// rows that start syncing, and publishes only while `scanGeneration` is still current
    /// (a newer scan supersedes both the rows and their verification).
    func autoVerifySameSizePairs(scanGeneration: Int) async {
        guard autoVerifySameSizeDuringScan,
              !isVerifyAllRunning, !isBulkSyncRunning,
              activeFileOperationsCount == 0 else { return }

        // The entry guard above only proves nothing was writing when the pass STARTED. A
        // copy/move that begins during the long parallel hash can overwrite a candidate
        // mid-read, and if it also finishes before the commit below — before its rescan bumps
        // `scanRequestGeneration` — a pre-operation "identical" verdict would hide a row that
        // now genuinely differs. Capture the operations epoch (bumped whenever an operation
        // begins, never decremented) and discard the whole batch if it moved: stronger than
        // re-checking `activeFileOperationsCount == 0`, which an op that ran start-to-finish
        // during the hash would pass.
        let startOperationsEpoch = fileOperationsEpoch

        let candidates = rawDifferences.filter {
            $0.type == .differentDates && $0.sizesMatch && !syncingDifferenceIds.contains($0.id)
        }
        guard !candidates.isEmpty else { return }

        let activeFM = fileManager
        let collector = VerifyResultsCollector()
        // A private Progress solely for processInParallel's cancellation contract — never
        // published, so nothing shows in the UI.
        let progress = Progress(totalUnitCount: Int64(candidates.count))

        await Self.processInParallel(
            items: candidates,
            concurrency: min(4, candidates.count),
            progress: ProgressRef(progress),
            reportCompleted: { _ in }
        ) { diff in
            let same = await FileContentVerifier.filesHaveSameContent(
                leftPath: diff.leftItemPath,
                rightPath: diff.rightItemPath,
                fileManager: activeFM,
                cache: ContentHashCache.shared
            )
            if same == true {
                await collector.addIdentical(diff)
            }
        }

        let identical = await collector.get().verifiedIdentical
        // Publish only against the scan the candidates came from; a newer scan owns the rows
        // now. Checked AFTER the last suspension point above, so a scan requested while the
        // collector drained can't slip past the gate.
        guard scanGeneration == scanRequestGeneration else { return }
        // Re-check the operations epoch at commit time (see `startOperationsEpoch` above): an
        // operation that started — even one that already finished — since entry may have
        // rewritten the very bytes these verdicts describe. Discard the batch; the operation's
        // own rescan re-runs this pass over fresh rows.
        //
        // The epoch is the WHOLE commit-time exclusion, deliberately: re-checking the entry
        // guard's other two terms discarded batches that nothing had written. The count can
        // only exceed the epoch's knowledge for an operation pre-counted but not yet enqueued
        // — its confirmation prompt still up — and `isBulkSyncRunning` is latched before
        // syncAll's read-only stat pass and prompts; in both states not a byte has been
        // written, since every write goes through `enqueueFileOperation`, which bumps the
        // epoch first. Discarding on them cost real coverage: if the user then DECLINED, no
        // I/O ran, nothing sent `refreshSubject`, and no rescan re-ran this pass — so pairs
        // already hashed as identical stayed listed until a manual rescan.
        guard fileOperationsEpoch == startOperationsEpoch else {
            Logger.shared.debug("Scan checksum pass: discarded — the file operations epoch moved mid-hash")
            return
        }
        let liveIds = Set(rawDifferences.map(\.id))
        let ids = identical.map(\.id).filter { liveIds.contains($0) }
        guard !ids.isEmpty else { return }

        verifiedSameDifferenceIds.formUnion(ids)
        Logger.shared.info("Scan checksum pass: hid \(ids.count) same-size pair(s) with identical content")
        await applyFilters()
    }
}

// MARK: - Verify-all parallel workers

private actor VerifyResultsCollector {
    private var verifiedIdentical: [FileDifference] = []
    private var differed: Int = 0
    private var skipped: Int = 0
    func addIdentical(_ diff: FileDifference) {
        verifiedIdentical.append(diff)
    }
    func addDiffered() { differed += 1 }
    func addSkipped() { skipped += 1 }
    func get() -> (verifiedIdentical: [FileDifference], differed: Int, skipped: Int) {
        (verifiedIdentical, differed, skipped)
    }
}
