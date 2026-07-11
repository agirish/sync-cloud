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
        // these overwrites. A concurrent Verify All would hash files mid-overwrite. Refuse
        // visibly, mirroring syncAll's verify refusal.
        guard !isBulkSyncRunning, !isVerifyAllRunning else {
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

        for (diff, (trashed, from, to)) in result.successes {
            let actionName = "Sync \(diff.relativePath.components(separatedBy: "/").last ?? "")"
            registerCopyUndo(items: [(source: from, destination: to, overwritten: trashed)], actionName: actionName, fileManager: activeFM)
        }
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
            banner = .success("\(result.successes.count) files copied — dates matched")
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
    public func syncAll(direction: FileDifference.SyncAction, isMove: Bool = false, subset: [FileDifference]? = nil) async {
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
        // Confirm before any I/O (and before the run claims the bulk-sync flag): a bulk sync
        // is one header click away, so a mis-click must be cancellable while it still costs
        // nothing. The prompt names the two compared folders of the first item — every item
        // in one direction shares them.
        if let first = toSync.first {
            let containers = first.transferContainers
            let confirmed = transferConfirmer(TransferSummary(
                isMove: isMove,
                itemCount: total,
                firstItemName: first.transferURLs.from.lastPathComponent,
                sourceDirectory: containers.from,
                destinationDirectory: containers.to
            ))
            guard confirmed else { return }
        }
        isBulkSyncRunning = true
        let toSyncIDs = Set(toSync.map { $0.id })
        bulkApplyToAllResolution = nil

        let progress = Progress(totalUnitCount: Int64(total))
        progress.localizedDescription = "Syncing \(total) files"
        progress.isCancellable = true
        activeProgress = progress

        markSyncing(ids: toSyncIDs)

        defer {
            isBulkSyncRunning = false
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
                if let cached = bulkApplyToAllResolution {
                    resolution = cached
                } else {
                    promptShownSinceStatPass = true
                    let (res, applyToAll) = bulkCollisionResolver(FileCollision(
                        sourcePath: candidate.fromURL.path,
                        destinationPath: toURL.path,
                        isMove: isMove,
                        isDirectory: destinationIsDirectory
                    ))
                    if applyToAll { bulkApplyToAllResolution = res }
                    resolution = res
                }
                switch resolution {
                case .skip:
                    skippedCount += 1
                    continue
                case .keepBoth:
                    let collidingURL = toURL
                    let claimed = reservedTargets
                    toURL = await Task.detached(priority: .userInitiated) {
                        Self.generateUniqueURL(for: collidingURL, fileManager: activeFM, reserved: claimed)
                    }.value
                case .replace:
                    break
                }
            }
            // Final guard for the non-collision paths (a "missing" target, or a Replace): its plain
            // name may still be one an earlier item's keep-both already claimed this batch. Uniquify
            // against disk + the reserved set so no two items ever share a destination.
            if reservedTargets.contains(toURL.path) {
                let claimedURL = toURL
                let claimed = reservedTargets
                toURL = await Task.detached(priority: .userInitiated) {
                    Self.generateUniqueURL(for: claimedURL, fileManager: activeFM, reserved: claimed)
                }.value
            }
            reservedTargets.insert(toURL.path)
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

        for (diff, (trashed, from, to)) in result.successes {
            let actionName = "Sync \(diff.relativePath.components(separatedBy: "/").last ?? "")"
            if isMove {
                registerMoveUndo(items: [(from: from, to: to, overwritten: trashed)], actionName: actionName, fileManager: activeFM)
            } else {
                registerCopyUndo(items: [(source: from, destination: to, overwritten: trashed)], actionName: actionName, fileManager: activeFM)
            }
        }
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
