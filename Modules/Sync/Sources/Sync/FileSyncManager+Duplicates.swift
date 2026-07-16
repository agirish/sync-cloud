import Events
import Foundation

/// Tidy — the in-provider duplicate finder. Reuses the existing tree walk and content hasher to
/// gather input for the pure ``DuplicateFinder``, and routes removals through ``deleteItems`` so
/// they land in the Trash with the same one-step Undo as every other destructive action.
extension FileSyncManager {

    /// Files the most recent duplicate scan had to skip during content hashing — and therefore
    /// could not prove identical to anything. Without this figure, two identical >100 MB files
    /// (or cloud-only placeholders) are simply invisible to Tidy with zero indication. Labels the
    /// current `duplicateGroups` like `duplicateScanRoot` does: published with the results
    /// (`duplicateScanSkips` in FileSyncManager.swift), reset by `clearDuplicates`.
    public struct DuplicateScanSkips: Sendable, Equatable {
        /// Candidates skipped because they exceed the hashing size cap (`maxBytesToHash`).
        public var tooLarge: Int
        /// Candidates skipped because they are cloud-only (dataless) placeholders that hashing
        /// would force-download.
        public var cloudOnly: Int
        public var total: Int { tooLarge + cloudOnly }

        public init(tooLarge: Int = 0, cloudOnly: Int = 0) {
            self.tooLarge = tooLarge
            self.cloudOnly = cloudOnly
        }
    }

    /// Aggregate headline numbers for the Duplicates results view.
    public struct DuplicateSummary: Sendable, Equatable {
        public var groupCount: Int
        public var reclaimableBytes: Int
        public var redundantCopyCount: Int
        public var needsReviewCount: Int
    }

    /// Summary derived from the current ``duplicateGroups``. The headline "reclaimable" and
    /// "redundant" figures count only batch-eligible (identical) groups, so they match exactly
    /// what "Apply recommended" delivers — overlapping (merge deferred) and name-only (different
    /// content) groups never inflate them.
    public var duplicateSummary: DuplicateSummary {
        var reclaimable = 0, redundant = 0, review = 0
        for g in duplicateGroups {
            if g.isRecommendedForBatch {
                reclaimable += g.reclaimableBytes
                redundant += g.copies.count - 1
            }
            if case .nameOnly = g.matchType { review += 1 }
        }
        return DuplicateSummary(groupCount: duplicateGroups.count,
                                reclaimableBytes: reclaimable,
                                redundantCopyCount: redundant,
                                needsReviewCount: review)
    }

    // MARK: Scan

    /// Walks one provider subtree, hashes duplicate-candidate files, and groups the results.
    /// - Parameters:
    ///   - root: The provider root (or focused folder) to scan.
    ///   - options: Detection tuning.
    /// Starts a cancellable Find Duplicates scan, replacing any in-flight one.
    public func startFindDuplicates(root: URL, options: DuplicateFinderOptions = .init()) {
        duplicateScanTask = restartedScanTask(replacing: duplicateScanTask) { [weak self] in
            await self?.findDuplicates(root: root, options: options)
        }
    }

    /// Cancels a running Find Duplicates scan; results are left as they were.
    public func cancelFindDuplicates() {
        duplicateScanTask?.cancel()
    }

    /// `maxBytesToHash` and `isCloudOnly` are injectable for tests only (a real >100 MB fixture
    /// per run would be wasteful, and a real dataless file can't be fabricated); production
    /// callers use the verifier's defaults.
    public func findDuplicates(
        root: URL,
        options: DuplicateFinderOptions = .init(),
        fileManager fm: FileManaging? = nil,
        maxBytesToHash: Int = FileContentVerifier.maxBytesToHash,
        isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) }
    ) async {
        guard !isFindingDuplicates else { return }
        let fileManager = fm ?? self.fileManager
        let epoch = beginScan(\.duplicateScanLifecycle, status: "Scanning \(root.lastPathComponent)…")
        duplicateScanProgress = nil   // walk phase — total unknown until candidates are counted
        // hasCompleted is set only on completion (below), so a cancelled scan leaves the
        // prior state intact rather than flashing an empty "no duplicates".
        defer {
            // endScan bumps the epoch FIRST, so hashing-progress hops still in the main-actor
            // queue can't republish status/numbers after this scan has ended (or into the next).
            endScan(\.duplicateScanLifecycle)
            duplicateScanProgress = nil
        }

        // 1. Walk the full subtree (off-main inside buildTree).
        let tree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager, maxDepth: nil)
        if Task.isCancelled { return }

        // 2. Only files whose size collides with another can possibly be identical — hash just
        //    those. Everything else gets a unique placeholder so folder signatures still compute
        //    but never falsely match.
        let allFiles = Self.flattenFiles(tree)
        var sizeCount: [Int: Int] = [:]
        for f in allFiles where (f.fileSize ?? -1) >= 0 {
            sizeCount[f.fileSize!, default: 0] += 1
        }
        let candidatePaths = allFiles
            .filter { ($0.fileSize ?? -1) >= 0 && sizeCount[$0.fileSize!, default: 0] >= 2 }
            .map { $0.id }

        let total = candidatePaths.count
        updateScan(\.duplicateScanLifecycle, epoch: epoch,
                   status: "Hashing \(total) candidate\(total == 1 ? "" : "s")…")
        duplicateScanProgress = total > 0 ? (completed: 0, total: total) : nil
        let hashOutcome = await Self.hashFilesCounting(
            candidatePaths, fileManager: fileManager, maxBytesToHash: maxBytesToHash,
            isCloudOnly: isCloudOnly
        ) { [weak self] done in
            if done % 50 == 0 || done == total {
                Task { @MainActor in
                    guard let self,
                          self.updateScan(\.duplicateScanLifecycle, epoch: epoch,
                                          status: "Hashing \(done) of \(total)…") else { return }
                    self.duplicateScanProgress = (completed: done, total: total)
                }
            }
        }
        let realHashes = hashOutcome.hashes
        if Task.isCancelled { return }
        // Deterministic terminal publish: the done == total update above is an unstructured
        // main-actor Task that can lose the race against this resumption — the defer's epoch
        // bump would then drop it, ending the bar at the last 50-multiple instead of full.
        // We're back on the main actor with the epoch still current (and not cancelled, per
        // the guard above), so pin the bar to 100% before the grouping pass below.
        if total > 0 {
            updateScan(\.duplicateScanLifecycle, epoch: epoch, status: "Hashing \(total) of \(total)…")
            duplicateScanProgress = (completed: total, total: total)
        }

        var fileHashes: [String: String] = [:]
        fileHashes.reserveCapacity(allFiles.count)
        for f in allFiles {
            fileHashes[f.id] = realHashes[f.id] ?? DuplicateFinder.unknownSignature(forPath: f.id)
        }

        // 3. Group (pure), then drop anything the user has kept separate.
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: fileHashes, options: options)
        if Task.isCancelled { return }
        let ignored = ignoredDuplicateKeys
        // Set BEFORE duplicateGroups so its @Published publish is observed with a matching value
        // (like duplicateScanRoot, it labels what's on screen, not the in-flight scan).
        duplicateScanSkips = DuplicateScanSkips(tooLarge: hashOutcome.skippedTooLarge,
                                                cloudOnly: hashOutcome.skippedCloudOnly)
        self.duplicateGroups = groups.filter { !ignored.contains($0.ignoreKey) }
        // Published with the results, not at scan start: the root labels what's on screen, and a
        // cancelled rescan of a different folder must not relabel the previous results.
        completeScan(\.duplicateScanLifecycle, root: root)
        let summary = duplicateSummary
        Logger.shared.info("Tidy: scanned \(root.lastPathComponent) — \(summary.groupCount) duplicate group(s), \(Self.formatBytes(summary.reclaimableBytes)) reclaimable")
        let skips = duplicateScanSkips
        if skips.total > 0 {
            Logger.shared.info("Tidy: \(skips.total) candidate file(s) could not be content-verified — \(skips.tooLarge) over the \(Self.formatBytes(maxBytesToHash)) hash limit, \(skips.cloudOnly) cloud-only (not downloaded); identical copies among them are not detected")
        }
    }

    // MARK: Keep separate (persistent ignore)

    private static let ignoreDefaultsKey = "tidyIgnoredGroupKeys"

    /// The set of duplicate-group keys the user has chosen to keep separate (persisted).
    public var ignoredDuplicateKeys: Set<String> {
        get { Set(duplicateIgnoreDefaults.stringArray(forKey: Self.ignoreDefaultsKey) ?? []) }
        set { duplicateIgnoreDefaults.set(Array(newValue), forKey: Self.ignoreDefaultsKey) }
    }

    /// Marks a group as intentionally separate: removes it now and remembers it so future scans
    /// don't re-flag the same cluster.
    public func keepDuplicateGroupSeparate(_ group: DuplicateGroup) {
        var keys = ignoredDuplicateKeys
        keys.insert(group.ignoreKey)
        ignoredDuplicateKeys = keys
        duplicateGroups.removeAll { $0.id == group.id }
    }

    /// Clears the current results (called when switching providers, so stale groups from one
    /// provider can never be shown — or acted on — under another).
    public func clearDuplicates() {
        // Cancel any in-flight scan so it can't republish the old provider's results after the
        // switch (findDuplicates checks Task.isCancelled before it assigns duplicateGroups).
        duplicateScanTask?.cancel()
        duplicateGroups = []
        duplicateScanRoot = nil
        duplicateScanSkips = DuplicateScanSkips()
        hasFoundDuplicates = false
    }

    // MARK: Resolve

    /// Whether a group's keeper is still where — and what — the scan saw. Groups are point-in-time
    /// snapshots: if the keeper was deleted, renamed, moved, or (for a byte-identical file group)
    /// overwritten in place between scan and click, trashing the "redundant" copies would trash the
    /// *last* copies of the keeper's original content — the one invariant Tidy promises never to
    /// break. Re-verified at resolve time, not just scan time.
    ///
    /// For a file we also re-check the byte size against the scan snapshot: any in-place edit
    /// changes the size (and mtime), so a size mismatch means the keeper's content drifted and its
    /// copies are no longer provably identical to it. (Size is used rather than mtime because the
    /// scan reads mtime via URL resource values, which need not compare equal to a re-stat through
    /// the file-manager seam; size is exact and can never false-fail an unchanged file.) Folders
    /// keep the existence-only check — a folder's stat size isn't its recursive content size.
    private func keeperStillExists(_ group: DuplicateGroup) -> Bool {
        let keeper = group.keeper
        guard fileManager.fileExists(atPath: keeper.path) else { return false }
        guard !keeper.isDirectory else { return true }
        guard let attrs = try? fileManager.attributesOfItem(atPath: keeper.path) else { return false }
        let currentSize = (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int)
        // Refuse only on a KNOWN mismatch: a real file always reports its size, so a drifted
        // keeper is caught; if size is unavailable (never happens on the real FS) fall back to the
        // existence check rather than over-refuse.
        if let currentSize, currentSize != keeper.size { return false }
        return true
    }

    /// Drops every group whose recommended copies are all off the disk — trashed just now,
    /// trashed via a pruned ancestor, or already gone externally — keeping partially or wholly
    /// failed groups visible for a retry. Returns the resolved groups. The disk is the ground
    /// truth here: a mid-batch cancel or declined permanent-delete leaves real files behind,
    /// and those groups must stay listed however the delete call accounted for them.
    private func dropFullyRemovedGroups(from groups: [DuplicateGroup]) -> [DuplicateGroup] {
        let done = groups.filter { group in
            group.recommendedRemovalPaths.allSatisfy { !fileManager.fileExists(atPath: $0) }
        }
        let doneIDs = Set(done.map { $0.id })
        duplicateGroups.removeAll { doneIDs.contains($0.id) }
        return done
    }

    /// Applies a single group's recommended removal (Trash the fully-redundant / older copies).
    /// No-op for groups that need a merge or manual review. Reversible via Undo (⌘Z).
    @discardableResult
    public func resolveDuplicateGroup(_ group: DuplicateGroup) async -> Bool {
        let paths = group.recommendedRemovalPaths
        guard !paths.isEmpty else { return false }
        guard keeperStillExists(group) else {
            banner = .warning("“\(group.keeper.name)” is no longer at its scanned location — rescan before removing its copies.")
            return false
        }
        let bytes = group.reclaimableBytes
        let removed = await deleteItems(at: paths, fileManager: fileManager)
        // Only drop the group and claim success if every copy actually left the disk — a declined,
        // failed, or cancelled trash must not vanish still-listed copies behind a false banner.
        guard removed > 0 else { return false }
        guard !dropFullyRemovedGroups(from: [group]).isEmpty else {
            if currentError == nil {
                banner = .warning("Removed \(removed) of \(paths.count) copies — the group stays listed until the rest are handled.")
            }
            return false
        }
        if currentError == nil {
            banner = .success("Reclaimed \(Self.formatBytes(bytes)) — press ⌘Z to undo")
        }
        Logger.shared.info("Tidy: removed \(paths.count) redundant copy(ies) of “\(group.keeper.name)”, reclaimed \(Self.formatBytes(bytes))")
        return true
    }

    /// Applies the recommended removal for every batch-eligible group (byte-identical only).
    /// Versions, name-only, and overlapping groups are deliberately left for a per-group look.
    public func applyRecommendedDuplicates() async {
        let eligible = duplicateGroups.filter { $0.isRecommendedForBatch }
        let batch = eligible.filter { keeperStillExists($0) }
        let paths = batch.flatMap { $0.recommendedRemovalPaths }
        guard !paths.isEmpty else {
            if !eligible.isEmpty {
                banner = .warning("The keepers are no longer at their scanned locations — rescan before removing copies.")
            }
            return
        }
        let removed = await deleteItems(at: paths, fileManager: fileManager)
        guard removed > 0 else { return }
        let done = dropFullyRemovedGroups(from: batch)
        let bytes = done.reduce(0) { $0 + $1.reclaimableBytes }
        Logger.shared.info("Tidy: applied recommended removal to \(done.count) of \(eligible.count) group(s), reclaimed \(Self.formatBytes(bytes))")
        if currentError == nil {
            if done.count == batch.count, batch.count == eligible.count {
                banner = .success("Reclaimed \(Self.formatBytes(bytes)) from \(done.count) group\(done.count == 1 ? "" : "s") — press ⌘Z to undo")
            } else {
                // Partial (cancelled mid-batch, declined fallback, or skipped missing keepers):
                // claim only what landed; the rest stay listed.
                banner = .warning("Reclaimed \(Self.formatBytes(bytes)) from \(done.count) of \(eligible.count) groups — the rest stay listed. Press ⌘Z to undo")
            }
        }
    }

    // MARK: Overlapping merge

    /// Additively merges an overlapping group's redundant copies into its keeper: copies every
    /// file the keeper doesn't already have into it, then moves the now-fully-contained copy to
    /// the Trash. Safe by construction — a file is skipped only if its content is *provably*
    /// already in the keeper (a known, matching hash); anything unhashable is copied, so trashing
    /// the folded copy can never lose data. Reversible with Undo.
    @discardableResult
    public func mergeDuplicateGroup(_ group: DuplicateGroup) async -> Bool {
        guard case .overlapping = group.matchType else { return false }
        // Re-entry guard, independent of any UI disabling: a merge runs for minutes, and a second
        // call for the same group would re-plan against the half-merged keeper — every unique
        // file already folded in now "exists" at its destination, so the second pass would mint
        // " 2" junk copies of all of them. Claimed synchronously on the main actor BEFORE the
        // first suspension point, so two rapid clicks can never both pass.
        guard !mergingGroupIDs.contains(group.id) else {
            Logger.shared.info("Tidy merge: “\(group.name)” is already merging — duplicate request dropped")
            return false
        }
        mergingGroupIDs.insert(group.id)
        defer { mergingGroupIDs.remove(group.id) }
        // Verify All's exclusion guard, mirrored in the write direction (same rationale as
        // syncFile's): the merge copies into the keeper while Verify All may be hashing it.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before merging duplicates")
            return false
        }
        // A vanished keeper must refuse, not silently recreate itself from the copies being folded.
        guard keeperStillExists(group) else {
            banner = .warning("“\(group.keeper.name)” is no longer at its scanned location — rescan before merging.")
            return false
        }
        // Progress for the minutes-long run, published the way Verify All does it: an NSProgress
        // on `activeProgress` drives the app-wide ProgressDialog overlay (bar, per-file line,
        // Cancel). One unit per redundant copy; the current file name rides along as the
        // additional description from inside the copy loop.
        let progress = Progress(totalUnitCount: Int64(group.redundantCopies.count))
        progress.localizedDescription = "Merging “\(group.name)”"
        progress.isCancellable = true
        activeProgress = progress
        defer {
            // Clear only if still ours: a queued operation may have published its own by now.
            if activeProgress === progress { activeProgress = nil }
        }
        let keeperPath = group.keeper.path
        let keeperURL = URL(fileURLWithPath: keeperPath)
        let fm = fileManager
        var totalFolded = 0
        var allTrashed = true
        var cancelled = false
        // Copies refused at the trash step because their contents changed after the plan was
        // snapshotted — surfaced with a drift-specific warning below, like the keeper drift.
        var driftedCopies: [String] = []

        for redundant in group.redundantCopies {
            // Honor the dialog's Cancel between copies: whatever already landed is undoable and
            // a retry skips it; the remaining copies stay listed. Nothing is ever trashed for a
            // copy whose fold didn't complete.
            if progress.isCancelled {
                cancelled = true
                allTrashed = false
                break
            }
            progress.localizedAdditionalDescription = redundant.name
            defer { progress.completedUnitCount += 1 }
            // Already gone (e.g. from a prior partial merge/retry) — treat as done, don't fail.
            guard fm.fileExists(atPath: redundant.path) else { continue }
            // Defensive: never merge a copy that contains, or is contained by, the keeper. The
            // engine no longer emits such nested pairs, but folding into self then trashing would
            // delete out of the keeper. Skip it and keep the group.
            if Self.pathsOverlap(redundant.path, keeperPath) {
                allTrashed = false
                continue
            }

            let rURL = URL(fileURLWithPath: redundant.path)
            let plan = await Self.planMerge(from: rURL, into: keeperURL, fileManager: fm)
            // Merge targets all land under the keeper — collapse reserved-key case on a
            // case-insensitive keeper volume (same reason as the bulk sync path).
            let keeperCaseSensitive = FileSyncManager.volumeSupportsCaseSensitiveNames(for: keeperURL)
            let logger = Logger.shared   // captured on the main actor; its methods are nonisolated
            let progressRef = ProgressRef(progress)   // NSProgress is thread-safe; the ref is the Sendable wrapper

            let outcome: (copied: [CopyItemState], failed: Bool, cancelled: Bool) = await enqueueFileOperation {
                func reservedKey(_ path: String) -> String { keeperCaseSensitive ? path : path.lowercased() }
                var copied: [CopyItemState] = []
                var failed = false
                var cancelledMidCopy = false
                var reserved = Set<String>()
                for step in plan.steps {
                    // Per-file progress + Cancel between files: already-copied files stay
                    // (registered for undo below); the copy whose fold is incomplete is
                    // never trashed.
                    if progressRef.progress.isCancelled {
                        cancelledMidCopy = true
                        break
                    }
                    progressRef.progress.localizedAdditionalDescription = step.src.lastPathComponent
                    do {
                        try FileSyncManager.ensureParentDirectoryExists(for: step.dst, fileManager: fm)
                        var dst = step.dst
                        if fm.fileExists(atPath: dst.path) || reserved.contains(reservedKey(dst.path)) {
                            dst = FileSyncManager.generateUniqueURL(for: step.dst, fileManager: fm, reserved: reserved, caseSensitiveVolume: keeperCaseSensitive)
                        }
                        reserved.insert(reservedKey(dst.path))
                        let overwritten = try FileSyncManager.safeCopyItem(at: step.src, to: dst, fileManager: fm)
                        copied.append((source: step.src, destination: dst, overwritten: overwritten))
                    } catch {
                        // Record the underlying cause: the user-facing alert only says "some files
                        // couldn't be merged", so without this the reason is unrecoverable.
                        logger.warning("Tidy merge: copying “\(step.src.lastPathComponent)” into \(keeperURL.lastPathComponent) failed: \(error.localizedDescription)")
                        failed = true
                        break
                    }
                }
                return (copied, failed, cancelledMidCopy)
            }

            if !outcome.copied.isEmpty {
                registerCopyUndo(items: outcome.copied, actionName: "Merge \(group.name)", fileManager: fm)
                totalFolded += outcome.copied.count
            }
            if outcome.cancelled {
                // Fold incomplete — this copy must not be trashed; stop here, keep the group.
                cancelled = true
                allTrashed = false
                break
            }
            if outcome.failed {
                // Leave the redundant copy in place so nothing is trashed after a partial copy;
                // the group stays so the user can retry (already-copied files are skipped next time).
                present(.syncFailed(item: redundant.name, path: redundant.path,
                                    reason: "Some files couldn't be merged; the folder was left in place."))
                return false
            }

            // The plan is a point-in-time snapshot, and minutes of hashing/copying may have passed.
            // Re-walk the redundant copy IMMEDIATELY before trashing: anything new or size-changed
            // since plan time is content the merge neither verified nor copied, and trashing the
            // folder would destroy it. Same refusal shape as the keeper drift check — log, leave
            // the copy in place, keep the group listed for a re-scan/retry.
            let currentSnapshot = Self.fileSnapshotsByRelativePath(
                await Self.buildTree(url: rURL, sortOption: .name, fileManager: fm, maxDepth: nil))
            if Self.mergeSourceDrifted(planned: plan.sourceSnapshot, current: currentSnapshot) {
                Logger.shared.warning("Tidy merge: “\(redundant.name)” changed after the merge was planned — left in place, not trashed")
                driftedCopies.append(redundant.name)
                allTrashed = false
                continue
            }

            // Every file in the redundant copy is now present in the keeper → safe to trash it.
            let removed = await deleteItems(at: [redundant.path], fileManager: fm)
            if removed == 0 { allTrashed = false }   // trash declined/failed — don't claim the group done
        }

        // Only drop the group and claim success when every redundant copy actually left the disk
        // and no error surfaced — otherwise keep the group (retry skips what already landed) and
        // never show a false "Merged" banner over an orphaned folder.
        guard allTrashed, currentError == nil else {
            if cancelled {
                banner = .warning("Merge of “\(group.name)” cancelled — unfinished copies were left in place. Everything already merged is undoable with ⌘Z; the group stays listed and a retry skips what landed.")
            } else if let drifted = driftedCopies.first {
                banner = .warning("“\(drifted)” changed since it was scanned — it was left in place. Rescan before merging.")
            } else if totalFolded > 0 {
                banner = .warning("Merged part of “\(group.name)” — some copies were left in place. Review and retry.")
            }
            return false
        }
        duplicateGroups.removeAll { $0.id == group.id }
        banner = .success("Merged “\(group.name)” — folded \(totalFolded) file\(totalFolded == 1 ? "" : "s") into \(group.keeper.name). Press ⌘Z to undo")
        Logger.shared.info("Tidy: merged “\(group.name)” — folded \(totalFolded) file(s) into \(group.keeper.name)")
        return true
    }

    /// Whether two paths are the same or one contains the other.
    nonisolated static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        a == b || a.isInsideDirectory(anyOf: [b]) || b.isInsideDirectory(anyOf: [a])
    }

    /// Plans the additive merge of `rURL` into `kURL`: the files under `rURL` whose content the
    /// keeper does NOT provably already have, mapped to their destination under the keeper —
    /// plus a `sourceSnapshot` of the redundant copy's full file set (relative path → size+mtime)
    /// as it stood at plan time, so the trash step can prove nothing appeared or changed since.
    /// Relative paths come from the tree walk (not string prefix math), so path canonicalization
    /// quirks — e.g. `/var` vs `/private/var` symlinks — can't mangle the destinations.
    nonisolated static func planMerge(
        from rURL: URL, into kURL: URL, fileManager fm: FileManaging
    ) async -> (steps: [(src: URL, dst: URL)], sourceSnapshot: [String: MergeFileSnapshot]) {
        let kItems = flattenFilesWithRelativePaths(await buildTree(url: kURL, sortOption: .name, fileManager: fm, maxDepth: nil))
        let kHashesByPath = await hashFiles(kItems.map { $0.id }, fileManager: fm)
        // Keeper content hash keyed by RELATIVE path — so "already have it" means the keeper has
        // this exact content *at the same location*, not merely somewhere.
        var keeperHashByRel: [String: String] = [:]
        for k in kItems { if let h = kHashesByPath[k.id] { keeperHashByRel[k.rel] = h } }

        let rTree = await buildTree(url: rURL, sortOption: .name, fileManager: fm, maxDepth: nil)
        let rItems = flattenFilesWithRelativePaths(rTree)
        let rHashes = await hashFiles(rItems.map { $0.id }, fileManager: fm)

        var steps: [(src: URL, dst: URL)] = []
        for item in rItems {
            // Skip ONLY when the keeper already has this exact content at the SAME relative path —
            // a true same-location duplicate. A distinctly-named or -located file is folded in even
            // when its bytes happen to also live elsewhere in the keeper, so the merge never
            // silently drops a meaningfully-named file (a later Tidy scan can reconcile any
            // resulting byte-duplicate — losing a filename is the worse surprise).
            if let h = rHashes[item.id], keeperHashByRel[item.rel] == h { continue }
            steps.append((src: URL(fileURLWithPath: item.id), dst: kURL.appendingPathComponent(item.rel)))
        }
        return (steps, fileSnapshotsByRelativePath(rTree))
    }

    /// What the drift check knows about one file in the merge source: byte size AND modification
    /// date. Size alone let a same-length in-place rewrite of a plan-skipped file slip through the
    /// minutes-long hash/copy window — the rewrite's only copy would then be trashed. Any real
    /// write bumps the mtime (both fields come from the same tree walk, so an unchanged file
    /// always compares equal).
    struct MergeFileSnapshot: Sendable, Equatable {
        var size: Int
        var modificationDate: Date?
    }

    /// Flattens a walked tree into relative path → (size, mtime) for the drift check around a
    /// merge's trash step. Mirrors ``flattenFilesWithRelativePaths(_:prefix:)``'s traversal.
    nonisolated static func fileSnapshotsByRelativePath(
        _ nodes: [FileNode], prefix: String = ""
    ) -> [String: MergeFileSnapshot] {
        var out: [String: MergeFileSnapshot] = [:]
        for n in nodes {
            let rel = prefix.isEmpty ? n.name : prefix + "/" + n.name
            if n.isDirectory {
                out.merge(fileSnapshotsByRelativePath(n.children ?? [], prefix: rel)) { a, _ in a }
            } else {
                out[rel] = MergeFileSnapshot(size: n.fileSize ?? 0, modificationDate: n.modificationDate)
            }
        }
        return out
    }

    /// Whether the merge's redundant copy drifted between plan time and trash time: any file that
    /// is NEW (a relative path the snapshot never saw), CHANGED size, or CHANGED mtime holds
    /// content the plan neither verified nor copied — trashing the folder would destroy it.
    /// Files that merely disappeared are fine: everything that remains was covered by the plan.
    nonisolated static func mergeSourceDrifted(planned: [String: MergeFileSnapshot],
                                               current: [String: MergeFileSnapshot]) -> Bool {
        current.contains { rel, snapshot in planned[rel] != snapshot }
    }

    /// Flattens a walked tree into (relative path, absolute path) leaf pairs, accumulating the
    /// relative path from node names during the walk.
    nonisolated static func flattenFilesWithRelativePaths(
        _ nodes: [FileNode], prefix: String = ""
    ) -> [(rel: String, id: String)] {
        var out: [(rel: String, id: String)] = []
        for n in nodes {
            let rel = prefix.isEmpty ? n.name : prefix + "/" + n.name
            if n.isDirectory {
                out.append(contentsOf: flattenFilesWithRelativePaths(n.children ?? [], prefix: rel))
            } else {
                out.append((rel: rel, id: n.id))
            }
        }
        return out
    }

    /// Removes a group from the list without touching disk (in-memory only).
    public func dismissDuplicateGroup(_ group: DuplicateGroup) {
        duplicateGroups.removeAll { $0.id == group.id }
    }

    /// Drops a single resolved copy — one trashed out-of-band, e.g. from the Compare duplicate
    /// review — from its group without a rescan: removes the copy and recomputes the group's
    /// figures, or removes the whole group when only the keeper is left. Matched by absolute path;
    /// a no-op if the path isn't in any current group.
    public func removeResolvedDuplicateCopy(atPath path: String) {
        guard let idx = duplicateGroups.firstIndex(where: { $0.copies.contains { $0.id == path } }) else { return }
        if let updated = duplicateGroups[idx].removingRedundantCopy(atPath: path) {
            duplicateGroups[idx] = updated
        } else {
            duplicateGroups.remove(at: idx)
        }
    }

    /// Chooses a different keeper for a group (identical & versions only). Updates fates/reclaim.
    public func setKeeper(for groupID: DuplicateGroup.ID, to copyID: String) {
        guard let idx = duplicateGroups.firstIndex(where: { $0.id == groupID }) else { return }
        duplicateGroups[idx] = duplicateGroups[idx].choosingKeeper(copyID)
    }

    // MARK: Helpers

    /// Recursively collects leaf file nodes from a walked tree.
    nonisolated static func flattenFiles(_ nodes: [FileNode]) -> [FileNode] {
        var out: [FileNode] = []
        for n in nodes {
            if n.isDirectory {
                out.append(contentsOf: flattenFiles(n.children ?? []))
            } else {
                out.append(n)
            }
        }
        return out
    }

    /// The hashes plus why the rest were skipped — what the duplicate scan needs to report that
    /// some candidates were never content-verified (identical copies among them go undetected).
    struct HashBatchOutcome: Sendable {
        var hashes: [String: String] = [:]
        var skippedTooLarge = 0
        var skippedCloudOnly = 0
    }

    /// Hashes files with bounded concurrency, returning path → SHA-256 hex (missing when a file
    /// can't be hashed — too large, unreadable). Off-main via ``FileContentVerifier``.
    nonisolated static func hashFiles(
        _ paths: [String],
        fileManager: FileManaging,
        maxConcurrent: Int = 6,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async -> [String: String] {
        await hashFilesCounting(paths, fileManager: fileManager, maxConcurrent: maxConcurrent,
                                onProgress: onProgress).hashes
    }

    /// ``hashFiles`` plus per-reason skip counts. `maxBytesToHash` and `isCloudOnly` are
    /// injectable for tests (a real dataless file can't be fabricated — the flag is provider-set).
    nonisolated static func hashFilesCounting(
        _ paths: [String],
        fileManager: FileManaging,
        maxConcurrent: Int = 6,
        maxBytesToHash: Int = FileContentVerifier.maxBytesToHash,
        isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) },
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async -> HashBatchOutcome {
        guard !paths.isEmpty else { return HashBatchOutcome() }
        var result = HashBatchOutcome()
        result.hashes.reserveCapacity(paths.count)
        var next = 0
        var completed = 0
        await withTaskGroup(of: (String, FileContentVerifier.HashOutcome).self) { group in
            func schedule(_ path: String) {
                group.addTask {
                    (path, await FileContentVerifier.hashOutcome(filePath: path, fileManager: fileManager,
                                                                 maxBytes: maxBytesToHash,
                                                                 isCloudOnly: isCloudOnly))
                }
            }
            let initial = min(maxConcurrent, paths.count)
            while next < initial { schedule(paths[next]); next += 1 }
            for await (path, outcome) in group {
                switch outcome {
                case .hashed(let hash): result.hashes[path] = hash
                case .skippedTooLarge: result.skippedTooLarge += 1
                case .skippedCloudOnly: result.skippedCloudOnly += 1
                case .unverifiable: break
                }
                completed += 1
                onProgress?(completed)
                // Cancellation stops scheduling new work; already-detached hashes drain out.
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if next < paths.count { schedule(paths[next]); next += 1 }
            }
        }
        return result
    }

    public nonisolated static func formatBytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(max(0, n)))
    }
}
