import Foundation

/// Tidy — the in-provider duplicate finder. Reuses the existing tree walk and content hasher to
/// gather input for the pure ``DuplicateFinder``, and routes removals through ``deleteItems`` so
/// they land in the Trash with the same one-step Undo as every other destructive action.
extension FileSyncManager {

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
        let previous = duplicateScanTask
        previous?.cancel()
        duplicateScanTask = Task { [weak self] in
            // Let the cancelled scan fully unwind (its defer clears isFindingDuplicates) before the
            // new one runs, so findDuplicates' re-entrancy guard doesn't silently drop the restart.
            _ = await previous?.value
            await self?.findDuplicates(root: root, options: options)
        }
    }

    /// Cancels a running Find Duplicates scan; results are left as they were.
    public func cancelFindDuplicates() {
        duplicateScanTask?.cancel()
    }

    public func findDuplicates(
        root: URL,
        options: DuplicateFinderOptions = .init(),
        fileManager fm: FileManaging? = nil
    ) async {
        guard !isFindingDuplicates else { return }
        let fileManager = fm ?? self.fileManager
        isFindingDuplicates = true
        duplicateScanStatus = "Scanning \(root.lastPathComponent)…"
        duplicateScanProgress = nil   // walk phase — total unknown until candidates are counted
        duplicateScanEpoch += 1
        let epoch = duplicateScanEpoch
        // hasFoundDuplicates is set only on completion (below), so a cancelled scan leaves the
        // prior state intact rather than flashing an empty "no duplicates".
        defer {
            // Bump the epoch so hashing-progress hops still in the main-actor queue can't
            // republish status/numbers after this scan has ended (or into the next scan).
            duplicateScanEpoch += 1
            isFindingDuplicates = false
            duplicateScanStatus = nil
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
        duplicateScanStatus = "Hashing \(total) candidate\(total == 1 ? "" : "s")…"
        duplicateScanProgress = total > 0 ? (completed: 0, total: total) : nil
        let realHashes = await Self.hashFiles(candidatePaths, fileManager: fileManager) { [weak self] done in
            if done % 50 == 0 || done == total {
                Task { @MainActor in
                    guard let self, self.duplicateScanEpoch == epoch else { return }
                    self.duplicateScanStatus = "Hashing \(done) of \(total)…"
                    self.duplicateScanProgress = (completed: done, total: total)
                }
            }
        }
        if Task.isCancelled { return }
        // Deterministic terminal publish: the done == total update above is an unstructured
        // main-actor Task that can lose the race against this resumption — the defer's epoch
        // bump would then drop it, ending the bar at the last 50-multiple instead of full.
        // We're back on the main actor with the epoch still current (and not cancelled, per
        // the guard above), so pin the bar to 100% before the grouping pass below.
        if total > 0 {
            duplicateScanStatus = "Hashing \(total) of \(total)…"
            duplicateScanProgress = (completed: total, total: total)
        }

        var fileHashes: [String: String] = [:]
        fileHashes.reserveCapacity(allFiles.count)
        for f in allFiles {
            fileHashes[f.id] = realHashes[f.id] ?? ("u:" + f.id)
        }

        // 3. Group (pure), then drop anything the user has kept separate.
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: fileHashes, options: options)
        if Task.isCancelled { return }
        let ignored = ignoredDuplicateKeys
        self.duplicateGroups = groups.filter { !ignored.contains($0.ignoreKey) }
        // Published with the results, not at scan start: the root labels what's on screen, and a
        // cancelled rescan of a different folder must not relabel the previous results.
        duplicateScanRoot = root.path
        hasFoundDuplicates = true
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
        hasFoundDuplicates = false
    }

    // MARK: Resolve

    /// Whether a group's keeper is still where the scan saw it. Groups are point-in-time
    /// snapshots: if the keeper was deleted, renamed, or moved externally between scan and click,
    /// trashing the "redundant" copies would trash the *last* copies — the one invariant Tidy
    /// promises never to break. Re-verified at resolve time, not just scan time.
    private func keeperStillExists(_ group: DuplicateGroup) -> Bool {
        fileManager.fileExists(atPath: group.keeper.path)
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
        let keeperPath = group.keeper.path
        let keeperURL = URL(fileURLWithPath: keeperPath)
        let fm = fileManager
        var totalFolded = 0
        var allTrashed = true

        for redundant in group.redundantCopies {
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

            let outcome: (copied: [CopyItemState], failed: Bool) = await enqueueFileOperation {
                var copied: [CopyItemState] = []
                var failed = false
                var reserved = Set<String>()
                for step in plan {
                    do {
                        try FileSyncManager.ensureParentDirectoryExists(for: step.dst, fileManager: fm)
                        var dst = step.dst
                        if fm.fileExists(atPath: dst.path) || reserved.contains(dst.path) {
                            dst = FileSyncManager.generateUniqueURL(for: step.dst, fileManager: fm, reserved: reserved)
                        }
                        reserved.insert(dst.path)
                        let overwritten = try FileSyncManager.safeCopyItem(at: step.src, to: dst, fileManager: fm)
                        copied.append((source: step.src, destination: dst, overwritten: overwritten))
                    } catch {
                        failed = true
                        break
                    }
                }
                return (copied, failed)
            }

            if !outcome.copied.isEmpty {
                registerCopyUndo(items: outcome.copied, actionName: "Merge \(group.name)", fileManager: fm)
                totalFolded += outcome.copied.count
            }
            if outcome.failed {
                // Leave the redundant copy in place so nothing is trashed after a partial copy;
                // the group stays so the user can retry (already-copied files are skipped next time).
                present(.syncFailed(item: redundant.name, path: redundant.path,
                                    reason: "Some files couldn't be merged; the folder was left in place."))
                return false
            }

            // Every file in the redundant copy is now present in the keeper → safe to trash it.
            let removed = await deleteItems(at: [redundant.path], fileManager: fm)
            if removed == 0 { allTrashed = false }   // trash declined/failed — don't claim the group done
        }

        // Only drop the group and claim success when every redundant copy actually left the disk
        // and no error surfaced — otherwise keep the group (retry skips what already landed) and
        // never show a false "Merged" banner over an orphaned folder.
        guard allTrashed, currentError == nil else {
            if totalFolded > 0 {
                banner = .warning("Merged part of “\(group.name)” — some copies were left in place. Review and retry.")
            }
            return false
        }
        duplicateGroups.removeAll { $0.id == group.id }
        banner = .success("Merged “\(group.name)” — folded \(totalFolded) file\(totalFolded == 1 ? "" : "s") into \(group.keeper.name). Press ⌘Z to undo")
        return true
    }

    /// Whether two paths are the same or one contains the other.
    nonisolated static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        a == b || a.isInsideDirectory(anyOf: [b]) || b.isInsideDirectory(anyOf: [a])
    }

    /// Plans the additive merge of `rURL` into `kURL`: the files under `rURL` whose content the
    /// keeper does NOT provably already have, mapped to their destination under the keeper.
    /// Relative paths come from the tree walk (not string prefix math), so path canonicalization
    /// quirks — e.g. `/var` vs `/private/var` symlinks — can't mangle the destinations.
    nonisolated static func planMerge(
        from rURL: URL, into kURL: URL, fileManager fm: FileManaging
    ) async -> [(src: URL, dst: URL)] {
        let kFiles = flattenFiles(await buildTree(url: kURL, sortOption: .name, fileManager: fm, maxDepth: nil))
        let keeperHashes = Set(await hashFiles(kFiles.map { $0.id }, fileManager: fm).values)

        let rItems = flattenFilesWithRelativePaths(await buildTree(url: rURL, sortOption: .name, fileManager: fm, maxDepth: nil))
        let rHashes = await hashFiles(rItems.map { $0.id }, fileManager: fm)

        var plan: [(src: URL, dst: URL)] = []
        for item in rItems {
            // Skip ONLY when we can prove the keeper already has this content.
            if let h = rHashes[item.id], keeperHashes.contains(h) { continue }
            plan.append((src: URL(fileURLWithPath: item.id), dst: kURL.appendingPathComponent(item.rel)))
        }
        return plan
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

    /// Hashes files with bounded concurrency, returning path → SHA-256 hex (missing when a file
    /// can't be hashed — too large, unreadable). Off-main via ``FileContentVerifier``.
    nonisolated static func hashFiles(
        _ paths: [String],
        fileManager: FileManaging,
        maxConcurrent: Int = 6,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        var result: [String: String] = [:]
        result.reserveCapacity(paths.count)
        var next = 0
        var completed = 0
        await withTaskGroup(of: (String, String?).self) { group in
            func schedule(_ path: String) {
                group.addTask {
                    (path, await FileContentVerifier.sha256Hex(filePath: path, fileManager: fileManager))
                }
            }
            let initial = min(maxConcurrent, paths.count)
            while next < initial { schedule(paths[next]); next += 1 }
            for await (path, hash) in group {
                if let hash { result[path] = hash }
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
