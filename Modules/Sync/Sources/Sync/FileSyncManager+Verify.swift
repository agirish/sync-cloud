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

        await Self.processInParallel(
            items: toVerify,
            concurrency: min(4, max(1, toVerify.count)),
            progress: ProgressRef(progress),
            reportCompleted: { completed in weakRef.value?.verifyAllProgress = (completed, totalCount) }
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
        // Only publish the copy offer if no rescan superseded these differences while we hashed.
        if !verifiedIdentical.isEmpty, scanRequestGeneration == startGeneration {
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
    public func verifiedCopyDialogDismissed() {
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
