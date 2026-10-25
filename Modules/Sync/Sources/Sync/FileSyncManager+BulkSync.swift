import Events
import Foundation

extension FileSyncManager {

    /// Bulk copy the given differences from left to right (overwrites if exists). No per-file confirmation; 2–4 concurrent copies.
    /// Internal (not private) because `confirmVerifiedCopy` in FileSyncManager+Verify.swift starts it.
    /// - Parameter asOf: The `fileOperationsEpoch` the copied-from verdicts were taken under —
    ///   `VerifiedCopyOffer.asOf`. Re-checked here, at the point the write is actually ordered.
    /// - Parameter stamps: `VerifiedCopyOffer.stamps`. A pair stamped here was PROVEN
    ///   byte-identical by Verify All, and gets its dates matched rather than a copy (FR41).
    ///
    /// **"Copy to match dates" copied every pair over whole, and every pair it is offered is one
    /// Verify All has just read in full and found byte-identical.** So the copy changed no byte and
    /// still cost everything a copy costs: each file re-uploaded by its cloud app, a backup of the
    /// identical original sent to the Trash, and the right side's tags, labels and other metadata
    /// replaced by the left's. What the user asked for is the one thing the two files do not
    /// share — the date — so a proven pair now gets just that: the right file's modification date
    /// set to the left's (`matchDatesOfProvenPairs`). The copy path stays for a pair this run was
    /// not handed a stamp for, i.e. anything not proven identical.
    ///
    /// **A link on either side is never written through** (FR41, FR8). Verify reads a link as the
    /// file it points to, but a copy writes the LINK — over the real file on the right — and a
    /// date set on a link path lands on its target. `FileDifference.heldBack` already keeps link
    /// rows out of bulk runs, but only for the side the row copies FROM, and this run always copies
    /// left to right whatever the row's suggested direction, so both sides are checked on disk too.
    /// A held row is left out and said so, as `syncAll` does.
    func bulkCopyDifferencesLeftToRight(_ allPairs: [FileDifference], asOf: Int,
                                        stamps: [UUID: FilePairStamp] = [:]) async {
        let activeFMForHold = fileManager
        func isLink(_ path: String) -> Bool {
            (try? activeFMForHold.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
        }
        let held = allPairs.filter { $0.heldBack != nil || isLink($0.leftItemPath) || isLink($0.rightItemPath) }
        let heldIDs = Set(held.map(\.id))
        let toCopy = allPairs.filter { !heldIDs.contains($0.id) }
        for pair in held {
            Logger.shared.info("Copy to match dates: left out \(pair.relativePath) — \(pair.heldBack == nil ? "one side is a symbolic link" : "it needs a decision of its own")")
        }
        if toCopy.isEmpty, !held.isEmpty {
            banner = .warning((["No dates were matched"] + Self.leftOutPhrases(held, linkOnEitherSide: true))
                .joined(separator: "; "))
            return
        }
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
        progress.localizedDescription = toCopy.allSatisfy({ stamps[$0.id]?.left != nil && stamps[$0.id]?.right != nil })
            ? "Matching the dates of \(CountedNoun.phrase(total, "file"))"
            : "Copying \(CountedNoun.phrase(total, "file")) to match dates"
        progress.isCancellable = true
        progress.runLockReason = Progress.runLockReason(waitingFor: "the date match")
        activeProgress = progress

        markSyncing(ids: toCopyIDs)
        bulkSyncProgress = (0, total)

        // **A deliberate YIELD, not a stray isolation hop — do not delete it as one.** This method
        // is already on the main actor, so the block buys nothing for isolation, and
        // `enqueueFileOperation` now carries a prominent note that exactly this shape "was
        // redundant for isolation" where IT used it. The difference is the whole point: there the
        // hop was pure cost, here the hop IS the work. `MainActor.run` is a *nonisolated* async
        // function, so awaiting it from the main actor really does suspend (SE-0338) — which hands
        // the main thread back long enough for the overlay this method just published
        // (`activeProgress`, `bulkSyncProgress`) to render before the copy work blocks it.
        //
        // It is also the last one of its kind in `Modules/Sync/Sources`: every other
        // `MainActor.run` there is inside a detached task, a `nonisolated` body, or a `@Sendable`
        // closure, where it is doing real isolation work.
        await MainActor.run { }

        defer {
            isBulkSyncRunning = false
            bulkSyncProgress = nil
            if activeProgress === progress { activeProgress = nil }
            clearSyncing(ids: toCopyIDs)
        }

        // Re-assert the confirm-time guard HERE, where the write is about to be ordered, rather
        // than trusting the reading it took at the click. Between the two there are TWO
        // main-actor hops — the `Task` this runs in starting, and the overlay yield just above.
        // (There used to be a third, inside `enqueueFileOperation`, and this paragraph named it as
        // where "the epoch is bumped and the operation chain is claimed". That hop is gone: the
        // claim is straight-line now, and for the undo/redo paths both the epoch bump and the
        // chain claim happen synchronously in `undo()` itself, via `claimFileOperationSlot()`.)
        //
        // The guard is still needed, and the removed hop made it STRONGER rather than redundant.
        // A ⌘Z delivered into either remaining window runs its handler synchronously on the main
        // actor, and that handler now claims the queue and bumps the epoch before it returns — so
        // by the time this line runs, `fileOperationsEpoch != asOf` and the count is non-zero, and
        // this run refuses instead of queueing behind the undo and overwriting the bytes it just
        // restored. Before the slot, only the COUNT term caught that case; the epoch had not moved
        // yet, because the undo's bump waited on its own `Task`.
        //
        // Both terms stay, because they still answer different questions for a different caller:
        // a confirmation-gated transfer counts at `preCountFileOperation()` and bumps the epoch
        // only when the user confirms, so a pending one is visible in the count alone. The window
        // is sub-millisecond and keystroke-only either way, so this closes the last check-then-act
        // in the path rather than a reachable bug; a guard resting on a value read before a
        // suspension point is the shape, not the timing.
        guard fileOperationsEpoch == asOf, activeFileOperationsCount == 0 else {
            banner = .warning("A file operation ran or is pending — run Verify All again")
            return
        }

        // Proven = stamped at hash time with a date on both ends: a pair with no date to read
        // cannot have it matched, and takes the copy it always took.
        func isProven(_ diff: FileDifference) -> Bool {
            stamps[diff.id]?.left != nil && stamps[diff.id]?.right != nil
        }
        let proven = toCopy.filter(isProven)
        if !proven.isEmpty {
            await matchDatesOfProvenPairs(proven, stamps: stamps, held: held)
        }
        let unproven = toCopy.filter { !isProven($0) }
        guard !unproven.isEmpty else { return }

        let activeFM = fileManager
        let workList: [(FileDifference, URL, URL, Bool)] = unproven.map { diff in
            (diff, URL(fileURLWithPath: diff.leftItemPath), URL(fileURLWithPath: diff.rightItemPath), false)
        }

        let progressRef = ProgressRef(progress)
        let weakRef = WeakSyncManagerRef(self)
        let totalCount = total
        // One @Published write per whole percent instead of one per file — see
        // `ProgressPublishGate` for what the ungated version cost the window.
        let publishGate = ProgressPublishGateBox()

        let result = await enqueueFileOperation {
            await Self.performBulkSyncIO(
                workList: workList,
                concurrency: min(4, max(2, workList.count)),
                progress: progressRef,
                fileManager: activeFM,
                reportCompleted: { completed in
                    guard publishGate.admits(completed: completed, total: totalCount) else { return }
                    weakRef.value?.bulkSyncProgress = (completed, totalCount)
                }
            )
        }

        // Group the whole run's per-file undo registrations into ONE undo step so "Undo last
        // sync run" (and ⌘Z) reverses the entire bulk copy at once, reusing the existing
        // per-file reversal — no new mutation path. The group is named so the run reads as a
        // unit in the Undo menu. Skip the empty case so no phantom group is opened.
        let runId = UUID()
        var historyRecords: [SyncHistoryRecord] = []
        // Each item's identity walk was started inside `performBulkSyncIO`, the moment its own
        // copy landed; each registration hands back the task that wraps its walk, collected here
        // and awaited only AFTER the undo grouping closes — an await inside the group would open
        // the main actor mid-group, letting an interleaved operation register into OUR "Sync
        // run" step. Bulk sync copies files, so each walk is a single stat.
        var identityWalks: [Task<Void, Never>] = []
        if !result.successes.isEmpty { undoManager?.beginUndoGrouping() }
        for (diff, (trashed, from, to), identityWalk) in result.successes {
            let actionName = "Sync \(diff.relativePath.components(separatedBy: "/").last ?? "")"
            // The nil-coalescing is defensive only: this run copies (isMove is never true here),
            // so the IO loop started a walk for every success.
            identityWalks.append(registerCopyUndo(
                pendingItems: [(source: from, destination: to, overwritten: trashed,
                                identity: identityWalk ?? Self.startCopyIdentityWalk(at: to, fileManager: activeFM))],
                actionName: actionName, fileManager: activeFM))
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
        // The pairing is armed HERE, in the turn that closed the group, and not after the walks
        // below (FR26): what tops the stack after an await may be a rename or a ⌘Z made during
        // the tail, and "Undo Last Run" would then describe this run while reversing that.
        recordSyncHistory(historyRecords)
        // Outside the group (see the note at `identityWalks`): the run does not report complete
        // until every undo it registered is fully armed.
        for walk in identityWalks { await walk.value }
        removeResolvedDifferences(matching: result.successes.map { $0.0 })
        // The failures stay in the list — only successes were removed — so mark them while they
        // are still in hand. Unconditional: a clean run clears the previous one's marks.
        recordTransferFailures(result.failures)
        // No per-failure isSyncing reset here: the defer above clears the flag for every
        // item of this run, and nothing can observe the list before it runs.
        if result.failures.count == 1, let (diff, error) = result.failures.first {
            present(.copyFailed(
                items: "“\(diff.relativePath)”",
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
                firstPath: firstDiff.leftItemPath,
                firstReason: firstError.localizedDescription
            ))
        }
        if !result.failures.isEmpty {
            banner = .warning("\(result.successes.count) copied; \(result.failures.count) failed")
        } else if !result.successes.isEmpty {
            // The whole run's per-file undos are wrapped in one group above, so ⌘Z reverses it all.
            banner = .success("\(CountedNoun.phrase(result.successes.count, "file")) copied — dates matched", undoable: true)
        }
        // Summary breadcrumb for the bulk path: a single-file copy already logs its "Copied …"
        // line, but a "Copy All" of hundreds of files otherwise leaves no successful-outcome
        // record — only the per-failure ERROR lines above. Log the count so the batch is visible.
        if !result.successes.isEmpty {
            Logger.shared.info("Copied \(result.successes.count) item(s) in bulk\(result.failures.isEmpty ? "" : ", \(result.failures.count) failed")")
        }
    }

    /// One file whose date `matchDatesOfProvenPairs` set: the date it had, the date it was given
    /// (as read back from disk, so a later comparison is exact), and its size, so an undo can tell
    /// the file it touched from one written since.
    typealias DateMatchState = (url: URL, previous: Date, matched: Date, size: Int64)

    /// FR41's write: for each pair Verify All proved byte-identical, the right file takes the left
    /// file's modification date, and nothing else about it changes — no bytes, no backup, no tags.
    ///
    /// Each pair is re-stamped immediately before its date is set and compared with the stamp
    /// taken when it was hashed; a pair that moved since is left alone and counted as changed. The
    /// confirm already checks this, but these readings are an operation-queue wait old by now, and
    /// matching the dates over a file rewritten since would make two DIFFERENT files read as in
    /// sync to every later scan — the one thing this must never manufacture.
    ///
    /// Undoable as one step: ⌘Z puts each right file's previous date back, but only on a file that
    /// still reads as this run left it (same size, the date it was given).
    private func matchDatesOfProvenPairs(_ pairs: [FileDifference], stamps: [UUID: FilePairStamp],
                                         held: [FileDifference]) async {
        let activeFM = fileManager
        let outcome = await enqueueFileOperation { () -> (matched: [(FileDifference, DateMatchState)], changed: [FileDifference], failures: [(FileDifference, Error)]) in
            var matched: [(FileDifference, DateMatchState)] = []
            var changed: [FileDifference] = []
            var failures: [(FileDifference, Error)] = []
            for diff in pairs {
                guard let stamp = stamps[diff.id], FilePairStamp.read(diff, fileManager: activeFM) == stamp,
                      let leftDate = stamp.left?.modified, let right = stamp.right else {
                    changed.append(diff)
                    continue
                }
                do {
                    // Exact, not `setAttributes`: that rounds to the microsecond, and at the
                    // "Exact match" tolerance a pair 6e-7 s apart still differs on the next scan.
                    try activeFM.setModificationDate(leftDate, ofItemAtPath: diff.rightItemPath)
                } catch {
                    failures.append((diff, error))
                    continue
                }
                let landed = FileEndpointStamp.read(atPath: diff.rightItemPath, fileManager: activeFM)?.modified ?? leftDate
                matched.append((diff, (url: URL(fileURLWithPath: diff.rightItemPath), previous: right.modified,
                                       matched: landed, size: right.size)))
            }
            return (matched, changed, failures)
        }

        if !outcome.matched.isEmpty {
            registerDateMatchUndo(outcome.matched.map(\.1), restoringPrevious: true,
                                  actionName: "Match \(CountedNoun.phrase(outcome.matched.count, "Date"))", fileManager: activeFM)
            // **In Sync History, and paired for Undo Last Run, like every other run** (FR41). The
            // match changed files on disk and recorded nothing, so the History window never
            // listed it and Undo Last Run refused it as "not a sync run". One record per file,
            // armed in this turn — the one that registered the step (FR26).
            let runId = UUID()
            recordSyncHistory(outcome.matched.map { diff, state in
                SyncHistoryRecord(runId: runId, action: .matchDates,
                                  sourcePath: diff.leftItemPath, destPath: state.url.path,
                                  sizeBytes: Int(state.size), direction: "→ Right")
            })
            removeResolvedDifferences(matching: outcome.matched.map(\.0))
            Logger.shared.info("Copy to match dates: set the date of \(outcome.matched.count) verified-identical file(s) on the right to the left's — no bytes copied")
        }
        for diff in outcome.changed {
            Logger.shared.warning("Copy to match dates: left \(diff.relativePath) alone — it changed since it was verified")
        }
        recordTransferFailures(outcome.failures)
        for (diff, error) in outcome.failures {
            Logger.shared.error("Copy to match dates: could not set the date of \(diff.rightItemPath): \(error.localizedDescription)")
        }
        let leftOut = outcome.changed.count + outcome.failures.count + held.count
        if leftOut > 0 {
            var parts = ["\(CountedNoun.phrase(outcome.matched.count, "date")) matched"]
            if !outcome.changed.isEmpty { parts.append("\(outcome.changed.count) changed since Verify All and left alone") }
            if !outcome.failures.isEmpty { parts.append("\(outcome.failures.count) failed") }
            parts += Self.leftOutPhrases(held, linkOnEitherSide: true)
            // The dates it did match are one undo step all the same, so the banner keeps its Undo.
            banner = .warning(parts.joined(separator: "; "), undoable: !outcome.matched.isEmpty)
        } else {
            banner = .success("\(CountedNoun.phrase(outcome.matched.count, "file")) now match — dates set, nothing copied",
                              undoable: true)
        }
    }

    /// What a run says about the held rows it left out, one phrase per kind: the rows that need the
    /// user's decision, with where they make it — the row's right-click menu, which copies a held
    /// row either way — and the links, which nothing in the app copies right (`syncFile` refuses a
    /// row copying FROM one), so no path is named for them.
    ///
    /// `linkOnEitherSide` words the link half for Copy to match dates, which also leaves out a pair
    /// with a link on the side it would write — such a row carries no hold, so a row without one
    /// counts as a link there.
    static func leftOutPhrases(_ held: [FileDifference], linkOnEitherSide: Bool = false) -> [String] {
        let links = held.filter { $0.heldBack == nil || $0.heldBack == .sourceIsSymbolicLink }.count
        let decisions = held.count - links
        var phrases: [String] = []
        if decisions > 0 {
            phrases.append(decisions == 1
                ? "1 item needs your decision and was left out — right-click its row to choose which to keep"
                : "\(decisions) items need your decision and were left out — right-click each row to choose which to keep")
        }
        if links > 0 {
            switch (linkOnEitherSide, links == 1) {
            case (true, true): phrases.append("1 item has a link on one side and was left out")
            case (true, false): phrases.append("\(links) items have a link on one side and were left out")
            case (false, true): phrases.append("1 item is a link and was left out — a copy would be a link too")
            case (false, false): phrases.append("\(links) items are links and were left out — a copy would be a link too")
            }
        }
        return phrases
    }

    /// Registers one undo step over a date match: it sets each file's date back toward
    /// `restoringPrevious ? previous : matched`, but only on a file that still reads with the
    /// other date and the recorded size — a file saved since is not this step's to re-date — and
    /// registers its own inverse as the redo.
    func registerDateMatchUndo(_ items: [DateMatchState], restoringPrevious: Bool, actionName: String,
                               fileManager fm: FileManaging) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered \(restoringPrevious ? "Undo" : "Redo"): \(actionName)")
            let slot = target.claimFileOperationSlot()
            target.registerDateMatchUndo(items, restoringPrevious: !restoringPrevious, actionName: actionName, fileManager: fm)
            Task {
                await target.enqueueFileOperation(slot: slot) {
                    var reset = 0
                    var changed = 0
                    var unwritable = 0
                    for item in items {
                        let expected = restoringPrevious ? item.matched : item.previous
                        let goal = restoringPrevious ? item.previous : item.matched
                        guard let now = FileEndpointStamp.read(atPath: item.url.path, fileManager: fm),
                              now.size == item.size, now.modified == expected else {
                            changed += 1
                            continue
                        }
                        // Exact, so the inverse step's `now.modified == expected` holds on the
                        // file this one leaves: `setAttributes` rounds to the microsecond, and a
                        // Redo after an Undo then found ~9 in 10 files "changed since".
                        if (try? fm.setModificationDate(goal, ofItemAtPath: item.url.path)) != nil {
                            reset += 1
                        } else {
                            unwritable += 1
                        }
                    }
                    var outcome = "re-dated \(reset) of \(items.count) file(s)"
                    if changed > 0 { outcome += ", \(changed) left alone — changed since" }
                    if unwritable > 0 { outcome += ", \(unwritable) could not be re-dated" }
                    Logger.shared.info("\(restoringPrevious ? "Undo" : "Redo") (\(actionName)): \(outcome)")
                }
            }
        }
        undoManager?.setActionName(actionName)
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
    ///
    /// Each COPY success also carries its identity walk (`startCopyIdentityWalk`), started right
    /// here, the moment that item's own copy landed — not at registration time, which comes only
    /// after the ENTIRE run (minutes on slow volumes). Post-run, a walk would record an edit the
    /// user made inside an already-landed copy while the rest of the run ground on as that
    /// copy's BASELINE, and ⌘Z would trash the edit as `.unchanged`. Per item, the edit
    /// postdates the recording and refuses. Moves carry nil: their undo records shallow, at
    /// registration, deliberately (see `registerMoveUndo`).
    private nonisolated static func performBulkSyncIO(
        workList: [(FileDifference, URL, URL, Bool)],
        concurrency: Int,
        progress progressRef: ProgressRef,
        completedBase: Int = 0,
        fileManager: FileManaging,
        reportCompleted: @escaping @MainActor @Sendable (Int) -> Void
    ) async -> (successes: [(FileDifference, (URL?, URL, URL), Task<FileSyncManager.CopyIdentityReading, Never>?)], failures: [(FileDifference, Error)]) {
        let collector = BulkSyncResultsCollector()
        await processInParallel(
            items: workList,
            concurrency: concurrency,
            progress: progressRef,
            completedBase: completedBase,
            reportCompleted: reportCompleted
        ) { item in
            let (diff, fromURL, toURL, isMove) = item
            // RD24: each worker's copy also watches Cancel, so a run holding a very large file stops
            // inside it rather than after it. The dialog's item line is not touched here — four
            // copies share it, so a byte count would describe whichever wrote last.
            let progress = progressRef.progress
            let observer = CopyObserver(shouldContinue: { !progress.isCancelled })
            do {
                let syncResult = try performFileSyncIO(from: fromURL, to: toURL, isMove: isMove, fileManager: fileManager, observer: observer)
                let identityWalk = isMove ? nil
                    : FileSyncManager.startCopyIdentityWalk(at: syncResult.to, fileManager: fileManager)
                await collector.addSuccess(diff, (syncResult.trashed, syncResult.from, syncResult.to), identityWalk)
            } catch where CopyObserver.isCancellation(error) && progress.isCancelled {
                // Abandoned inside its staging copy: not synced, and not a failure to report — the
                // row simply stays in the list, as the items the cancel never reached do.
            } catch {
                await collector.addFailure(diff, error)
            }
        }
        return await collector.get()
    }

    /// Resolves all differences in one direction by copying or moving each matching item (same behavior as per-file sync; collisions show "Apply to all" when applicable).
    /// Runs up to 4 file operations in parallel. Cancellation abandons the files in flight inside their staging copies and starts no new ones.
    /// - Parameters:
    ///   - direction: Which direction to sync (e.g. `.copyToRight` → copy all that are "missing on right" or "left newer").
    ///   - isMove: If true, moves each file; otherwise copies.
    ///   - subset: When non-nil, only differences in this array are considered (e.g. the currently filtered list). When nil, uses the full `differences` array.
    ///   - confirmed: Pass true when the calling UI already embodies the user's confirmation
    ///     for this exact run (e.g. review mode's "Copy Remaining N" button, which names the
    ///     count) — the `transferConfirmer` prompt is skipped so one gesture never asks twice.
    public func syncAll(direction: FileDifference.SyncAction, isMove: Bool = false, subset: [FileDifference]? = nil, confirmed: Bool = false, postBanner: Bool = true) async {
        _ = await syncAllResolving(direction: direction, isMove: isMove, subset: subset, confirmed: confirmed, postBanner: postBanner)
    }

    /// `syncAll`, returning the ids of the rows the run resolved — empty when it copied nothing —
    /// for a caller that has to say which ones landed (`copyRemaining`).
    func syncAllResolving(direction: FileDifference.SyncAction, isMove: Bool, subset: [FileDifference]?, confirmed: Bool, postBanner: Bool) async -> Set<UUID> {
        let source = subset ?? differences
        // **A row whose direction is a guess is not taken in bulk** (`FileDifference.heldBack`:
        // FR8, FR39, FR40). The user approves a count here, not each row, so a guess inside the
        // count overwrote whichever side it guessed against. Held rows are left on the list,
        // logged with their reason, and named in the outcome — never silently dropped.
        let inDirection = source.filter { $0.action == direction }
        let toSync = inDirection.filter { $0.heldBack == nil }
        let heldBack = inDirection.filter { $0.heldBack != nil }
        for held in heldBack {
            Logger.shared.info("Bulk \(isMove ? "move" : "sync") left \(held.relativePath) for a decision: \(held.description)")
        }
        let leftOut = Self.leftOutPhrases(heldBack)
        let heldNote = leftOut.map { "; " + $0 }.joined()
        let total = toSync.count
        guard total > 0 else {
            if !heldBack.isEmpty, postBanner {
                banner = .warning("Nothing was \(isMove ? "moved" : "copied")" + heldNote)
            }
            return []
        }
        // Drop, don't queue, a bulk run started while another is in flight (see the flag's doc).
        guard !isBulkSyncRunning else { return [] }
        // A Verify All in flight is hashing the very files this run would overwrite; starting
        // anyway would feed it half-written content. Tell the user rather than silently drop.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for the current operation to finish before syncing")
            return []
        }
        // A single-row syncFile in flight (possibly parked at its prompt — the latch is set
        // before any prompt) may target the very rows this run would stat and copy; running
        // anyway could double-write one difference from two flows. Mirrors Verify All's guard.
        guard syncingDifferenceIds.isEmpty else {
            banner = .warning("Wait for the current operation to finish before syncing")
            return []
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
                // .info like the single-transfer decline: a bulk run's start is visible at Info
                // level, so its cancellation has to be too, or the trace shows a run that never ends.
                Logger.shared.info("Bulk \(isMove ? "move" : "sync") of \(total) item(s) cancelled at the confirmation prompt")
                return []
            }
        }
        let toSyncIDs = Set(toSync.map { $0.id })
        bulkApplyToAllResolution = nil

        let progress = Progress(totalUnitCount: Int64(total))
        progress.localizedDescription = "\(isMove ? "Moving" : "Syncing") \(CountedNoun.phrase(total, "file"))"
        progress.isCancellable = true
        progress.runLockReason = Progress.runLockReason(waitingFor: isMove ? "the move" : "the sync")
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
        //
        // Asked PER DESTINATION, not once for the batch. One batch can span volumes — a nested
        // mount inside the destination root, or a pane rooted at /Volumes — and a single answer
        // taken from the first candidate applies that volume's rule to items landing on a different
        // one. Getting it wrong in the "case-sensitive" direction is the dangerous half: two
        // case-variant targets on a case-INSENSITIVE volume both pass the reservation check, the
        // parallel workers then write to the SAME file, and with `isMove` both sources are consumed
        // — one file's content is gone, with a success banner and no Trash entry. (Before the probe
        // could answer at all this was unreachable, because the failed probe folded case for
        // everything; making it answer is what opened it.) Memoized per parent directory, so this
        // costs one stat per distinct destination folder rather than one per item.
        var caseSensitivityByParent: [String: Bool] = [:]
        let probeCaseSensitivity = destinationCaseSensitivity
        func destinationIsCaseSensitive(_ url: URL) -> Bool {
            let parent = url.deletingLastPathComponent().path
            if let known = caseSensitivityByParent[parent] { return known }
            let sensitive = probeCaseSensitivity(url)
            caseSensitivityByParent[parent] = sensitive
            return sensitive
        }
        func reservedKey(_ path: String) -> String {
            destinationIsCaseSensitive(URL(fileURLWithPath: path)) ? path : path.lowercased()
        }
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
                case .skip, .merge:
                    // `.merge` is never offered here (the collision above does not set
                    // `offersMerge`), so it can only be a stray answer — given the safe reading.
                    skippedCount += 1
                    continue
                case .keepBoth:
                    let collidingURL = toURL
                    let claimed = reservedTargets
                    let caseSensitive = destinationIsCaseSensitive(collidingURL)
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
                let caseSensitive = destinationIsCaseSensitive(claimedURL)
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
        // One @Published write per whole percent instead of one per file — see
        // `ProgressPublishGate` for what the ungated version cost the window.
        let publishGate = ProgressPublishGateBox()
        let workList = preparedList

        let result = await enqueueFileOperation {
            await Self.performBulkSyncIO(
                workList: workList,
                concurrency: 4,
                progress: progressRef,
                completedBase: skipped,
                fileManager: activeFM,
                reportCompleted: { completed in
                    guard publishGate.admits(completed: completed, total: totalCount) else { return }
                    weakRef.value?.bulkSyncProgress = (completed, totalCount)
                }
            )
        }

        // Group the whole run's per-file undo registrations into ONE undo step so "Undo last
        // sync run" (and ⌘Z) reverses the entire bulk sync at once, reusing the existing
        // per-file reversal — no new mutation path. Named so the run reads as a unit in the Undo
        // menu; the empty case opens no group.
        let runId = UUID()
        var historyRecords: [SyncHistoryRecord] = []
        // Same shape as the Verify All path above: each copy's identity walk was started inside
        // `performBulkSyncIO` the moment its own copy landed; the registrations' wrapper tasks
        // are collected and awaited after the grouping closes, so nothing can interleave into
        // the "Sync run" undo step while the main actor suspends.
        var identityWalks: [Task<Void, Never>] = []
        if !result.successes.isEmpty { undoManager?.beginUndoGrouping() }
        for (diff, (trashed, from, to), identityWalk) in result.successes {
            let actionName = "Sync \(diff.relativePath.components(separatedBy: "/").last ?? "")"
            if isMove {
                registerMoveUndo(items: [(from: from, to: to, overwritten: trashed)], actionName: actionName, fileManager: activeFM)
            } else {
                // Defensive fallback only: the IO loop starts a walk for every copy success.
                identityWalks.append(registerCopyUndo(
                    pendingItems: [(source: from, destination: to, overwritten: trashed,
                                    identity: identityWalk ?? Self.startCopyIdentityWalk(at: to, fileManager: activeFM))],
                    actionName: actionName, fileManager: activeFM))
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
        // The pairing is armed HERE, in the turn that closed the group, and not after the walks
        // below (FR26): what tops the stack after an await may be a rename or a ⌘Z made during
        // the tail, and "Undo Last Run" would then describe this run while reversing that.
        recordSyncHistory(historyRecords)
        // Outside the group (see the note at `identityWalks`): the run does not report complete
        // until every undo it registered is fully armed.
        for walk in identityWalks { await walk.value }
        removeResolvedDifferences(matching: result.successes.map { $0.0 })
        // The failures stay in the list — only successes were removed — so mark them while they
        // are still in hand. Unconditional: a clean run clears the previous one's marks.
        recordTransferFailures(result.failures)
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
            banner = .success((result.successes.count == 1
                ? "\(pastTense) 1 item"
                : "\(pastTense) \(result.successes.count) items") + heldNote, undoable: true)
        }

        // Summary breadcrumb for the bulk path (parity with the single-file "Synced file:" line):
        // a "Sync All" of hundreds of files otherwise leaves no successful-outcome record.
        if !result.successes.isEmpty {
            let verb = isMove ? "Moved" : "Synced"
            Logger.shared.info("\(verb) \(result.successes.count) item(s) in bulk\(result.failures.isEmpty ? "" : ", \(result.failures.count) failed")")
        }
        return Set(result.successes.map { $0.0.id })
    }

    /// Review's "Copy Remaining N" when some of the rows left need the user's decision.
    ///
    /// **It left them out and said nothing** (owner decision 2026-10-25). Each direction is its own
    /// `syncAll`, and a remainder holding both ran them with their banners off — so the held rows
    /// were dropped from the outcome, and with one direction only the held rows going that way
    /// were named. Here every row that can go is copied, both directions, and one banner names the
    /// held rows in the words every bulk run uses (`leftOutPhrases`); they stay on the list.
    ///
    /// The prompt is skipped: the button names the count and is the confirmation. Undo is offered
    /// only for one direction — two runs are two undo steps, and one Undo would reverse half.
    /// - Returns: The ids of the rows it resolved, so Review can mark them and stay on the rest —
    ///   or nil when it refused to start (another operation is running), having said so.
    @discardableResult
    public func copyRemaining(_ remaining: [FileDifference], isMove: Bool) async -> Set<UUID>? {
        // syncAll's own guards, up front: a refusal inside it would read here as "nothing
        // copied", and this banner would cover the reason.
        guard !isBulkSyncRunning, !isVerifyAllRunning, syncingDifferenceIds.isEmpty else {
            banner = .warning("Wait for the current operation to finish before syncing")
            return nil
        }
        let held = remaining.filter { $0.heldBack != nil }
        let toCopy = remaining.filter { $0.heldBack == nil }
        let directions = [FileDifference.SyncAction.copyToRight, .copyToLeft].filter { direction in
            toCopy.contains { $0.action == direction }
        }
        var resolved: Set<UUID> = []
        for direction in directions {
            resolved.formUnion(await syncAllResolving(direction: direction, isMove: isMove, subset: toCopy,
                                                      confirmed: true, postBanner: false))
        }
        let pastTense = isMove ? "Moved" : "Copied"
        let head = resolved.isEmpty
            ? "Nothing was \(isMove ? "moved" : "copied")"
            : resolved.count == 1 ? "\(pastTense) 1 item" : "\(pastTense) \(resolved.count) items"
        let message = ([head] + Self.leftOutPhrases(held)).joined(separator: "; ")
        if resolved.count < toCopy.count || resolved.isEmpty {
            // A row that did not land has told the user already, in its own alert.
            banner = .warning(message)
        } else {
            banner = .success(message, undoable: directions.count == 1)
        }
        return resolved
    }

}

// MARK: - Bulk sync helpers (Sendable-safe refs and actors for parallel workers)

// ProgressRef and WeakSyncManagerRef are internal (not private) because the verify machinery
// in FileSyncManager+Verify.swift shares the parallel-worker scaffolding.
// @unchecked: NSProgress is itself thread-safe; the ref exists only to be the Sendable wrapper.
final class ProgressRef: @unchecked Sendable {
    let progress: Progress
    init(_ progress: Progress) { self.progress = progress }
}

final class WeakSyncManagerRef: @unchecked Sendable {
    // `weak let`: never reassigned after init (all construction sites pass `self` once), so the
    // only mutation is the runtime nil-ing on deallocation — which is what makes this Sendable-safe.
    weak let value: FileSyncManager?
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
    private var successes: [(FileDifference, (URL?, URL, URL), Task<FileSyncManager.CopyIdentityReading, Never>?)] = []
    private var failures: [(FileDifference, Error)] = []
    func addSuccess(_ diff: FileDifference, _ result: (URL?, URL, URL), _ identityWalk: Task<FileSyncManager.CopyIdentityReading, Never>?) {
        successes.append((diff, result, identityWalk))
    }
    func addFailure(_ diff: FileDifference, _ error: Error) {
        failures.append((diff, error))
    }
    func get() -> (successes: [(FileDifference, (URL?, URL, URL), Task<FileSyncManager.CopyIdentityReading, Never>?)], failures: [(FileDifference, Error)]) {
        (successes, failures)
    }
}
