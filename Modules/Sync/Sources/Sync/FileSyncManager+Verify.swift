import Events
import Foundation

extension FileSyncManager {

    /// Runs checksum verification on the differences that meet the Verify criteria (newer/older but same size).
    /// Pass `subset` to scope verification to specific differences (e.g. the current table selection or
    /// filtered set); `nil` verifies every eligible difference. Runs up to 4 verifications in parallel.
    /// Cancellable via activeProgress. When done, if any verified identical, sets `verifiedIdenticalForCopy` so the UI can offer to copy left→right.
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
        guard !toVerify.isEmpty else { return }

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
        // Only publish the copy offer if no rescan superseded these differences while we hashed
        // AND no file operation started since the hash began (see `startOperationsEpoch` above —
        // an operation that ran start-to-finish mid-hash may have rewritten the very bytes these
        // verdicts describe, before its rescan could move the generation).
        if !verifiedIdentical.isEmpty, scanRequestGeneration == startGeneration,
           fileOperationsEpoch == startOperationsEpoch {
            // The assignment stamps `verifiedIdenticalForCopyEpoch` itself (see its didSet); the
            // guard above has just established that the live epoch is still the one these
            // verdicts were hashed under, so the stamp is exactly `startOperationsEpoch`.
            verifiedIdenticalForCopy = verifiedIdentical
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

    /// Dismisses the "copy verified" dialog without copying; hides the verified identical items from the list.
    public func dismissVerifiedCopyDialogWithoutCopy() {
        guard let list = verifiedIdenticalForCopy else { return }
        for diff in list {
            verifiedSameDifferenceIds.insert(diff.id)
        }
        verifiedIdenticalForCopy = nil
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
        guard let list = verifiedIdenticalForCopy, !list.isEmpty else { return nil }
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
        // restored. `bulkCopyDifferencesLeftToRight` deliberately does not refuse on the count,
        // so nothing downstream would catch it. Same pairing as this file's entry guard and
        // `sweepOrphanedTempArtifactsNow`.
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
        guard fileOperationsEpoch == verifiedIdenticalForCopyEpoch,
              activeFileOperationsCount == 0 else {
            verifiedIdenticalForCopy = nil
            banner = .warning("A file operation ran or is pending — run Verify All again")
            return nil
        }
        verifiedIdenticalForCopy = nil
        return Task { await self.bulkCopyDifferencesLeftToRight(list) }
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
