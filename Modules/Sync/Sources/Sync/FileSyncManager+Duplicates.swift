import Events
import Foundation

/// Duplicates — the in-provider duplicate finder. Reuses the existing tree walk and content hasher to
/// gather input for the pure ``DuplicateFinder``, and routes removals through ``deleteItems`` so
/// they land in the Trash with the same one-step Undo as every other destructive action.
extension FileSyncManager {

    /// Files the most recent duplicate scan had to skip during content hashing — and therefore
    /// could not prove identical to anything. Without this figure, two identical >100 MB files
    /// (or cloud-only placeholders) are simply invisible to the scan with zero indication. Labels the
    /// current `duplicateGroups` like `duplicateScanRoot` does: published with the results
    /// (`duplicateScanSkips` in FileSyncManager.swift), reset by `clearDuplicates`.
    public struct DuplicateScanSkips: Sendable, Equatable {
        /// Candidates skipped because they exceed the hashing size cap (`maxBytesToHash`).
        public var tooLarge: Int
        /// Candidates skipped because they are cloud-only (dataless) placeholders that hashing
        /// would force-download.
        public var cloudOnly: Int
        /// Files excluded because they are hard links (link count > 1): a directory entry is
        /// not the bytes, so no single-path duplicate offer about one is truthful. Counted so
        /// a Time-Machine-shaped tree doesn't just quietly report fewer duplicates.
        public var multiLink: Int
        /// Documents the same-text pass could not judge: an image-only scan, a password-locked
        /// PDF, or one whose page 1 holds fewer than ``ContentFingerprint/minimumTokens`` tokens.
        ///
        /// **Counted for exactly the reason this feature exists.** The roadmap's complaint about
        /// the re-stamped-PDF blind spot was not that it was large, it was that it was *silent* —
        /// the files hashed fine, failed to match, and no counter moved. A same-text pass that
        /// declined a thousand image-only scans without saying so would recreate that.
        public var textUnreadable: Int
        /// Files no duplicate claim of any kind could be made about. `textUnreadable` is
        /// deliberately NOT in it: those files were hashed and grouped normally, and only the
        /// weaker text claim was declined for them.
        public var total: Int { tooLarge + cloudOnly + multiLink }

        public init(tooLarge: Int = 0, cloudOnly: Int = 0, multiLink: Int = 0, textUnreadable: Int = 0) {
            self.tooLarge = tooLarge
            self.cloudOnly = cloudOnly
            self.multiLink = multiLink
            self.textUnreadable = textUnreadable
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
            // Both kinds the user must look at before acting: a name-only group because its copies
            // differ, a same-text group because its copies only provably *read* the same.
            switch g.matchType {
            case .nameOnly, .sameText: review += 1
            case .identical, .overlapping, .versions: break
            }
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

    /// Re-runs the duplicate scan on lens open, when `root` is one of the targets the user has
    /// scanned to completion before. Free of *money and of network*, always — everything it does is
    /// local — and free of time on the second run onwards, because both persisted indexes mean an
    /// unchanged file is neither re-read nor re-parsed. It is no longer free of time on the FIRST
    /// run after the same-text pass arrived: that pass reads every PDF in the tree once (measured
    /// at ~5.5 minutes for 10,569 documents) before its digests are cached. The scan is cancellable
    /// and reports progress throughout, and the pass has a Settings toggle, so the cost is visible
    /// and refusable rather than hidden — but "free by construction", which this said before, is
    /// now only true of the repeat. The questions remain consent and idempotence:
    ///
    /// - **Consent** is a remembered target matching: the user has scanned exactly this before,
    ///   so repeating it unasked offers nothing they didn't already ask for. Nothing remembered
    ///   (or no injected store) means never, and a target that is no longer a reachable directory
    ///   is declined rather than scanned into an empty result — see
    ///   ``FileSyncManager/isReachableDirectory(_:fileManager:)``.
    /// - **Idempotence** against the callers' overlapping triggers (appear, workspace change,
    ///   root change — the same trio as `restoreStorageLens`): a completed scan this session
    ///   declines via `hasFoundDuplicates`, a running one via `isFindingDuplicates`, and an
    ///   attempt that ended any other way (cancelled) via the per-target latch.
    ///
    /// Returns whether a scan was started, for tests.
    @discardableResult
    public func autoRescanDuplicatesIfEligible(root: URL,
                                               options: DuplicateFinderOptions = .init()) -> Bool {
        guard lensScanTargetIsRemembered(root.path, forKey: Self.lastDuplicatesScanRootKey),
              Self.isReachableDirectory(root.path, fileManager: fileManager),
              !isFindingDuplicates, !hasFoundDuplicates,
              duplicateAutoRescanAttempted != root.path else { return false }
        duplicateAutoRescanAttempted = root.path
        Logger.shared.info("Duplicates: auto-rescanning \(root.lastPathComponent) for duplicates (scanned before, free to repeat)")
        startFindDuplicates(root: root, options: options)
        return true
    }

    /// `maxBytesToHash` and `isCloudOnly` are injectable for tests only (a real >100 MB fixture
    /// per run would be wasteful, and a real dataless file can't be fabricated); production
    /// callers use the verifier's defaults.
    ///
    /// `cache` is the session hash cache, shared with Verify so a rescan of an unchanged tree costs
    /// no re-reads. A test that varies `maxBytesToHash` or `isCloudOnly` across scans of the SAME
    /// files must pass `nil` — see ``hashFilesCounting`` for why a hit bypasses both knobs.
    /// `textFingerprint` is the same-text pass's reader: a path in, a ``ContentFingerprint`` digest
    /// out, or nil for a document that said too little. Defaulted to the real PDFKit reader for the
    /// same reason `isCloudOnly` is defaulted to the real materialization check — production wants
    /// it and only tests want to vary it. `fingerprintCache` is its own store, separate from the
    /// content-hash one because the two hold different things under the same key shape.
    public func findDuplicates(
        root: URL,
        options: DuplicateFinderOptions = .init(),
        fileManager fm: FileManaging? = nil,
        maxBytesToHash: Int = FileContentVerifier.maxBytesToHash,
        isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) },
        cache: ContentHashCache? = .shared,
        textFingerprint: @escaping @Sendable (String) async -> String? = PDFTextExtractor.fingerprint,
        fingerprintCache: ContentHashCache? = .sharedFingerprints
    ) async {
        guard !isFindingDuplicates else { return }
        let fileManager = fm ?? self.fileManager
        // The two caches must not be the same instance. They share a key shape — (path, mtime,
        // size) — and both store a 64-hex string, so one instance holding both would let a file's
        // SHA-256 be served as its fingerprint and vice versa, silently and with nothing about the
        // value to give it away. `ContentHashCache.sharedFingerprints` exists to make that
        // unwriteable; this is what makes that claim true rather than a comment. Declining the
        // cache rather than trapping: the cost is re-reading documents, and a crash over a caching
        // mistake is the worse outcome.
        let documentCache: ContentHashCache? =
            (fingerprintCache != nil && fingerprintCache === cache) ? nil : fingerprintCache
        if documentCache == nil, fingerprintCache != nil {
            Logger.shared.warning("Duplicates: the document-fingerprint cache and the content-hash cache are the same instance — reading documents without a cache rather than letting one serve the other's digests")
        }
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
        // "Hashing 0 candidates…" read as what it was — a format string. Zero candidates is a
        // real, common state (no two files share a size), so it gets its own sentence.
        updateScan(\.duplicateScanLifecycle, epoch: epoch,
                   status: total == 0 ? "Looking for candidates…"
                                      : "Hashing \(total) candidate\(total == 1 ? "" : "s")…")
        duplicateScanProgress = total > 0 ? (completed: 0, total: total) : nil
        let hashOutcome = await Self.hashFilesCounting(
            candidatePaths, fileManager: fileManager, maxBytesToHash: maxBytesToHash,
            isCloudOnly: isCloudOnly, cache: cache
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

        // Hard-linked files (link count > 1) are dropped from grouping entirely: a directory
        // entry is not the bytes, so no single-path offer about one is truthful — whether the
        // sibling link is inside the scan or beyond it. Statted over ALL scanned files, not
        // just the size-colliding hash candidates: the versions pass admits ANY file ≥
        // minFileSize (unknown-hash members ride along in a group real hashes justify), so a
        // unique-size link skipped by a candidates-only stat rode straight into a versions
        // group and was recommended for removal. Stat-only metadata reads, off the main actor.
        // Persist what this scan hashed before the next cancellation check. Reading and hashing
        // those bytes was the expensive part of the scan and it has already happened; discarding
        // the digests because the user cancelled a moment later would mean re-reading the same
        // gigabytes next time. Cancelling abandons the GROUPING, not the measurements.
        await cache?.save()

        let linkCheckPaths = allFiles.map { $0.id }
        let multiLinkPaths = await Task.detached(priority: .userInitiated) {
            Self.multiLinkPaths(among: linkCheckPaths)
        }.value
        if Task.isCancelled { return }

        // 2b. Read the documents, for the duplicates a byte hash cannot see: a provider re-stamps
        //     each PDF on download, so the same bill fetched twice is byte-different with identical
        //     content. Every fingerprintable document is read, NOT just the size-colliding hash
        //     candidates above — measured on the real tree, restricting the pass to files that
        //     already share a size would find fewer than half the groups it finds unrestricted:
        //     119 of 251 on the replay that measured it. (Both totals are from that one pre-lane
        //     run; the shipped serial lane reports ~248. The ratio is what this argues, not the
        //     total, and re-stating 119 against a total it was not measured with would be an
        //     invented number.) The reason is that
        //     a re-stamp routinely changes the byte count too (a compressed re-save changes it by
        //     an order of magnitude). Cached by (path, mtime, size), so this is paid once.
        var textFingerprints: [String: String] = [:]
        var textUnreadable = 0
        if options.detectSameText {
            let documentPaths = allFiles.map { $0.id }
                .filter { ContentFingerprint.canFingerprint(path: $0) }
            if !documentPaths.isEmpty {
                let documentTotal = documentPaths.count
                // Named subject: on an empty pane this line is the only thing on screen, and
                // "Reading 61 documents…" answers neither where nor why.
                updateScan(\.duplicateScanLifecycle, epoch: epoch,
                           status: "Reading \(documentTotal) document\(documentTotal == 1 ? "" : "s") in “\(root.lastPathComponent)”…")
                duplicateScanProgress = (completed: 0, total: documentTotal)
                textFingerprints = await Self.fingerprintDocuments(
                    documentPaths, fileManager: fileManager, cache: documentCache,
                    extract: textFingerprint
                ) { [weak self] done in
                    // Every 50, and deliberately NOT also on the last one. The hashing phase above
                    // publishes `done == total` from here as well as terminally, which is harmless
                    // but makes the terminal publish untestable — the racing hop usually lands, so
                    // deleting the terminal publish leaves every assertion green and the bug only
                    // shows up under load. With the interval hops alone, the full value has exactly
                    // one source and a test can hold it to that.
                    if done % 50 == 0 {
                        Task { @MainActor in
                            guard let self,
                                  self.updateScan(\.duplicateScanLifecycle, epoch: epoch,
                                                  status: "Reading \(done) of \(documentTotal)…") else { return }
                            self.duplicateScanProgress = (completed: done, total: documentTotal)
                        }
                    }
                }
                textUnreadable = documentTotal - textFingerprints.count
                // Deterministic terminal publish, for the same reason the hashing phase above has
                // one: the `done == documentTotal` update is an unstructured main-actor Task that
                // can lose the race against this resumption, and the defer's epoch bump then drops
                // it — leaving the bar at the last 50-multiple. It matters MORE here than there,
                // because this is now the long phase (minutes on a cold tree), so a bar frozen at
                // "Reading 10,550 of 10,569" is what the user stares at for the rest of the scan.
                if !Task.isCancelled {
                    updateScan(\.duplicateScanLifecycle, epoch: epoch,
                               status: "Reading \(documentTotal) of \(documentTotal)…")
                    duplicateScanProgress = (completed: documentTotal, total: documentTotal)
                }
                // Same contract as the content hashes above: the reading has happened whatever the
                // grouping below decides, so a cancellation must not throw the digests away.
                await documentCache?.save()
            }
        }
        if Task.isCancelled { return }

        // 3. Group (pure), then drop anything the user has kept separate.
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: fileHashes, options: options,
                                                multiLinkPaths: multiLinkPaths,
                                                textFingerprints: textFingerprints)
        if Task.isCancelled { return }
        let ignored = ignoredDuplicateKeys
        // Set BEFORE duplicateGroups so its @Published publish is observed with a matching value
        // (like duplicateScanRoot, it labels what's on screen, not the in-flight scan).
        duplicateScanSkips = DuplicateScanSkips(tooLarge: hashOutcome.skippedTooLarge,
                                                cloudOnly: hashOutcome.skippedCloudOnly,
                                                multiLink: multiLinkPaths.count,
                                                textUnreadable: textUnreadable)
        self.duplicateGroups = groups.filter { !ignored.contains($0.ignoreKey) }
        // Published with the results, not at scan start: the root labels what's on screen, and a
        // cancelled rescan of a different folder must not relabel the previous results.
        completeScan(\.duplicateScanLifecycle, root: root)
        // Remembered only on completion, for the same reason: the auto-rescan consent is "the
        // user scanned exactly this before", and a cancelled scan is not that.
        rememberLensScanTarget(root.path, forKey: Self.lastDuplicatesScanRootKey)
        let summary = duplicateSummary
        Logger.shared.info("Duplicates: scanned \(root.lastPathComponent) — \(summary.groupCount) duplicate group(s), \(Self.formatBytes(summary.reclaimableBytes)) reclaimable")
        let skips = duplicateScanSkips
        if skips.total > 0 {
            Logger.shared.info("Duplicates: \(skips.total) file(s) outside duplicate detection — \(skips.tooLarge) over the \(Self.formatBytes(maxBytesToHash)) hash limit, \(skips.cloudOnly) cloud-only (not downloaded), \(skips.multiLink) hard-linked (trashing a link frees nothing); duplicates among them are not detected")
        }
        if skips.textUnreadable > 0 {
            Logger.shared.info("Duplicates: \(skips.textUnreadable) document(s) said too little to fingerprint (image-only scan, locked, or under \(ContentFingerprint.minimumTokens) tokens) — a re-stamped copy of one of them is not detected")
        }
    }

    /// The (path, mtime, size) triple a fingerprint is cached under — ``ContentHashKey``'s own
    /// invalidation contract, reused verbatim: any edit to a document moves its mtime, so a stale
    /// digest is bypassed rather than served. nil when the file has no readable mtime, which means
    /// this document is fingerprinted every scan rather than cached under an unstable key.
    nonisolated static func fingerprintCacheKey(forPath path: String,
                                                fileManager: FileManaging) -> ContentHashKey? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? (attributes[.size] as? Int) ?? 0
        return ContentHashKey(path: path, mtime: modified.timeIntervalSince1970, size: size)
    }

    /// Fingerprints documents with bounded concurrency, returning path → digest for the ones that
    /// produced one. Cached by the (path, mtime, size) key the content hashes use, so a rescan of
    /// an unchanged tree re-parses nothing.
    ///
    /// A cache MISS and a document that legitimately has no fingerprint look the same to the
    /// cache — both are "no entry" — so an image-only scan is re-parsed on every scan. That is a
    /// parse of a page that yields nothing, not a re-hash of gigabytes, and the alternative
    /// (persisting a negative) would have to be invalidated by the same key anyway.
    nonisolated static func fingerprintDocuments(
        _ paths: [String],
        fileManager: FileManaging,
        maxConcurrent: Int = 6,
        cache: ContentHashCache?,
        extract: @escaping @Sendable (String) async -> String?,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        var out: [String: String] = [:]
        out.reserveCapacity(paths.count)
        var next = 0
        var completed = 0
        await withTaskGroup(of: (String, String?).self) { group in
            func schedule(_ path: String) {
                group.addTask {
                    let key = fingerprintCacheKey(forPath: path, fileManager: fileManager)
                    if let key, let cached = await cache?.hash(for: key) { return (path, cached) }
                    guard let digest = await extract(path) else { return (path, nil) }
                    if let key { await cache?.store(digest, for: key) }
                    return (path, digest)
                }
            }
            let initial = min(maxConcurrent, paths.count)
            while next < initial { schedule(paths[next]); next += 1 }
            for await (path, digest) in group {
                if let digest { out[path] = digest }
                completed += 1
                onProgress?(completed)
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if next < paths.count { schedule(paths[next]); next += 1 }
            }
        }
        return out
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
    /// Every lens result that belongs to the provider being switched away from.
    ///
    /// **A list, in one place, because a list spread across call sites is what broke.** The two
    /// provider-switch handlers in `ContentView` each cleared duplicates, filing and the automation
    /// dry-run inline, under the comment "stale Tidy results must not outlive their provider" — and
    /// the risky-name finding, which became a lens result when Rename folded into Organize, was
    /// never added to either. It outlived its provider: Organize kept showing the previous
    /// account's finding, and "Fix all" would have renamed those files — under the OLD provider's
    /// ruleset, at absolute paths under the OLD provider's root — while the window said you were
    /// somewhere else. `clearFiling()` does not cover it; the name scan has its own lifecycle.
    ///
    /// Adding a lens now means adding it here, where the omission is one line from the others and
    /// `everyLensResultIsClearedByAProviderSwitch` fails until it is.
    public func clearLensResultsForProviderSwitch() {
        clearDuplicates()
        clearFiling()
        clearAutomationDryRun()
        clearNameScan()
        // The rename backlog needs no line of its own: `clearFiling()` above drops it, because it
        // is that scan's finding and shares its scope.
        // Storage was the fifth lens and the omission this doc warns about, repeated: until now
        // `clearStorageLens()` was called from tests and from nowhere else, so switching provider
        // left the previous account's report on screen — its folder chip naming a root the window
        // no longer showed. Read-only, so nothing could be misapplied from it, but it is still a
        // reading attributed to the wrong place, and restoring reports makes it more confident:
        // the report now also carries a "Scanned 2h ago" marker vouching for numbers from
        // somewhere else entirely.
        clearStorageLens()
    }

    public func clearDuplicates() {
        // Cancel any in-flight scan so it can't republish the old provider's results after the
        // switch (findDuplicates checks Task.isCancelled before it assigns duplicateGroups).
        duplicateScanTask?.cancel()
        duplicateGroups = []
        duplicateScanRoot = nil
        duplicateScanSkips = DuplicateScanSkips()
        hasFoundDuplicates = false
        // Re-arm the auto-rescan: switching back to this provider should behave like a fresh
        // launch, exactly as Storage's restore does after `clearStorageLens()`.
        duplicateAutoRescanAttempted = nil
    }

    // MARK: Resolve

    /// Whether a group's keeper is still where — and what — the scan saw. Groups are point-in-time
    /// snapshots: if the keeper was deleted, renamed, moved, or (for a byte-identical file group)
    /// overwritten in place between scan and click, trashing the "redundant" copies would trash the
    /// *last* copies of the keeper's original content — the one invariant the finder promises never to
    /// break. Re-verified at resolve time, not just scan time.
    ///
    /// For a file we also re-check the byte size against the scan snapshot: any in-place edit
    /// changes the size (and mtime), so a size mismatch means the keeper's content drifted and its
    /// copies are no longer provably identical to it. (Size is used rather than mtime because the
    /// scan reads mtime via URL resource values, which need not compare equal to a re-stat through
    /// the file-manager seam; size is exact and can never false-fail an unchanged file.) A FOLDER
    /// keeper is existence-only *here* — its stat size isn't its recursive content size — and gets
    /// its content check from `driftedFolderInGroup`, which `resolveDuplicateGroup` and the batch
    /// run alongside this and which covers the keeper as well as the removal candidates. (The
    /// merge path deliberately has neither — see `copyDriftedInPlace` — its keeper is *meant* to
    /// change, and its own trash step re-walks the source.)
    private func keeperStillExists(_ group: DuplicateGroup) -> Bool {
        let keeper = group.keeper
        guard fileManager.fileExists(atPath: keeper.path) else { return false }
        return !copyDriftedInPlace(keeper)
    }

    /// Whether `copy` is still on disk but no longer the size the scan recorded — an in-place
    /// rewrite (a re-export to the same name, a provider re-download, an edit) that leaves the path
    /// intact while replacing the bytes underneath it.
    ///
    /// One member because two callers must agree: the keeper check above and the removal-candidate
    /// check below ask the same question about opposite ends of a group, and a group is only safe
    /// to act on when *neither* end drifted. A copy that has simply *vanished* is not drift — there
    /// is nothing left to trash, and `dropFullyRemovedGroups` already accounts for it.
    ///
    /// Unstattable counts as drifted, which refuses. That is the safe direction on both ends: a
    /// path we cannot measure is one we cannot show to be redundant.
    ///
    /// **Modification date, not just size.** This used to compare size alone, on the stated
    /// grounds that the scan reads mtime via `URLResourceValues` which "need not compare equal to
    /// a re-stat through the file-manager seam". Measured on this machine, that is not so: over
    /// 200 files the two read paths agreed EXACTLY, 200 of 200. Size alone waves through every
    /// same-length rewrite — 2025 to 2026, a `sed -i` over fixed-width text — and the merge path
    /// in this same file had already rejected that reasoning ("Size alone let a same-length
    /// in-place rewrite slip through"), which is why `MergeFileSnapshot` carries both. The mtime
    /// comparison is only as fine as the volume's timestamps: FAT and some SMB mounts round to
    /// 1–2 s, so a same-length rewrite landing inside that window still compares equal there.
    ///
    /// Two further accepted residuals, distinct from the timestamp-granularity one above:
    /// **mtime-preserving writers** defeat the size+mtime gate entirely — `touch -r`, `rsync
    /// --times`, and some cloud daemons re-write bytes and then restore the original mtime, so a
    /// same-length rewrite by one of them compares equal on any volume; and **xattr/Finder-tag
    /// edits are invisible** — they move ctime, not mtime, and neither size nor mtime records
    /// them, so a copy whose only change is metadata is still trashed as redundant (which loses
    /// the tags, not the bytes). Both are size+mtime's inherent ceiling; catching them would need
    /// a content re-hash at resolve time.
    ///
    /// **Folders are checked too now, per file rather than in aggregate.** The gap was real: a
    /// folder group's entire resolve-time guarantee was once "a directory entry still exists at
    /// this path", so scanning two 3,000-file folders as identical, moving 1,200 photos out of one
    /// and pressing Move to Trash took the last intact copy of those 1,200.
    ///
    /// The first folder check compared the scan's recursive count+bytes rollup against a raw
    /// re-walk, and the "every group would refuse for the opposite reason" risk it had dismissed
    /// was exactly what shipped: the scan skips `ignoredNames` and counts a symlink as one
    /// zero-byte entry, so a `.DS_Store` — every folder ever opened in Finder — was refused
    /// forever, the offset could mask a real loss, and a same-length rewrite was invisible to
    /// count and bytes alike. The scan now records a per-file baseline
    /// (``FolderContentSnapshot``) on each folder copy, and the check re-walks with the scan's own
    /// conventions and compares (path, size, mtime) per entry — the fidelity `MergeFileSnapshot`
    /// already gave the merge path. See ``folderDriftedInPlace(_:)``.
    private func copyDriftedInPlace(_ copy: DuplicateCopy) -> Bool {
        guard fileManager.fileExists(atPath: copy.path) else { return false }
        // Directories are answered by ``folderDriftedInPlace(_:)``, and only on the paths that
        // TRASH — see `driftedFolderInGroup`. Not here, because this member is also what the merge
        // path's keeper check goes through, and a merge is *designed* to change its keeper: it
        // plans against a fresh walk of both sides and re-verifies the source immediately before
        // trashing it, so holding its destination to the scan's recorded contents would refuse a
        // merge whenever the folder gained or lost anything since — which for a folder somebody
        // uses is most of the time.
        guard !copy.isDirectory else { return false }
        guard let attrs = try? fileManager.attributesOfItem(atPath: copy.path) else { return true }
        let currentDate = attrs[.modificationDate] as? Date
        let currentSize = (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int)
        // Refuse only on a KNOWN mismatch: a real file always reports its size, so a drifted
        // copy is caught; if size is unavailable (never happens on the real FS) fall back to the
        // existence check rather than over-refuse.
        if let currentSize, currentSize != copy.size { return true }
        // Same rule for the date: compare it when both ends have one, rather than refusing every
        // group whose scan recorded no date.
        if let recorded = copy.modificationDate, let currentDate, recorded != currentDate { return true }
        return false
    }

    /// Whether a FOLDER copy still holds what the scan measured — per entry, against the
    /// ``FolderContentSnapshot`` the scan recorded on the copy, via the one shared re-walk
    /// (``folderContentsMatchScan(path:snapshot:fileManager:)``) the Compare review's gate also
    /// consults, so the two destructive doors can never drift apart in what they check.
    ///
    /// **Per entry, because the aggregate this used to compare lied in both directions.** It
    /// summed a RAW listing (ignored names counted, symlinks statted for their own bytes) against
    /// the scan's convention-bound rollup, so a folder holding a `.DS_Store` was refused as
    /// "changed since it was scanned" forever — rescanning reproduced the mismatch — while the
    /// same constant offset could exactly mask a real loss. And even a convention-true count+bytes
    /// cannot see a same-length rewrite, which the file-level check above was already fixed to
    /// catch via mtime. The snapshot compares (path, size, mtime) per file, so an extra file, a
    /// missing file, a kind change, and a same-length rewrite all read as drift.
    ///
    /// Anything that cannot be re-walked completely — and a copy carrying NO snapshot — counts as
    /// drifted, which refuses: a partial walk cannot prove a folder is still what it was. That is
    /// the same direction the file check takes for an unstattable path, and the safe one on both
    /// ends of a group. A nil snapshot is not only a hand-built copy's state: the scan records nil
    /// on a folder whose subtree held an unexplored or unreadable descendant, so the callers word
    /// that refusal as "couldn't be fully checked" rather than claiming a change nobody measured —
    /// a rescan of the same unreadable tree records nil again.
    ///
    /// The cost is one recursive walk per folder copy, at the moment of a destructive click — the
    /// merge path has always re-walked here for the same reason, and the alternative is trashing
    /// the last copy of 1,200 photos to save it.
    private func folderDriftedInPlace(_ copy: DuplicateCopy) async -> Bool {
        !(await Self.folderContentsMatchScan(path: copy.path, snapshot: copy.contentSnapshot,
                                             fileManager: fileManager))
    }

    /// Re-walks `path` and answers what the scan would see there now, with the scan's OWN
    /// traversal conventions: the same tree walk (`buildTree`, off the main actor), the same
    /// ignored names skipped, the same symlink handling. Nil when the walk could not cover the
    /// whole subtree — a partial walk is not a baseline and not a verdict.
    ///
    /// Public alongside ``folderContentsMatchScan(path:snapshot:fileManager:)`` so the app target
    /// can both build and compare snapshots; the engine's own baselines are recorded by the scan.
    public nonisolated static func folderContentSnapshot(
        ofPath path: String, ignoredNames: Set<String>, fileManager: FileManaging
    ) async -> FolderContentSnapshot? {
        let tree = await buildTree(url: URL(fileURLWithPath: path), sortOption: .name,
                                   fileManager: fileManager, maxDepth: nil)
        return FolderContentSnapshot(walkedChildren: tree, ignoredNames: ignoredNames)
    }

    /// **The one folder drift gate**, shared by every path that destroys a folder copy over a
    /// scan-time claim: the engine's per-group and batch resolves (via `folderDriftedInPlace`)
    /// and the Compare review's "Trash right copy" (via `DuplicateReviewCoordinator`). Re-walks
    /// `path` with the conventions `snapshot` was recorded under and compares per entry; any
    /// walk failure, unreadable descendant, extra entry, missing entry, kind change, or
    /// size/mtime mismatch answers false — and so does a nil `snapshot`, because a copy without a
    /// baseline cannot be proven unchanged. False refuses the destructive action. The two false
    /// cases are worded apart by the callers: a real mismatch is "changed since it was scanned"
    /// and a rescan records a fresh baseline, while a nil snapshot means the scan itself could not
    /// fully read the subtree — nothing is known to have changed, and a rescan of the same
    /// unreadable tree records nil again.
    public nonisolated static func folderContentsMatchScan(
        path: String, snapshot: FolderContentSnapshot?, fileManager: FileManaging
    ) async -> Bool {
        guard let snapshot else { return false }
        guard let current = await folderContentSnapshot(ofPath: path,
                                                        ignoredNames: snapshot.ignoredNames,
                                                        fileManager: fileManager) else { return false }
        return current.entries == snapshot.entries
    }

    /// The first folder in `group` — keeper or removal candidate — whose contents no longer match
    /// what the scan measured, or nil when none has drifted.
    ///
    /// **Both ends, and only on the paths that trash.** The keeper is the copy being kept, so its
    /// loss is what makes a "redundant" copy the last one; the candidates are the copies being
    /// destroyed, so their gain is content nothing else has. The merge path deliberately does not
    /// come here — see `copyDriftedInPlace`.
    ///
    /// **The keeper is re-walked LAST.** Each walk here takes real time (~0.7 s per 40k-node
    /// folder), and a verdict ages from the moment it is formed: with the keeper walked first, a
    /// group with several candidate folders had the keeper's "unchanged" verdict staled by every
    /// candidate walk after it — an edit landing in the keeper during those walks was never seen,
    /// and the copies were trashed against a keeper that no longer held the scanned content.
    /// Walking the copy being KEPT last keeps its verdict the freshest one at the moment the
    /// caller acts.
    private func driftedFolderInGroup(_ group: DuplicateGroup) async -> DuplicateCopy? {
        let removalPaths = Set(group.recommendedRemovalPaths)
        let considered = group.copies.filter {
            $0.isDirectory && ($0.path == group.keeper.path || removalPaths.contains($0.path))
        }
        // Candidates first, keeper last — deliberately not `sorted`, whose stability Swift does
        // not guarantee; the candidates keep their group order.
        let ordered = considered.filter { $0.path != group.keeper.path }
                    + considered.filter { $0.path == group.keeper.path }
        // A copy that has simply VANISHED is not drift — there is nothing left to trash, and
        // `dropFullyRemovedGroups` accounts for it. Same carve-out the file rule makes.
        for copy in ordered where fileManager.fileExists(atPath: copy.path) {
            if await folderDriftedInPlace(copy) { return copy }
        }
        return nil
    }

    /// The copies this group would TRASH that no longer hold the bytes the scan grouped.
    ///
    /// The keeper check alone is half a guarantee, and the dangerous half is the other one: the
    /// keeper is the file being *kept*, while these are the files being *destroyed*. A group is a
    /// point-in-time snapshot, the results outlive the scan for the whole session, and one of these
    /// paths being rewritten in place between scan and click means the copy is no longer a copy —
    /// trashing it destroys the only instance of its new content, under a banner calling it
    /// redundant. On a volume with no Trash `deleteItems` escalates to a *permanent* delete, which
    /// the user confirms believing the app verified the file was a duplicate.
    ///
    /// Same refusal shape the merge path has always had (`mergeSourceDrifted`, which re-walks the
    /// redundant copy immediately before trashing it): if it changed, leave it alone and say so.
    private func driftedRemovalCandidates(_ group: DuplicateGroup) -> [DuplicateCopy] {
        let removalPaths = Set(group.recommendedRemovalPaths)
        return group.copies.filter { removalPaths.contains($0.path) && copyDriftedInPlace($0) }
    }

    /// Drops every group whose recommended copies are all off the disk — trashed just now,
    /// trashed via a pruned ancestor, or already gone externally — keeping partially or wholly
    /// failed groups visible for a retry. Returns the resolved groups. The disk is the ground
    /// truth here: a mid-batch cancel or declined permanent-delete leaves real files behind,
    /// and those groups must stay listed however the delete call accounted for them.
    private func dropFullyRemovedGroups(from groups: [DuplicateGroup]) -> [DuplicateGroup] {
        let done = groups.filter { group in
            // A group with nothing to remove is not resolved — `allSatisfy` on an empty list is
            // vacuously true, which would drop it from the list as though its copies had been
            // trashed AND credit its bytes to the reclaimed total. Reachable: re-aiming the keeper
            // of a folder-protected group leaves every removal candidate protected, so
            // `recommendedRemovalPaths` is empty while the copies are all still on disk.
            let paths = group.recommendedRemovalPaths
            return !paths.isEmpty && paths.allSatisfy { !fileManager.fileExists(atPath: $0) }
        }
        let doneIDs = Set(done.map { $0.id })
        duplicateGroups.removeAll { doneIDs.contains($0.id) }
        return done
    }

    /// Why the last-moment removal gate refused a group. Two kinds because the two refusals make
    /// different claims — see `resolveDuplicateGroup`'s banner split.
    enum DuplicateRemovalRefusalKind: Sendable {
        /// Something in the group measurably changed after the scan.
        case drifted
        /// A folder copy carries no scan baseline, so nothing can be proven either way.
        case missingBaseline
    }

    /// Collects the removal gate's refusals across `deleteItems`' (up to two) gate invocations,
    /// for the caller's banner and accounting once the delete returns. A lock-guarded class
    /// because the gate closure is `@Sendable`; the gate body itself runs on the main actor.
    final class DuplicateRemovalRefusals: @unchecked Sendable {
        private let lock = NSLock()
        private var kinds: [DuplicateGroup.ID: DuplicateRemovalRefusalKind] = [:]
        func record(_ id: DuplicateGroup.ID, _ kind: DuplicateRemovalRefusalKind) {
            lock.lock(); kinds[id] = kind; lock.unlock()
        }
        var all: [DuplicateGroup.ID: DuplicateRemovalRefusalKind] {
            lock.lock(); defer { lock.unlock() }
            return kinds
        }
    }

    /// The duplicates flows' `removalGate` body: re-runs the full drift verdict — keeper, file
    /// candidates, folder re-walks — for every group among `paths`, and returns the paths of the
    /// groups that no longer hold. `deleteItems` calls this when the serialized operation starts
    /// (the queue wait can put a long operation between the caller's checks and the removal) and
    /// again after a confirmed permanent delete (the dialog is user-paced, and what follows it is
    /// unrecoverable) — the two windows the callers' own pre-checks cannot cover.
    ///
    /// Refusals are logged HERE, per group with the keeper and the drifted copy's path, so the
    /// single resolve and the batch report identically and a refusal is never a silent counter
    /// bump — he audits `~/sync-cloud.log`, and a copy the app promised to trash and then kept
    /// must say why.
    func refuseDriftedDuplicateRemovals(_ paths: [String], groups: [DuplicateGroup],
                                        refusals: DuplicateRemovalRefusals) async -> Set<String> {
        var refusedPaths = Set<String>()
        // Keyed by `canonicalRemovalPath`, and the answer is given back in the caller's OWN
        // spelling. The two sides of this exchange do not always hold one spelling of a path — the
        // post-confirmation invocation is fed URL round-tripped strings — and matching them raw
        // failed open in the worst possible way: the intersection came back empty, the `guard`
        // below `continue`d, and the group went unverified immediately before a permanent delete,
        // silently. See `FileSyncManager.canonicalRemovalPath`.
        var askedByKey: [String: Set<String>] = [:]
        for p in paths { askedByKey[Self.canonicalRemovalPath(p), default: []].insert(p) }
        var attributed = Set<String>()
        for group in groups {
            let groupKeys = Set(group.recommendedRemovalPaths.map(Self.canonicalRemovalPath))
            let groupPaths = Set(groupKeys.flatMap { askedByKey[$0] ?? [] })
            attributed.formUnion(groupPaths)
            guard !groupPaths.isEmpty else { continue }
            var kind: DuplicateRemovalRefusalKind?
            var culprit: DuplicateCopy?
            if !keeperStillExists(group) {
                kind = .drifted
                culprit = group.keeper
            } else if let drifted = driftedRemovalCandidates(group).first {
                kind = .drifted
                culprit = drifted
            } else if let drifted = await driftedFolderInGroup(group) {
                kind = (drifted.isDirectory && drifted.contentSnapshot == nil) ? .missingBaseline : .drifted
                culprit = drifted
            }
            guard let kind, let culprit else { continue }
            refusedPaths.formUnion(groupPaths)
            refusals.record(group.id, kind)
            switch kind {
            case .missingBaseline:
                Logger.shared.warning("Duplicates: refused to remove copies of “\(group.keeper.name)” (keeper \(group.keeper.path)) at the last check before removal — “\(culprit.name)” (\(culprit.path)) has no scan baseline, so it can't be proven unchanged")
            case .drifted:
                Logger.shared.warning("Duplicates: refused to remove copies of “\(group.keeper.name)” (keeper \(group.keeper.path)) at the last check before removal — “\(culprit.name)” (\(culprit.path)) changed after the scan")
            }
        }
        // **Fail CLOSED.** Anything left over belongs to none of the groups this gate was built
        // for, so nothing here has re-verified it — and the gate's whole job is to answer for what
        // is about to be destroyed. Unattributable used to mean unrefused, which made "the match
        // failed" and "the file was removed" the same outcome. Unreachable from the shipped
        // callers (each passes exactly its own groups' `recommendedRemovalPaths`, and
        // `deleteItems` only ever prunes that list), so this costs the ordinary path nothing and
        // is logged rather than silent, because reaching it means a caller wired the gate wrong.
        let unattributed = Set(paths).subtracting(attributed)
        if !unattributed.isEmpty {
            Logger.shared.warning("Duplicates: refused \(unattributed.count) path(s) at the last check before removal because they belong to none of the groups being verified — \(unattributed.sorted().joined(separator: ", "))")
            refusedPaths.formUnion(unattributed)
        }
        return refusedPaths
    }

    /// The gate closure `resolveDuplicateGroup` and `applyRecommendedDuplicates` hand to
    /// `deleteItems`, over the given groups. `self` is captured weakly: a manager torn down
    /// mid-delete refuses nothing rather than crashing the queue.
    private func duplicateRemovalGate(groups: [DuplicateGroup],
                                      refusals: DuplicateRemovalRefusals)
        -> @Sendable ([String]) async -> Set<String> {
        { [weak self] about in
            guard let self else { return [] }
            return await self.refuseDriftedDuplicateRemovals(about, groups: groups, refusals: refusals)
        }
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
        var driftedCopy = driftedRemovalCandidates(group).first
        if driftedCopy == nil { driftedCopy = await driftedFolderInGroup(group) }
        if let drifted = driftedCopy {
            // Two refusals, told apart: a folder that carries NO baseline was never fully read by
            // the scan, so "changed since it was scanned" would assert a change nobody measured —
            // and send the user to a rescan that reproduces nil while the subtree stays unreadable.
            // The refusal stands either way; only the claim changes. (Same honesty rule as the
            // empty-batch banner in `applyRecommendedDuplicates`: name the cause only where the
            // cause has been checked.)
            if drifted.isDirectory, drifted.contentSnapshot == nil {
                // "Unreadable or too deep", not just "wasn't readable": the scan records nil for
                // a subtree it could not COVER, and an unreadable descendant is only one way to
                // get one — the walk's hard depth cap and its symlink-cycle guard leave the same
                // mark. Naming only the readable half over-claimed.
                banner = .warning("“\(drifted.name)” couldn't be fully checked against the scan — the scan couldn't read all of it (unreadable, or nested too deep), so there's no baseline to prove it unchanged. Review it manually before removing.")
                Logger.shared.warning("Duplicates: refused to remove copies of “\(group.keeper.name)” — “\(drifted.name)” has no scan baseline (its subtree wasn't fully coverable at scan time: unreadable, too deep, or a link cycle)")
            } else {
                banner = .warning("“\(drifted.name)” changed since it was scanned — it may no longer be a copy. Rescan before removing it.")
                Logger.shared.warning("Duplicates: refused to remove copies of “\(group.keeper.name)” — “\(drifted.name)” changed after the scan")
            }
            return false
        }
        let bytes = group.reclaimableBytes
        // The checks above are the FIRST verdict, not the last: `deleteItems` routes through the
        // serialized op queue (anything queued ahead of it runs in between) and can hold a
        // permanent-delete confirmation open for as long as the user leaves it. Both windows are
        // covered by the removal gate, which re-runs the full drift verdict at the moment the
        // removal actually starts and again after a confirmed permanent delete — so the verdict
        // the trash acts on is always the freshest one. The batch and the Compare review hand
        // `deleteItems` the same shape of gate.
        let refusals = DuplicateRemovalRefusals()
        let outcome = await deleteItems(at: paths, fileManager: fileManager,
                                        removalGate: duplicateRemovalGate(groups: [group],
                                                                          refusals: refusals))
        let removed = outcome.removed
        // Refused whole at the last check: surface it with the same banner split as the
        // pre-checks above (the gate has already logged the specifics).
        if removed == 0, let kind = refusals.all[group.id] {
            banner = .warning(kind == .missingBaseline
                ? "A copy of “\(group.keeper.name)” couldn't be fully checked against the scan — review it manually before removing."
                : "A copy of “\(group.keeper.name)” changed since it was scanned — it may no longer be a copy. Rescan before removing it.")
            return false
        }
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
            // Only promise ⌘Z when the delete can actually be taken back. On a Trash-less volume
            // these files were destroyed permanently and nothing was registered, so the promise
            // sent ⌘Z at whatever was previously on top of the stack.
            banner = .success("Reclaimed \(Self.formatBytes(bytes))" + (outcome.isUndoable ? " — press ⌘Z to undo" : ""),
                              undoable: outcome.isUndoable)
        }
        Logger.shared.info("Duplicates: removed \(paths.count) redundant copy(ies) of “\(group.keeper.name)”, reclaimed \(Self.formatBytes(bytes))")
        return true
    }

    /// Every group eligible for the recommended batch, unfiltered — the honest "all of them"
    /// scope. The Duplicates lens deliberately does NOT pass this: its button scopes to whatever
    /// the search left on screen (see `applyRecommendedDuplicates`).
    public var recommendedDuplicateGroups: [DuplicateGroup] {
        duplicateGroups.filter { $0.isRecommendedForBatch }
    }

    /// Applies the recommended removal to `scope` — the byte-identical groups among it. Versions,
    /// name-only, and overlapping groups are deliberately left for a per-group look.
    ///
    /// `scope` is REQUIRED, and that is the safety property, not a style choice. This used to read
    /// `duplicateGroups` itself, which was safe only while the button that called it always meant
    /// "all of them". Now that a search can narrow the list, the button says "Trash all 3" over 3
    /// visible rows — and a method recomputing its own targets from the unfiltered `duplicateGroups`
    /// would have trashed all 8, destroying 5 items the user could not see. Making the caller name
    /// the exact collection is what makes that unwriteable rather than merely untested: the count
    /// on the button and the array iterated here are one value, passed in.
    ///
    /// The group's own eligibility and keeper checks still apply on top, so a caller that passes a
    /// name-only group can't talk this into trashing it.
    public func applyRecommendedDuplicates(_ scope: [DuplicateGroup]) async {
        let eligible = scope.filter { $0.isRecommendedForBatch }
        // The batch is TWO phases, and the shape is load-bearing:
        //
        // **Phase 1 — verify every group up front, with no undo group open and nothing deleted.**
        // Refusals are decided (and logged, per group) here, before anything destructive starts.
        //
        // **Phase 2 — ONE `deleteItems` call for every surviving path.** One call means:
        //   - ONE restore-undo registration, so ⌘Z reverses the whole batch as one step — with no
        //     `beginUndoGrouping` held open anywhere. The per-group-call version of this method
        //     held its undo group open across the folder re-walks and the delete awaits (one of
        //     which can hold a modal permanent-delete dialog); NSUndoManager grouping is
        //     manager-global, so any unrelated operation completing in one of those windows — a
        //     queued copy finishing and registering its undo — nested INSIDE the batch's group,
        //     and "undo the batch" also reversed the unrelated operation. The bulk-sync run
        //     (`FileSyncManager+BulkSync.swift`) states the same rule and closes its group before
        //     awaiting anything; here the group is gone entirely, because `deleteItems`' own
        //     single registration IS the one step.
        //   - ONE permanent-delete confirmation on a Trash-less volume, where the per-group loop
        //     raised one dialog per group.
        //   - The phase-1 verdicts are re-checked by the removal gate at the moment the removal
        //     actually starts, and again after a confirmed permanent delete — the same
        //     last-moment re-verification `resolveDuplicateGroup` and the Compare review use —
        //     so neither the queue wait nor the dialog can stale a verdict into a wrong trash.
        //     A group that drifts in either window is refused (and logged) by the gate; its
        //     copies stay on disk and it stays listed.
        //   - **The residual that shape carries, named:** the gate runs ONCE over the whole
        //     surviving list, not once per group immediately before that group's own trash, so a
        //     group late in a large batch is removed some way after the walk that cleared it. It
        //     is accepted, and `deleteItems`' `removalGate` parameter carries the reasoning —
        //     everything between the gate and the removals is machine-paced inside one serialized
        //     operation, while the two windows the gate exists for are user-unbounded.
        var survivors: [DuplicateGroup] = []          // passed phase 1 and offer paths
        var verifiedButEmpty: [DuplicateGroup] = []   // passed phase 1; offered no paths
        var refused = 0
        var refusedForMissingBaseline = 0

        for group in eligible {
            guard keeperStillExists(group) else {
                refused += 1
                Logger.shared.warning("Duplicates: batch refused copies of “\(group.keeper.name)” — the keeper (\(group.keeper.path)) is no longer what the scan saw")
                continue
            }
            if let drifted = driftedRemovalCandidates(group).first {
                refused += 1
                Logger.shared.warning("Duplicates: batch refused copies of “\(group.keeper.name)” (keeper \(group.keeper.path)) — “\(drifted.name)” (\(drifted.path)) changed after the scan")
                continue
            }
            if let drifted = await driftedFolderInGroup(group) {
                refused += 1
                // Same two-refusal split as `resolveDuplicateGroup`: a folder with a nil baseline
                // was never fully read by the scan — "couldn't be checked", not "changed".
                if drifted.isDirectory, drifted.contentSnapshot == nil {
                    refusedForMissingBaseline += 1
                    Logger.shared.warning("Duplicates: batch refused copies of “\(group.keeper.name)” (keeper \(group.keeper.path)) — “\(drifted.name)” (\(drifted.path)) has no scan baseline, so it can't be proven unchanged")
                } else {
                    Logger.shared.warning("Duplicates: batch refused copies of “\(group.keeper.name)” (keeper \(group.keeper.path)) — “\(drifted.name)” (\(drifted.path)) changed after the scan")
                }
                continue
            }
            let paths = group.recommendedRemovalPaths
            guard !paths.isEmpty else {
                verifiedButEmpty.append(group)
                continue
            }
            survivors.append(group)
        }

        guard !survivors.isEmpty else {
            // **"Nothing to remove" is not "something changed".** This said "rescan before removing
            // copies" for every empty batch, and drift is only one of the two ways to get one: a
            // group that survived the checks and still contributes no paths has every removal
            // candidate FOLDER-PROTECTED — reachable by re-aiming the keeper of a folder-protected
            // group, as `dropFullyRemovedGroups` notes. Nothing changed there, so a rescan finds
            // exactly the same thing and the advice sends the user around a loop.
            if verifiedButEmpty.isEmpty, !eligible.isEmpty {
                // Every eligible group was refused by the checks. When every refusal was a folder
                // with no baseline, "changed since they were scanned" asserts a change nobody
                // measured — and a rescan reproduces the nil baseline, not a fresh one.
                banner = .warning(refused == refusedForMissingBaseline
                    ? "These groups couldn't be fully checked against the scan — review them individually before removing copies."
                    : "These groups changed since they were scanned — rescan before removing copies.")
            } else if !verifiedButEmpty.isEmpty {
                // **Name the cause only where the cause has been checked.** Protection is the
                // reachable reason and the useful thing to say — but an empty removal list is also
                // exactly what a group carrying no redundant copies produces, and this method is
                // `public` with a `DuplicateGroup` initializer that validates nothing, so what a
                // "group" is belongs to the caller. Measured: a one-copy group, with nothing
                // protected anywhere, was told every copy in it was protected.
                let allProtected = verifiedButEmpty.allSatisfy { group in
                    !group.redundantCopies.isEmpty
                        && group.redundantCopies.allSatisfy(\.isProtectedFromRemoval)
                }
                let subject = verifiedButEmpty.count == 1 ? "this group" : "these groups"
                banner = .warning(allProtected
                    ? "Nothing to remove — every copy in \(subject) is protected."
                    : "Nothing to remove — \(subject) offered no copies to remove.")
            }
            return
        }

        // Phase 2 — one delete for the whole batch.
        //
        // Which paths were on disk immediately before the delete. A copy that had already
        // vanished externally still makes its group RESOLVE — every removal path is gone, so it
        // correctly drops off the list — but this run freed nothing for it, and its recorded
        // bytes were being added to the total the banner prints. Measured before the fix: two
        // identical pairs with one copy already removed by something else reported "Reclaimed 5 KB
        // from 2 groups — press ⌘Z to undo" for a run that trashed one 1 KB file.
        //
        // **The drift checks do not cover this, and the reason is `copyDriftedInPlace`'s first
        // line.** It opens with `guard fileManager.fileExists(...) else { return false }` — a copy
        // that is GONE is explicitly *not* drifted, so the group sails through the checks. (The
        // `else { return true }` on the attribute read below it fires only for a file that exists
        // and cannot be stat'ed, which is a different state.) Two earlier explanations of this
        // were wrong in both directions — first that the drift filter caught it, then that it did
        // not for an unrelated reason — so the guard above is the one to read.
        let allPaths = survivors.flatMap { $0.recommendedRemovalPaths }
        let presentBefore = Set(allPaths.filter { fileManager.fileExists(atPath: $0) })
        let refusals = DuplicateRemovalRefusals()
        let outcome = await deleteItems(at: allPaths, fileManager: fileManager,
                                        removalGate: duplicateRemovalGate(groups: survivors,
                                                                          refusals: refusals))
        // Fold the gate's refusals into the batch accounting — the gate logged each one already.
        let gateRefused = refusals.all
        refused += gateRefused.count
        refusedForMissingBaseline += gateRefused.values.filter { $0 == .missingBaseline }.count

        guard outcome.removed > 0 else {
            // Nothing left the disk. A decline posted `deleteItems`' own "Kept those items"
            // banner; a batch the gate refused wholesale gets the same honesty split as an
            // all-refused phase 1.
            Logger.shared.info("Duplicates: the batch removed nothing — \(refused) group(s) refused, \(outcome.declined) permanent delete(s) declined")
            if outcome.declined == 0, gateRefused.count == survivors.count, !gateRefused.isEmpty {
                banner = .warning(refused == refusedForMissingBaseline
                    ? "These groups couldn't be fully checked against the scan — review them individually before removing copies."
                    : "These groups changed since they were scanned — rescan before removing copies.")
            }
            return
        }
        let done = dropFullyRemovedGroups(from: survivors)
        // Group-level, because `reclaimableBytes` is a group-level figure the scan computed from the
        // whole removal set: a group that was PARTLY gone beforehand still credits its whole recorded
        // number, and re-deriving that per copy would change what the ordinary case reports too.
        // What this fixes is the whole-group case — a group removed entirely by something else no
        // longer contributes to a total claiming this run freed it.
        let credited = done.filter { !Set($0.recommendedRemovalPaths).isDisjoint(with: presentBefore) }
        let bytes = credited.reduce(0) { $0 + $1.reclaimableBytes }
        Logger.shared.info("Duplicates: applied recommended removal to \(done.count) of \(eligible.count) group(s), reclaimed \(Self.formatBytes(bytes))")
        // The batch stopping short of what was on disk is a state the log must account for — a
        // declined permanent delete, a cancelled dialog, a gate refusal or a failure all leave
        // copies behind that the scan said were removable.
        if outcome.removed < presentBefore.count {
            Logger.shared.info("Duplicates: the batch stopped short — removed \(outcome.removed) of \(presentBefore.count) copies (\(outcome.declined) declined, \(outcome.refusedByGate) refused at the last check); the remaining groups stay listed")
        }
        if currentError == nil {
            // `DeleteOutcome`'s own rule: any permanent delete anywhere in the batch poisons the
            // offer, because the one restore-undo can only bring back the trashed subset.
            let isUndoable = outcome.permanentlyDeleted == 0 && outcome.trashed > 0
            if done.count == eligible.count, refused == 0, outcome.declined == 0 {
                banner = .success("Reclaimed \(Self.formatBytes(bytes)) from \(done.count) group\(done.count == 1 ? "" : "s")" + (isUndoable ? " — press ⌘Z to undo" : ""),
                                  undoable: isUndoable)
            } else {
                // Partial (refused groups, a declined fallback, a cancelled dialog): claim only
                // what landed, and say what was REFUSED rather than burying it in "the rest stay
                // listed" — a group the batch skipped on purpose is information, not leftovers.
                // `undoable:` as well as the sentence. The flag is what `invalidateUndoableBanner`
                // reads to retire the offer when the undo stack moves on — without it the "Press
                // ⌘Z to undo" here outlives the step it points at, and the next operation makes it
                // an instruction to reverse the WRONG one. That a warning is normally left standing
                // is exactly why this needs saying: severity and undoability are separate, which is
                // why `.warning` takes the parameter at all.
                var clauses: [String] = []
                let drifted = refused - refusedForMissingBaseline
                if drifted > 0 {
                    clauses.append("\(drifted) group\(drifted == 1 ? "" : "s") changed since the scan and \(drifted == 1 ? "was" : "were") left alone")
                }
                if refusedForMissingBaseline > 0 {
                    clauses.append("\(refusedForMissingBaseline) group\(refusedForMissingBaseline == 1 ? "" : "s") couldn't be fully checked and \(refusedForMissingBaseline == 1 ? "was" : "were") left alone")
                }
                let refusalClause = clauses.isEmpty ? "" : " " + clauses.joined(separator: "; ") + ";"
                banner = .warning("Reclaimed \(Self.formatBytes(bytes)) from \(done.count) of \(eligible.count) groups —\(refusalClause) the rest stay listed." + (isUndoable ? " Press ⌘Z to undo" : ""),
                                  undoable: isUndoable)
            }
        }
    }

    // MARK: Overlapping merge

    /// One redundant copy a merge has finished folding into the keeper and now proposes to trash,
    /// carried from the fold to the trash so the removal gate can re-prove the claim behind it:
    /// this copy, as `planMerge` snapshotted it, is the copy whose every file the keeper now has.
    struct MergeFoldRecord: Sendable {
        let name: String
        let url: URL
        let plannedSnapshot: [String: MergeFileSnapshot]
        /// Every keeper-side path this fold's claim rests on: the destination of each file the copy
        /// loop actually wrote, PLUS the keeper file `planMerge` matched for each file it skipped as
        /// already present. Together they are "every byte this copy is being trashed for now lives
        /// in the keeper", spelled as paths the gate can stat.
        ///
        /// No default. The gate refuses on a missing destination, so an empty list is silence, and a
        /// defaulted parameter would make a new call site fail OPEN by omission — the exact shape
        /// the two `unattributed` blocks in this file exist to prevent.
        let keeperDestinations: [String]
    }

    /// Collects the merge gate's refusals across `deleteItems`' (up to two) invocations, for the
    /// banner once the delete returns. Lock-guarded because the gate closure is `@Sendable`; the
    /// body itself runs on the main actor. Names, not paths: the merge's banners name copies.
    final class MergeRemovalRefusals: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            if !names.contains(name) { names.append(name) }
        }
        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return names
        }
    }

    /// The merge's `removalGate` body: re-runs `mergeSourceDrifted` — the same verdict the loop
    /// formed before enqueuing the delete — for every fold among `paths`, plus the keeper check,
    /// and returns the paths whose claim no longer holds.
    ///
    /// The merge's trash was the one destructive duplicates path with no gate at all. Its own
    /// drift re-walk runs *before* `deleteItems` enqueues, so both windows the resolve and batch
    /// paths cover were wide open here: the serialized queue wait, and the user-paced
    /// permanent-delete confirmation with nothing re-verified before the unrecoverable branch.
    ///
    /// The keeper is checked too, and it is not redundant with the fold's own snapshot: every byte
    /// this copy is being trashed for now lives in the keeper, so a keeper that left its scanned
    /// location between the fold and the removal turns the copy back into the only instance.
    ///
    /// **That check is `keeperStillExists` AND the fold's own destinations, and the second is the
    /// load-bearing one.** `keeperStillExists` is `fileExists(keeper.path) && !copyDriftedInPlace`,
    /// and `copyDriftedInPlace` returns false unconditionally for a directory (see its own comment
    /// for why a merge keeper is MEANT to change and cannot be held to the scan baseline) — a merge
    /// keeper is always a folder, so on its own it asks only "is a directory entry still mounted
    /// here". Measured with probes: `refused=[]` for an emptied-in-place keeper AND for a
    /// removed-and-recreated one, with the redundant copy trashed in both. What the merge cannot
    /// check against the SCAN it can check against ITSELF: `keeperDestinations` is exactly what this
    /// fold put in the keeper plus what `planMerge` matched there, and a stat of each is cheap.
    ///
    /// Refusals are logged per copy, in the shape the duplicates gate logs its own — he audits
    /// `~/sync-cloud.log`, and a copy the app was about to trash and then kept must say why.
    func refuseDriftedMergeSources(_ paths: [String], group: DuplicateGroup,
                                   folds: [MergeFoldRecord],
                                   refusals: MergeRemovalRefusals) async -> Set<String> {
        // Keyed on `canonicalRemovalPath` and answered in the caller's own spelling, for the
        // reason `refuseDriftedDuplicateRemovals` states: the post-confirmation pass is fed URL
        // round-tripped paths, and an unmatched refusal fails open.
        var askedByKey: [String: Set<String>] = [:]
        for p in paths { askedByKey[Self.canonicalRemovalPath(p), default: []].insert(p) }
        var refused = Set<String>()
        var attributed = Set<String>()
        let fm = fileManager
        let keeperGone = !keeperStillExists(group)
        for fold in folds {
            let asked = askedByKey[Self.canonicalRemovalPath(fold.url.path)] ?? []
            guard !asked.isEmpty else { continue }
            attributed.formUnion(asked)
            if keeperGone {
                Logger.shared.warning("Duplicates merge: refused to trash “\(fold.name)” (\(fold.url.path)) at the last check before removal — the keeper “\(group.keeper.name)” (\(group.keeper.path)) is no longer at its scanned location, so the folded files are no longer provably anywhere else")
                refusals.record(fold.name)
                refused.formUnion(asked)
                continue
            }
            // A copy that has simply VANISHED is not drift — there is nothing left to trash, and
            // the caller reads the disk afterwards. Same carve-out the duplicates rules make.
            guard fm.fileExists(atPath: fold.url.path) else { continue }
            // Before the walk, because it is a handful of stats against a full tree read: does the
            // keeper still hold what this fold put there (and what the plan matched there)? A file
            // deleted out of the keeper in either user-paced window makes the redundant copy the
            // last instance again, and on a Trash-less volume the next step destroys it outright.
            let missing = fold.keeperDestinations.filter { !fm.fileExists(atPath: $0) }
            if let first = missing.first {
                Logger.shared.warning("Duplicates merge: refused to trash “\(fold.name)” (\(fold.url.path)) at the last check before removal — the keeper “\(group.keeper.name)” (\(group.keeper.path)) no longer holds \(missing.count) of the \(fold.keeperDestinations.count) file(s) this fold rests on (first: \(first)), so those bytes are provably nowhere else")
                refusals.record(fold.name)
                refused.formUnion(asked)
                continue
            }
            let current = Self.fileSnapshotsByRelativePath(
                await Self.buildTree(url: fold.url, sortOption: .name, fileManager: fm, maxDepth: nil))
            if Self.mergeSourceDrifted(planned: fold.plannedSnapshot, current: current) {
                Logger.shared.warning("Duplicates merge: refused to trash “\(fold.name)” (\(fold.url.path)) at the last check before removal — it changed after the merge was planned, so it holds content the fold neither verified nor copied")
                refusals.record(fold.name)
                refused.formUnion(asked)
            }
        }
        // Fail CLOSED, same rule and same reachability as the duplicates gate's: a path this gate
        // cannot attribute to a fold has been re-verified by nothing.
        let unattributed = Set(paths).subtracting(attributed)
        if !unattributed.isEmpty {
            Logger.shared.warning("Duplicates merge: refused \(unattributed.count) path(s) at the last check before removal because they belong to none of the folds being verified — \(unattributed.sorted().joined(separator: ", "))")
            refused.formUnion(unattributed)
        }
        return refused
    }

    /// The gate closure `mergeDuplicateGroup` hands to `deleteItems`. `self` is captured weakly: a
    /// manager torn down mid-delete refuses nothing rather than crashing the queue.
    private func mergeRemovalGate(group: DuplicateGroup, folds: [MergeFoldRecord],
                                  refusals: MergeRemovalRefusals)
        -> @Sendable ([String]) async -> Set<String> {
        { [weak self] about in
            guard let self else { return [] }
            return await self.refuseDriftedMergeSources(about, group: group, folds: folds, refusals: refusals)
        }
    }

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
            Logger.shared.info("Duplicates merge: “\(group.name)” is already merging — duplicate request dropped")
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
        // **The whole merge is ONE undo step, and NOTHING is registered until the awaiting is
        // over.** Both halves matter and they used to fight each other.
        //
        // The step: without a grouping a merge registered 2N steps — one `registerCopyUndo` per
        // redundant copy plus one delete group each — so "Press ⌘Z to undo" reversed only the last
        // trash and left the user guessing how many more presses the rest needed.
        //
        // The hazard the grouping brought with it: NSUndoManager grouping is manager-GLOBAL, so a
        // group held open across a suspension swallows whatever anything else registers in that
        // window — and this merge's group was open across the planning walks, the queued copy, the
        // drift re-walk and a `deleteItems` that can hold a modal permanent-delete dialog. "Undo
        // the merge" then reversed an unrelated operation too, and this is the one duplicates path
        // whose ⌘Z reversal DELETES files out of the keeper.
        //
        // Both are had by recording the run and registering it afterwards, the shape
        // `FileSyncManager+BulkSync.swift` states and `applyRecommendedDuplicates` was rebuilt
        // around:
        //
        //   * every fold's copies land in `foldedItems`, each with the identity walk that was
        //     started the moment that copy landed (`startCopyIdentityWalk`) — a batch must not use
        //     `registerCopyUndo(items:)`, whose walk begins at registration, because registration
        //     is now the END of the merge and an edit made anywhere in between would be recorded
        //     as the copy's own baseline;
        //   * the trash is ONE `deleteItems` for every fold that completed, after the loop, and it
        //     hands its restore registration back (`restoreUndoHandback`) instead of registering
        //     mid-await;
        //   * the tail then opens the group, registers the copy-undo and the restore, names it and
        //     closes it, with NO await anywhere between `beginUndoGrouping` and `endUndoGrouping`.
        //     A synchronous main-actor stretch cannot be interleaved by construction, which is
        //     what makes this a fix rather than a smaller window.
        //
        // The group is still only opened when there is something to put in it: an empty group
        // cannot be taken back (calling undo() to discard it reverses the user's PREVIOUS action
        // if the platform dropped the empty group itself), so it is never created.
        //
        // What the reshuffle costs, stated: the redundant copies now all stay on disk until the
        // loop ends, so a merge's peak disk use is the keeper plus every copy (it was the keeper
        // plus the copies not yet folded), and a run that is cancelled or fails mid-copy trashes
        // only the folds that fully completed BEFORE that point — the same set as before, just
        // trashed later. In exchange a Trash-less volume raises ONE permanent-delete confirmation
        // instead of one per copy.
        // Every copy this merge folded in, flat across the folds: they share one action name, so
        // one registration covers them all and the undo reverses them as a unit.
        var foldedItems: [PendingCopyItemState] = []
        let keeperPath = group.keeper.path
        let keeperURL = URL(fileURLWithPath: keeperPath)
        let fm = fileManager
        var totalFolded = 0
        var allTrashed = true
        var cancelled = false
        // A fold whose copy phase failed. It used to `return false` on the spot, which was only
        // safe while the earlier folds had already been trashed and registered inside the loop;
        // now the registration tail is the single exit, so the failure is carried to it.
        var copyFailed = false
        // The folds that completed AND still matched their plan: exactly what the one trash below
        // is allowed to remove, and what the removal gate re-verifies at the last moment.
        var readyToTrash: [MergeFoldRecord] = []
        // Set when any redundant copy left by permanent delete rather than the Trash — the merge
        // is then not reversible, whatever else succeeded.
        var anyPermanentlyDeleted = false
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
            // Resolved BEFORE planning: the plan's same-location and retry-skip checks compare
            // relative paths with the keeper volume's own case semantics (same reason the copy
            // loop below collapses reserved-key case on a case-insensitive keeper volume).
            let keeperCaseSensitive = FileSyncManager.volumeSupportsCaseSensitiveNames(for: keeperURL)
            let plan = await Self.planMerge(from: rURL, into: keeperURL, caseSensitiveVolume: keeperCaseSensitive, fileManager: fm)
            // Steps aimed under a keeper SYMLINK folder can't run safely — the copy would write
            // through the link (into an external folder, or into the source itself, where the
            // self-collision minted junk per retry) — and skipping them silently would let the
            // trash step destroy content that never landed. Refuse the whole copy: nothing is
            // copied or trashed, the group stays listed, and the banner names the link.
            guard plan.blockedLinkedDirs.isEmpty else {
                let dirs = plan.blockedLinkedDirs.map { "“\($0)”" }.joined(separator: ", ")
                Logger.shared.warning("Duplicates merge: “\(redundant.name)” needs files under \(dirs) in \(keeperURL.lastPathComponent), which \(plan.blockedLinkedDirs.count == 1 ? "is a symlinked folder" : "are symlinked folders") — refusing to write through the link")
                banner = .warning("Can't merge “\(group.name)”: \(dirs) in “\(keeperURL.lastPathComponent)” \(plan.blockedLinkedDirs.count == 1 ? "is a symbolic link" : "are symbolic links") — the fold would write through it. Resolve the link, then rescan.")
                allTrashed = false
                continue
            }
            let logger = Logger.shared   // captured on the main actor; its methods are nonisolated
            let progressRef = ProgressRef(progress)   // NSProgress is thread-safe; the ref is the Sendable wrapper

            let outcome: (copied: [PendingCopyItemState], failed: Bool, cancelled: Bool) = await enqueueFileOperation {
                func reservedKey(_ path: String) -> String { keeperCaseSensitive ? path : path.lowercased() }
                var copied: [PendingCopyItemState] = []
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
                        // The identity walk starts HERE, the moment this file's own copy landed —
                        // not at registration, which the restructure moved to the end of the whole
                        // merge. `registerCopyUndo(items:)`'s walk-at-registration convenience is
                        // documented for single-item call sites for exactly this reason: a batch
                        // that blocks on user prompts and slow-volume I/O in between would record
                        // an edit made during that tail as the copy's own baseline, and a later ⌘Z
                        // would trash it.
                        copied.append((source: step.src, destination: dst, overwritten: overwritten,
                                       identity: FileSyncManager.startCopyIdentityWalk(at: dst, fileManager: fm)))
                    } catch {
                        // Record the underlying cause: the user-facing alert only says "some files
                        // couldn't be merged", so without this the reason is unrecoverable.
                        logger.warning("Duplicates merge: copying “\(step.src.lastPathComponent)” into \(keeperURL.lastPathComponent) failed: \(error.localizedDescription)")
                        failed = true
                        break
                    }
                }
                return (copied, failed, cancelledMidCopy)
            }

            if !outcome.copied.isEmpty {
                // Recorded, not registered: the registration is the tail's, and it happens with no
                // undo group open in between. Their identity walks are already running.
                foldedItems.append(contentsOf: outcome.copied)
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
                // Falls through to the tail rather than returning here: the copies that DID land in
                // this run — this fold's and every earlier one's — have no undo registered yet, and
                // an early return would leave them in the keeper with nothing to reverse them.
                present(.syncFailed(item: redundant.name, path: redundant.path,
                                    reason: "Some files couldn't be merged; the folder was left in place."))
                copyFailed = true
                allTrashed = false
                break
            }

            // The plan is a point-in-time snapshot, and minutes of hashing/copying may have passed.
            // Re-walk the redundant copy IMMEDIATELY before trashing: anything new or size-changed
            // since plan time is content the merge neither verified nor copied, and trashing the
            // folder would destroy it. Same refusal shape as the keeper drift check — log, leave
            // the copy in place, keep the group listed for a re-scan/retry.
            let currentSnapshot = Self.fileSnapshotsByRelativePath(
                await Self.buildTree(url: rURL, sortOption: .name, fileManager: fm, maxDepth: nil))
            if Self.mergeSourceDrifted(planned: plan.sourceSnapshot, current: currentSnapshot) {
                Logger.shared.warning("Duplicates merge: “\(redundant.name)” changed after the merge was planned — left in place, not trashed")
                driftedCopies.append(redundant.name)
                allTrashed = false
                continue
            }

            // Every file in the redundant copy is now present in the keeper → safe to trash it,
            // once the loop is done. The trash itself is the single `deleteItems` below; what is
            // recorded here is the claim it rests on — this copy, as the plan snapshotted it — so
            // the removal gate can re-prove it at the last moment.
            readyToTrash.append(MergeFoldRecord(name: redundant.name, url: rURL,
                                                plannedSnapshot: plan.sourceSnapshot,
                                                keeperDestinations: outcome.copied.map { $0.destination.path }
                                                    + plan.vouchedKeeperPaths))
        }

        // ONE trash for every fold that completed, gated. The gate is the whole reason this can be
        // deferred at all: it re-walks each copy against its own plan snapshot at the moment the
        // serialized removal STARTS, and again after a confirmed permanent delete — the two windows
        // a check made up in the loop cannot cover (the op queue can put a minutes-long operation
        // in between, and the confirmation dialog sits open for as long as the user leaves it).
        // This path had neither: `mergeSourceDrifted` above ran before `deleteItems` even enqueued,
        // and the unrecoverable branch re-verified nothing at all.
        let gateRefusals = MergeRemovalRefusals()
        var trashedForUndo: (originals: [URL], backups: [URL?])?
        if !readyToTrash.isEmpty {
            let outcome = await deleteItems(
                at: readyToTrash.map { $0.url.path }, fileManager: fm,
                removalGate: mergeRemovalGate(group: group, folds: readyToTrash, refusals: gateRefusals),
                restoreUndoHandback: { originals, backups in
                    trashedForUndo = (originals, backups)
                })
            if outcome.permanentlyDeleted > 0 { anyPermanentlyDeleted = true }
            // The disk is the ground truth for "did this copy leave", the same rule
            // `dropFullyRemovedGroups` follows: a gate refusal, a decline, a cancelled dialog and a
            // failure all leave a real folder behind, however the call accounted for it.
            for fold in readyToTrash where fm.fileExists(atPath: fold.url.path) { allTrashed = false }
            // A gate refusal reads to the user exactly like the pre-check's drift refusal, because
            // it is the same verdict taken later; the gate has already logged the specifics.
            driftedCopies.append(contentsOf: gateRefusals.all)
        }

        // **The registration tail — synchronous, start to finish.** No `await` may appear between
        // `beginUndoGrouping` and `endUndoGrouping`: the main actor cannot be interleaved inside a
        // synchronous stretch, so nothing else can register into the merge's step. The identity
        // walks are awaited AFTER the group closes.
        var identityWalk: Task<Void, Never>?
        if !foldedItems.isEmpty || trashedForUndo != nil {
            let actionName = "Merge \(group.name)"
            // Grouped only when there is a manager to group in. Without one (headless/CLI) the
            // registrations are no-ops, but the handback still has to be ANSWERED — the trash
            // happened, and dropping the pairs on the floor is the one way to lose an undo the
            // caller took responsibility for.
            let grouped = undoManager != nil
            if grouped { undoManager?.beginUndoGrouping() }
            if !foldedItems.isEmpty {
                identityWalk = registerCopyUndo(pendingItems: foldedItems, actionName: actionName, fileManager: fm)
            }
            // Registered AFTER the copy-undo, so ⌘Z pops it FIRST: the redundant copies come back
            // out of the Trash before anything is removed from the keeper.
            //
            // Registration order is only HALF of that guarantee, and the half that was always
            // sound. Both handlers spawn a `Task` that calls `enqueueFileOperation`, so what the
            // user actually sees is the order that queue runs them in — and that order used to be
            // a race (`enqueueFileOperation` claimed its slot only after an actor round trip, so
            // the later caller could claim first). Measured through this exact pair: ~1 inversion
            // in 300 undos on an idle machine, i.e. a ⌘Z that deleted the folded files out of the
            // keeper first. Fixed there, pinned by `FileOperationQueueOrderTests`. The other order would,
            // if the restore then failed, have already deleted the folded files with the originals
            // still gone. Only the copies that reached the Trash are here — a permanently deleted
            // one registers nothing, which is what `anyPermanentlyDeleted` withdraws the ⌘Z offer
            // for below: the group would still hold the copy-undo, whose reversal DELETES the
            // folded items out of the keeper, and the originals would be gone.
            if let trashedForUndo {
                registerRestoreItems(urls: trashedForUndo.originals, trashedItems: trashedForUndo.backups,
                                     actionName: actionName, fileManager: fm)
            }
            // No `setActionName` here, and that is measured rather than assumed: every registrar
            // above names the step after the `actionName` it was handed, and here both were handed
            // the SAME one, so a call adding it back is inert (mutation-checked — deleting it left
            // `oneUndoReversesAWholeTwoCopyMergeAndNothingElse` green). Bulk sync does need one
            // because its per-file registrations carry per-file names. What the step used to read
            // in the Edit menu — "Delete N Items", the name of `deleteItems`' own registration —
            // is fixed by the handback, which put the naming back in this method's hands.
            if grouped { undoManager?.endUndoGrouping() }
        }

        // Outside the group, for the reason stated at the tail. Awaiting keeps the
        // `registerCopyUndo` contract this site alone used to break: every banner below,
        // ⌘Z-offering or not, posts only after the identities the undo checks exist.
        await identityWalk?.value
        if copyFailed { return false }   // the alert is the feedback; no merge banner over it

        // Only drop the group and claim success when every redundant copy actually left the disk
        // and no error surfaced — otherwise keep the group (retry skips what already landed) and
        // never show a false "Merged" banner over an orphaned folder.
        guard allTrashed, currentError == nil else {
            if cancelled {
                banner = .warning("Merge of “\(group.name)” cancelled — unfinished copies were left in place."
                                  + (anyPermanentlyDeleted
                                     ? " A copy was deleted permanently, so this cannot be undone."
                                     : " Everything already merged is undoable with ⌘Z;")
                                  + " the group stays listed and a retry skips what landed.")
            } else if let drifted = driftedCopies.first {
                banner = .warning("“\(drifted)” changed since it was scanned — it was left in place. Rescan before merging.")
            } else if totalFolded > 0 {
                banner = .warning("Merged part of “\(group.name)” — some copies were left in place. Review and retry.")
            }
            return false
        }
        duplicateGroups.removeAll { $0.id == group.id }
        banner = .success("Merged “\(group.name)” — folded \(totalFolded) file\(totalFolded == 1 ? "" : "s") into \(group.keeper.name)."
                          + (anyPermanentlyDeleted ? "" : " Press ⌘Z to undo"),
                          undoable: !anyPermanentlyDeleted)
        Logger.shared.info("Duplicates: merged “\(group.name)” — folded \(totalFolded) file(s) into \(group.keeper.name)")
        if anyPermanentlyDeleted {
            // He audits this log, and this is the case where the fold cannot be taken back.
            Logger.shared.warning(
                "Duplicates: “\(group.name)” had a redundant copy deleted permanently rather than trashed — the merge is not undoable, and undoing the fold would remove the copied files from \(group.keeper.name)")
        }
        return true
    }

    /// The paths whose file has MORE THAN ONE directory entry (hard links), via the link count —
    /// which also catches an inode whose sibling entry lies OUTSIDE the scan root, something an
    /// in-scope identity comparison can't see. Paths that can't be statted are simply absent:
    /// unknown stays in candidacy, which at worst over-reports a duplicate, never hides one.
    /// Reads through URL resource values (not the injectable FileManaging), so mock-backed
    /// tests see no link counts and keep their exact pre-existing grouping behavior.
    nonisolated static func multiLinkPaths(among paths: [String]) -> Set<String> {
        // **Every file, in parallel.** The comment at the call site explains why this cannot be
        // narrowed to the hash candidates — a unique-size link skipped by a candidates-only stat
        // rode straight into a versions group and was recommended for removal — so the semantics
        // are fixed and the only thing left to change is how long they take. Measured over 20,000
        // real paths from ~/Documents: 0.501s serial against 0.183s across the cores, finding the
        // same 7 multi-link files. On a 39,000-file tree that is most of a second of pure stat.
        //
        // `concurrentPerform` over chunks rather than per path: the work per item is one stat, so
        // per-item dispatch would cost more than it saves. Results are merged under a lock once
        // per chunk, and the answer is a Set, so ordering does not enter into it.
        guard !paths.isEmpty else { return [] }
        let keys: Set<URLResourceKey> = [.linkCountKey]
        let chunkSize = 256
        let chunks = (paths.count + chunkSize - 1) / chunkSize
        let lock = NSLock()
        var out = Set<String>()
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            var local: [String] = []
            for i in (chunk * chunkSize)..<min((chunk + 1) * chunkSize, paths.count) {
                let url = URL(fileURLWithPath: paths[i])
                if let count = (try? url.resourceValues(forKeys: keys))?.linkCount, count > 1 {
                    local.append(paths[i])
                }
            }
            guard !local.isEmpty else { return }
            lock.lock(); out.formUnion(local); lock.unlock()
        }
        return out
    }

    /// Whether two paths are the same or one contains the other.
    nonisolated static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        a == b || a.isInsideDirectory(anyOf: [b]) || b.isInsideDirectory(anyOf: [a])
    }

    /// Plans the additive merge of `rURL` into `kURL`: the files under `rURL` whose content the
    /// keeper does NOT provably already have, mapped to their destination under the keeper —
    /// plus a `sourceSnapshot` of the redundant copy's full file set (relative path → size+mtime)
    /// as it stood at plan time, so the trash step can prove nothing appeared or changed since.
    ///
    /// `vouchedKeeperPaths` is the other half of that proof and the reason this returns four things
    /// instead of three: the keeper-side path of every source file this plan SKIPPED, i.e. the file
    /// whose existence is the entire reason no step was emitted. The copy is trashed on the claim
    /// that every byte in it lives in the keeper, and for a skipped file that claim rests on a
    /// keeper file the merge never wrote and therefore never re-checks. Both skip branches report:
    /// the same-relative-path hash match (`keeperHashByRel`) and the retry-idempotence match, whose
    /// keeper file carries the uniquified name a previous run minted, not the source's.
    /// Relative paths come from the tree walk (not string prefix math), so path canonicalization
    /// quirks — e.g. `/var` vs `/private/var` symlinks — can't mangle the destinations.
    nonisolated static func planMerge(
        from rURL: URL, into kURL: URL, caseSensitiveVolume: Bool = true, fileManager fm: FileManaging,
        cache: ContentHashCache? = .shared
    ) async -> (steps: [(src: URL, dst: URL)], sourceSnapshot: [String: MergeFileSnapshot],
                blockedLinkedDirs: [String], vouchedKeeperPaths: [String]) {
        let kTree = await buildTree(url: kURL, sortOption: .name, fileManager: fm, maxDepth: nil)
        // Keeper content hash keyed by RELATIVE path — so "already have it" means the keeper has
        // this exact content *at the same location*, not merely somewhere. "Same location" uses
        // the keeper VOLUME's name semantics: case folds on a case-insensitive volume ("A.txt"
        // and "a.txt" are one on-disk name — an exact-case key missed the collision, copied,
        // and uniquified a junk sibling the retry-skip then never saw), and Unicode always
        // precomposes (APFS/HFS+ lookups are normalization-insensitive regardless of case
        // sensitivity, and providers mix NFC/NFD forms — the same reason nearNameKey folds NFC).
        let relKey: (String) -> String = caseSensitiveVolume
            ? { $0.precomposedStringWithCanonicalMapping }
            : { $0.precomposedStringWithCanonicalMapping.lowercased() }

        // ONE pruning walk builds the keeper's whole view, so the symlink invariant has a
        // single choke point: a symlink ENTRY (file or directory — lstat semantics) may vouch
        // for nothing. Its own NAME still counts as taken (fileExists collides with a link),
        // but its content — and, for a linked DIRECTORY, its entire followed subtree, which
        // buildTree deliberately walks as ordinary files — must feed neither hash map nor the
        // name set: counting through-the-link content as "present in the keeper" lets the
        // skip fire for bytes whose only real copy is the redundant folder the merge is about
        // to trash, leaving the keeper a dangling link over Trash-recoverable content.
        //
        // keeperNames carries every surviving rel — files, FOLDERS, unhashable files — for the
        // "name taken" gate: the copy loop decides collisions with fileExists, which a
        // directory or a too-large file triggers exactly like a hashed file. The per-parent
        // hash sets serve the retry-skip: hashFiles omits unhashable files entirely (no
        // placeholder values), so a set hit is always a real SHA-256 match.
        var kItems: [(rel: String, id: String)] = []
        var keeperNames = Set<String>()
        // Folded rels of keeper entries that are SYMLINKED DIRECTORIES: pruning them from the
        // maps is only half the invariant — a plan step aimed at a rel UNDER one would still
        // write THROUGH the link (fileExists, uniquify, and the copy's temp staging all resolve
        // intermediate links), landing "folded" files in whatever the link points at: an
        // external folder the merge has no business modifying, or the SOURCE itself (where the
        // self-collision uniquified junk per retry and the fold could never complete). Steps
        // descending through one are returned as blocked instead, and the caller refuses.
        var linkedDirRels = Set<String>()
        // Whether the walk's own symlink flag can be trusted for this manager. The real filesystem
        // branch of the walk's `stat` records `isSymbolicLink` from `.isSymbolicLinkKey`; the mock
        // branch never sets it, so injected managers keep the explicit stat and their behaviour is
        // byte-for-byte what it was.
        let walkKnowsSymlinks = fm is FileManager
        func isSymlinkEntry(_ n: FileNode) -> Bool {
            // The walk already lstat'ed every entry and wrote down whether it is a link, so asking
            // the file manager again is a second syscall for an answer we are already holding —
            // and this runs per node, per redundant copy. Measured at 0.134 s of `planMerge`'s
            // 0.252 s on a 2000-file keeper: the single largest cost in the planner, larger than
            // the tree walk it decorates by an order of magnitude.
            //
            // Equivalent, not merely similar: `.isSymbolicLinkKey` and `attributesOfItem`'s
            // `.type` are both lstat semantics on the entry itself, and a broken link never
            // reaches here at all (the walk drops it, because its `fileExists` resolves).
            if walkKnowsSymlinks { return n.isSymbolicLink == true }
            return (try? fm.attributesOfItem(atPath: n.id))?[.type] as? FileAttributeType == .typeSymbolicLink
        }
        func collectKeeperView(_ nodes: [FileNode], prefix: String) {
            for n in nodes {
                let rel = prefix.isEmpty ? n.name : prefix + "/" + n.name
                keeperNames.insert(relKey(rel))
                if isSymlinkEntry(n) {
                    // The entry's name is taken; everything beyond it is not the keeper's.
                    if n.isDirectory { linkedDirRels.insert(relKey(rel)) }
                    continue
                }
                if n.isDirectory {
                    collectKeeperView(n.children ?? [], prefix: rel)
                } else {
                    kItems.append((rel: rel, id: n.id))
                }
            }
        }
        collectKeeperView(kTree, prefix: "")
        func descendsThroughLinkedDir(_ foldedRel: String) -> String? {
            guard !linkedDirRels.isEmpty else { return nil }
            var prefix = ""
            for component in foldedRel.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + String(component)
                if linkedDirRels.contains(prefix) { return prefix }
            }
            return nil
        }

        let kHashesByPath = await hashFiles(kItems.map { $0.id }, fileManager: fm, cache: cache)
        var keeperHashByRel: [String: String] = [:]
        var keeperHashesByParent: [String: Set<String>] = [:]
        // The ACTUAL keeper file behind each vouch, so a skip can name what it rested on. Keyed the
        // same two ways the skips are decided, because the retry-idempotence branch matches on
        // (parent, hash) and the file it finds is named differently from the source's.
        var keeperPathByRel: [String: String] = [:]
        var keeperPathByParentHash: [String: String] = [:]
        for k in kItems {
            if let h = kHashesByPath[k.id] {
                keeperHashByRel[relKey(k.rel)] = h
                keeperPathByRel[relKey(k.rel)] = k.id
                let parent = relKey((k.rel as NSString).deletingLastPathComponent)
                keeperHashesByParent[parent, default: []].insert(h)
                // First writer wins: any one file with these bytes in this folder vouches, and a
                // stable choice keeps the plan deterministic.
                if keeperPathByParentHash[parent + "\u{0}" + h] == nil {
                    keeperPathByParentHash[parent + "\u{0}" + h] = k.id
                }
            }
        }

        let rTree = await buildTree(url: rURL, sortOption: .name, fileManager: fm, maxDepth: nil)
        let rItems = flattenFilesWithRelativePaths(rTree)
        let rHashes = await hashFiles(rItems.map { $0.id }, fileManager: fm, cache: cache)
        // The third hashing site, and the one the "keep the digests" pass missed: both trees were
        // just read in full, and quitting after a merge threw that work away where the scan and
        // Verify already keep theirs. Same contract as those two — the reads have happened
        // whatever the plan below decides.
        await cache?.save()

        var steps: [(src: URL, dst: URL)] = []
        var blockedLinkedDirs = Set<String>()
        var vouchedKeeperPaths: [String] = []
        for item in rItems {
            // Skip ONLY when the keeper already has this exact content at the SAME relative path —
            // a true same-location duplicate. A distinctly-named or -located file is folded in even
            // when its bytes happen to also live elsewhere in the keeper, so the merge never
            // silently drops a meaningfully-named file (a later duplicates scan can reconcile any
            // resulting byte-duplicate — losing a filename is the worse surprise).
            // An UNHASHABLE source file (too large, unreadable, cloud-only) is deliberately
            // re-planned every run: its content can't be proven landed, and the trash step's
            // safety rests on this run's own copy. A cancelled run's prior landing then sits
            // as a junk sibling — the price of never skipping unverified content.
            if let h = rHashes[item.id] {
                if keeperHashByRel[relKey(item.rel)] == h {
                    if let vouch = keeperPathByRel[relKey(item.rel)] { vouchedKeeperPaths.append(vouch) }
                    continue
                }
                // Retry idempotence: the destination NAME is taken (by anything fileExists
                // would collide with — a different-content file, a folder, an unhashable
                // file), and the same bytes already live in that folder under another name —
                // the collision-uniquify outcome of a previous (cancelled/failed) run of this
                // very merge. Copying again would mint "x 2"/"x 3" junk on every retry,
                // against the cancel banner's "a retry skips what landed". The name-preserving
                // principle above is not violated: with the name taken, this fold could only
                // ever land junk-named.
                let parent = relKey((item.rel as NSString).deletingLastPathComponent)
                if keeperNames.contains(relKey(item.rel)),
                   keeperHashesByParent[parent]?.contains(h) == true {
                    if let vouch = keeperPathByParentHash[parent + "\u{0}" + h] { vouchedKeeperPaths.append(vouch) }
                    continue
                }
            }
            // A destination under a keeper symlink-dir cannot be planned safely (see
            // linkedDirRels above): record the linked dir and plan nothing for this item —
            // the caller refuses the whole merge so the trash step can never run without it.
            if let linkedDir = descendsThroughLinkedDir(relKey(item.rel)) {
                blockedLinkedDirs.insert(linkedDir)
                continue
            }
            steps.append((src: URL(fileURLWithPath: item.id), dst: kURL.appendingPathComponent(item.rel)))
        }
        return (steps, fileSnapshotsByRelativePath(rTree), blockedLinkedDirs.sorted(), vouchedKeeperPaths)
    }

    /// What the drift check knows about one file in the merge source: byte size AND modification
    /// date. Size alone let a same-length in-place rewrite of a plan-skipped file slip through the
    /// minutes-long hash/copy window — the rewrite's only copy would then be trashed. Any real
    /// write bumps the mtime (both fields come from the same tree walk, so an unchanged file
    /// always compares equal) — to within the volume's timestamp granularity: on FAT or a coarse
    /// SMB mount (1–2 s ticks) a same-length rewrite inside one tick still compares equal, the
    /// same residual blindness the resolve path's file and folder checks carry — and the same two
    /// further residuals too: an mtime-preserving writer (`touch -r`, `rsync --times`, some cloud
    /// daemons) makes any rewrite invisible to size+mtime, and xattr/Finder-tag edits move ctime
    /// only, so neither field sees them (see `copyDriftedInPlace`).
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
        // EVERY group holding the path, not the first — one file can now legitimately be in two.
        // `groupedFilePaths` used to guarantee a file appeared in at most one file group, and
        // `firstIndex` was correct because of it; the same-text pass broke that invariant on
        // purpose, by letting an identical group's KEEPER anchor a same-text group as well (see
        // `sameTextFileGroups`). Trash that keeper out-of-band from the Compare review and the
        // first-match version updated one group and left the other listing a file that is now in
        // the Trash — not destructive, because `keeperStillExists` refuses the resolve, but the
        // user is told to rescan for something the app was holding the answer to.
        for idx in duplicateGroups.indices.reversed()
        where duplicateGroups[idx].copies.contains(where: { $0.id == path }) {
            if let updated = duplicateGroups[idx].removingRedundantCopy(atPath: path) {
                duplicateGroups[idx] = updated
            } else {
                duplicateGroups.remove(at: idx)
            }
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
        cache: ContentHashCache?,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async -> [String: String] {
        await hashFilesCounting(paths, fileManager: fileManager, maxConcurrent: maxConcurrent,
                                cache: cache, onProgress: onProgress).hashes
    }

    /// ``hashFiles`` plus per-reason skip counts. `maxBytesToHash` and `isCloudOnly` are
    /// injectable for tests (a real dataless file can't be fabricated — the flag is provider-set).
    ///
    /// `cache` is REQUIRED rather than defaulted, because the right answer differs per caller and a
    /// default would pick one silently. The entry points (``findDuplicates`` and ``planMerge``) pass
    /// the session cache Verify already uses, so the two features stop paying for each other's work:
    /// a duplicates scan after a Verify — or a second duplicates scan, or the keeper tree re-walked once per
    /// redundant copy during a merge — re-read and re-hashed gigabytes that had not changed.
    ///
    /// Note what a hit deliberately bypasses: the cache holds DIGESTS, while `maxBytesToHash` and
    /// `isCloudOnly` only decide whether computing one is worth it. A file whose digest is already
    /// known is therefore hashed-and-grouped even if it now exceeds the cap — which is the better
    /// answer (the duplicate really is detectable) but means a caller VARYING those knobs across
    /// calls must not share a cache, or the second call inherits the first's willingness. Only
    /// tests vary them; production holds them constant.
    nonisolated static func hashFilesCounting(
        _ paths: [String],
        fileManager: FileManaging,
        maxConcurrent: Int = 6,
        maxBytesToHash: Int = FileContentVerifier.maxBytesToHash,
        isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) },
        cache: ContentHashCache?,
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
                                                                 cache: cache,
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
