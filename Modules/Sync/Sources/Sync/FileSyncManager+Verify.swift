import Events
import Foundation

/// A "copy the verified-identical files left→right" offer, together with the
/// `fileOperationsEpoch` its verdicts were hashed under.
///
/// One value on purpose: `confirmVerifiedCopy()` refuses the bulk copy when `asOf` no longer
/// matches the live epoch. A stamp kept apart from the list could be certified current for a
/// stale list, and the guard would fail open into a silent bulk overwrite. As part of the value
/// it can't be forgotten, and a wrong one fails closed: one refused copy and a banner. It also
/// lets tests build an offer stamped behind the live epoch.
public struct VerifiedCopyOffer: Equatable, Sendable {
    /// The differences that verified byte-identical.
    public let differences: [FileDifference]
    /// `fileOperationsEpoch` as it stood when these verdicts were taken.
    public let asOf: Int
    /// Both ends of each pair as they read on disk just before their bytes were hashed, keyed by
    /// difference id. The epoch answers "did we write anything since?"; this answers "did anyone?".
    /// A cloud daemon syncing a new right-side version while the dialog is open moves no epoch,
    /// count or scan generation, and Confirm would overwrite it with the stale left copy.
    ///
    /// Read before the content, so the stamp also covers the hash itself: a write landing mid-hash
    /// shows up in the confirm-time re-stat.
    public let stamps: [UUID: FilePairStamp]

    /// - Parameter stamps: pass `nil` to stamp the pairs from disk now, so a caller that forgets
    ///   the argument still gets a checked write rather than every pair certified unchanged.
    ///   Callers that hashed earlier (only `verifyAllWithChecksum`) pass the values taken at hash
    ///   time.
    public init(
        differences: [FileDifference],
        asOf: Int,
        stamps: [UUID: FilePairStamp]? = nil,
        fileManager: FileManaging = FileManager.default
    ) {
        self.differences = differences
        self.asOf = asOf
        self.stamps = stamps ?? Dictionary(
            uniqueKeysWithValues: differences.map { ($0.id, FilePairStamp.read($0, fileManager: fileManager)) }
        )
    }

    /// Why an offer can no longer be acted on, beyond the epoch: one of its pairs has moved on
    /// disk, or one of them was never stamped and so cannot be re-checked at all.
    public enum Staleness: Equatable, Sendable {
        case changed(FileDifference, FilePairStamp.Side)
        case unstamped(FileDifference)

        /// The offending row, for the message.
        public var difference: FileDifference {
            switch self {
            case .changed(let diff, _), .unstamped(let diff): return diff
            }
        }
    }

    /// Re-stats every pair and returns the first that no longer reads as it did at hash time,
    /// or `nil` when the whole offer still stands.
    ///
    /// The first offender refuses the whole offer rather than shrinking it: the user confirmed the
    /// list as a whole, and a daemon that just rewrote one file may not be done. A pair with no
    /// stamp counts as stale (unreachable today), so an offer that can't back its verdicts costs
    /// one re-verify, never an unchecked bulk write.
    func firstStaleness(fileManager: FileManaging) -> Staleness? {
        for diff in differences {
            guard let recorded = stamps[diff.id] else { return .unstamped(diff) }
            if let side = recorded.sideThatChanged(of: diff, fileManager: fileManager) {
                return .changed(diff, side)
            }
        }
        return nil
    }
}

/// One end of a pair as a later re-stat can compare it: size and modification date, as they
/// stood when a decision was based on them.
///
/// Not a content hash: it only has to notice that the bytes may have moved, cheaply, at a click.
/// A second hash would cost as much as the first. Its blind spot is a rewrite with the same size
/// and timestamp, which APFS's nanosecond times make an accident no writer produces.
public struct FileEndpointStamp: Equatable, Sendable {
    public let size: Int64
    public let modified: Date

    public init(size: Int64, modified: Date) {
        self.size = size
        self.modified = modified
    }

    /// Stats `path` without following symlinks, the same item the copy acts on. `nil` means
    /// "nothing there", a value and not a failure: `nil` then a stamp means the file appeared while
    /// the dialog was open, and the reverse means it was deleted.
    public static func read(atPath path: String, fileManager: FileManaging) -> FileEndpointStamp? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileEndpointStamp(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: modified
        )
    }
}

/// Both ends of one pair, stamped at the same moment, so a later re-stat can say which side
/// moved — the left (the bytes about to be written) or the right (the bytes about to be
/// overwritten).
public struct FilePairStamp: Equatable, Sendable {
    public enum Side: String, Equatable, Sendable {
        case left
        case right
    }

    public let left: FileEndpointStamp?
    public let right: FileEndpointStamp?

    public init(left: FileEndpointStamp?, right: FileEndpointStamp?) {
        self.left = left
        self.right = right
    }

    public static func read(_ diff: FileDifference, fileManager: FileManaging) -> FilePairStamp {
        FilePairStamp(
            left: FileEndpointStamp.read(atPath: diff.leftItemPath, fileManager: fileManager),
            right: FileEndpointStamp.read(atPath: diff.rightItemPath, fileManager: fileManager)
        )
    }

    /// Re-stats both ends of `diff` and returns the side that no longer matches this stamp, or
    /// `nil` when both still do. The right side is reported first when both moved: it names the
    /// end that is about to be overwritten, which is the expensive one to be wrong about.
    public func sideThatChanged(of diff: FileDifference, fileManager: FileManaging) -> Side? {
        let now = Self.read(diff, fileManager: fileManager)
        if now.right != right { return .right }
        if now.left != left { return .left }
        return nil
    }
}

extension FileSyncManager {

    /// Runs checksum verification on the differences that meet the Verify criteria (newer/older but
    /// same size). `subset` scopes it (e.g. the table selection); `nil` verifies every eligible
    /// difference. Up to 4 in parallel; cancellable via activeProgress.
    ///
    /// Publishes `verifiedIdenticalForCopy`, the offer behind the copy-left→right dialog, stamped
    /// with the epoch its verdicts were hashed under, and only while nothing has superseded them.
    ///
    /// A pass with nothing to offer retracts any standing offer: no eligible candidates, nothing
    /// identical, or cancellation. This pass writes nothing, so the confirm-time guards would see
    /// an unmoved epoch and a zero count and let the old list through to a bulk write.
    public func verifyAllWithChecksum(subset: [FileDifference]? = nil) async {
        // Refuse to start while anything is writing, or about to write, the files this run would
        // hash: a file mid-overwrite can hash as "identical" and produce a wrong bulk-copy offer.
        // `isBulkSyncRunning` covers syncAll from its prepare phase and the verified-copy bulk
        // copy; `syncingDifferenceIds` a syncFile parked at its collision prompt;
        // `activeFileOperationsCount` every queued file operation, undo included. The user gets a
        // banner, not a silent no-op.
        guard !isVerifyAllRunning, !isBulkSyncRunning,
              activeFileOperationsCount == 0, syncingDifferenceIds.isEmpty else {
            banner = .refusal("Wait for the current operation to finish before verifying", log: .info)
            return
        }
        isVerifyAllRunning = true
        defer { isVerifyAllRunning = false }

        let candidates = subset ?? differences
        let toVerify = candidates.filter { $0.type == .differentDates && $0.sizesMatch }
        // Retract here too, not only in the empty-verdict branch below, which this return skips.
        // A selection with no date-only same-size row is the common empty case, and the
        // confirm-time guards would otherwise wave the old offer through.
        guard !toVerify.isEmpty else {
            if verifiedIdenticalForCopy != nil {
                Logger.shared.debug("Verify All: no eligible pairs in the selection — retracted the standing verified-copy offer")
            }
            verifiedIdenticalForCopy = nil
            return
        }
        // The banner reports how the pass ended; this records that it began, so a hang or a
        // force-quit mid-hash leaves a trace.
        Logger.shared.info("Verify All: hashing \(toVerify.count) same-size pair(s)")
        let elapsed = Elapsed()

        // A rescan can complete during the hash and replace `differences`, and an offer
        // published then would point at a superseded set. Re-checked before publishing, as in
        // autoVerifySameSizePairs.
        let startGeneration = scanRequestGeneration
        // A file operation can also overwrite a candidate mid-hash and finish before its rescan
        // bumps the generation. ⌘Z is the live route: every other write path waits for
        // `isVerifyAllRunning`, but undo deliberately doesn't, since blocking it through a long
        // verify would be worse. `enqueueFileOperation` bumps this epoch before any I/O, so it is
        // re-checked before publishing too.
        let startOperationsEpoch = fileOperationsEpoch

        let progress = Progress(totalUnitCount: Int64(toVerify.count))
        progress.localizedDescription = "Verifying \(CountedNoun.phrase(toVerify.count, "file"))"
        progress.isCancellable = true
        progress.runLockReason = Progress.runLockReason(waitingFor: "Verify All")
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
        // One @Published write per whole percent, not per file (`ProgressPublishGate`).
        let publishGate = ProgressPublishGateBox()
        let progressRef = ProgressRef(progress)

        await Self.processInParallel(
            items: toVerify,
            concurrency: min(4, max(1, toVerify.count)),
            progress: progressRef,
            reportCompleted: { completed in
                guard publishGate.admits(completed: completed, total: totalCount) else { return }
                weakRef.value?.verifyAllProgress = (completed, totalCount)
            }
        ) { diff in
            // Stamped before the read, so a write landing mid-read is caught by the confirm-time
            // re-stat instead of being recorded as how it looked when hashed.
            let stamp = FilePairStamp.read(diff, fileManager: activeFM)
            // Stop is a `Progress` cancel, not a task cancel, so the hash asks it per chunk: a
            // pair of 5 GB files would otherwise read to the end after the click.
            let same = await FileContentVerifier.filesHaveSameContent(
                leftPath: diff.leftItemPath,
                rightPath: diff.rightItemPath,
                fileManager: activeFM,
                cache: ContentHashCache.shared,
                isCancelled: { progressRef.progress.isCancelled }
            )
            if same == true {
                await collector.addIdentical(diff, stamp: stamp)
            } else if same == false {
                await collector.addDiffered()
            } else {
                await collector.addSkipped()
            }
        }

        // Keep the digests whatever this pass publishes, even on cancellation when its verdicts
        // are discarded: the bytes were read either way, and re-reading is what the cache saves.
        await ContentHashCache.shared.save()

        let (verifiedIdentical, stamps, differed, skipped) = await collector.get()
        // Its own finish line, whatever the outcome: the banner is a separate record of what was
        // shown, and a cancel's counts are only here.
        Logger.shared.info(VerifyAllLog.finish(identical: verifiedIdentical.count, differed: differed,
                                               skipped: skipped, of: toVerify.count,
                                               canceled: progress.isCancelled, elapsed: elapsed.text))
        if progress.isCancelled || verifiedIdentical.isEmpty {
            // Nothing this pass stands behind, so retract any offer a previous pass left. Kept,
            // its old list and stamp would pass `confirmVerifiedCopy`'s guards, since verify
            // writes nothing. Unconditional on the supersedence checks below: dropping it costs one
            // re-verify, keeping it a bulk write.
            //
            // Cancellation lands here too. The collector then holds only the pairs that drained
            // before the click; offering a bulk write over them under a "cancelled" banner is
            // what the user just declined. Re-run Verify All to get an offer.
            if verifiedIdenticalForCopy != nil {
                Logger.shared.debug("Verify All: \(progress.isCancelled ? "cancelled" : "nothing verified identical") — retracted the standing verified-copy offer")
            }
            verifiedIdenticalForCopy = nil
        } else if scanRequestGeneration == startGeneration,
                  fileOperationsEpoch == startOperationsEpoch {
            // Publish only if no rescan superseded these differences and no file operation
            // started during the hash (`startOperationsEpoch` above). Stamped with the epoch the
            // verdicts were hashed under, which the guard just showed equals the live one.
            verifiedIdenticalForCopy = VerifiedCopyOffer(
                differences: verifiedIdentical, asOf: startOperationsEpoch, stamps: stamps
            )
            // The offer is a standing permission for a bulk overwrite with no per-file prompt, so
            // log that it was extended, not only whether it was taken.
            Logger.shared.info("Verify All: \(verifiedIdentical.count) pair(s) verified identical — offering copy left→right")
        }
        var parts: [String] = []
        if !verifiedIdentical.isEmpty { parts.append("\(verifiedIdentical.count) identical") }
        if differed > 0 { parts.append("\(differed) differed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if progress.isCancelled {
            banner = .warning("Verify All canceled", log: .info)
        } else if parts.isEmpty {
            banner = nil
        } else {
            let message = "Verify All: " + parts.joined(separator: "; ")
            // Anything that differed or couldn't be verified needs the user's attention.
            banner = (differed > 0 || skipped > 0) ? .warning(message, log: .warn) : .success(message)
        }
    }

    /// Dismisses the "copy verified" dialog without copying, and hides the verified-identical rows,
    /// but only on verdicts still worth acting on.
    ///
    /// Hiding a row claims the two files are byte-identical, so it rests on the same verdicts as
    /// the copy and passes the same guards as `confirmVerifiedCopy`. An undo landing while the
    /// dialog is up can make a pair differ again, and a hide on a stale verdict would last until a
    /// manual rescan. The offer is dropped either way; only the hiding has to be earned.
    public func dismissVerifiedCopyDialogWithoutCopy() {
        guard let offer = verifiedIdenticalForCopy else { return }
        verifiedIdenticalForCopy = nil
        guard fileOperationsEpoch == offer.asOf, activeFileOperationsCount == 0 else { return }
        // And the confirm's disk re-check: a pair rewritten outside this app is no longer
        // identical, and nothing rescans after such a write, so the hide would outlive its reason.
        guard offer.firstStaleness(fileManager: fileManager) == nil else { return }
        for diff in offer.differences {
            verifiedSameDifferenceIds.insert(diff.id)
        }
        Task { await self.applyFilters() }
    }

    /// For the dialog's `isPresented` binding: defers the "dismissed without copy" cleanup by one
    /// main-actor turn. SwiftUI writes `false` on any dismissal, the confirm button included, in no
    /// guaranteed order against the button action, so a synchronous cleanup could destroy the list
    /// before `confirmVerifiedCopy()` claims it. Deferred, a claimed list makes this a no-op.
    /// - Returns: The deferred cleanup task, so tests can await the turn instead of sleeping.
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
        // The offer can outlive its verdicts: a file operation (⌘Z most directly) landing while
        // the dialog is up rewrites verified bytes, and its rescan clears the offer only once it
        // completes. A confirm in that window would overwrite what the operation just wrote.
        //
        // Both terms are needed. The epoch says an operation ran; the count says one is claimed
        // and about to. They differ for `transferItems`, which calls `preCountFileOperation()`
        // before its modal and bumps the epoch in `enqueueFileOperation` only once the user
        // confirms, maybe minutes later. On the epoch alone the bulk copy would queue behind that
        // transfer and overwrite what it wrote.
        //
        // `bulkCopyDifferencesLeftToRight` checks both again, since these readings age before it
        // orders its write; this check keeps the offer and banner honest at click time.
        //
        // The scan-checksum pass is epoch-only at commit time on purpose
        // (`autoVerifySameSizePairs`): there a declined pre-counted operation would void a hashed
        // batch for nothing. Here refusing costs one re-verify and allowing costs an unverified
        // bulk write. Don't merge the two guards.
        //
        // The banner says only what the guard can see: an operation ran or is pending, not that a
        // verified file was touched.
        guard fileOperationsEpoch == offer.asOf, activeFileOperationsCount == 0 else {
            verifiedIdenticalForCopy = nil
            banner = .refusal("A file operation ran or is pending — run Verify All again", log: .warn)
            return nil
        }
        // The epoch and count can't see writers outside this app, and the dialog can stay open
        // indefinitely: a cloud daemon syncing a new right-side version would be overwritten with
        // no per-file prompt. So re-stat both ends rather than expire the offer, which would still
        // admit any write inside its window. Two stats per pair on the main actor is far cheaper
        // than the copy it gates.
        if let staleness = offer.firstStaleness(fileManager: fileManager) {
            verifiedIdenticalForCopy = nil
            let name = staleness.difference.relativePath
            switch staleness {
            case .changed(_, let side):
                let end = side == .right ? "on the right" : "on the left"
                banner = .warning("“\(name)” changed \(end) since it was verified — run Verify All again", log: .warn)
            case .unstamped:
                banner = .refusal("“\(name)” cannot be re-checked against its verification — run Verify All again", log: .warn)
            }
            return nil
        }
        verifiedIdenticalForCopy = nil
        // The counterpart of the offer's log line. A pair stamped at hash time has its date
        // matched, not its bytes copied.
        Logger.shared.info("Verified-copy confirmed: matching \(offer.differences.count) file(s) left→right without per-file prompts")
        // Hand the stamps on so the run can re-check them as it orders the write, several
        // main-actor hops later.
        return Task { await self.bulkCopyDifferencesLeftToRight(offer.differences, asOf: offer.asOf, stamps: offer.stamps) }
    }

    /// The largest file a pass the user didn't ask for reads whole: the scan-time verify and the
    /// filing scan's already-filed check. Both run unasked, so a 5 GB file would add seconds of
    /// reading. Larger pairs stay listed for Verify All, which the user starts and can stop; a
    /// larger loose file isn't checked against the tree.
    ///
    /// 100,000,000 bytes, not 100 MiB: sizes are shown in decimal units (`formatBytes`, as Finder
    /// does), so Settings help can call it "100 MB". Checked against the size as the file is read
    /// (``isWithinUnaskedLimit``), not only the scanned size, since a landing download grows.
    nonisolated static let unaskedPassMaxFileBytes = 100_000_000

    /// Whether `path` is small enough, right now, for a pass nobody asked for to read it whole.
    /// Its size as the hash would read it (``FileContentVerifier/sizeForHash``); unknown counts as
    /// too large, the safe answer for a pass that can simply leave the file for later. Synchronous
    /// file metadata: call it off the main actor.
    nonisolated static func isWithinUnaskedLimit(_ path: String, fileManager: FileManaging) -> Bool {
        (FileContentVerifier.sizeForHash(filePath: path, fileManager: fileManager) ?? .max)
            <= unaskedPassMaxFileBytes
    }

    /// The scan-time checksum pass behind `autoVerifySameSizeDuringScan`: hashes each pair that
    /// only differs by date (same size, both sides present) and silently hides the identical
    /// ones via `verifiedSameDifferenceIds` — the same mechanism as a dismissed Verify All, so
    /// the rows reappear if a later scan finds them genuinely changed.
    ///
    /// Unlike Verify All it publishes no progress, offers no copy-to-match-dates dialog, and
    /// doesn't claim `isVerifyAllRunning`: blocking a bulk sync behind an unasked pass would be
    /// worse than re-hashing. Instead it skips while anything is writing, skips rows that start
    /// syncing, and publishes only while `scanGeneration` is still current.
    func autoVerifySameSizePairs(scanGeneration: Int) async {
        guard autoVerifySameSizeDuringScan,
              !isVerifyAllRunning, !isBulkSyncRunning,
              activeFileOperationsCount == 0 else { return }

        // The entry guard only proves nothing was writing at the start. An operation that begins
        // and finishes during the hash, before its rescan bumps `scanRequestGeneration`, would let
        // a stale "identical" hide a row that now differs. The epoch only ever grows, so the
        // batch is discarded if it moved; a count check would miss an operation already done.
        let startOperationsEpoch = fileOperationsEpoch

        let candidates = rawDifferences.filter {
            $0.type == .differentDates && $0.sizesMatch && !syncingDifferenceIds.contains($0.id)
                && ($0.leftFileSize ?? 0) <= Self.unaskedPassMaxFileBytes
        }
        guard !candidates.isEmpty else { return }

        let activeFM = fileManager
        let collector = VerifyResultsCollector()
        // A private Progress only for processInParallel's cancellation contract; never published.
        let progress = Progress(totalUnitCount: Int64(candidates.count))

        await Self.processInParallel(
            items: candidates,
            concurrency: min(4, candidates.count),
            progress: ProgressRef(progress),
            reportCompleted: { _ in }
        ) { diff in
            // The scan's recorded size let this pair in; what the hash would read now decides.
            guard Self.isWithinUnaskedLimit(diff.leftItemPath, fileManager: activeFM),
                  Self.isWithinUnaskedLimit(diff.rightItemPath, fileManager: activeFM) else { return }
            let same = await FileContentVerifier.filesHaveSameContent(
                leftPath: diff.leftItemPath,
                rightPath: diff.rightItemPath,
                fileManager: activeFM,
                cache: ContentHashCache.shared
            )
            if same == true {
                // No stamp: this pass makes no copy offer; it only hides rows the next scan
                // re-derives.
                await collector.addIdentical(diff, stamp: nil)
            }
        }

        // Keep the digests whatever this run publishes: the reads were the expensive part.
        await ContentHashCache.shared.save()

        let identical = await collector.get().verifiedIdentical
        // Publish only against the scan the candidates came from. Checked after the last
        // suspension point, so a scan requested while the collector drained can't slip past.
        guard scanGeneration == scanRequestGeneration else { return }
        // Re-check the epoch at commit time: an operation started since entry, even a finished
        // one, may have rewritten these bytes. Discard the batch; that operation's rescan re-runs
        // this pass.
        //
        // Only the epoch, deliberately. The entry guard's other terms (a pre-counted operation
        // at its prompt, syncAll's stat pass) mean nothing is written yet, since every write goes
        // through `enqueueFileOperation`, which bumps the epoch first. Discarding on them would
        // leave identical pairs listed if the user then declined, because no rescan would follow.
        guard fileOperationsEpoch == startOperationsEpoch else {
            Logger.shared.info("Scan checksum pass: discarded — the file operations epoch moved mid-hash")
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
    private var stamps: [UUID: FilePairStamp] = [:]
    private var differed: Int = 0
    private var skipped: Int = 0
    /// The stamp travels with the verdict, since it is evidence only if taken around that read.
    /// No default on `stamp`, so a forgotten argument can't produce an offer that can't be
    /// re-checked; the scan-time pass passes `nil` explicitly.
    func addIdentical(_ diff: FileDifference, stamp: FilePairStamp?) {
        verifiedIdentical.append(diff)
        stamps[diff.id] = stamp
    }
    func addDiffered() { differed += 1 }
    func addSkipped() { skipped += 1 }
    func get() -> (verifiedIdentical: [FileDifference], stamps: [UUID: FilePairStamp],
                   differed: Int, skipped: Int) {
        (verifiedIdentical, stamps, differed, skipped)
    }
}
