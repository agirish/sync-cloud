import Events
import Foundation

extension FileSyncManager {

    /// Verify All's "Match Dates": the right file of each pair it proved byte-identical takes the
    /// left file's modification date (`matchDatesOfProvenPairs`). No per-file confirmation. The
    /// name is from when the run copied each pair. Internal because `confirmVerifiedCopy` in
    /// FileSyncManager+Verify.swift starts it.
    /// - Parameter asOf: The `fileOperationsEpoch` the verdicts were taken under
    ///   (`VerifiedCopyOffer.asOf`), re-checked here where the write is ordered.
    /// - Parameter stamps: `VerifiedCopyOffer.stamps`, each pair as it stood when it was hashed.
    ///
    /// Nothing is copied: the files are identical, and a copy would re-upload each one, trash a
    /// backup of an identical original and replace the right side's tags. Only the date differs,
    /// so only the date is set. A pair with no date to set is left alone and counted.
    ///
    /// A link on either side is never written through: a date set on a link path lands on its
    /// target. `FileDifference.heldBack` covers only the side a row copies from, and this run always
    /// writes the right file, so both sides are checked on disk too. Held rows are left out and
    /// named, as `syncAll` does.
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
            Logger.shared.info("Match dates: left out \(pair.relativePath) — \(pair.heldBack == nil ? "one side is a symbolic link" : "it needs a decision of its own")")
        }
        if toCopy.isEmpty, !held.isEmpty {
            banner = .warning((["No dates were matched"] + Self.leftOutPhrases(held, linkOnEitherSide: true))
                .joined(separator: "; "), log: .warn)
            return
        }
        let total = toCopy.count
        guard total > 0 else { return }
        // Same exclusion as syncAll. Overlapping a bulk sync would interleave `bulkSyncProgress`
        // and tear down its overlay; a Verify All would hash files mid-write; a single-row
        // syncFile (perhaps parked at its prompt) may target one of these rows, and this run's
        // defer would clear its syncing mark. Refuse visibly.
        guard !isBulkSyncRunning, !isVerifyAllRunning, syncingDifferenceIds.isEmpty else {
            banner = .warning("Wait for the current operation to finish before copying", log: .info)
            return
        }
        isBulkSyncRunning = true
        let toCopyIDs = Set(toCopy.map { $0.id })

        let progress = Progress(totalUnitCount: Int64(total))
        progress.localizedDescription = "Matching the dates of \(CountedNoun.phrase(total, "file"))"
        progress.isCancellable = true
        progress.runLockReason = Progress.runLockReason(waitingFor: "the date match")
        activeProgress = progress

        markSyncing(ids: toCopyIDs)
        bulkSyncProgress = (0, total)

        // **A deliberate yield; don't delete it as a redundant hop.** We're already on the main
        // actor, but `MainActor.run` is nonisolated async, so awaiting it really suspends
        // (SE-0338). That lets the overlay just published (`activeProgress`, `bulkSyncProgress`)
        // render before the work blocks the main thread.
        await MainActor.run { }

        defer {
            isBulkSyncRunning = false
            bulkSyncProgress = nil
            if activeProgress === progress { activeProgress = nil }
            clearSyncing(ids: toCopyIDs)
        }

        // Re-check the confirm-time guard here, where the write is ordered: two main-actor hops
        // (this `Task` starting, and the yield above) separate it from the click. A ⌘Z in either
        // window claims its slot (`claimFileOperationSlot()`) and bumps the epoch synchronously,
        // so this run refuses instead of queueing behind the undo and overwriting what it
        // restored. Both terms are needed: a confirmation-gated transfer counts at
        // `preCountFileOperation()` but bumps the epoch only once confirmed, so a pending one
        // shows in the count alone.
        guard fileOperationsEpoch == asOf, activeFileOperationsCount == 0 else {
            banner = .warning("A file operation ran or is pending — run Verify All again", log: .warn)
            return
        }

        await matchDatesOfProvenPairs(toCopy, stamps: stamps, held: held)
    }

    /// One file whose date `matchDatesOfProvenPairs` set: the date it had, the date it was given
    /// (as read back from disk, so a later comparison is exact), and its size, so an undo can tell
    /// the file it touched from one written since.
    typealias DateMatchState = (url: URL, previous: Date, matched: Date, size: Int64)

    /// For each pair Verify All proved byte-identical, the right file takes the left file's
    /// modification date; nothing else changes (no bytes, no backup, no tags).
    ///
    /// Each pair is re-stamped just before its date is set and compared with its hash-time stamp;
    /// one that changed since is left alone and counted. The confirm checked this too, but a queue
    /// wait has passed, and matching dates over a rewritten file would make two different files
    /// read as in sync to every later scan.
    ///
    /// Undoable as one step: ⌘Z puts each previous date back, but only on a file that still reads
    /// as this run left it (same size, the date it was given).
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
            // Recorded in Sync History and paired for Undo Last Run, like every other run: one
            // record per file, armed in the same turn that registered the undo step.
            let runId = UUID()
            recordSyncHistory(outcome.matched.map { diff, state in
                SyncHistoryRecord(runId: runId, action: .matchDates,
                                  sourcePath: diff.leftItemPath, destPath: state.url.path,
                                  sizeBytes: Int(state.size), direction: "→ Right",
                                  previousModificationDate: state.previous)
            })
            removeResolvedDifferences(matching: outcome.matched.map(\.0))
            Logger.shared.info("Match dates: set the date of \(outcome.matched.count) verified-identical file(s) on the right to the left's — no bytes copied")
        }
        for diff in outcome.changed {
            Logger.shared.warning("Match dates: left \(diff.relativePath) alone — it changed since it was verified")
        }
        recordTransferFailures(outcome.failures)
        for (diff, error) in outcome.failures {
            Logger.shared.error("Match dates: could not set the date of \(diff.rightItemPath): \(error.localizedDescription)")
        }
        let leftOut = outcome.changed.count + outcome.failures.count + held.count
        if leftOut > 0 {
            var parts = ["\(CountedNoun.phrase(outcome.matched.count, "date")) matched"]
            if !outcome.changed.isEmpty { parts.append("\(outcome.changed.count) changed since Verify All and left alone") }
            if !outcome.failures.isEmpty { parts.append("\(outcome.failures.count) failed") }
            parts += Self.leftOutPhrases(held, linkOnEitherSide: true)
            // The dates it did match are one undo step all the same, so the banner keeps its Undo.
            banner = .warning(parts.joined(separator: "; "), undoable: !outcome.matched.isEmpty, log: .warn)
        } else {
            banner = .success("\(CountedNoun.phrase(outcome.matched.count, "file")) now match — dates set, nothing copied",
                              undoable: true)
        }
    }

    /// What a run says about the held rows it left out, one phrase per kind. Rows needing a
    /// decision point to the row's right-click menu, which copies a held row either way. Links get
    /// no such pointer: nothing in the app copies them right (`syncFile` refuses a row copying from
    /// one). A one-sided folder holding a link gets its own phrase: its menu offers the single
    /// copy, which proceeds for one row at a time.
    ///
    /// `linkOnEitherSide` words the link phrase for Match Dates, which also leaves out a pair with a
    /// link on the side it writes; such a row has no hold, so a row without one counts as a link.
    static func leftOutPhrases(_ held: [FileDifference], linkOnEitherSide: Bool = false) -> [String] {
        let links = held.filter { $0.heldBack == nil || $0.heldBack == .sourceIsSymbolicLink }.count
        let folderLinks = held.filter {
            if case .enclosesSymbolicLink = $0.heldBack { return true }
            return false
        }.count
        let decisions = held.count - links - folderLinks
        var phrases: [String] = []
        if decisions > 0 {
            phrases.append(decisions == 1
                ? "1 item needs your decision and was left out — right-click its row to choose which to keep"
                : "\(decisions) items need your decision and were left out — right-click each row to choose which to keep")
        }
        if folderLinks > 0 {
            phrases.append(folderLinks == 1
                ? "1 folder holds a link to somewhere outside it and was left out — right-click its row to copy it on its own"
                : "\(folderLinks) folders hold links to somewhere outside them and were left out — right-click each row to copy it on its own")
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

    /// Registers one undo step over a date match: it sets each file's date to
    /// `restoringPrevious ? previous : matched`, but only on a file that still has the other date
    /// and the recorded size (a file saved since isn't this step's to re-date), and registers its
    /// own inverse as the redo.
    func registerDateMatchUndo(_ items: [DateMatchState], restoringPrevious: Bool, actionName: String,
                               fileManager fm: FileManaging) {
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            Logger.shared.info("User triggered \(restoringPrevious ? "Undo" : "Redo"): \(actionName)")
            let slot = target.claimFileOperationSlot()
            target.registerDateMatchUndo(items, restoringPrevious: !restoringPrevious, actionName: actionName, fileManager: fm)
            Task { @MainActor in
                let (reset, changed, unwritable) = await target.enqueueFileOperation(slot: slot) { () -> (Int, Int, Int) in
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
                        // Exact, so the inverse step's `now.modified == expected` holds:
                        // `setAttributes` rounds to the microsecond, and most files would then read
                        // as "changed since".
                        if (try? fm.setModificationDate(goal, ofItemAtPath: item.url.path)) != nil {
                            reset += 1
                        } else {
                            unwritable += 1
                        }
                    }
                    return (reset, changed, unwritable)
                }
                let verb = restoringPrevious ? "Undo" : "Redo"
                var outcome = "re-dated \(reset) of \(items.count) file(s)"
                if changed > 0 { outcome += ", \(changed) left alone — changed since" }
                if unwritable > 0 { outcome += ", \(unwritable) could not be re-dated" }
                // A file left alone is shown, not only logged, or an Undo that re-dated nothing
                // would look like one that re-dated everything.
                let leftAlone = changed + unwritable
                guard leftAlone > 0 else {
                    Logger.shared.info("\(verb) (\(actionName)): \(outcome)")
                    return
                }
                Logger.shared.warning("\(verb) (\(actionName)): \(outcome)")
                let files = leftAlone == 1 ? "1 file’s date" : "\(leftAlone) files’ dates"
                let reason: String
                switch (changed, unwritable) {
                case (_, 0): reason = leftAlone == 1 ? "it changed since" : "they changed since"
                case (0, _): reason = leftAlone == 1 ? "it couldn’t be re-dated" : "they couldn’t be re-dated"
                default: reason = "\(changed) changed since, \(unwritable) couldn’t be re-dated"
                }
                target.banner = .warning("\(verb) left \(files) alone — \(reason)", log: .warn)
            }
        }
        undoManager?.setActionName(actionName)
    }

    /// Shared scaffolding for the parallel bulk-sync and verify workers: a work queue drained by up
    /// to `concurrency` tasks, stopping once the progress is cancelled. After each item the
    /// completed count (offset by `completedBase`, for items resolved before the workers started)
    /// goes into the `Progress` and is reported on the main actor. Internal because
    /// `verifyAllWithChecksum` in FileSyncManager+Verify.swift uses it too.
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

    /// Runs `syncAll`'s copy/move I/O for a prepared work list on the parallel scaffolding,
    /// collecting per-difference successes and failures.
    ///
    /// Each copy success carries its identity walk (`startCopyIdentityWalk`), started the moment
    /// that copy landed. A walk after the whole run (minutes on slow volumes) would record the
    /// user's edits inside a landed copy as its baseline, and ⌘Z would trash them as `.unchanged`.
    /// Moves carry nil: their undo records shallow, at registration (`registerMoveUndo`).
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
            // Each copy watches Cancel, so a run stops inside a very large file, not after it. The
            // dialog's item line is left alone: four copies share it.
            let progress = progressRef.progress
            let observer = CopyObserver(shouldContinue: { !progress.isCancelled })
            do {
                let syncResult = try performFileSyncIO(from: fromURL, to: toURL, isMove: isMove, fileManager: fileManager, observer: observer)
                let identityWalk = isMove ? nil
                    : FileSyncManager.startCopyIdentityWalk(at: syncResult.to, fileManager: fileManager)
                await collector.addSuccess(diff, (syncResult.trashed, syncResult.from, syncResult.to), identityWalk)
            } catch where CopyObserver.isCancellation(error) && progress.isCancelled {
                // Abandoned inside its staging copy: not synced and not a failure. The row stays in
                // the list, like the items the cancel never reached.
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
    ///   - confirmed: True when the calling UI already is the user's confirmation for this run
    ///     (review mode's "Copy Remaining N" names the count), so `transferConfirmer` is skipped.
    public func syncAll(direction: FileDifference.SyncAction, isMove: Bool = false, subset: [FileDifference]? = nil, confirmed: Bool = false, postBanner: Bool = true) async {
        _ = await syncAllResolving(direction: direction, isMove: isMove, subset: subset, confirmed: confirmed, postBanner: postBanner)
    }

    /// `syncAll`, returning the ids of the rows it resolved (empty when it copied nothing), for a
    /// caller that has to say which landed (`copyRemaining`).
    func syncAllResolving(direction: FileDifference.SyncAction, isMove: Bool, subset: [FileDifference]?, confirmed: Bool, postBanner: Bool) async -> Set<UUID> {
        let source = subset ?? differences
        // A row whose direction is a guess (`FileDifference.heldBack`) is not taken in bulk: the
        // user approves a count, not each row, so a wrong guess would overwrite the other side.
        // Held rows stay on the list, logged with their reason and named in the outcome.
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
            if !heldBack.isEmpty { Logger.shared.info(BulkRunLog.allHeld(isMove: isMove, held: heldBack.count)) }
            if !heldBack.isEmpty, postBanner {
                banner = .warning("Nothing was \(isMove ? "moved" : "copied")" + heldNote, log: .warn)
            }
            return []
        }
        // Drop, don't queue, a bulk run started while another is in flight (see the flag's doc).
        guard !isBulkSyncRunning else { return [] }
        // A Verify All in flight is hashing the files this run would overwrite, and would read
        // them half-written. Tell the user rather than drop silently.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for the current operation to finish before syncing", log: .info)
            return []
        }
        // A single-row syncFile in flight (perhaps parked at its prompt) may target these rows,
        // and two flows could write one difference twice. Mirrors Verify All's guard.
        guard syncingDifferenceIds.isEmpty else {
            banner = .warning("Wait for the current operation to finish before syncing", log: .info)
            return []
        }
        // Latch the flag before the confirmation prompt: its modal spins the run loop, and a
        // second syncAll or a Verify All would pass its guard while the prompt is up. The defer
        // releases it on every exit, decline included, so no early return can leak it and
        // disable bulk syncs for the session.
        isBulkSyncRunning = true
        defer { isBulkSyncRunning = false }
        // Confirm before any I/O: a bulk sync is one header click away, so a mis-click must be
        // cancellable while it costs nothing. The prompt names the first item's two folders,
        // which every item in one direction shares.
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
                // .info, like the run's start, or the trace shows a run that never ends.
                Logger.shared.info("Bulk \(isMove ? "move" : "sync") of \(total) item(s) cancelled at the confirmation prompt")
                return []
            }
        }
        // The run starts here, past its guards and its confirmation: one start line, and the finish
        // line below on every exit that follows, under the run ID its Sync History records carry.
        let runId = UUID()
        let elapsed = Elapsed()
        let bytes = toSync.reduce(Int64(0)) { sum, row in
            sum + Int64((row.action == .copyToRight ? row.leftFileSize : row.rightFileSize) ?? 0)
        }
        if let containers = toSync.first?.transferContainers {
            Logger.shared.info(BulkRunLog.start(runId: runId, isMove: isMove, items: total, bytes: bytes,
                                                from: containers.from, to: containers.to))
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
            // isBulkSyncRunning is released by the defer at the latch above.
            bulkSyncProgress = nil
            bulkApplyToAllResolution = nil
            if activeProgress === progress { activeProgress = nil }
            clearSyncing(ids: toSyncIDs)
        }

        let activeFM = fileManager
        // Resolve the URLs, then stat every destination in one detached pass: a per-file stat on
        // the main actor stalls the UI on network and cloud volumes. Collision prompts still run
        // on the main actor in list order; once a prompt has held the run, the loop re-stats the
        // "missing" results so a destination created meanwhile still gets its prompt.
        var candidates: [(difference: FileDifference, fromURL: URL, toURL: URL)] = []
        candidates.reserveCapacity(toSync.count)
        for difference in toSync {
            let urls = difference.transferURLs
            candidates.append((difference, urls.from, urls.to))
        }

        let statURLs = candidates.map(\.toURL)
        let statProgress = ProgressRef(progress)
        let destinationExists = await Task.detached(priority: .userInitiated) { () -> [(exists: Bool, isDirectory: Bool)] in
            // A cancelled run stops stat-ing; the loop below breaks on the same flag before it
            // reads the placeholder results.
            statURLs.map { url in
                guard !statProgress.progress.isCancelled else { return (false, false) }
                var isDir: ObjCBool = false
                let exists = activeFM.fileExists(atPath: url.path, isDirectory: &isDir)
                return (exists, isDir.boolValue)
            }
        }.value

        var preparedList: [(FileDifference, URL, URL, Bool)] = []
        var skippedCount = 0
        // Destinations already claimed by earlier items in this batch. The copies run later in
        // parallel, so a disk-only uniqueness check can't see another pending target: a keep-both
        // "report 2.txt" could coincide with another item's real target, and the workers would
        // overwrite one with the other, losing data silently.
        var reservedTargets = Set<String>()
        // On a case-insensitive volume two targets differing only by case are one file, so the
        // reserved set must fold case there, or the parallel workers write to the same file. On a
        // case-sensitive volume it must not, or `README.md` beside `Readme.md` gets an invented
        // `README 2.md`. The probe works for a not-yet-existing item, since every target here is.
        //
        // Asked per destination, not once per batch. A batch can span volumes (a nested mount,
        // a pane rooted at /Volumes). Wrongly answering "case-sensitive" is the dangerous half:
        // two case-variant targets pass the check, the workers write the same file, and with
        // `isMove` both sources are consumed, so one file is lost under a success banner with no
        // Trash entry. Memoized per parent folder: one stat per destination folder.
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
        // The batch stat ran before the first prompt, and a prompt can hold this loop for any
        // length of time. A destination created meanwhile would be replaced without its prompt,
        // so once a prompt has shown, re-stat the "missing" results (off the main actor).
        var promptShownSinceStatPass = false
        for (index, candidate) in candidates.enumerated() {
            if progress.isCancelled { break }
            var toURL = candidate.toURL
            var destinationOccupied = destinationExists[index].exists
            var destinationIsDirectory = destinationExists[index].isDirectory
            // Provider name check first: a sanitized target needs a fresh stat, and its prompt
            // holds the loop like a collision prompt, so it sets the same re-stat flag.
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
                // A folder collision always prompts, never taken from the "Apply to all" cache:
                // replacing a folder trashes everything only the destination has, so it must not
                // ride on a decision made for a file. Mirrors ConflictPolicy.autoResolution's
                // `guard !isDirectory`. A folder decision never seeds the cache either.
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
                    // `.merge` isn't offered here (no `offersMerge`), so a stray one is skipped.
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
            // For a missing target or a Replace, the plain name may be one an earlier keep-both
            // claimed this batch. Uniquify against disk and the reserved set so no two items share
            // a destination.
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

        // Skipped items count as completed, so progress can reach 100%.
        progress.completedUnitCount = Int64(skippedCount)
        bulkSyncProgress = (skippedCount, total)
        let skipped = skippedCount
        let progressRef = ProgressRef(progress)
        let weakRef = WeakSyncManagerRef(self)
        let totalCount = total
        // One @Published write per whole percent, not per file (`ProgressPublishGate`).
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

        // Group the run's per-file undos into one "Sync run" step, so ⌘Z and Undo Last Run reverse
        // the whole bulk sync through the existing per-file reversal. An empty run opens no group.
        var historyRecords: [SyncHistoryRecord] = []
        // Each copy's identity walk started in `performBulkSyncIO` as its copy landed. The
        // registrations' tasks are awaited after the group closes, so nothing can slip into the
        // "Sync run" step while the main actor suspends.
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
            // Size comes free from the difference (source side). Checksum is nil: hashing inline
            // would slow a bulk run, and a later Verify can fill it.
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
        // Armed here, in the turn that closed the group, not after the walks below: after an
        // await the stack may be topped by a rename or a ⌘Z, and Undo Last Run would describe
        // this run while reversing that.
        recordSyncHistory(historyRecords)
        // Nothing left for Stop to stop: the capsule drops it, and so does the Differences list's
        // Cancel, which reads the flag only on redraw, so the count is republished to force one.
        progress.markFinishing(isMove ? "the move" : "the sync")
        bulkSyncProgress = bulkSyncProgress
        // Outside the group: the run isn't complete until every undo it registered is armed.
        for walk in identityWalks { await walk.value }
        removeResolvedDifferences(matching: result.successes.map { $0.0 })
        // Failures stay in the list, so mark them now. Unconditional: a clean run clears the
        // previous run's marks.
        recordTransferFailures(result.failures)
        // No per-failure isSyncing reset: the defer clears it for every item of this run before
        // anything can observe the list.
        if result.failures.count == 1, let (diff, error) = result.failures.first {
            present(.syncFailed(
                item: diff.relativePath,
                path: diff.sourceItemPath,
                reason: error.localizedDescription,
                isRetryable: false
            ))
        } else if result.failures.count > 1 {
            // The alert holds one error at a time, so the log names every failure, grouped by
            // kind: one ERROR line per kind with its reason, then every path in it, at most 200 a
            // line, so a 5,000-item disk-full run is a handful of lines, not 5,000.
            for line in GroupedFailureLog.lines("Bulk \(isMove ? "move" : "sync")",
                                                result.failures.map { (name: $0.0.sourceItemPath, error: $0.1) }) {
                Logger.shared.error(line)
            }
            let (firstDiff, firstError) = result.failures[0]
            present(.bulkFailed(
                verb: "sync",
                failureCount: result.failures.count,
                firstPath: firstDiff.sourceItemPath,
                firstReason: firstError.localizedDescription
            ))
        }
        // Completion banner. A clean run offers Undo, which reverses the grouped "Sync run" step
        // in one go. On a partial run the failure alert already speaks, so stay quiet.
        if postBanner, result.failures.isEmpty, !result.successes.isEmpty {
            let pastTense = isMove ? "Moved" : "Copied"
            banner = .success((result.successes.count == 1
                ? "\(pastTense) 1 item"
                : "\(pastTense) \(result.successes.count) items") + heldNote, undoable: true)
        }

        // The run's finish line, written whatever came of it, so an all-failed or cancelled run
        // still ends in the log. Rows the loop never reached were left by a cancel.
        let reached = result.successes.count + result.failures.count + skipped
        Logger.shared.info(BulkRunLog.finish(
            runId: runId, isMove: isMove,
            counts: .init(done: result.successes.count, failed: result.failures.count, held: heldBack.count,
                          skipped: skipped, canceled: max(0, total - reached)),
            elapsed: elapsed.text))
        return Set(result.successes.map { $0.0.id })
    }

    /// Review's "Copy Remaining N" when some of the rows left need the user's decision. Every row
    /// that can go is copied, in both directions, and one banner names the held rows in the words
    /// every bulk run uses (`leftOutPhrases`); they stay on the list.
    ///
    /// The prompt is skipped: the button names the count and is the confirmation. Undo is offered
    /// only for one direction: two runs are two undo steps, and one Undo would reverse half.
    /// - Returns: The ids of the rows it resolved, so Review can mark them and stay on the rest,
    ///   or nil when it refused to start (another operation is running), having said so.
    @discardableResult
    public func copyRemaining(_ remaining: [FileDifference], isMove: Bool) async -> Set<UUID>? {
        // syncAll's own guards, up front: a refusal inside it would read here as "nothing
        // copied", and this banner would hide the reason.
        guard !isBulkSyncRunning, !isVerifyAllRunning, syncingDifferenceIds.isEmpty else {
            banner = .warning("Wait for the current operation to finish before syncing", log: .info)
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
            banner = .warning(message, log: .warn)
        } else {
            banner = .success(message, undoable: directions.count == 1)
        }
        return resolved
    }

}

// MARK: - Bulk sync helpers (Sendable-safe refs and actors for parallel workers)

// ProgressRef and WeakSyncManagerRef are internal because FileSyncManager+Verify.swift shares the
// parallel-worker scaffolding. @unchecked: NSProgress is thread-safe; this only wraps it.
final class ProgressRef: @unchecked Sendable {
    let progress: Progress
    init(_ progress: Progress) { self.progress = progress }
}

final class WeakSyncManagerRef: @unchecked Sendable {
    // `weak let`: never reassigned, so the only mutation is the runtime nil-ing on deallocation,
    // which is what makes this Sendable-safe.
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
