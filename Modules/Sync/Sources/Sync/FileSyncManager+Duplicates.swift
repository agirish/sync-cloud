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
    /// the file-manager seam; size is exact and can never false-fail an unchanged file.) Folders
    /// keep the existence-only check — a folder's stat size isn't its recursive content size.
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
    /// in-place rewrite slip through"), which is why `MergeFileSnapshot` carries both.
    ///
    /// **Folders are still exempt, and that gap is still open.** A folder group's entire
    /// resolve-time guarantee remains "a directory entry still exists at this path": scan two
    /// 3,000-file folders as identical, move 1,200 photos out of one, press Move to Trash, and the
    /// last intact copy of those 1,200 goes. Closing it was attempted here and reverted, because
    /// the scan records no baseline a resolve-time check can compare against — measured, folder
    /// copies arrive with `modificationDate` nil, so gating on it refuses EVERY folder group and
    /// disables folder dedup rather than protecting it. `itemCount` is recorded and is a real
    /// signal, but it is a RECURSIVE count whose definition a re-walk would have to reproduce
    /// exactly or every group refuses for the opposite reason. Closing this needs the scan to
    /// record a comparable folder baseline; it is not a change to this function alone.
    private func copyDriftedInPlace(_ copy: DuplicateCopy) -> Bool {
        guard fileManager.fileExists(atPath: copy.path) else { return false }
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
        if let drifted = driftedRemovalCandidates(group).first {
            banner = .warning("“\(drifted.name)” changed since it was scanned — it may no longer be a copy. Rescan before removing it.")
            Logger.shared.warning("Duplicates: refused to remove copies of “\(group.keeper.name)” — “\(drifted.name)” changed after the scan")
            return false
        }
        let bytes = group.reclaimableBytes
        let outcome = await deleteItems(at: paths, fileManager: fileManager)
        let removed = outcome.removed
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
        // Both ends re-verified, for the same reason the per-group path checks both: the blind
        // batch is exactly where a drifted copy would go unlooked-at.
        let batch = eligible.filter { keeperStillExists($0) && driftedRemovalCandidates($0).isEmpty }
        let paths = batch.flatMap { $0.recommendedRemovalPaths }
        guard !paths.isEmpty else {
            if !eligible.isEmpty {
                banner = .warning("These groups changed since they were scanned — rescan before removing copies.")
            }
            return
        }
        let outcome = await deleteItems(at: paths, fileManager: fileManager)
        let removed = outcome.removed
        guard removed > 0 else { return }
        let done = dropFullyRemovedGroups(from: batch)
        let bytes = done.reduce(0) { $0 + $1.reclaimableBytes }
        Logger.shared.info("Duplicates: applied recommended removal to \(done.count) of \(eligible.count) group(s), reclaimed \(Self.formatBytes(bytes))")
        if currentError == nil {
            if done.count == batch.count, batch.count == eligible.count {
                banner = .success("Reclaimed \(Self.formatBytes(bytes)) from \(done.count) group\(done.count == 1 ? "" : "s")" + (outcome.isUndoable ? " — press ⌘Z to undo" : ""),
                                  undoable: outcome.isUndoable)
            } else {
                // Partial (cancelled mid-batch, declined fallback, or skipped missing keepers):
                // claim only what landed; the rest stay listed.
                banner = .warning("Reclaimed \(Self.formatBytes(bytes)) from \(done.count) of \(eligible.count) groups — the rest stay listed." + (outcome.isUndoable ? " Press ⌘Z to undo" : ""))
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
        // Fold the whole merge into ONE undo step, the way syncAll groups a bulk run. Without it a
        // merge registered 2N groups — one `registerCopyUndo` per redundant copy plus one delete
        // group each — so the success banner's "Press ⌘Z to undo" reversed only the last trash and
        // left the user guessing how many more presses the rest needed. The grouping reuses the
        // existing per-step reversals; no new mutation path.
        //
        // Opened LAZILY, at the first registration, and closed by the `defer` below. Opening it up
        // front would leave an empty group whenever a merge registers nothing (refused early, every
        // copy already gone), and there is no safe way to take an empty group back: calling undo()
        // to discard it reverses the user's PREVIOUS action if the platform dropped the empty group
        // itself. Never creating one sidesteps the question.
        var undoGroupOpen = false
        func openUndoGroupIfNeeded() {
            guard !undoGroupOpen, undoManager != nil else { return }
            undoManager?.beginUndoGrouping()
            undoGroupOpen = true
        }
        defer { if undoGroupOpen { undoManager?.endUndoGrouping() } }
        let keeperPath = group.keeper.path
        let keeperURL = URL(fileURLWithPath: keeperPath)
        let fm = fileManager
        var totalFolded = 0
        var allTrashed = true
        var cancelled = false
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
                        logger.warning("Duplicates merge: copying “\(step.src.lastPathComponent)” into \(keeperURL.lastPathComponent) failed: \(error.localizedDescription)")
                        failed = true
                        break
                    }
                }
                return (copied, failed, cancelledMidCopy)
            }

            if !outcome.copied.isEmpty {
                openUndoGroupIfNeeded()
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
                Logger.shared.warning("Duplicates merge: “\(redundant.name)” changed after the merge was planned — left in place, not trashed")
                driftedCopies.append(redundant.name)
                allTrashed = false
                continue
            }

            // Every file in the redundant copy is now present in the keeper → safe to trash it.
            // Its restore-undo joins the merge's group so one ⌘Z takes the whole fold back — but
            // only when it reached the Trash. A copy destroyed permanently registers no restore,
            // and the group still holds this fold's `registerCopyUndo`, whose reversal DELETES the
            // copied items. So "Press ⌘Z to undo" would walk the user from a merge that cannot be
            // taken back to a prompt that removes the folded files from the keeper, with the
            // originals already gone. Track it and stop making the offer.
            openUndoGroupIfNeeded()
            // `trashOutcome`, not `outcome`: the copy phase above already binds that name for its
            // own result in this scope.
            let trashOutcome = await deleteItems(at: [redundant.path], fileManager: fm)
            if trashOutcome.removed == 0 { allTrashed = false }   // trash declined/failed — don't claim the group done
            if trashOutcome.permanentlyDeleted > 0 { anyPermanentlyDeleted = true }
        }

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
        var out = Set<String>()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if let count = (try? url.resourceValues(forKeys: [.linkCountKey]))?.linkCount, count > 1 {
                out.insert(path)
            }
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
    /// Relative paths come from the tree walk (not string prefix math), so path canonicalization
    /// quirks — e.g. `/var` vs `/private/var` symlinks — can't mangle the destinations.
    nonisolated static func planMerge(
        from rURL: URL, into kURL: URL, caseSensitiveVolume: Bool = true, fileManager fm: FileManaging,
        cache: ContentHashCache? = .shared
    ) async -> (steps: [(src: URL, dst: URL)], sourceSnapshot: [String: MergeFileSnapshot], blockedLinkedDirs: [String]) {
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
        for k in kItems {
            if let h = kHashesByPath[k.id] {
                keeperHashByRel[relKey(k.rel)] = h
                keeperHashesByParent[relKey((k.rel as NSString).deletingLastPathComponent), default: []].insert(h)
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
                if keeperHashByRel[relKey(item.rel)] == h { continue }
                // Retry idempotence: the destination NAME is taken (by anything fileExists
                // would collide with — a different-content file, a folder, an unhashable
                // file), and the same bytes already live in that folder under another name —
                // the collision-uniquify outcome of a previous (cancelled/failed) run of this
                // very merge. Copying again would mint "x 2"/"x 3" junk on every retry,
                // against the cancel banner's "a retry skips what landed". The name-preserving
                // principle above is not violated: with the name taken, this fold could only
                // ever land junk-named.
                if keeperNames.contains(relKey(item.rel)),
                   keeperHashesByParent[relKey((item.rel as NSString).deletingLastPathComponent)]?.contains(h) == true {
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
        return (steps, fileSnapshotsByRelativePath(rTree), blockedLinkedDirs.sorted())
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
