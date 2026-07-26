import Events
import Foundation

extension FileSyncManager {

    /// Bulk copy the given differences from left to right (overwrites if exists). No per-file confirmation; 2–4 concurrent copies.
    /// Internal (not private) because `confirmVerifiedCopy` in FileSyncManager+Verify.swift starts it.
    func bulkCopyDifferencesLeftToRight(_ toCopy: [FileDifference]) async {
        let total = toCopy.count
        guard total > 0 else { return }
        // Same exclusion as syncAll: this run writes `bulkSyncProgress` and nils it in its
        // defer, so overlapping a bulk sync would interleave the shared counter and tear down
        // the survivor's overlay — and syncAll's up-front destination stats would be staled by
        // these overwrites. A concurrent Verify All would hash files mid-overwrite. And a
        // single-row syncFile in flight (possibly parked at its prompt) may target one of
        // these very differences; this run's defer would also clearSyncing the parked row's
        // id out from under it. Refuse visibly, mirroring syncAll's guards.
        guard !isBulkSyncRunning, !isVerifyAllRunning, syncingDifferenceIds.isEmpty else {
            banner = .warning("Wait for the current operation to finish before copying")
            return
        }
        isBulkSyncRunning = true
        let toCopyIDs = Set(toCopy.map { $0.id })

        let progress = Progress(totalUnitCount: Int64(total))
        progress.localizedDescription = "Copying \(total) files to match dates"
        progress.isCancellable = true
        activeProgress = progress

        markSyncing(ids: toCopyIDs)
        bulkSyncProgress = (0, total)

        // Yield so the progress overlay can render before we block on the copy work.
        await MainActor.run { }

        defer {
            isBulkSyncRunning = false
            bulkSyncProgress = nil
            if activeProgress === progress { activeProgress = nil }
            clearSyncing(ids: toCopyIDs)
        }

        let activeFM = fileManager
        let workList: [(FileDifference, URL, URL, Bool)] = toCopy.map { diff in
            (diff, URL(fileURLWithPath: diff.leftItemPath), URL(fileURLWithPath: diff.rightItemPath), false)
        }

        let progressRef = ProgressRef(progress)
        let weakRef = WeakSyncManagerRef(self)
        let totalCount = total

        let result = await enqueueFileOperation {
            await Self.performBulkSyncIO(
                workList: workList,
                concurrency: min(4, max(2, workList.count)),
                progress: progressRef,
                fileManager: activeFM,
                reportCompleted: { completed in weakRef.value?.bulkSyncProgress = (completed, totalCount) }
            )
        }

        // Group the whole run's per-file undo registrations into ONE undo step so "Undo last
        // sync run" (and ⌘Z) reverses the entire bulk copy at once, reusing the existing
        // per-file reversal — no new mutation path. The group is named so the run reads as a
        // unit in the Undo menu. Skip the empty case so no phantom group is opened.
        let runId = UUID()
        var historyRecords: [SyncHistoryRecord] = []
        if !result.successes.isEmpty { undoManager?.beginUndoGrouping() }
        for (diff, (trashed, from, to)) in result.successes {
            let actionName = "Sync \(diff.relativePath.components(separatedBy: "/").last ?? "")"
            registerCopyUndo(items: [(source: from, destination: to, overwritten: trashed)], actionName: actionName, fileManager: activeFM)
            historyRecords.append(SyncHistoryRecord(
                runId: runId,
                action: .copy,
                sourcePath: from.path,
                destPath: to.path,
                sizeBytes: diff.leftFileSize,
                checksum: nil,
                backupPath: trashed?.path,
                direction: "→ Right"
            ))
        }
        if !result.successes.isEmpty {
            undoManager?.setActionName("Sync run")
            undoManager?.endUndoGrouping()
        }
        recordSyncHistory(historyRecords)
        removeResolvedDifferences(matching: result.successes.map { $0.0 })
        // No per-failure isSyncing reset here: the defer above clears the flag for every
        // item of this run, and nothing can observe the list before it runs.
        if result.failures.count == 1, let (diff, error) = result.failures.first {
            present(.copyFailed(
                items: "\"\(diff.relativePath)\"",
                path: diff.leftItemPath,
                reason: error.localizedDescription
            ))
        } else if result.failures.count > 1 {
            // Same aggregation as syncAll: one alert summarizes; every failure is logged.
            for (diff, error) in result.failures {
                Logger.shared.error(SyncError.copyFailed(
                    items: "\"\(diff.relativePath)\"",
                    path: diff.leftItemPath,
                    reason: error.localizedDescription
                ).logDescription)
            }
            let (firstDiff, firstError) = result.failures[0]
            present(.bulkFailed(
                verb: "copy",
                failureCount: result.failures.count,
                firstItem: firstDiff.relativePath,
                firstPath: firstDiff.leftItemPath,
                firstReason: firstError.localizedDescription
            ))
        }
        if !result.failures.isEmpty {
            banner = .warning("\(result.successes.count) copied; \(result.failures.count) failed")
        } else if !result.successes.isEmpty {
            // The whole run's per-file undos are wrapped in one group above, so ⌘Z reverses it all.
            banner = .success("\(result.successes.count) files copied — dates matched", undoable: true)
        }
        // Summary breadcrumb for the bulk path: a single-file copy already logs its "Copied …"
        // line, but a "Copy All" of hundreds of files otherwise leaves no successful-outcome
        // record — only the per-failure ERROR lines above. Log the count so the batch is visible.
        if !result.successes.isEmpty {
            Logger.shared.info("Copied \(result.successes.count) item(s) in bulk\(result.failures.isEmpty ? "" : ", \(result.failures.count) failed")")
        }
    }

    /// Shared scaffolding for the parallel bulk-sync / verify workers: a work queue drained by
    /// up to `concurrency` tasks, stopping early once the progress is cancelled. After each item
    /// the shared completed count (offset by `completedBase`, for items resolved before the
    /// workers started) is mirrored into the `Progress` and reported on the MainActor.
    /// Internal (not private) because `verifyAllWithChecksum` in FileSyncManager+Verify.swift
    /// runs its checksum workers on the same scaffolding.
    nonisolated static func processInParallel<Item: Sendable>(
        items: [Item],
        concurrency: Int,
        progress progressRef: ProgressRef,
        completedBase: Int = 0,
        reportCompleted: @escaping @MainActor @Sendable (Int) -> Void,
        handle: @escaping @Sendable (Item) async -> Void
    ) async {
        let queue = WorkQueue(items: items)
        let counter = CompletedCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    while !progressRef.progress.isCancelled, let item = await queue.next() {
                        await handle(item)
                        let completed = completedBase + (await counter.increment())
                        progressRef.progress.completedUnitCount = Int64(completed)
                        await MainActor.run { reportCompleted(completed) }
                    }
                }
            }
        }
    }

    /// Runs the copy/move I/O for a prepared bulk work list on the parallel scaffolding,
    /// collecting per-difference successes and failures. Shared by `syncAll` and
    /// `bulkCopyDifferencesLeftToRight`.
    private nonisolated static func performBulkSyncIO(
        workList: [(FileDifference, URL, URL, Bool)],
        concurrency: Int,
        progress progressRef: ProgressRef,
        completedBase: Int = 0,
        fileManager: FileManaging,
        reportCompleted: @escaping @MainActor @Sendable (Int) -> Void
    ) async -> (successes: [(FileDifference, (URL?, URL, URL))], failures: [(FileDifference, Error)]) {
        let collector = BulkSyncResultsCollector()
        await processInParallel(
            items: workList,
            concurrency: concurrency,
            progress: progressRef,
            completedBase: completedBase,
            reportCompleted: reportCompleted
        ) { item in
            let (diff, fromURL, toURL, isMove) = item
            do {
                let syncResult = try performFileSyncIO(from: fromURL, to: toURL, isMove: isMove, fileManager: fileManager)
                await collector.addSuccess(diff, (syncResult.trashed, syncResult.from, syncResult.to))
            } catch {
                await collector.addFailure(diff, error)
            }
        }
        return await collector.get()
    }

    /// Resolves all differences in one direction by copying or moving each matching item (same behavior as per-file sync; collisions show "Apply to all" when applicable).
    /// Runs up to 4 file operations in parallel. Cancellation completes the current file then stops before starting new ones.
    /// - Parameters:
    ///   - direction: Which direction to sync (e.g. `.copyToRight` → copy all that are "missing on right" or "left newer").
    ///   - isMove: If true, moves each file; otherwise copies.
    ///   - subset: When non-nil, only differences in this array are considered (e.g. the currently filtered list). When nil, uses the full `differences` array.
    ///   - confirmed: Pass true when the calling UI already embodies the user's confirmation
    ///     for this exact run (e.g. review mode's "Copy Remaining N…" button, which names the
    ///     count) — the `transferConfirmer` prompt is skipped so one gesture never asks twice.
    public func syncAll(direction: FileDifference.SyncAction, isMove: Bool = false, subset: [FileDifference]? = nil, confirmed: Bool = false, postBanner: Bool = true) async {
        let source = subset ?? differences
        let toSync = source.filter { $0.action == direction }
        let total = toSync.count
        guard total > 0 else { return }
        // Drop, don't queue, a bulk run started while another is in flight (see the flag's doc).
        guard !isBulkSyncRunning else { return }
        // A Verify All in flight is hashing the very files this run would overwrite; starting
        // anyway would feed it half-written content. Tell the user rather than silently drop.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for the current operation to finish before syncing")
            return
        }
        // A single-row syncFile in flight (possibly parked at its prompt — the latch is set
        // before any prompt) may target the very rows this run would stat and copy; running
        // anyway could double-write one difference from two flows. Mirrors Verify All's guard.
        guard syncingDifferenceIds.isEmpty else {
            banner = .warning("Wait for the current operation to finish before syncing")
            return
        }
        // Latch the bulk-sync flag BEFORE the confirmation prompt, not after: the prompt's
        // modal spins the run loop, so a queued second syncAll (or a Verify All, whose guard
        // reads this flag) would otherwise pass its exclusion check while the prompt is up —
        // reopening exactly the overlap these guards exist to prevent. The defer directly
        // below releases it on EVERY exit — decline included — so no future early return
        // can leak the flag and silently disable bulk syncs for the session.
        isBulkSyncRunning = true
        defer { isBulkSyncRunning = false }
        // Confirm before any I/O: a bulk sync is one header click away, so a mis-click must
        // be cancellable while it still costs nothing. The prompt names the two compared
        // folders of the first item — every item in one direction shares them. Callers that
        // already embody the user's confirmation pass `confirmed: true`.
        if !confirmed, let first = toSync.first {
            let containers = first.transferContainers
            let userConfirmed = transferConfirmer(TransferSummary(
                isMove: isMove,
                itemCount: total,
                firstItemName: first.transferURLs.from.lastPathComponent,
                sourceDirectory: containers.from,
                destinationDirectory: containers.to
            ))
            guard userConfirmed else {
                Logger.shared.debug("Bulk \(isMove ? "move" : "sync") of \(total) item(s) cancelled at the confirmation prompt")
                return
            }
        }
        let toSyncIDs = Set(toSync.map { $0.id })
        bulkApplyToAllResolution = nil

        let progress = Progress(totalUnitCount: Int64(total))
        progress.localizedDescription = "Syncing \(total) files"
        progress.isCancellable = true
        activeProgress = progress

        markSyncing(ids: toSyncIDs)

        defer {
            // isBulkSyncRunning is released by the defer installed at the latch above.
            bulkSyncProgress = nil
            bulkApplyToAllResolution = nil
            if activeProgress === progress { activeProgress = nil }
            clearSyncing(ids: toSyncIDs)
        }

        let activeFM = fileManager
        // Resolve from/to URLs first (pure string work), then stat every destination in one
        // detached pass: a per-file synchronous fileExists on the MainActor stalls the UI
        // proportionally to file count on network/cloud volumes before any copying starts.
        // Collision prompts still run afterwards on the MainActor, in list order, with the
        // same resolutions; once a prompt has held the run, the loop below re-stats results
        // the batch saw as missing so externally created destinations still get prompted.
        var candidates: [(difference: FileDifference, fromURL: URL, toURL: URL)] = []
        candidates.reserveCapacity(toSync.count)
        for difference in toSync {
            let urls = difference.transferURLs
            candidates.append((difference, urls.from, urls.to))
        }

        let statURLs = candidates.map(\.toURL)
        let statProgress = ProgressRef(progress)
        let destinationExists = await Task.detached(priority: .userInitiated) { () -> [(exists: Bool, isDirectory: Bool)] in
            // A cancelled run stops stat-ing; the prepare loop below breaks on the same flag
            // before ever reading the remaining (false) placeholders.
            statURLs.map { url in
                guard !statProgress.progress.isCancelled else { return (false, false) }
                var isDir: ObjCBool = false
                let exists = activeFM.fileExists(atPath: url.path, isDirectory: &isDir)
                return (exists, isDir.boolValue)
            }
        }.value

        var preparedList: [(FileDifference, URL, URL, Bool)] = []
        var skippedCount = 0
        // Destinations already claimed by earlier items in THIS batch. Targets are resolved here,
        // up front, but the copies run later in parallel — so a disk-only uniqueness check can't
        // see another pending target. Without this, a keep-both "report 2.txt" could coincide with
        // a different item whose real target is "report 2.txt" (missing at the batch stat), and the
        // workers would overwrite one with the other: silent data loss.
        var reservedTargets = Set<String>()
        // Case sensitivity of the copy destination. On a case-insensitive volume two targets that
        // differ only by case name the same file, so the reserved-target set must collapse case —
        // otherwise two case-variant items pass the in-memory uniqueness check and the parallel
        // workers write to the same file (the disk `fileExists` check already collapses case).
        // Probed for a NOT-YET-EXISTING item: every candidate here is missing on the destination
        // side, so the plain probe could never answer and always fell back to "folds case" — which
        // on a case-sensitive volume uniquified `README.md` to `README 2.md` merely because
        // `Readme.md` was in the same batch, and the next scan then reported the invented name
        // forever.
        let destCaseSensitive = candidates.first.map { FileSyncManager.volumeSupportsCaseSensitiveNamesForNewItem(at: $0.toURL) } ?? true
        func reservedKey(_ path: String) -> String { destCaseSensitive ? path : path.lowercased() }
        // The batch stat above ran before the first prompt. A prompt holds this loop for an
        // unbounded time, during which a destination the batch saw as missing can be created
        // externally — and would then be replaced without its overwrite prompt. Once a prompt
        // has been shown, re-stat the "missing" results (still off the main actor) so such a
        // file gets the same prompt a just-in-time stat would have produced.
        var promptShownSinceStatPass = false
        for (index, candidate) in candidates.enumerated() {
            if progress.isCancelled { break }
            var toURL = candidate.toURL
            var destinationOccupied = destinationExists[index].exists
            var destinationIsDirectory = destinationExists[index].isDirectory
            // Provider name check first: it can redirect the item to a sanitized target,
            // which invalidates this item's batch stat (re-stat below) — and its prompt holds
            // the loop like a collision prompt does, so it sets the same re-stat flag.
            switch checkDestinationName(for: toURL, isMove: isMove) {
            case .skip:
                promptShownSinceStatPass = true
                skippedCount += 1
                continue
            case .sanitized(let sanitizedURL):
                promptShownSinceStatPass = true
                toURL = sanitizedURL
                (destinationOccupied, destinationIsDirectory) = await Self.statExists(at: toURL, fileManager: activeFM)
            case .keepOriginal:
                promptShownSinceStatPass = true
            case .clean:
                break
            }
            if !destinationOccupied && promptShownSinceStatPass {
                (destinationOccupied, destinationIsDirectory) = await Self.statExists(at: toURL, fileManager: activeFM)
            }
            if destinationOccupied {
                let resolution: CollisionResolution
                // A directory collision ALWAYS prompts and is never auto-resolved from the
                // "Apply to all" cache — replacing a folder trashes every item that exists only in
                // the destination, so it must never ride in on a decision the user made for a FILE.
                // This mirrors ConflictPolicy.autoResolution's `guard !isDirectory` (which the
                // single-file and standing-policy paths honor); the interactive bulk cache is the
                // one path that otherwise skips it. A directory decision likewise never SEEDS the
                // cache, so a folder Replace can't silently automate a later file (or folder).
                if let cached = bulkApplyToAllResolution, !destinationIsDirectory {
                    resolution = cached
                } else {
                    promptShownSinceStatPass = true
                    let (res, applyToAll) = bulkCollisionResolver(FileCollision(
                        sourcePath: candidate.fromURL.path,
                        destinationPath: toURL.path,
                        isMove: isMove,
                        isDirectory: destinationIsDirectory
                    ))
                    if applyToAll && !destinationIsDirectory { bulkApplyToAllResolution = res }
                    resolution = res
                }
                switch resolution {
                case .skip:
                    skippedCount += 1
                    continue
                case .keepBoth:
                    let collidingURL = toURL
                    let claimed = reservedTargets
                    let caseSensitive = destCaseSensitive
                    toURL = await Task.detached(priority: .userInitiated) {
                        Self.generateUniqueURL(for: collidingURL, fileManager: activeFM, reserved: claimed, caseSensitiveVolume: caseSensitive)
                    }.value
                case .replace:
                    break
                }
            }
            // Final guard for the non-collision paths (a "missing" target, or a Replace): its plain
            // name may still be one an earlier item's keep-both already claimed this batch. Uniquify
            // against disk + the reserved set so no two items ever share a destination.
            if reservedTargets.contains(reservedKey(toURL.path)) {
                let claimedURL = toURL
                let claimed = reservedTargets
                let caseSensitive = destCaseSensitive
                toURL = await Task.detached(priority: .userInitiated) {
                    Self.generateUniqueURL(for: claimedURL, fileManager: activeFM, reserved: claimed, caseSensitiveVolume: caseSensitive)
                }.value
            }
            reservedTargets.insert(reservedKey(toURL.path))
            preparedList.append((candidate.difference, candidate.fromURL, toURL, isMove))
        }

        // Skipped items still count toward the visible total; treat them as already completed
        // so the progress can reach 100% instead of stalling at (total - skipped).
        progress.completedUnitCount = Int64(skippedCount)
        bulkSyncProgress = (skippedCount, total)
        let skipped = skippedCount
        let progressRef = ProgressRef(progress)
        let weakRef = WeakSyncManagerRef(self)
        let totalCount = total
        let workList = preparedList

        let result = await enqueueFileOperation {
            await Self.performBulkSyncIO(
                workList: workList,
                concurrency: 4,
                progress: progressRef,
                completedBase: skipped,
                fileManager: activeFM,
                reportCompleted: { completed in weakRef.value?.bulkSyncProgress = (completed, totalCount) }
            )
        }

        // Group the whole run's per-file undo registrations into ONE undo step so "Undo last
        // sync run" (and ⌘Z) reverses the entire bulk sync at once, reusing the existing
        // per-file reversal — no new mutation path. Named so the run reads as a unit in the Undo
        // menu; the empty case opens no group.
        let runId = UUID()
        var historyRecords: [SyncHistoryRecord] = []
        if !result.successes.isEmpty { undoManager?.beginUndoGrouping() }
        for (diff, (trashed, from, to)) in result.successes {
            let actionName = "Sync \(diff.relativePath.components(separatedBy: "/").last ?? "")"
            if isMove {
                registerMoveUndo(items: [(from: from, to: to, overwritten: trashed)], actionName: actionName, fileManager: activeFM)
            } else {
                registerCopyUndo(items: [(source: from, destination: to, overwritten: trashed)], actionName: actionName, fileManager: activeFM)
            }
            // Size is free from the difference (source side). Checksum is deliberately nil at op
            // time: hashing inline would slow a bulk run of hundreds of files — the "with
            // checksum" contract is met by the field existing, to be populated by a later Verify.
            let size = diff.action == .copyToRight ? diff.leftFileSize : diff.rightFileSize
            historyRecords.append(SyncHistoryRecord(
                runId: runId,
                action: isMove ? .move : .copy,
                sourcePath: from.path,
                destPath: to.path,
                sizeBytes: size,
                checksum: nil,
                backupPath: trashed?.path,
                direction: diff.action == .copyToRight ? "→ Right" : "← Left"
            ))
        }
        if !result.successes.isEmpty {
            undoManager?.setActionName("Sync run")
            undoManager?.endUndoGrouping()
        }
        recordSyncHistory(historyRecords)
        removeResolvedDifferences(matching: result.successes.map { $0.0 })
        // No per-failure isSyncing reset here: the defer above clears the flag for every
        // item of this run, and nothing can observe the list before it runs.
        if result.failures.count == 1, let (diff, error) = result.failures.first {
            present(.syncFailed(
                item: diff.relativePath,
                path: diff.sourceItemPath,
                reason: error.localizedDescription,
                isRetryable: false
            ))
        } else if result.failures.count > 1 {
            // The alert holds one error at a time, so presenting per failure would leave only
            // the last one visible. Log each failure individually, then present one aggregate.
            for (diff, error) in result.failures {
                Logger.shared.error(SyncError.syncFailed(
                    item: diff.relativePath,
                    path: diff.sourceItemPath,
                    reason: error.localizedDescription,
                    isRetryable: false
                ).logDescription)
            }
            let (firstDiff, firstError) = result.failures[0]
            present(.bulkFailed(
                verb: "sync",
                failureCount: result.failures.count,
                firstItem: firstDiff.relativePath,
                firstPath: firstDiff.sourceItemPath,
                firstReason: firstError.localizedDescription
            ))
        }
        // Completion banner for the bulk transfer. This marquee Compare flow ("Copy N to →")
        // previously finished with no confirmation at all — only the resolved differences vanished.
        // On a clean run, offer Undo: the whole run's per-file undos are grouped into one "Sync run"
        // step above, so ⌘Z reverses it in one go. On a partial run the failure alert already
        // speaks, so stay quiet here rather than stacking a second message.
        if postBanner, result.failures.isEmpty, !result.successes.isEmpty {
            let pastTense = isMove ? "Moved" : "Copied"
            banner = .success(result.successes.count == 1
                ? "\(pastTense) 1 item"
                : "\(pastTense) \(result.successes.count) items", undoable: true)
        }

        // Summary breadcrumb for the bulk path (parity with the single-file "Synced file:" line):
        // a "Sync All" of hundreds of files otherwise leaves no successful-outcome record.
        if !result.successes.isEmpty {
            let verb = isMove ? "Moved" : "Synced"
            Logger.shared.info("\(verb) \(result.successes.count) item(s) in bulk\(result.failures.isEmpty ? "" : ", \(result.failures.count) failed")")
        }
    }

}

// MARK: - Bulk sync helpers (Sendable-safe refs and actors for parallel workers)

// ProgressRef and WeakSyncManagerRef are internal (not private) because the verify machinery
// in FileSyncManager+Verify.swift shares the parallel-worker scaffolding.
final class ProgressRef: @unchecked Sendable {
    let progress: Progress
    init(_ progress: Progress) { self.progress = progress }
}

final class WeakSyncManagerRef: @unchecked Sendable {
    weak var value: FileSyncManager?
    init(_ value: FileSyncManager?) { self.value = value }
}

/// Hands work items one at a time to the parallel workers.
private actor WorkQueue<Item: Sendable> {
    private let items: [Item]
    private var index: Int = 0
    init(items: [Item]) { self.items = items }
    func next() -> Item? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}

/// Monotonic completed-item counter shared by the parallel workers.
private actor CompletedCounter {
    private var completed: Int = 0
    func increment() -> Int {
        completed += 1
        return completed
    }
}

private actor BulkSyncResultsCollector {
    private var successes: [(FileDifference, (URL?, URL, URL))] = []
    private var failures: [(FileDifference, Error)] = []
    func addSuccess(_ diff: FileDifference, _ result: (URL?, URL, URL)) {
        successes.append((diff, result))
    }
    func addFailure(_ diff: FileDifference, _ error: Error) {
        failures.append((diff, error))
    }
    func get() -> (successes: [(FileDifference, (URL?, URL, URL))], failures: [(FileDifference, Error)]) {
        (successes, failures)
    }
}
