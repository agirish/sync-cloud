import Events
import Foundation

/// Duplicates — the in-provider duplicate finder. Reuses the existing tree walk and content hasher to
/// gather input for the pure ``DuplicateFinder``, and routes removals through ``deleteItems`` so
/// they land in the Trash with the same one-step Undo as every other destructive action.
extension FileSyncManager {

    /// Files the last duplicate scan couldn't prove identical to anything, by reason, so skipped
    /// files are reported rather than silently missing. Labels the current `duplicateGroups` as
    /// `duplicateScanRoot` does: published with the results, reset by `clearDuplicates`.
    public struct DuplicateScanSkips: Sendable, Equatable {
        /// Candidates skipped because they are cloud-only (dataless) placeholders that hashing
        /// would force-download.
        public var cloudOnly: Int
        /// Files excluded because they are hard links (link count > 1): a directory entry is
        /// not the bytes, so no single-path duplicate offer about one is truthful. Counted so
        /// a Time-Machine-shaped tree doesn't just quietly report fewer duplicates.
        public var multiLink: Int
        /// Documents the same-text pass couldn't judge: an image-only scan, a password-locked PDF,
        /// or one whose page 1 holds fewer than ``ContentFingerprint/minimumTokens`` tokens.
        /// Counted so a pass that declines many documents says so, rather than silently missing
        /// their re-stamped copies.
        public var textUnreadable: Int
        /// Candidates whose bytes couldn't be read, or couldn't be proved to be the bytes that were
        /// read: gone or unreadable by the time hashing reached them, a directory or broken link
        /// where a file was expected, replaced between the stat and the open, or rewritten
        /// mid-read. Counted so a volume that answers badly can't turn into "no duplicates" with
        /// nothing on screen saying why.
        public var unverifiable: Int
        /// Files no duplicate claim of any kind could be made about. `textUnreadable` is not in it:
        /// those files were hashed and grouped normally, and only the weaker text claim was
        /// declined for them.
        public var total: Int { cloudOnly + multiLink + unverifiable }

        public init(cloudOnly: Int = 0, multiLink: Int = 0,
                    textUnreadable: Int = 0, unverifiable: Int = 0) {
            self.cloudOnly = cloudOnly
            self.multiLink = multiLink
            self.textUnreadable = textUnreadable
            self.unverifiable = unverifiable
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
    /// what "Apply recommended" delivers — overlapping, versions and same-text groups never
    /// inflate them.
    public var duplicateSummary: DuplicateSummary {
        var reclaimable = 0, redundant = 0, review = 0
        for g in duplicateGroups {
            if g.isRecommendedForBatch {
                reclaimable += g.reclaimableBytes
                redundant += g.copies.count - 1
            }
            // The kind the user must look at before acting: a same-text group's copies only
            // provably *read* the same.
            switch g.matchType {
            case .sameText: review += 1
            case .identical, .overlapping, .versions: break
            }
        }
        return DuplicateSummary(groupCount: duplicateGroups.count,
                                reclaimableBytes: reclaimable,
                                redundantCopyCount: redundant,
                                needsReviewCount: review)
    }

    // MARK: Scan

    /// Starts a cancellable Find Duplicates scan of one subtree, replacing any in-flight one.
    /// - Parameters:
    ///   - root: The provider root (or focused folder) to scan.
    ///   - options: Detection tuning.
    public func startFindDuplicates(root: URL, options: DuplicateFinderOptions = .init()) {
        duplicateScanTask = restartedScanTask(replacing: duplicateScanTask) { [weak self] in
            await self?.findDuplicates(root: root, options: options)
        }
    }

    /// Cancels a running Find Duplicates scan; results are left as they were.
    public func cancelFindDuplicates() {
        duplicateScanTask?.cancel()
    }

    /// Re-runs the duplicate scan on lens open, when `root` is a target the user has scanned to
    /// completion before. It is all local, so it never costs money or network. A repeat costs
    /// little time, since both persisted indexes skip unchanged files, but the first run with the
    /// same-text pass reads every PDF in the tree once (minutes on a large tree). The scan is
    /// cancellable and shows progress, and the pass has a Settings toggle. The questions are
    /// consent and idempotence:
    ///
    /// - Consent is a remembered target: the user has scanned exactly this before, so repeating it
    ///   offers nothing they didn't ask for. Nothing remembered (or no injected store) means never,
    ///   and a target that is no longer a reachable directory is declined rather than scanned into
    ///   an empty result (``FileSyncManager/isReachableDirectory(_:fileManager:)``).
    /// - Idempotence against the callers' overlapping triggers (appear, workspace change, root
    ///   change, as for `restoreStorageLens`): a completed scan this session declines via
    ///   `hasFoundDuplicates`, a running one via `isFindingDuplicates`, and a cancelled attempt via
    ///   the per-target latch.
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

    /// `sampleAbove` and `isCloudOnly` are injectable for tests only (a >100 MB fixture per run is
    /// wasteful, and a dataless file can't be fabricated). `sampleAbove` is the size past which a
    /// candidate's ends are sampled before it is read whole (``duplicateEdgeSampleAbove``).
    ///
    /// `cache` is the session hash cache, shared with Verify so a rescan of an unchanged tree
    /// re-reads nothing. A test that varies `isCloudOnly` across scans of the same files must pass
    /// `nil` (see ``hashFilesCounting`` for why a hit bypasses it).
    ///
    /// `textFingerprint` is the same-text pass's reader: a path in, a ``FingerprintReading`` out.
    /// `fingerprintCache` holds its digests, apart from the content hashes because the two share a
    /// key shape but hold different things. `textlessCache` holds the too-little-text answers,
    /// apart from the digests for the reason ``ContentHashCache/sharedTextless`` gives.
    public func findDuplicates(
        root: URL,
        options: DuplicateFinderOptions = .init(),
        fileManager fm: FileManaging? = nil,
        sampleAbove: Int = duplicateEdgeSampleAbove,
        isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) },
        cache: ContentHashCache? = .shared,
        textFingerprint: @escaping @Sendable (String) async -> FingerprintReading = PDFTextExtractor.fingerprintReading,
        fingerprintCache: ContentHashCache? = .sharedFingerprints,
        textlessCache: ContentHashCache? = .sharedTextless
    ) async {
        guard !isFindingDuplicates else { return }
        let fileManager = fm ?? self.fileManager
        // The caches must be distinct instances. They share a key shape (`ContentHashKey`) and both
        // store a 64-hex string, so one instance holding both would silently serve a file's SHA-256
        // as its fingerprint, or the reverse. Decline the cache rather than trap: re-reading
        // documents beats a crash.
        let documentCache: ContentHashCache? =
            (fingerprintCache != nil && fingerprintCache === cache) ? nil : fingerprintCache
        if documentCache == nil, fingerprintCache != nil {
            Logger.shared.warning("Duplicates: the document-fingerprint cache and the content-hash cache are the same instance — reading documents without a cache rather than letting one serve the other's digests")
        }
        // The same refusal for the negatives: shared with either store, the marker would sit where
        // a digest is looked for, and an older build reading that file would take it for one.
        let negativeCache: ContentHashCache? =
            (textlessCache != nil && (textlessCache === cache || textlessCache === fingerprintCache))
                ? nil : textlessCache
        if negativeCache == nil, textlessCache != nil {
            Logger.shared.warning("Duplicates: the textless-document cache is the same instance as a digest cache — re-reading textless documents rather than mixing the two")
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
        //
        // Budgeted first, as a probe, as the storage lens does (`buildStorageLens`). The answer
        // can't be budgeted, since groups computed from part of a tree miss duplicates, but the
        // probe learns the tree's size before committing. Past the walk this hashes every
        // size-colliding file, so a tree too big for the probe costs real content reads, and the
        // user confirms it first.
        let probe = NodeBudget(wholeTreeProbeBudget)
        var tree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager,
                                        maxDepth: nil, budget: probe)
        if Task.isCancelled { return }
        if probe.didStopADescent {
            let preflight = LargeWalkPreflight(pass: .duplicates, rootPath: root.path,
                                               probeLimit: probe.limit)
            guard largeWalkConfirmer(preflight) else {
                Logger.shared.info("Duplicates: “\(preflight.rootName)” holds more than \(preflight.probeLimit) entries — not scanned")
                return
            }
            tree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager,
                                        maxDepth: nil)
            if Task.isCancelled { return }
        }

        // 2. Only files whose size collides with another can be identical, so hash just those.
        //    Everything else gets a unique placeholder so folder signatures still compute but never
        //    falsely match.
        //
        //    Nothing under an ignored name (`.git`, `node_modules`, …) counts: the grouping stops
        //    at the name (`DuplicateFinder.collect`), so hashing, reading or link-checking below it
        //    is wasted.
        let allFiles = Self.flattenFiles(tree, skipping: options.ignoredNames)
        var sizeCount: [Int: Int] = [:]
        for f in allFiles where (f.fileSize ?? -1) >= 0 {
            sizeCount[f.fileSize!, default: 0] += 1
        }
        let candidates = allFiles
            .filter { ($0.fileSize ?? -1) >= 0 && sizeCount[$0.fileSize!, default: 0] >= 2 }
            .map { (path: $0.id, size: $0.fileSize!) }
        //    A large candidate is read whole only if its ends match another's of the same size —
        //    see `duplicateEdgeSampleAbove` for why, and `candidatesNeedingFullHash` for the rule.
        let large = candidates.filter { $0.size > sampleAbove }
        // Reading 2 MB of each takes a while on a slow disk: say so, rather than leave the walk's
        // words up while it runs.
        if !large.isEmpty {
            updateScan(\.duplicateScanLifecycle, epoch: epoch,
                       status: "Comparing the ends of \(large.count) large file\(large.count == 1 ? "" : "s")…")
        }
        let samples = large.isEmpty ? [:]
            : await Self.edgeSamples(large, fileManager: fileManager, cache: cache,
                                     isCloudOnly: isCloudOnly)
        if Task.isCancelled { return }
        let candidatePaths = Self.candidatesNeedingFullHash(candidates, samples: samples,
                                                            sampleAbove: sampleAbove)

        let total = candidatePaths.count
        // Zero candidates is a common state (no two files share a size), so it gets its own
        // sentence rather than "Hashing 0 candidates…".
        updateScan(\.duplicateScanLifecycle, epoch: epoch,
                   status: total == 0 ? "Looking for candidates…"
                                      : "Hashing \(total) candidate\(total == 1 ? "" : "s")…")
        duplicateScanProgress = total > 0 ? (completed: 0, total: total) : nil
        // One @Published write per whole percent (`ProgressPublishGate`). Two gates in series,
        // because each fails alone at the other's end: the `% 50` floor keeps a small scan quiet (a
        // percent gate publishes on nearly every file below ~5,000 candidates), and the percent
        // gate keeps a large one quiet. Together the traffic is min(total / 50, ~101).
        let hashGate = ProgressPublishGateBox()
        let hashOutcome = await Self.hashFilesCounting(
            candidatePaths, fileManager: fileManager,
            isCloudOnly: isCloudOnly, cache: cache
        ) { [weak self] done in
            if done % 50 == 0 || done == total {
                Task { @MainActor in
                    // Consult the gate inside the main-actor hop, never in the closure above:
                    // `ProgressPublishGateBox` is `@unchecked Sendable` only because it is touched
                    // solely on the main actor, and that closure runs on the worker, so reading it
                    // there is a data race.
                    guard let self, hashGate.admits(completed: done, total: total),
                          self.updateScan(\.duplicateScanLifecycle, epoch: epoch,
                                          status: "Hashing \(done) of \(total)…") else { return }
                    self.duplicateScanProgress = (completed: done, total: total)
                }
            }
        }
        let realHashes = hashOutcome.hashes
        if Task.isCancelled { return }
        // Deterministic terminal publish: the `done == total` update above is an unstructured
        // main-actor Task that can lose the race to this resumption, and the defer's epoch bump
        // would then drop it, leaving the bar short of full. Back on the main actor with the epoch
        // current, so pin it at 100%.
        if total > 0 {
            updateScan(\.duplicateScanLifecycle, epoch: epoch, status: "Hashing \(total) of \(total)…")
            duplicateScanProgress = (completed: total, total: total)
        }

        var fileHashes: [String: String] = [:]
        fileHashes.reserveCapacity(allFiles.count)
        for f in allFiles {
            fileHashes[f.id] = realHashes[f.id] ?? DuplicateFinder.unknownSignature(forPath: f.id)
        }

        // Save what this scan hashed before the next cancellation check: the reads were the
        // expensive part, and a cancel abandons the grouping, not the measurements.
        //
        // Then drop hard-linked files (link count > 1) from grouping: a directory entry is not the
        // bytes, so no single-path offer about one is truthful, wherever the sibling link is.
        // Statted over all scanned files, not just the hash candidates, because the versions pass
        // admits any file ≥ minFileSize: a unique-size link would otherwise reach a versions group
        // and be recommended for removal. Stat-only reads, off the main actor.
        await cache?.save()

        let linkCheckPaths = allFiles.map { $0.id }
        let multiLinkPaths = await Task.detached(priority: .userInitiated) {
            Self.multiLinkPaths(among: linkCheckPaths)
        }.value
        if Task.isCancelled { return }

        // 2b. Read the documents, for duplicates a byte hash can't see: a provider re-stamps each
        //     PDF on download, so the same bill fetched twice differs in bytes but not in content.
        //     Every fingerprintable document is read, not just the size-colliding candidates,
        //     because a re-stamp often changes the byte count too: restricting to shared sizes
        //     found under half the groups on a real tree. Cached by (path, mtime, size, file
        //     number, ctime), so this is paid once.
        var textFingerprints: [String: String] = [:]
        var textUnreadable = 0
        if options.detectSameText {
            let documentPaths = allFiles.map { $0.id }
                .filter { ContentFingerprint.canFingerprint(path: $0) }
            if !documentPaths.isEmpty {
                let documentTotal = documentPaths.count
                let textGate = ProgressPublishGateBox()
                // Named subject: on an empty pane this line is the only thing on screen, and
                // "Reading 61 documents…" answers neither where nor why.
                updateScan(\.duplicateScanLifecycle, epoch: epoch,
                           status: "Reading \(documentTotal) document\(documentTotal == 1 ? "" : "s") in “\(root.lastPathComponent)”…")
                duplicateScanProgress = (completed: 0, total: documentTotal)
                textFingerprints = await Self.fingerprintDocuments(
                    documentPaths, fileManager: fileManager, cache: documentCache,
                    textless: negativeCache, extract: textFingerprint
                ) { [weak self] done in
                    // Every 50, and deliberately not also on the last one: with the interval hops
                    // alone, the full value has one source (the terminal publish below), and a test
                    // can hold it to that.
                    if done % 50 == 0 {
                        Task { @MainActor in
                            // Percent gate inside the hop, `% 50` floor outside it — the same
                            // composition, and the same main-actor reason, as the hashing phase.
                            guard let self, textGate.admits(completed: done, total: documentTotal),
                                  self.updateScan(\.duplicateScanLifecycle, epoch: epoch,
                                                  status: "Reading \(done) of \(documentTotal)…") else { return }
                            self.duplicateScanProgress = (completed: done, total: documentTotal)
                        }
                    }
                }
                textUnreadable = documentTotal - textFingerprints.count
                // Deterministic terminal publish: the interval hops stop at the last multiple of
                // 50, and one still queued can lose the race to this resumption and be dropped by
                // the defer's epoch bump. This is the long phase on a cold tree, so a bar left
                // short would show for the rest of the scan.
                if !Task.isCancelled {
                    updateScan(\.duplicateScanLifecycle, epoch: epoch,
                               status: "Reading \(documentTotal) of \(documentTotal)…")
                    duplicateScanProgress = (completed: documentTotal, total: documentTotal)
                }
                // Same contract as the content hashes above: the reading has happened whatever the
                // grouping below decides, so a cancellation must not throw the digests away.
                await documentCache?.save()
                await negativeCache?.save()
            }
        }
        if Task.isCancelled { return }

        // 3. Group (pure), then drop anything the user has kept separate. Off the main actor: on a
        //    Documents-sized tree the grouping alone takes 0.5–0.9 s, and it takes and returns
        //    plain values.
        let groupInput = (tree, fileHashes, multiLinkPaths, textFingerprints)
        let groups = await Task.detached(priority: .userInitiated) {
            DuplicateFinder.findGroups(tree: groupInput.0, fileHashes: groupInput.1, options: options,
                                       multiLinkPaths: groupInput.2, textFingerprints: groupInput.3)
        }.value
        if Task.isCancelled { return }
        let ignored = ignoredDuplicateKeys
        // Set BEFORE duplicateGroups so its @Published publish is observed with a matching value
        // (like duplicateScanRoot, it labels what's on screen, not the in-flight scan).
        duplicateScanSkips = DuplicateScanSkips(cloudOnly: hashOutcome.skippedCloudOnly,
                                                multiLink: multiLinkPaths.count,
                                                textUnreadable: textUnreadable,
                                                unverifiable: hashOutcome.unverifiable)
        // From the tree in hand, not the disk: the lens counts these on every redraw, and a stat
        // per copy from a view body is main-thread I/O on whatever volume the copies are on.
        keptSeparateGoneKeys = Self.goneKeptSeparateKeys(ignored, under: root.path, tree: tree)
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
            Logger.shared.info("Duplicates: \(skips.total) file(s) outside duplicate detection — \(skips.cloudOnly) cloud-only (not downloaded), \(skips.multiLink) hard-linked (trashing a link frees nothing); duplicates among them are not detected")
        }
        if skips.textUnreadable > 0 {
            Logger.shared.info("Duplicates: \(skips.textUnreadable) document(s) said too little to fingerprint (image-only scan, locked, or under \(ContentFingerprint.minimumTokens) tokens) — a re-stamped copy of one of them is not detected")
        }
    }

    /// The key a fingerprint is cached under: ``ContentHashKey``'s own contract, path, mtime and
    /// size plus file number and status-change time (``ContentHashKey/diskIdentity(atPath:)``). The
    /// triple alone can't see a document replaced by a same-size one carrying its dates (what a
    /// copy over it leaves), and would serve the old fingerprint as "same text". nil without a
    /// readable mtime, so that document is fingerprinted every scan rather than cached under an
    /// unstable key.
    nonisolated static func fingerprintCacheKey(forPath path: String,
                                                fileManager: FileManaging) -> ContentHashKey? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? (attributes[.size] as? Int) ?? 0
        let identity = ContentHashKey.diskIdentity(atPath: path)
        return ContentHashKey(path: path, mtime: modified.timeIntervalSince1970, size: size,
                              fileNumber: identity?.fileNumber, statusChanged: identity?.statusChanged)
    }

    /// Fingerprints documents with bounded concurrency, returning path → digest for those that
    /// produced one. Cached under ``fingerprintCacheKey``, so a rescan of an unchanged tree
    /// re-parses nothing.
    ///
    /// A read that came to too little text is cached in `textless` as
    /// ``ContentFingerprint/tooLittleTextMarker`` under the same key, so it is invalidated exactly
    /// as a digest is and warm rescans skip image-only scans too. An unreadable document
    /// (``FingerprintReading/unreadable``) is never stored, so a placeholder that downloads, or a
    /// file that stops being locked, is read next scan. The marker is answered as nil and never
    /// leaves here.
    nonisolated static func fingerprintDocuments(
        _ paths: [String],
        fileManager: FileManaging,
        maxConcurrent: Int = 6,
        cache: ContentHashCache?,
        textless: ContentHashCache? = nil,
        extract: @escaping @Sendable (String) async -> FingerprintReading,
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
                    if let key {
                        if let cached = await cache?.hash(for: key),
                           !ContentFingerprint.isNoFingerprintMarker(cached) { return (path, cached) }
                        // Only this scheme's negative is believed; another's is a miss, and the
                        // document is read again below.
                        if await textless?.hash(for: key) == ContentFingerprint.tooLittleTextMarker {
                            return (path, nil)
                        }
                    }
                    switch await extract(path) {
                    case .digest(let digest):
                        if let key { await cache?.store(digest, for: key) }
                        return (path, digest)
                    case .tooLittleText:
                        if let key { await textless?.store(ContentFingerprint.tooLittleTextMarker, for: key) }
                        return (path, nil)
                    case .unreadable:
                        return (path, nil)
                    }
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

    nonisolated static let ignoreDefaultsKey = "tidyIgnoredGroupKeys"

    /// The set of duplicate-group keys the user has chosen to keep separate (persisted).
    public var ignoredDuplicateKeys: Set<String> {
        get { Set(duplicateIgnoreDefaults.stringArray(forKey: Self.ignoreDefaultsKey) ?? []) }
        set { duplicateIgnoreDefaults.set(Array(newValue), forKey: Self.ignoreDefaultsKey) }
    }

    /// Marks a group as intentionally separate: removes it now and remembers it so future scans
    /// don't re-flag the same cluster. Registers one ⌘Z step and says so in an undoable banner;
    /// ``forgetKeptSeparateGroups(under:)`` brings back older ones.
    public func keepDuplicateGroupSeparate(_ group: DuplicateGroup) {
        var keys = ignoredDuplicateKeys
        keys.insert(group.ignoreKey)
        ignoredDuplicateKeys = keys
        // By cluster, not by `id`: a redo after a rescan holds the group under its old id, and
        // the card on screen for the same copies carries the new one.
        let index = duplicateGroups.firstIndex { $0.ignoreKey == group.ignoreKey }
        let root = duplicateScanRoot
        duplicateGroups.removeAll { $0.ignoreKey == group.ignoreKey }
        Logger.shared.info("Duplicates: kept “\(group.name)” separate")
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreKeptSeparateGroup(group, at: index, scannedFrom: root)
        }
        undoManager?.setActionName("Keep Separate")
        // "While its copies stay put": the key is the cluster's exact copy paths, so a copy
        // added, moved or removed makes a different group, which a scan flags.
        banner = .success("Kept “\(group.name)” separate — it won’t be flagged again while its copies stay put.",
                          undoable: undoManager != nil)
    }

    /// ⌘Z for ``keepDuplicateGroupSeparate(_:)``: forgets the key, puts the card back, and
    /// registers the redo. The card goes back only into the results it came from, and not when they
    /// already show the same cluster: ids are minted per scan, so a rescan or another folder's scan
    /// would get a duplicate or a stray card. The key is forgotten either way, so the next scan
    /// flags it again.
    func restoreKeptSeparateGroup(_ group: DuplicateGroup, at index: Int?,
                                  scannedFrom root: String?) {
        var keys = ignoredDuplicateKeys
        keys.remove(group.ignoreKey)
        ignoredDuplicateKeys = keys
        if Self.restoresKeptSeparateCard(group, keptFrom: root, currentRoot: duplicateScanRoot,
                                         showing: duplicateGroups) {
            duplicateGroups.insert(group, at: min(index ?? duplicateGroups.count, duplicateGroups.count))
        }
        Logger.shared.info("Duplicates: “\(group.name)” is flagged again (undo)")
        // The "Kept … separate [Undo]" banner is stale the moment this runs: its Undo would pop
        // the redo registered next, or whatever sits below it.
        invalidateUndoableBanner()
        undoManager?.registerUndo(withTarget: self) { target in
            target.keepDuplicateGroupSeparate(group)
        }
        undoManager?.setActionName("Keep Separate")
    }

    /// Whether undoing *Keep separate* puts the card back: only into the scan it was kept from, and
    /// only when that scan is not already showing the same cluster under a newer id.
    nonisolated static func restoresKeptSeparateCard(
        _ group: DuplicateGroup, keptFrom root: String?, currentRoot: String?,
        showing groups: [DuplicateGroup]) -> Bool {
        guard root != nil, root == currentRoot else { return false }
        return !groups.contains { $0.ignoreKey == group.ignoreKey }
    }

    /// Whether a kept-separate key belongs to the folder at `root`: every copy in it sits below
    /// the root. Read off the key alone — ``DuplicateGroup/ignoreKey`` is the cluster's sorted
    /// absolute copy paths — so a sibling sharing a name prefix (`/a/bb` beside `/a/b`) is not
    /// "under" it.
    nonisolated static func keptSeparateKey(_ key: String, isUnder root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let paths = key.split(separator: "\n")
        return !paths.isEmpty && paths.allSatisfy { $0.hasPrefix(prefix) }
    }

    /// The kept-separate keys a scan of `root` could flag: what the lens's *Show them again* counts
    /// and forgets. Empty without a root.
    ///
    /// Only keys under `root`, since the set spans every provider and folder at once. And not those
    /// whose copy the last scan found gone: a key is the cluster's exact copy paths, so it can
    /// never match again. Read from ``keptSeparateGoneKeys``, which the scan fills from its own
    /// tree, because this is counted from the lens's body, where a stat per copy would be
    /// main-thread disk I/O.
    public func keptSeparateKeys(under root: String?) -> Set<String> {
        keptSeparateKeysInFolder(root).subtracting(keptSeparateGoneKeys)
    }

    /// The keys under `root` with a copy the scan's tree does not hold. A copy outside every walk
    /// (an ignored subtree) reads as gone too, which is the same answer: no scan of `root` can
    /// flag that group.
    nonisolated static func goneKeptSeparateKeys(_ keys: Set<String>, under root: String,
                                                 tree: [FileNode]) -> Set<String> {
        let under = keys.filter { keptSeparateKey($0, isUnder: root) }
        guard !under.isEmpty else { return [] }
        var present = Set<String>()
        func walk(_ nodes: [FileNode]) {
            for node in nodes {
                present.insert(node.id)
                if let children = node.children { walk(children) }
            }
        }
        walk(tree)
        return under.filter { key in key.split(separator: "\n").contains { !present.contains(String($0)) } }
    }

    /// Every kept-separate key below `root`, its copies on disk or not.
    private func keptSeparateKeysInFolder(_ root: String?) -> Set<String> {
        guard let root else { return [] }
        return ignoredDuplicateKeys.filter { Self.keptSeparateKey($0, isUnder: root) }
    }

    /// Forgets the groups kept separate below `root`, so the next scan of it flags them again —
    /// the lens's *Show them again*. Keys for other folders stay. Says how many in a banner, and
    /// returns the count.
    @discardableResult
    public func forgetKeptSeparateGroups(under root: String?) -> Int {
        // Forgets the keys whose copies are gone as well — they can never match again — but counts
        // and promises only the ones a scan could bring back.
        let all = keptSeparateKeysInFolder(root)
        let forgotten = keptSeparateKeys(under: root)
        guard !all.isEmpty else { return 0 }
        ignoredDuplicateKeys = ignoredDuplicateKeys.subtracting(all)
        Logger.shared.info("Duplicates: forgot \(forgotten.count) group(s) kept separate under "
                           + "\((root.map { ($0 as NSString).lastPathComponent }) ?? "?")"
                           + (all.count > forgotten.count ? ", and \(all.count - forgotten.count) whose copies are gone" : ""))
        guard !forgotten.isEmpty else { return 0 }
        banner = .success(Self.keptSeparateForgottenSentence(forgotten.count))
        return forgotten.count
    }

    /// How many groups are kept separate, in every folder: what Settings ▸ Organize ▸ Duplicates
    /// counts. Keys whose copies have gone count too, since the scan alone knows which they are.
    public var keptSeparateGroupCount: Int { ignoredDuplicateKeys.count }

    /// Forgets every group kept separate, in every folder, so each scan flags them again if they
    /// are still duplicates: Settings' *Show Again…*, which asks first. Returns how many.
    @discardableResult
    public func forgetAllKeptSeparateGroups() -> Int {
        let count = ignoredDuplicateKeys.count
        guard count > 0 else { return 0 }
        ignoredDuplicateKeys = []
        Logger.shared.info("Duplicates: forgot all \(count) group(s) kept separate")
        return count
    }

    /// "Any still duplicates", because a group kept separate is flagged again only if its copies
    /// still match — one edited since is not a duplicate any more, and nothing comes back.
    nonisolated static func keptSeparateForgottenSentence(_ count: Int) -> String {
        count == 1 ? "Forgot 1 group kept separate — this scan flags it again if it’s still a duplicate."
            : "Forgot \(count.formatted()) groups kept separate — this scan flags any that are still duplicates."
    }

    /// Clears every lens result belonging to the provider being switched away from, so stale
    /// results can never be shown, or acted on, under another provider.
    ///
    /// One list in one place: a lens missing here keeps the previous account's finding on screen,
    /// and acting on it would use the old provider's root and rules while the window shows another.
    /// A new lens is added here, and `everyLensResultIsClearedByAProviderSwitch` fails until it is.
    public func clearLensResultsForProviderSwitch() {
        clearDuplicates()
        clearFiling()
        clearAutomationDryRun()
        clearNameScan()
        // The rename backlog needs no line of its own: `clearFiling()` drops it, as that scan's
        // finding. Storage is read-only, but its report would still name the old root and vouch for
        // it with a "Scanned 2h ago" marker.
        clearStorageLens()
    }

    public func clearDuplicates() {
        // Cancel any in-flight scan so it can't republish the old provider's results after the
        // switch (findDuplicates checks Task.isCancelled before it assigns duplicateGroups).
        duplicateScanTask?.cancel()
        duplicateGroups = []
        duplicateScanRoot = nil
        duplicateScanSkips = DuplicateScanSkips()
        keptSeparateGoneKeys = []
        hasFoundDuplicates = false
        // Re-arm the auto-rescan: switching back to this provider should behave like a fresh
        // launch, exactly as Storage's restore does after `clearStorageLens()`.
        duplicateAutoRescanAttempted = nil
    }

    // MARK: Resolve

    /// Whether a group's keeper is still where, and what, the scan saw. Groups are point-in-time
    /// snapshots: if the keeper was deleted, moved or rewritten between scan and click, trashing
    /// the "redundant" copies would trash the last copies of its original content. So it is
    /// re-checked at resolve time, not just scan time.
    ///
    /// A file keeper is checked by size and modification date (`copyDriftedInPlace`). A folder
    /// keeper is existence-only here and gets its content check from `driftedFolderInGroup`, which
    /// the group resolve and the batch run alongside this. The merge path has neither: its keeper
    /// is meant to change, and its own trash step re-walks the source.
    private func keeperStillExists(_ group: DuplicateGroup) -> Bool {
        copyStillExists(group.keeper)
    }

    /// ``keeperStillExists(_:)`` for any copy, so the pair resolve
    /// (``resolveDuplicateCopy(_:keeper:)``) asks the keeper question in the same spelling as the
    /// group resolve. Two copies of a safety predicate agree only by luck.
    private func copyStillExists(_ copy: DuplicateCopy) -> Bool {
        guard fileManager.fileExists(atPath: copy.path) else { return false }
        return !copyDriftedInPlace(copy)
    }

    /// Whether `copy` is still on disk but no longer the size or modification date the scan
    /// recorded: an in-place rewrite (a re-export, a provider re-download, an edit) under the same
    /// path.
    ///
    /// Shared by the keeper check and the removal-candidate check, because a group is safe to act
    /// on only when neither end drifted. A vanished copy is not drift: nothing is left to trash,
    /// and `dropFullyRemovedGroups` accounts for it. An unstattable file counts as drifted, which
    /// refuses.
    ///
    /// Size and mtime, because size alone passes a same-length rewrite (`MergeFileSnapshot` holds
    /// both for the same reason). Known blind spots: coarse volume timestamps (1–2 s on FAT and
    /// some SMB), writers that restore the old mtime (`touch -r`, `rsync --times`, some cloud
    /// daemons), and xattr or Finder-tag edits, which move only ctime (trashing then loses the
    /// tags, not the bytes). Catching those would need a content re-hash at resolve time.
    ///
    /// Folders always answer false here; their per-file check is ``folderDriftedInPlace(_:)``.
    private func copyDriftedInPlace(_ copy: DuplicateCopy) -> Bool {
        guard fileManager.fileExists(atPath: copy.path) else { return false }
        // Directories are answered by ``folderDriftedInPlace(_:)``, and only on the paths that
        // trash (`driftedFolderInGroup`). Not here, because the merge path's keeper check also
        // comes through this member, and a merge is meant to change its keeper: it plans against a
        // fresh walk and re-verifies the source just before trashing, so holding its keeper to the
        // scan would refuse nearly every merge of a folder in use.
        guard !copy.isDirectory else { return false }
        guard let attrs = try? fileManager.attributesOfItem(atPath: copy.path) else { return true }
        let currentDate = attrs[.modificationDate] as? Date
        let currentSize = (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int)
        // Refuse only on a known mismatch: a real file always reports its size, so a drifted copy
        // is caught; if size is missing, fall back to the existence check rather than over-refuse.
        if let currentSize, currentSize != copy.size { return true }
        // Same rule for the date: compare it when both ends have one, rather than refusing every
        // group whose scan recorded no date.
        if let recorded = copy.modificationDate, let currentDate, recorded != currentDate { return true }
        return false
    }

    /// Whether a folder copy no longer holds what the scan measured, per entry, against the
    /// ``FolderContentSnapshot`` the scan recorded on it. Uses the one shared re-walk
    /// (``folderContentsMatchScan(path:snapshot:fileManager:)``) the Compare review's gate also
    /// uses, so the two destructive paths can't differ in what they check. An extra file, a missing
    /// file, a kind change and a same-length rewrite all read as drift.
    ///
    /// Anything that can't be re-walked completely, and a copy with no snapshot, counts as drifted,
    /// which refuses: a partial walk can't prove a folder unchanged. The scan records nil for a
    /// subtree it couldn't fully read, so callers word that refusal as "couldn't be fully checked"
    /// rather than "changed"; a rescan of the same tree records nil again.
    ///
    /// Costs one recursive walk per folder copy at the destructive click, the price of never
    /// trashing the last copy of a folder's contents.
    private func folderDriftedInPlace(_ copy: DuplicateCopy) async -> Bool {
        !(await Self.folderContentsMatchScan(path: copy.path, snapshot: copy.contentSnapshot,
                                             fileManager: fileManager))
    }

    /// Re-walks `path` and answers what the scan would see there now, with the scan's own
    /// conventions: the same tree walk (`buildTree`, off the main actor), ignored names and symlink
    /// handling. Nil when the walk couldn't cover the whole subtree: a partial walk is not a
    /// baseline.
    ///
    /// Public alongside ``folderContentsMatchScan(path:snapshot:fileManager:)`` so the app target
    /// can build and compare snapshots; the engine's own baselines are recorded by the scan.
    public nonisolated static func folderContentSnapshot(
        ofPath path: String, ignoredNames: Set<String>, fileManager: FileManaging
    ) async -> FolderContentSnapshot? {
        let tree = await buildTree(url: URL(fileURLWithPath: path), sortOption: .name,
                                   fileManager: fileManager, maxDepth: nil)
        return FolderContentSnapshot(walkedChildren: tree, ignoredNames: ignoredNames)
    }

    /// The one folder drift gate, shared by every path that destroys a folder copy on a scan-time
    /// claim: the engine's group and batch resolves (via `folderDriftedInPlace`) and the Compare
    /// review's "Trash right copy" (via `DuplicateReviewCoordinator`). Re-walks `path` with the
    /// conventions `snapshot` was recorded under and compares per entry. Any walk failure,
    /// unreadable descendant, extra or missing entry, kind change or size/mtime mismatch answers
    /// false, as does a nil `snapshot`, and false refuses. Callers word the two apart: a mismatch
    /// is "changed since it was scanned", while a nil snapshot means the scan couldn't fully read
    /// the subtree.
    public nonisolated static func folderContentsMatchScan(
        path: String, snapshot: FolderContentSnapshot?, fileManager: FileManaging
    ) async -> Bool {
        guard let snapshot else { return false }
        guard let current = await folderContentSnapshot(ofPath: path,
                                                        ignoredNames: snapshot.ignoredNames,
                                                        fileManager: fileManager) else { return false }
        return current.entries == snapshot.entries
    }

    /// The first folder in `group`, keeper or removal candidate, whose contents no longer match the
    /// scan, or nil. Both ends, and only on the paths that trash: the keeper's loss makes a
    /// "redundant" copy the last one, and a candidate's gain is content nothing else has. The merge
    /// path doesn't come here (`copyDriftedInPlace`).
    ///
    /// The keeper is re-walked last. Each walk takes real time (~0.7 s per 40k-node folder) and a
    /// verdict ages from when it is formed; walked first, the keeper could be edited during the
    /// candidates' walks unseen. Last, its verdict is the freshest when the caller acts.
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

    /// The copies this group would trash that no longer hold the bytes the scan grouped. The keeper
    /// check covers what is kept; this covers what is destroyed. Results outlive the scan for the
    /// whole session, and a copy rewritten in place since is no longer a copy: trashing it destroys
    /// the only instance of its new content, and on a volume with no Trash `deleteItems` escalates
    /// to a permanent delete. Same refusal shape as the merge path's `mergeSourceDrifted`.
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
            // A group with nothing to remove is not resolved: `allSatisfy` on an empty list is
            // true, which would drop it and credit its bytes as reclaimed. Reachable when re-aiming
            // the keeper of a folder-protected group leaves every removal candidate protected.
            let paths = group.recommendedRemovalPaths
            return !paths.isEmpty && paths.allSatisfy { !fileManager.fileExists(atPath: $0) }
        }
        let doneIDs = Set(done.map { $0.id })
        duplicateGroups.removeAll { doneIDs.contains($0.id) }
        return done
    }

    /// Why the last-moment removal gate refused a group. Three kinds because the three refusals
    /// make different claims — see `resolveDuplicateGroup`'s banner split.
    enum DuplicateRemovalRefusalKind: Sendable {
        /// Something in the group measurably changed after the scan.
        case drifted
        /// A folder copy carries no scan baseline, so nothing can be proven either way.
        case missingBaseline
        /// A copy to remove is, or holds, the copy another listed group keeps. Nothing changed: the
        /// keepers moved under it, so "changed since the scan" would be false.
        case holdsKeeper
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

    /// The duplicates flows' `removalGate` body: re-runs the full drift verdict (keeper, file
    /// candidates, folder re-walks) for every group among `paths`, and returns the paths of the
    /// groups that no longer hold. `deleteItems` calls it when the serialized operation starts (the
    /// queue wait can be long) and again after a confirmed permanent delete (the dialog is
    /// user-paced and what follows is unrecoverable): the two windows the callers' own pre-checks
    /// can't cover.
    ///
    /// Refusals are logged here, per group, with the keeper's and the culprit's paths, so the
    /// single resolve and the batch report alike in `~/sync-cloud.log` and a refusal is never
    /// silent.
    func refuseDriftedDuplicateRemovals(_ paths: [String], groups: [DuplicateGroup],
                                        refusals: DuplicateRemovalRefusals) async -> Set<String> {
        var refusedPaths = Set<String>()
        // Keyed by `canonicalRemovalPath`, answered in the caller's own spelling. The
        // post-confirmation call is fed URL round-tripped strings, and matching raw would come back
        // empty, skip the group, and leave it unverified right before a permanent delete. See
        // `FileSyncManager.canonicalRemovalPath`.
        var askedByKey: [String: Set<String>] = [:]
        for p in paths { askedByKey[Self.canonicalRemovalPath(p), default: []].insert(p) }
        var attributed = Set<String>()
        // Every listed group's keeper as it stands now, including keepers picked by hand (which the
        // scan's own protection can't see), and every folder above one, built once so the check
        // below is one lookup per copy.
        let holdingKeepers = Self.pathsHoldingKeepers(
            (duplicateGroups + groups).map { Self.canonicalRemovalPath($0.keeper.path) })
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
            } else if let holder = group.redundantCopies.first(where: { copy in
                let key = Self.canonicalRemovalPath(copy.path)
                return groupKeys.contains(key) && holdingKeepers.contains(key)
            }) {
                // A copy that is, or holds, another group's keeper is never removed. The scan
                // protects such folders only against the keepers it chose, and a keeper picked by
                // hand in one group can sit inside another group's removal. A rescan recomputes the
                // protection.
                kind = .holdsKeeper
                culprit = holder
            }
            guard let kind, let culprit else { continue }
            refusedPaths.formUnion(groupPaths)
            refusals.record(group.id, kind)
            switch kind {
            case .missingBaseline:
                Logger.shared.warning("Duplicates: refused to remove copies of “\(group.keeper.name)” (keeper \(group.keeper.path)) at the last check before removal — “\(culprit.name)” (\(culprit.path)) has no scan baseline, so it can't be proven unchanged")
            case .drifted:
                Logger.shared.warning("Duplicates: refused to remove copies of “\(group.keeper.name)” (keeper \(group.keeper.path)) at the last check before removal — “\(culprit.name)” (\(culprit.path)) changed after the scan")
            case .holdsKeeper:
                Logger.shared.warning("Duplicates: refused to remove copies of “\(group.keeper.name)” (keeper \(group.keeper.path)) at the last check before removal — “\(culprit.name)” (\(culprit.path)) is or holds the copy another group keeps; rescan to recompute which copies are safe to remove")
            }
        }
        // Fail closed. Anything left over belongs to none of the groups this gate was built for, so
        // nothing has re-verified it, and the gate answers for everything about to be destroyed.
        // Unreachable from the shipped callers (each passes its own groups'
        // `recommendedRemovalPaths`, and `deleteItems` only prunes that list), and logged, because
        // reaching it means a caller wired the gate wrong.
        let unattributed = Set(paths).subtracting(attributed)
        if !unattributed.isEmpty {
            Logger.shared.warning("Duplicates: refused \(unattributed.count) path(s) at the last check before removal because they belong to none of the groups being verified — \(unattributed.sorted().joined(separator: ", "))")
            refusedPaths.formUnion(unattributed)
        }
        return refusedPaths
    }

    /// Every path that is, or holds, one of `keepers`: each keeper and every prefix of it ending
    /// before a `/`. Built once per gate run, as the scan's `recordAncestors` builds its own,
    /// because asking every keeper about every copy is O(copies × keepers) on the main actor
    /// (seconds for a few thousand groups). Walked from the longest prefix down, stopping at the
    /// first already present: whoever added it also added every shorter one.
    nonisolated static func pathsHoldingKeepers(_ keepers: [String]) -> Set<String> {
        var out = Set<String>()
        for keeper in keepers {
            out.insert(keeper)
            var end = keeper.endIndex
            while let slash = keeper[..<end].lastIndex(of: "/"),
                  out.insert(String(keeper[..<slash])).inserted {
                end = slash
            }
        }
        return out
    }

    /// The gate closure `resolveDuplicateGroup` and `applyRecommendedDuplicates` hand to
    /// `deleteItems`, over the given groups. `self` is captured weakly, and a torn-down manager
    /// refuses everything: "nothing re-verified this" must never mean "this may be destroyed".
    /// Unreachable today (both callers hold `self` while awaiting); not `private`, so a test can
    /// reach that branch.
    func duplicateRemovalGate(groups: [DuplicateGroup],
                              refusals: DuplicateRemovalRefusals)
        -> @Sendable ([String]) async -> Set<String> {
        { [weak self] about in
            guard let self else { return Set(about) }
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
            // Logged with the path, as the gate and the batch log a keeper refusal.
            Logger.shared.warning("Duplicates: refused to remove copies of “\(group.keeper.name)” — the keeper (\(group.keeper.path)) is no longer what the scan saw")
            banner = .refusal("“\(group.keeper.name)” is no longer at its scanned location — rescan before removing its copies.", log: .loggedAtSite)
            return false
        }
        var driftedCopy = driftedRemovalCandidates(group).first
        if driftedCopy == nil { driftedCopy = await driftedFolderInGroup(group) }
        if let drifted = driftedCopy {
            // Two refusals, told apart: a folder with no baseline was never fully read by the scan,
            // so "changed since it was scanned" would claim a change nobody measured, and a rescan
            // would reproduce the nil. The refusal stands either way; only the wording changes.
            if drifted.isDirectory, drifted.contentSnapshot == nil {
                // "Unreadable, or nested too deep": the scan records nil for any subtree it
                // couldn't cover, which includes the walk's depth cap and its symlink-cycle guard.
                banner = .warning("“\(drifted.name)” couldn’t be fully checked against the scan — the scan couldn’t read all of it (unreadable, or nested too deep), so there’s no baseline to prove it unchanged. Review it manually before removing.", log: .loggedAtSite)
                Logger.shared.warning("Duplicates: refused to remove copies of “\(group.keeper.name)” (keeper \(group.keeper.path)) — “\(drifted.name)” (\(drifted.path)) has no scan baseline (its subtree wasn't fully coverable at scan time: unreadable, too deep, or a link cycle)")
            } else {
                banner = .warning("“\(drifted.name)” changed since it was scanned — it may no longer be a copy. Rescan before removing it.", log: .loggedAtSite)
                Logger.shared.warning("Duplicates: refused to remove copies of “\(group.keeper.name)” (keeper \(group.keeper.path)) — “\(drifted.name)” (\(drifted.path)) changed after the scan")
            }
            return false
        }
        let bytes = group.reclaimableBytes
        // These checks are the first verdict, not the last: `deleteItems` runs on the serialized op
        // queue (anything queued ahead runs first) and can hold a permanent-delete confirmation
        // open for as long as the user leaves it. The removal gate re-runs the full verdict when
        // the removal starts and again after a confirmed permanent delete, so the trash acts on the
        // freshest one. The batch and the Compare review pass the same kind of gate.
        let refusals = DuplicateRemovalRefusals()
        let outcome = await deleteItems(at: paths, fileManager: fileManager,
                                        removalGate: duplicateRemovalGate(groups: [group],
                                                                          refusals: refusals))
        let removed = outcome.removed
        // Refused whole at the last check: surface it with the same banner split as the
        // pre-checks above (the gate has already logged the specifics).
        if removed == 0, let kind = refusals.all[group.id] {
            switch kind {
            case .missingBaseline:
                banner = .refusal("A copy of “\(group.keeper.name)” couldn’t be fully checked against the scan — review it manually before removing.", log: .warn)
            case .drifted:
                banner = .refusal("A copy of “\(group.keeper.name)” changed since it was scanned — it may no longer be a copy. Rescan before removing it.", log: .warn)
            case .holdsKeeper:
                banner = .refusal("A copy of “\(group.keeper.name)” holds the copy another duplicate group keeps — rescan before removing it.", log: .warn)
            }
            return false
        }
        // Only drop the group and claim success if every copy actually left the disk — a declined,
        // failed, or cancelled trash must not vanish still-listed copies behind a false banner.
        guard removed > 0 else { return false }
        guard !dropFullyRemovedGroups(from: [group]).isEmpty else {
            if currentError == nil {
                banner = .warning("Removed \(removed) of \(paths.count) copies — the group stays listed until the rest are handled.", log: .warn)
                    .reporting(run: outcome.runId)
            }
            return false
        }
        if currentError == nil {
            // Promise ⌘Z only when the delete can be taken back. On a Trash-less volume the files
            // are gone and nothing was registered, so ⌘Z would undo whatever was on the stack
            // before.
            banner = .success("Reclaimed \(Self.formatBytes(bytes))", undoable: outcome.isUndoable).reporting(run: outcome.runId)
        }
        Logger.shared.info("Duplicates: removed \(paths.count) redundant copy(ies) of “\(group.keeper.name)”, reclaimed \(Self.formatBytes(bytes))")
        return true
    }

    // MARK: Resolve one copy (the Compare Copies pair verdict)

    /// Why a single-copy resolve refused, or that it may proceed. Produced by one routine
    /// (``assessDuplicatePair(copy:keeper:)``) for both the pre-check and the removal gate, so the
    /// two windows around a `deleteItems` can't disagree. Mirrors the Compare review's
    /// `ReviewedPairVerdict`, the same question asked from the app target.
    enum DuplicatePairVerdict: Sendable, Equatable {
        /// Both ends are still what the scan saw; the copy may be removed.
        case matches
        /// No live group holds both paths any more: a rescan replaced the results, so nothing here
        /// can be re-verified against a current grouping.
        case noLiveGroup
        /// The keeper is gone, or is no longer what the scan measured. Removing the other copy
        /// could take the last instance of the keeper's original content.
        case keeperDrifted(missingBaseline: Bool)
        /// The copy being removed changed after the scan — it is no longer provably a duplicate.
        case copyDrifted(missingBaseline: Bool)
        /// The copy is already off the disk. Not drift, and not a refusal: there is nothing to
        /// trash and nothing was lost.
        case copyVanished
        /// The pair names a `keeper` the live group isn't keeping, as when a three-copy group is
        /// compared pairwise and the group keeps the third. Both paths are current and unchanged;
        /// the claim is what is wrong, since the removal would be verified, and reported, against a
        /// keeper the group doesn't have.
        case keeperNotKept(groupKeeperName: String)
        /// Another group's decision holds the copy: it sits inside a folder another group keeps
        /// (``DuplicateCopy/isProtectedFromRemoval``), or it is, or holds, a group's current keeper
        /// (``removalHold(onCopyAt:keeping:)``). Not drift: the file is what the scan saw, but
        /// removing it would undo a decision made elsewhere in the same results.
        case copyHeld(DuplicateRemovalHold)
    }

    /// The whole verdict for one pair: is there still a live grouping for both paths, anything left
    /// to trash, may it be trashed, has it drifted, and last, is the keeper still what the scan
    /// measured.
    ///
    /// The live group is found by path, never by id: `DuplicateGroup.id` is a fresh `UUID` every
    /// scan, so an id held across a rescan names nothing (`DuplicateCompareContext` works the same
    /// way). No live group fails closed.
    ///
    /// Order matters. The disk check comes first: a copy already gone has nothing to lose, and
    /// asked after the keeper it could read as `keeperDrifted`. The keeper is measured last, as in
    /// ``driftedFolderInGroup``: a folder walk takes real time, and its verdict must be the
    /// freshest when `deleteItems` acts.
    func assessDuplicatePair(copy: DuplicateCopy, keeper: DuplicateCopy) async -> DuplicatePairVerdict {
        guard let live = liveGroup(holding: copy.path, and: keeper.path) else { return .noLiveGroup }
        // A vanished copy is not drift (as in `dropFullyRemovedGroups` and the Compare review's
        // `.deleteVanished`). `copyDriftedInPlace` answers false for a missing path, so ask
        // separately.
        guard fileManager.fileExists(atPath: copy.path) else { return .copyVanished }
        // The keeper must be the one the group keeps; the lookup above only asks that both paths
        // share a group. The surface no longer offers such a pair (`PairKeeperStanding`), but this
        // verb is `public` and a disabled button is not a rule. Refused, not redirected: quietly
        // acting on a different keeper is worse than not acting.
        guard live.keeper.path == keeper.path else {
            return .keeperNotKept(groupKeeperName: live.keeper.name)
        }
        // Read the hold from the live results, not the caller's snapshot: a rescan can protect a
        // copy by keeping its folder, or a keeper picked by hand on another card can sit inside it.
        // Both halves of the hold, as `removalHold` documents and the Compare review's Trash right
        // copy asks.
        //
        // After the disk check, which can say there is nothing to do, and before the drift
        // measurements, which a hold makes pointless.
        if let hold = removalHold(onCopyAt: copy.path, keeping: keeper.path) {
            return .copyHeld(hold)
        }
        // Spelled out rather than folded into a `guard`'s `&&`: an `await` may not appear in the
        // autoclosure operand of a short-circuiting operator.
        var copyHolds = !copyDriftedInPlace(copy)
        if copyHolds, copy.isDirectory { copyHolds = !(await folderDriftedInPlace(copy)) }
        guard copyHolds else {
            return .copyDrifted(missingBaseline: copy.isDirectory && copy.contentSnapshot == nil)
        }
        var keeperHolds = copyStillExists(keeper)
        if keeperHolds, keeper.isDirectory { keeperHolds = !(await folderDriftedInPlace(keeper)) }
        guard keeperHolds else {
            return .keeperDrifted(missingBaseline:
                fileManager.fileExists(atPath: keeper.path)
                    && keeper.isDirectory && keeper.contentSnapshot == nil)
        }
        return .matches
    }

    /// The live group holding both paths, or nil. Copies are compared by absolute path, the
    /// spelling `removeResolvedDuplicateCopy` matches on and the identity that survives a rescan.
    /// Two linear passes rather than a `Set`: the Compare overlay reads this on every render, and a
    /// group holds only a handful of copies.
    public func liveGroup(holding copyPath: String, and keeperPath: String) -> DuplicateGroup? {
        duplicateGroups.first { group in
            group.copies.contains { $0.path == copyPath }
                && group.copies.contains { $0.path == keeperPath }
        }
    }

    /// Posts the banner and the log line for a refusing pair verdict, in one place so the pre-check
    /// and the gate report alike; a copy the app offered to trash and then kept must say why in
    /// `~/sync-cloud.log` too. The folder refusals stay worded apart, as in
    /// `resolveDuplicateGroup`: a copy with no scan baseline was never fully read, so "changed"
    /// would claim what nobody measured.
    private func reportPairRefusal(_ verdict: DuplicatePairVerdict,
                                   copy: DuplicateCopy, keeper: DuplicateCopy) {
        switch verdict {
        case .matches, .copyVanished:
            break   // nothing to refuse
        case .noLiveGroup:
            banner = .refusal("The duplicate scan has moved on since these copies were compared — rescan before trashing “\(copy.name)”.", log: .loggedAtSite)
            Logger.shared.warning("Duplicates: refused to trash \(copy.path) — no current group holds it together with the keeper \(keeper.path), so the pair could not be re-verified")
        case .keeperDrifted(missingBaseline: true):
            banner = .refusal("“\(keeper.name)” couldn’t be fully checked against the scan — the scan couldn’t read all of it (unreadable, or nested too deep), so “\(copy.name)” can’t be proven redundant. Review them manually.", log: .loggedAtSite)
            Logger.shared.warning("Duplicates: refused to trash \(copy.path) — the scan recorded no baseline for the keeper \(keeper.path) (subtree unreadable, too deep, or a link cycle), so the copy is not provably redundant")
        case .keeperDrifted(missingBaseline: false):
            banner = .refusal("“\(keeper.name)” is no longer what the scan saw — rescan before trashing “\(copy.name)”.", log: .loggedAtSite)
            Logger.shared.warning("Duplicates: refused to trash \(copy.path) — the keeper \(keeper.path) is no longer what the scan saw, so the copy may be its last intact instance")
        case .copyDrifted(missingBaseline: true):
            banner = .refusal("“\(copy.name)” couldn’t be fully checked against the scan — the scan couldn’t read all of it (unreadable, or nested too deep), so it can’t be proven still a copy. Review it manually.", log: .loggedAtSite)
            Logger.shared.warning("Duplicates: refused to trash \(copy.path) — the scan recorded no baseline for it (subtree unreadable, too deep, or a link cycle), so it is not provably still a duplicate")
        case .copyDrifted(missingBaseline: false):
            banner = .refusal("“\(copy.name)” changed since it was scanned — it may no longer be a copy. Rescan before trashing it.", log: .loggedAtSite)
            Logger.shared.warning("Duplicates: refused to trash \(copy.path) — it changed after the scan, so it is no longer provably a duplicate")
        case .keeperNotKept(let groupKeeperName):
            banner = .refusal("This group is keeping “\(groupKeeperName)”, not “\(keeper.name)” — so “\(copy.name)” can’t be trashed against it here. Compare against the copy being kept, or resolve the whole group.", log: .loggedAtSite)
            Logger.shared.warning("Duplicates: refused to trash \(copy.path) — the removal named \(keeper.path) as the keeper, but the live group keeps a different copy, so nothing here was verified against the copy this group is actually keeping")
        case .copyHeld(let hold):
            let wording = Self.removalHoldWording(hold, name: copy.name, path: copy.path)
            banner = .refusal(wording.banner, log: .loggedAtSite)
            Logger.shared.warning(wording.log)
        }
    }

    /// Why a decision in the live results forbids removing one copy outright. Asked by the
    /// single-copy removals (the Compare Copies pair and the Compare review's "Trash right copy");
    /// the group flows have their own forms of both checks (`recommendedRemovalPaths` and the
    /// removal gate).
    public enum DuplicateRemovalHold: Sendable, Equatable {
        /// The copy sits inside a folder another group is keeping
        /// (``DuplicateCopy/isProtectedFromRemoval``).
        case insideKeptFolder
        /// The copy is, or holds, a listed group's current keeper: the removal gate's check, which
        /// sees a keeper picked by hand where the scan's protection can't.
        case holdsKeeper
        /// The copy is now the keeper of the group it was offered for removal from, picked by hand
        /// since (as the Compare review's right copy can be). Its own case because it isn't
        /// "another group": the advice is to compare the pair again, not to rescan.
        case isItsGroupsKeeper
    }

    /// The hold on the copy at `path`, read from the live results, since a rescan or a keeper
    /// re-pick can move them under a surface left open. A copy flagged protected in any group it
    /// sits in is held: the flag says where it lives, not which group asks.
    ///
    /// `keeperPath` names the copy the removal means to keep, which picks out the asking group: a
    /// copy that has since become that group's keeper reads `.isItsGroupsKeeper`, not "another
    /// group".
    public func removalHold(onCopyAt path: String, keeping keeperPath: String? = nil)
        -> DuplicateRemovalHold? {
        if duplicateGroups.contains(where: { group in
            group.copies.contains { $0.path == path && $0.isProtectedFromRemoval }
        }) {
            return .insideKeptFolder
        }
        if let keeperPath, liveGroup(holding: path, and: keeperPath)?.keeper.path == path {
            return .isItsGroupsKeeper
        }
        let keepers = Self.pathsHoldingKeepers(
            duplicateGroups.map { Self.canonicalRemovalPath($0.keeper.path) })
        return keepers.contains(Self.canonicalRemovalPath(path)) ? .holdsKeeper : nil
    }

    /// The banner and log line for a hold — one wording for every single-copy removal.
    nonisolated static func removalHoldWording(_ hold: DuplicateRemovalHold, name: String,
                                               path: String) -> (banner: String, log: String) {
        switch hold {
        case .insideKeptFolder:
            return ("“\(name)” sits inside a folder another duplicate group is keeping — removing it here would undo that. Resolve that group first.",
                    "Duplicates: refused to trash \(path) — it is inside a folder another group is keeping, which the recommended removal also excludes")
        case .holdsKeeper:
            return ("“\(name)” holds the copy another duplicate group keeps — rescan before removing it.",
                    "Duplicates: refused to trash \(path) — it is or holds the copy another group keeps; rescan to recompute which copies are safe to remove")
        case .isItsGroupsKeeper:
            return ("“\(name)” is this group’s keeper now, so it isn’t trashed here. Compare the copies again from the Duplicates card.",
                    "Duplicates: refused to trash \(path) — it was picked as its own group’s keeper after this removal was offered")
        }
    }

    /// Posts the banner and log line and returns true when a hold forbids removing the copy at
    /// `path`; false, posting nothing, when none does. `keeperPath` as in ``removalHold(onCopyAt:keeping:)``.
    @discardableResult
    public func refuseRemovalIfHeld(copyAt path: String, keeping keeperPath: String? = nil) -> Bool {
        guard let hold = removalHold(onCopyAt: path, keeping: keeperPath) else { return false }
        let wording = Self.removalHoldWording(hold, name: (path as NSString).lastPathComponent, path: path)
        banner = .refusal(wording.banner, log: .loggedAtSite)
        Logger.shared.warning(wording.log)
        return true
    }

    /// The gate ``resolveDuplicateCopy(_:keeper:)`` hands to `deleteItems`, over one pair. A named
    /// member, like ``duplicateRemovalGate(groups:refusals:)``, so a test can reach the nil-`self`
    /// branch, which the call site never does. That branch must refuse: `return []` would let a
    /// file be destroyed with nothing re-verified.
    func duplicatePairRemovalGate(copy: DuplicateCopy, keeper: DuplicateCopy)
        -> @Sendable ([String]) async -> Set<String> {
        { [weak self] about in
            // Fail CLOSED on a torn-down manager, for the reason `duplicateRemovalGate` says:
            // "nothing has re-verified this" and "this may be destroyed" must not be one outcome.
            guard let self else { return Set(about) }
            let verdict = await self.assessDuplicatePair(copy: copy, keeper: keeper)
            switch verdict {
            case .matches, .copyVanished:
                return []
            case .noLiveGroup, .keeperDrifted, .copyDrifted, .copyHeld, .keeperNotKept:
                await self.reportPairRefusal(verdict, copy: copy, keeper: keeper)
                // Refuse what the gate was ASKED about, in the caller's own spelling: the
                // post-confirmation pass is fed URL round-tripped paths, and a refusal that
                // cannot be matched back is a banner posted over a file destroyed anyway.
                return Set(about)
            }
        }
    }

    /// Trashes one copy of a duplicate group, keeping `keeper`: the verdict the Compare Copies
    /// surface reaches on a pair. ``resolveDuplicateGroup(_:)`` can't stand in: it trashes every
    /// redundant copy, which on a three-copy group compared pairwise destroys two files where the
    /// user decided about one.
    ///
    /// Uses the shared machinery: the same ``assessDuplicatePair(copy:keeper:)`` verdict before and
    /// inside the removal gate, the same `deleteItems` path, the same conditional ⌘Z promise
    /// (`DeleteOutcome.isUndoable` is false on a Trash-less volume), and the same in-memory update
    /// through ``removeResolvedDuplicateCopy(atPath:)``, which handles a copy in two groups.
    ///
    /// Returns true only when the copy actually left the disk.
    @discardableResult
    public func resolveDuplicateCopy(_ copy: DuplicateCopy, keeper: DuplicateCopy) async -> Bool {
        guard copy.path != keeper.path else {
            Logger.shared.warning("Duplicates: refused to trash \(copy.path) — it IS the keeper")
            return false
        }
        let verdict = await assessDuplicatePair(copy: copy, keeper: keeper)
        switch verdict {
        case .noLiveGroup, .keeperDrifted, .copyDrifted, .copyHeld, .keeperNotKept:
            reportPairRefusal(verdict, copy: copy, keeper: keeper)
            return false
        case .copyVanished:
            // Nothing to trash and nothing lost — say so, and take the copy out of the list so the
            // surface and the card stop offering an act with no subject.
            Logger.shared.info("Duplicates: \(copy.path) is already gone — nothing to trash")
            removeResolvedDuplicateCopy(atPath: copy.path)
            banner = .success("“\(copy.name)” was already gone — nothing to trash.")
            return false
        case .matches:
            break
        }
        // This verdict is the first check, not the last: `deleteItems` runs on the serialized op
        // queue and can hold a permanent-delete confirmation open indefinitely. The gate re-runs
        // the same assessment when the removal starts and after a confirmed permanent delete,
        // refusing with the same banner and log line. `fileManager` is passed so the verdict and
        // the removal ask one filesystem.
        let bytes = copy.size
        let outcome = await deleteItems(at: [copy.path], fileManager: fileManager,
                                        removalGate: duplicatePairRemovalGate(copy: copy,
                                                                              keeper: keeper))
        guard outcome.removed > 0 else { return false }
        // Say which way it went: on a Trash-less volume (exFAT, most SMB shares) the copy was
        // destroyed, and "trashed" would send a log reader to a Trash that never got it. Ask the
        // permanent count, not the trashed one: a copy the Trash took without a location counts in
        // neither, and is in the Trash.
        Logger.shared.info(outcome.permanentlyDeleted == 0
            ? "Duplicates: trashed the compared copy \(copy.path), keeping \(keeper.path), reclaimed \(Self.formatBytes(bytes))"
            : "Duplicates: permanently deleted the compared copy \(copy.path), keeping \(keeper.path), reclaimed \(Self.formatBytes(bytes))")
        removeResolvedDuplicateCopy(atPath: copy.path)
        if currentError == nil {
            banner = .success("Reclaimed \(Self.formatBytes(bytes))", undoable: outcome.isUndoable).reporting(run: outcome.runId)
        }
        return true
    }

    /// Every group eligible for the recommended batch, unfiltered — the honest "all of them"
    /// scope. The Duplicates lens deliberately does NOT pass this: its button scopes to whatever
    /// the search left on screen (see `applyRecommendedDuplicates`).
    public var recommendedDuplicateGroups: [DuplicateGroup] {
        duplicateGroups.filter { $0.isRecommendedForBatch }
    }

    /// Applies the recommended removal to the batch-eligible (byte-identical) groups in `scope`.
    /// Other kinds of group are left for a per-group look.
    ///
    /// `scope` is required, and that is the safety property: a search can narrow the list, and a
    /// button reading "Trash all 3" must act on those 3 rows, never on groups the user can't see.
    /// The count on the button and the array iterated here are one value, passed in. Each group's
    /// own eligibility and keeper checks still apply, so a caller can't pass an ineligible group
    /// through.
    public func applyRecommendedDuplicates(_ scope: [DuplicateGroup]) async {
        let elapsed = Elapsed()
        let eligible = scope.filter { $0.isRecommendedForBatch }
        // The batch has two phases, and the shape is load-bearing.
        //
        // Phase 1 verifies every group up front, with no undo group open and nothing deleted.
        // Refusals are decided and logged per group here, before anything destructive starts.
        //
        // Phase 2 is one `deleteItems` call for every surviving path, which gives:
        //   - One restore-undo registration, so ⌘Z reverses the whole batch as one step, with no
        //     `beginUndoGrouping` held open. Undo grouping is manager-global: a group held open
        //     across the folder re-walks and the delete (which can hold a modal dialog) would
        //     swallow any unrelated operation registering meanwhile, and undoing the batch would
        //     reverse that too. `FileSyncManager+BulkSync.swift` states the same rule.
        //   - One permanent-delete confirmation on a Trash-less volume, not one per group.
        //   - The removal gate re-checks the phase-1 verdicts when the removal starts and after a
        //     confirmed permanent delete, as `resolveDuplicateGroup` and the Compare review do, so
        //     neither the queue wait nor the dialog can stale a verdict. A group that drifts in
        //     either window is refused and logged; its copies stay on disk and it stays listed.
        //   - Accepted residual: the gate runs once over the whole list, not per group right before
        //     its own trash, so a late group is removed a while after its check. Everything between
        //     gate and removal is machine-paced inside one serialized operation, while the two
        //     windows the gate covers are user-paced (`deleteItems`' `removalGate` parameter has
        //     the reasoning).
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
            // "Nothing to remove" is not "something changed". Drift is one way to get an empty
            // batch; the other is a group that passed the checks with every removal candidate
            // folder-protected (reachable by re-aiming the keeper of a folder-protected group). A
            // rescan finds the same thing there, so advising one would send the user round a loop.
            if verifiedButEmpty.isEmpty, !eligible.isEmpty {
                // Every eligible group was refused by the checks. When every refusal was a folder
                // with no baseline, "changed since they were scanned" asserts a change nobody
                // measured — and a rescan reproduces the nil baseline, not a fresh one.
                banner = .warning(Self.allRefusedBatchBanner(refused: refused,
                                                             missingBaseline: refusedForMissingBaseline,
                                                             holdsKeeper: 0), log: .warn)
            } else if !verifiedButEmpty.isEmpty {
                // Name the cause only where it has been checked. Protection is the reachable
                // reason, but an empty removal list is also what a group with no redundant copies
                // produces, and this method is `public` over an unvalidated `DuplicateGroup`, so
                // "every copy is protected" is said only when it is true.
                let allProtected = verifiedButEmpty.allSatisfy { group in
                    !group.redundantCopies.isEmpty
                        && group.redundantCopies.allSatisfy(\.isProtectedFromRemoval)
                }
                let subject = verifiedButEmpty.count == 1 ? "this group" : "these groups"
                banner = .warning(allProtected
                    ? "Nothing to remove — every copy in \(subject) is protected."
                    : "Nothing to remove — \(subject) offered no copies to remove.", log: .warn)
            }
            return
        }

        // Phase 2: one delete for the whole batch.
        //
        // Record which paths were on disk just before the delete. A copy already removed externally
        // still lets its group resolve (every removal path is gone), but this run freed nothing for
        // it, so its bytes must not count toward the banner's total. The drift checks don't catch
        // this: `copyDriftedInPlace` returns false for a path that no longer exists, so a gone
        // copy is explicitly not drifted.
        let allPaths = survivors.flatMap { $0.recommendedRemovalPaths }
        let presentBefore = Set(allPaths.filter { fileManager.fileExists(atPath: $0) })
        let refusals = DuplicateRemovalRefusals()
        let outcome = await deleteItems(at: allPaths, fileManager: fileManager,
                                        removalGate: duplicateRemovalGate(groups: survivors,
                                                                          refusals: refusals))
        // Fold the gate's refusals into the batch accounting — the gate logged each one already.
        let gateRefused = refusals.all
        // A group refused by the post-confirmation gate may already be partly removed: both gate
        // calls share one refusals object, and the second runs after the first pass has trashed
        // what it could. It stays listed (`dropFullyRemovedGroups`), but the banner must not call
        // it "left alone". The disk is the ground truth.
        let survivorsByID = Dictionary(survivors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let refusedAfterPartialRemovalIDs = Set(gateRefused.keys.filter { id in
            guard let group = survivorsByID[id] else { return false }
            return group.recommendedRemovalPaths.contains {
                presentBefore.contains($0) && !fileManager.fileExists(atPath: $0)
            }
        })
        refused += gateRefused.count
        refusedForMissingBaseline += gateRefused.filter {
            $0.value == .missingBaseline && !refusedAfterPartialRemovalIDs.contains($0.key)
        }.count
        // Phase 1 never refuses for this — only the gate sees the keepers as they stand now.
        let refusedForHoldingKeeper = gateRefused.filter {
            $0.value == .holdsKeeper && !refusedAfterPartialRemovalIDs.contains($0.key)
        }.count
        let refusedAfterPartialRemoval = refusedAfterPartialRemovalIDs.count
        if refusedAfterPartialRemoval > 0 {
            Logger.shared.info("Duplicates: \(refusedAfterPartialRemoval) group(s) were refused at the last check after part of them had already been removed — they stay listed, and the copies already trashed stay trashed")
        }

        guard outcome.removed > 0 else {
            // Nothing left the disk. A decline posted `deleteItems`' own "Kept those items"
            // banner; a batch the gate refused wholesale gets the same honesty split as an
            // all-refused phase 1.
            Logger.shared.info("Duplicates: the batch removed nothing — \(refused) group(s) refused, \(outcome.declined) permanent delete(s) declined")
            if outcome.declined == 0, gateRefused.count == survivors.count, !gateRefused.isEmpty {
                banner = .warning(Self.allRefusedBatchBanner(refused: refused,
                                                             missingBaseline: refusedForMissingBaseline,
                                                             holdsKeeper: refusedForHoldingKeeper), log: .warn)
            }
            return
        }
        let done = dropFullyRemovedGroups(from: survivors)
        // Group-level, because `reclaimableBytes` is a group-level figure from the scan: a group
        // partly gone beforehand still credits its whole number. Only a group removed entirely by
        // something else is left out of the total.
        let credited = done.filter { !Set($0.recommendedRemovalPaths).isDisjoint(with: presentBefore) }
        let bytes = credited.reduce(0) { $0 + $1.reclaimableBytes }
        Logger.shared.info("Duplicates: applied recommended removal to \(done.count) of \(eligible.count) group(s), reclaimed \(Self.formatBytes(bytes)) (\(elapsed.text))")
        // The batch stopping short of what was on disk is a state the log must account for — a
        // declined permanent delete, a cancelled dialog, a gate refusal or a failure all leave
        // copies behind that the scan said were removable.
        if outcome.removed < presentBefore.count {
            Logger.shared.info("Duplicates: the batch stopped short — removed \(outcome.removed) of \(presentBefore.count) copies (\(outcome.declined) declined, \(outcome.refusedByGate) refused at the last check); the remaining groups stay listed")
        }
        if currentError == nil {
            // `DeleteOutcome`'s own rule: any permanent delete — or any copy trashed with no
            // location — anywhere in the batch poisons the offer, because the one restore-undo can
            // only bring back the copies whose Trash location is known.
            let isUndoable = outcome.isUndoable
            if done.count == eligible.count, refused == 0, outcome.declined == 0 {
                banner = .success("Reclaimed \(Self.formatBytes(bytes)) from \(done.count) group\(done.count == 1 ? "" : "s")",
                                  undoable: isUndoable).reporting(run: outcome.runId)
            } else {
                // Partial (refused groups, a declined fallback, a cancelled dialog): claim only
                // what landed, and name what was refused rather than folding it into "the rest stay
                // listed". Pass `undoable:` too: `invalidateUndoableBanner` reads the flag, not the
                // sentence, to retire the offer when the undo stack moves on, or the Undo button
                // would later reverse the wrong step. Severity and undoability are separate, which
                // is why `.warning` takes the parameter.
                var clauses: [String] = []
                let drifted = refused - refusedForMissingBaseline - refusedForHoldingKeeper
                    - refusedAfterPartialRemoval
                if refusedAfterPartialRemoval > 0 {
                    // Deliberately NOT "left alone": part of this group is already in the Trash.
                    clauses.append("\(refusedAfterPartialRemoval) group\(refusedAfterPartialRemoval == 1 ? " was" : "s were") refused at the last check after part of \(refusedAfterPartialRemoval == 1 ? "it" : "them") had already been removed")
                }
                if drifted > 0 {
                    clauses.append("\(drifted) group\(drifted == 1 ? "" : "s") changed since the scan and \(drifted == 1 ? "was" : "were") left alone")
                }
                if refusedForMissingBaseline > 0 {
                    clauses.append("\(refusedForMissingBaseline) group\(refusedForMissingBaseline == 1 ? "" : "s") couldn’t be fully checked and \(refusedForMissingBaseline == 1 ? "was" : "were") left alone")
                }
                if refusedForHoldingKeeper > 0 {
                    clauses.append("\(refusedForHoldingKeeper) group\(refusedForHoldingKeeper == 1 ? " holds a copy" : "s hold copies") another group keeps and \(refusedForHoldingKeeper == 1 ? "was" : "were") left alone")
                }
                let refusalClause = clauses.isEmpty ? "" : " " + clauses.joined(separator: "; ") + ";"
                banner = .warning("Reclaimed \(Self.formatBytes(bytes)) from \(done.count) of \(eligible.count) groups —\(refusalClause) the rest stay listed.",
                                  undoable: isUndoable, log: .warn).reporting(run: outcome.runId)
            }
        }
    }

    /// The banner for a batch in which every group was refused, by cause — each wording claims only
    /// what was checked. A folder with no baseline was never fully read, so "changed" asserts a
    /// change nobody measured; a copy holding another group's keeper did not change at all (the
    /// keepers moved under it), so "changed" is false of it outright.
    nonisolated static func allRefusedBatchBanner(refused: Int, missingBaseline: Int,
                                                  holdsKeeper: Int) -> String {
        if refused == missingBaseline {
            return "These groups couldn’t be fully checked against the scan — review them individually before removing copies."
        }
        if refused == holdsKeeper {
            return "These groups hold copies other duplicate groups keep — rescan before removing copies."
        }
        if holdsKeeper == 0 {
            return "These groups changed since they were scanned — rescan before removing copies."
        }
        return "Some of these groups hold copies other duplicate groups keep, and the rest changed or couldn’t be checked since the scan — rescan before removing copies."
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
        /// loop wrote, plus the keeper file `planMerge` matched for each file it skipped as already
        /// present. Together they say every byte this copy is trashed for lives in the keeper, as
        /// paths the gate can stat.
        ///
        /// No default: the gate refuses on a missing destination, so an empty list checks nothing,
        /// and a default would let a new call site fail open by omission.
        let keeperDestinations: [String]
    }

    /// Collects the merge gate's refusals across `deleteItems`' (up to two) invocations, for the
    /// banner once the delete returns. Lock-guarded because the gate closure is `@Sendable`; the
    /// body itself runs on the main actor.
    ///
    /// Keyed by path, not name: overlapping copies often share a basename (often why they grouped),
    /// and keying by name would merge two refused folds into one.
    final class MergeRemovalRefusals: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(name: String, path: String)] = []
        func record(_ name: String, path: String) {
            lock.lock(); defer { lock.unlock() }
            let key = FileSyncManager.canonicalRemovalPath(path)
            guard !recorded.contains(where: { FileSyncManager.canonicalRemovalPath($0.path) == key }) else { return }
            recorded.append((name: name, path: path))
        }
        /// The refused copies' display names, in the order they were refused — one entry per
        /// refused FOLD, same-named or not.
        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return recorded.map(\.name)
        }
        var paths: [String] {
            lock.lock(); defer { lock.unlock() }
            return recorded.map(\.path)
        }
    }

    /// The merge's `removalGate` body: re-runs `mergeSourceDrifted`, the verdict the loop formed
    /// before enqueuing the delete, for every fold among `paths`, plus a keeper check, and returns
    /// the paths whose claim no longer holds. It covers the duplicates gate's two windows: the
    /// serialized queue wait, and the user-paced permanent-delete confirmation.
    ///
    /// The keeper check matters: every byte the copy is trashed for lives in the keeper, so a
    /// keeper changed since the fold makes the copy the only instance again. `keeperStillExists`
    /// alone is not enough: `copyDriftedInPlace` is always false for a directory, and a merge
    /// keeper is always a folder, so it only asks whether a folder still exists there, and an
    /// emptied or recreated keeper passes. So the gate also stats each of the fold's
    /// `keeperDestinations`: what this fold put in the keeper plus what `planMerge` matched there.
    ///
    /// Refusals are logged per copy, as the duplicates gate logs its own, so `~/sync-cloud.log`
    /// says why a copy the app was about to trash was kept.
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
                refusals.record(fold.name, path: fold.url.path)
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
                refusals.record(fold.name, path: fold.url.path)
                refused.formUnion(asked)
                continue
            }
            let current = Self.fileSnapshotsByRelativePath(
                await Self.buildTree(url: fold.url, sortOption: .name, fileManager: fm, maxDepth: nil))
            if Self.mergeSourceDrifted(planned: fold.plannedSnapshot, current: current) {
                Logger.shared.warning("Duplicates merge: refused to trash “\(fold.name)” (\(fold.url.path)) at the last check before removal — it changed after the merge was planned, so it holds content the fold neither verified nor copied")
                refusals.record(fold.name, path: fold.url.path)
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

    /// The gate closure `mergeDuplicateGroup` hands to `deleteItems`. `self` is captured weakly,
    /// and a torn-down manager refuses everything rather than crashing the queue, as in
    /// `duplicateRemovalGate`.
    func mergeRemovalGate(group: DuplicateGroup, folds: [MergeFoldRecord],
                          refusals: MergeRemovalRefusals)
        -> @Sendable ([String]) async -> Set<String> {
        { [weak self] about in
            guard let self else { return Set(about) }
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
        // Re-entry guard, independent of the UI: a merge runs for minutes, and a second call would
        // re-plan against the half-merged keeper, where every file already folded "exists", minting
        // " 2" junk copies of them all. Claimed synchronously on the main actor before the first
        // suspension point, so two rapid clicks can't both pass.
        guard !mergingGroupIDs.contains(group.id) else {
            Logger.shared.info("Duplicates merge: “\(group.name)” is already merging — duplicate request dropped")
            return false
        }
        mergingGroupIDs.insert(group.id)
        defer { mergingGroupIDs.remove(group.id) }
        // Verify All's exclusion guard, mirrored in the write direction (same rationale as
        // syncFile's): the merge copies into the keeper while Verify All may be hashing it.
        guard !isVerifyAllRunning else {
            banner = .refusal("Wait for Verify All to finish before merging duplicates", log: .info)
            return false
        }
        // A vanished keeper must refuse, not silently recreate itself from the copies being folded.
        guard keeperStillExists(group) else {
            banner = .refusal("“\(group.keeper.name)” is no longer at its scanned location — rescan before merging.", log: .warn)
            return false
        }
        // Progress for the minutes-long run, published the way Verify All does it: an NSProgress
        // on `activeProgress` drives the toolbar's progress capsule (bar, per-file line,
        // Cancel). One unit per redundant copy; the current file name rides along as the
        // additional description from inside the copy loop.
        let progress = Progress(totalUnitCount: Int64(group.redundantCopies.count))
        progress.localizedDescription = "Merging “\(group.name)”"
        progress.isCancellable = true
        progress.runLockReason = Progress.runLockReason(waitingFor: "the merge")
        activeProgress = progress
        defer {
            // Clear only if still ours: a queued operation may have published its own by now.
            if activeProgress === progress { activeProgress = nil }
        }
        // The whole merge is one undo step, and nothing is registered until the awaiting is over.
        //
        // One step, because otherwise a merge registers 2N steps (a copy-undo and a delete per
        // redundant copy) and "Press ⌘Z to undo" reverses only the last trash. Registered at the
        // end, because undo grouping is manager-global: a group held open across a suspension
        // (planning walks, the queued copy, the drift re-walk, a `deleteItems` that can hold a
        // modal dialog) swallows whatever else registers meanwhile, and this is the one duplicates
        // path whose ⌘Z deletes files from the keeper.
        //
        // So the run is recorded and registered afterwards, as in `FileSyncManager+BulkSync.swift`
        // and `applyRecommendedDuplicates`:
        //
        //   * every fold's copies land in `foldedItems`, each with an identity walk started the
        //     moment that copy landed (`startCopyIdentityWalk`). Not `registerCopyUndo(items:)`,
        //     whose walk starts at registration, the end of the merge, and would record an edit
        //     made in between as the copy's own baseline;
        //   * the trash is one `deleteItems` for every completed fold, after the loop, and it hands
        //     its restore registration back (`restoreUndoHandback`) instead of registering
        //     mid-await;
        //   * the tail opens the group, registers the copy-undo and the restore, and closes it with
        //     no await between `beginUndoGrouping` and `endUndoGrouping`. A synchronous main-actor
        //     stretch can't be interleaved.
        //
        // The group is opened only when there is something to put in it: an empty group can't be
        // taken back (calling undo() to discard it may reverse the user's previous action), so it
        // is never created.
        //
        // The cost: the redundant copies all stay on disk until the loop ends, so peak disk use is
        // the keeper plus every copy. A failed run trashes only the folds completed before the
        // failure, and a cancelled one trashes none (see below). In exchange a Trash-less volume
        // raises one permanent-delete confirmation, not one per copy.
        //
        // Every copy this merge folded in, flat across the folds: they share one action name, so
        // one registration covers them all and the undo reverses them as a unit.
        var foldedItems: [PendingCopyItemState] = []
        let keeperPath = group.keeper.path
        let keeperURL = URL(fileURLWithPath: keeperPath)
        let fm = fileManager
        var totalFolded = 0
        var allTrashed = true
        var cancelled = false
        // A fold whose copy phase failed, carried to the registration tail (the single exit) so the
        // copies that already landed still get their undo.
        var copyFailed = false
        // The folds that completed AND still matched their plan: exactly what the one trash below
        // is allowed to remove, and what the removal gate re-verifies at the last moment.
        var readyToTrash: [MergeFoldRecord] = []
        // Set when any redundant copy left by permanent delete rather than the Trash — the merge
        // is then not reversible, whatever else succeeded.
        var anyPermanentlyDeleted = false
        // Set when the Trash took a redundant copy without saying where — recoverable by hand, but
        // no restore can be registered for it, so the fold is withheld from ⌘Z just the same.
        var anyTrashedWithoutLocation = false
        // Set when a Stop left copies untrashed — see the trash below.
        var stoppedDuringTrash = false
        // Copies refused at the trash step because their contents changed after the plan was
        // snapshotted — surfaced with a drift-specific warning below, like the keeper drift.
        var driftedCopies: [String] = []

        for redundant in group.redundantCopies {
            // Honor the capsule's Cancel between copies: whatever already landed is undoable and
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
            // Never merge a copy that contains, or is contained by, the keeper: folding into itself
            // and then trashing would delete out of the keeper. The engine doesn't emit such pairs;
            // skip it and keep the group.
            if Self.pathsOverlap(redundant.path, keeperPath) {
                allTrashed = false
                continue
            }

            let rURL = URL(fileURLWithPath: redundant.path)
            // Resolved BEFORE planning: the plan's same-location and retry-skip checks compare
            // relative paths with the keeper volume's own case semantics (same reason the copy
            // loop below collapses reserved-key case on a case-insensitive keeper volume).
            let keeperCaseSensitive = FileSyncManager.volumeSupportsCaseSensitiveNames(for: keeperURL)
            let planProgress = ProgressRef(progress)
            let plan = await Self.planMerge(from: rURL, into: keeperURL, caseSensitiveVolume: keeperCaseSensitive,
                                            fileManager: fm,
                                            isCancelled: { planProgress.progress.isCancelled })
            // A Stop during planning stops its reads at the next chunk, so the plan is built on
            // missing digests. Nothing is copied or trashed from it.
            if progress.isCancelled {
                cancelled = true
                allTrashed = false
                break
            }
            // Steps aimed under a keeper symlink folder can't run safely: the copy would write
            // through the link (into an external folder, or into the source itself), and skipping
            // them silently would let the trash step destroy content that never landed. Refuse the
            // whole copy: nothing is copied or trashed, the group stays listed, and the banner
            // names the link.
            guard plan.blockedLinkedDirs.isEmpty else {
                let dirs = plan.blockedLinkedDirs.map { "“\($0)”" }.joined(separator: ", ")
                Logger.shared.warning("Duplicates merge: “\(redundant.name)” needs files under \(dirs) in \(keeperURL.lastPathComponent), which \(plan.blockedLinkedDirs.count == 1 ? "is a symlinked folder" : "are symlinked folders") — refusing to write through the link")
                banner = .refusal("Can’t merge “\(group.name)”: \(dirs) in “\(keeperURL.lastPathComponent)” \(plan.blockedLinkedDirs.count == 1 ? "is a symbolic link" : "are symbolic links") — the fold would write through it. Resolve the link, then rescan.", log: .loggedAtSite)
                allTrashed = false
                continue
            }
            // A folder the walk couldn't read is not an empty one. The merge would fold what it saw
            // and then trash the whole copy, unread subfolder included, for good on a volume
            // without a Trash. Refused whole, like the link case above.
            guard plan.unreadDirs.isEmpty else {
                let dirs = plan.unreadDirs.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
                Logger.shared.warning("Duplicates merge: “\(redundant.name)” holds \(plan.unreadDirs.count) folder(s) that could not be read (\(plan.unreadDirs.joined(separator: ", "))) — refusing to merge and trash it")
                // The copy's own folder unreadable comes back as one entry bearing its name.
                let what = plan.unreadDirs == [redundant.name] ? "“\(redundant.name)”" : "\(dirs) in “\(redundant.name)”"
                banner = .refusal("Can’t merge “\(group.name)”: \(what) couldn’t be read, so its contents can’t be checked. Open it, or make it available offline, then rescan.", log: .loggedAtSite)
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
                        // Start the identity walk here, the moment this file's copy landed, not at
                        // registration, which is the end of the whole merge: an edit made in
                        // between would be recorded as the copy's baseline, and a later ⌘Z would
                        // trash it.
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
                // Leave the redundant copy in place so nothing is trashed after a partial copy; the
                // group stays for a retry (already-copied files are skipped next time). Fall
                // through to the tail rather than return: the copies that did land in this run have
                // no undo registered yet.
                present(.syncFailed(item: redundant.name, path: redundant.path,
                                    reason: "Some files couldn’t be merged; the folder was left in place."))
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

        // One trash for every completed fold, gated. The gate re-walks each copy against its plan
        // snapshot when the serialized removal starts and again after a confirmed permanent delete:
        // the two windows the loop's own check (`mergeSourceDrifted` above, before `deleteItems`
        // enqueues) can't cover.
        let gateRefusals = MergeRemovalRefusals()
        // Copies the user chose not to destroy on a Trash-less volume. Carried so the banner names
        // the decline rather than overwriting `deleteItems`' own "Kept those N items" with "some
        // copies were left in place", which would be wrong: everything was folded, and nothing was
        // left by accident.
        var declinedCopies = 0
        var trashedForUndo: (originals: [URL], backups: [URL?])?
        // A Cancel must not start a destructive step that hadn't begun. Otherwise folds completed
        // before the Cancel would be trashed after it, and on a Trash-less volume the Cancel would
        // be answered by a permanent-delete alert (and `deleteItems`' own progress, with its own
        // Cancel). The folded copies stay on disk, as the cancel banner promises: a retry re-plans,
        // skips the files already copied, and trashes then.
        //
        // Only `cancelled` skips it, not a copy failure: the folds completed before the failure are
        // trashed, and a failure is not the user asking the run to stop touching their files.
        if cancelled, !readyToTrash.isEmpty {
            Logger.shared.info("Duplicates merge: “\(group.name)” was cancelled with \(readyToTrash.count) completed fold(s) not yet trashed — leaving them on disk rather than starting a removal the user just cancelled")
        }
        if !readyToTrash.isEmpty, !cancelled {
            let outcome = await deleteItems(
                at: readyToTrash.map { $0.url.path }, fileManager: fm,
                removalGate: mergeRemovalGate(group: group, folds: readyToTrash, refusals: gateRefusals),
                restoreUndoHandback: { originals, backups in
                    trashedForUndo = (originals, backups)
                },
                // The merge is not over when the trash is: the lock stays up through the undo
                // registration and identity walk below.
                resumingProgress: progress)
            if outcome.permanentlyDeleted > 0 { anyPermanentlyDeleted = true }
            if outcome.trashedWithoutLocation > 0 { anyTrashedWithoutLocation = true }
            declinedCopies = outcome.declined
            // A Stop pressed while the trash ran stops the merge: it is the only Stop on screen
            // then. Read from the trash's own answer — a Stop that came too late to leave anything
            // behind stopped nothing, and the merge below ends as a completed one.
            stoppedDuringTrash = outcome.stoppedShort
            // The disk is the ground truth for "did this copy leave", the same rule
            // `dropFullyRemovedGroups` follows: a gate refusal, a decline, a cancelled dialog and a
            // failure all leave a real folder behind, however the call accounted for it.
            for fold in readyToTrash where fm.fileExists(atPath: fold.url.path) { allTrashed = false }
            // A gate refusal reads to the user exactly like the pre-check's drift refusal, because
            // it is the same verdict taken later; the gate has already logged the specifics.
            driftedCopies.append(contentsOf: gateRefusals.all)
        }

        progress.markFinishing("the merge of “\(group.name)”")

        // The registration tail, synchronous start to finish. No `await` between
        // `beginUndoGrouping` and `endUndoGrouping`: a synchronous main-actor stretch can't be
        // interleaved, so nothing else can register into the merge's step. The identity walks are
        // awaited after the group closes.
        var identityWalk: Task<Void, Never>?
        // A merge with a permanently deleted copy registers no copy-undo. Withdrawing the banner's
        // button is not enough: Edit ▸ Undo reads the registration, and firing it would delete the
        // folded files out of the keeper while the original is gone. This is the one duplicates
        // path whose ⌘Z can destroy data.
        //
        // The Trash restore is still registered for copies that reached the Trash: it only puts
        // files back, and its redo re-trashes recoverably. It is named for what it does, not
        // "Merge", so the Edit menu doesn't promise to reverse a merge that can't be reversed.
        //
        // A copy the Trash took without a location withholds the copy-undo too: no restore exists
        // for it, so the undo would take the files out of the keeper while the original sits where
        // only Finder can find it.
        let copyUndoWithheld = anyPermanentlyDeleted || anyTrashedWithoutLocation
        let registersCopyUndo = !foldedItems.isEmpty && !copyUndoWithheld
        if registersCopyUndo || trashedForUndo != nil {
            let actionName = copyUndoWithheld ? "Restore Copies of “\(group.name)”" : "Merge \(group.name)"
            // Grouped only when there is a manager to group in. Without one (headless/CLI) the
            // registrations are no-ops, but the handback must still be consumed: the trash
            // happened.
            let grouped = undoManager != nil
            if grouped { undoManager?.beginUndoGrouping() }
            if registersCopyUndo {
                identityWalk = registerCopyUndo(pendingItems: foldedItems, actionName: actionName, fileManager: fm)
            }
            // Registered after the copy-undo, so ⌘Z pops it first: the redundant copies come back
            // out of the Trash before anything is removed from the keeper. The other order, if the
            // restore then failed, would have deleted the folded files with the originals still
            // gone.
            //
            // Registration order is only half of it: both handlers spawn a `Task` that calls
            // `enqueueFileOperation`, so what the user sees is the queue's order, which keeps call
            // order (pinned by `FileOperationQueueOrderTests`). Only the copies that reached the
            // Trash are here; a permanently deleted one registers nothing, which is why
            // `copyUndoWithheld` withholds the copy-undo above.
            if let trashedForUndo {
                registerRestoreItems(urls: trashedForUndo.originals, trashedItems: trashedForUndo.backups,
                                     actionName: actionName, fileManager: fm)
            }
            // No `setActionName` here: each registrar above names the step after the `actionName`
            // it was handed, and both got the same one, so the call would be inert. (Bulk sync
            // needs one because its per-file registrations carry per-file names.)
            if grouped { undoManager?.endUndoGrouping() }
        }

        // Outside the group, as the tail requires. Awaited so every banner below, offering ⌘Z or
        // not, posts only after the identities the undo checks exist (`registerCopyUndo`'s
        // contract).
        await identityWalk?.value
        if copyFailed { return false }   // the alert is the feedback; no merge banner over it

        // Whether this merge registered an undo: the offer every banner below makes or withholds,
        // asked once so a partial ending offers the ⌘Z its folds really have.
        let offersUndo = !copyUndoWithheld && (registersCopyUndo || trashedForUndo != nil)

        // Only drop the group and claim success when every redundant copy actually left the disk
        // and no error surfaced — otherwise keep the group (retry skips what already landed) and
        // never show a false "Merged" banner over an orphaned folder.
        guard allTrashed, currentError == nil else {
            if cancelled {
                // Nothing was trashed (the removal is skipped on cancel), so ⌘Z only reverses the
                // copy-undo registered above. Pass `undoable:` explicitly:
                // `invalidateUndoableBanner` reads the flag, not the sentence, to retire the offer,
                // and a "press ⌘Z" that outlives its step would reverse the next operation.
                banner = .warning(totalFolded > 0
                    ? "Merge of “\(group.name)” canceled — nothing was trashed, so every copy is still on disk. The \(totalFolded) file\(totalFolded == 1 ? "" : "s") already folded into \(group.keeper.name) can be undone with ⌘Z; the group stays listed and a retry skips what landed."
                    : "Merge of “\(group.name)” canceled — nothing was copied or trashed. The group stays listed.",
                                  undoable: totalFolded > 0, log: .warn)
            } else if stoppedDuringTrash {
                // Stopped while the copies went to the Trash: the folds stand, and so do the copies
                // the trash had not reached.
                banner = .warning("Merge of “\(group.name)” stopped — \(totalFolded) file\(totalFolded == 1 ? "" : "s") folded into \(group.keeper.name), and the copies not yet moved to the Trash are still on disk. The group stays listed and a retry skips what landed.",
                                  undoable: offersUndo, log: .warn)
            } else if let drifted = driftedCopies.first {
                banner = .warning("“\(drifted)” changed since it was scanned — it was left in place. Rescan before merging.",
                                  undoable: offersUndo, log: .warn)
            } else if declinedCopies > 0 {
                // The fold itself succeeded; the copies are still here because the user said so.
                banner = .warning("Merged “\(group.name)” — folded \(totalFolded) file\(totalFolded == 1 ? "" : "s") into \(group.keeper.name), but \(declinedCopies == 1 ? "the redundant copy can’t" : "\(declinedCopies) redundant copies can’t") be moved to the Trash and you chose not to delete \(declinedCopies == 1 ? "it" : "them") permanently. \(declinedCopies == 1 ? "It stays" : "They stay") on disk and the group stays listed.",
                                  undoable: offersUndo, log: .warn)
            } else if totalFolded > 0 {
                banner = .warning("Merged part of “\(group.name)” — some copies were left in place. Review and retry.",
                                  undoable: offersUndo, log: .warn)
            }
            return false
        }
        duplicateGroups.removeAll { $0.id == group.id }
        // Offer ⌘Z only where this merge registered one; `!copyUndoWithheld` alone isn't enough:
        //
        // - `!copyUndoWithheld` is the deliberate withdrawal above: with a copy destroyed outright
        //   the merge can't be taken back, and the restore registered for the copies that reached
        //   the Trash is named for itself.
        // - A merge that folded and trashed nothing registers nothing at all, while
        //   `copyUndoWithheld` is false. That happens when every redundant copy is already off the
        //   disk (an external delete, or a retry after a partial merge) or the group has no
        //   redundant copy.
        //
        // With the stack untouched, ⌘Z would reverse whatever the user did before the merge. The
        // reclaim paths answer this through `DeleteOutcome.isUndoable`; the merge registers by
        // hand, so it asks itself (`offersUndo`).
        let registeredUndo = offersUndo
        banner = .success("Merged “\(group.name)” — folded \(totalFolded) file\(totalFolded == 1 ? "" : "s") into \(group.keeper.name).",
                          undoable: registeredUndo)
        Logger.shared.info("Duplicates: merged “\(group.name)” — folded \(totalFolded) file(s) into \(group.keeper.name)")
        if copyUndoWithheld {
            // He audits this log, and this is the case where the fold can't be taken back. Say what
            // the code did, and say "deleted permanently" only when a copy was: one the Trash took
            // without a location is still in the Trash.
            let why = anyPermanentlyDeleted
                ? "had a redundant copy deleted permanently rather than trashed"
                : "had a redundant copy moved to the Trash with no location reported, so it can only be put back from the Trash in Finder"
            let effect = anyPermanentlyDeleted ? "with the original already gone" : "with the original out of ⌘Z’s reach"
            Logger.shared.warning(
                "Duplicates: “\(group.name)” \(why) — the fold's undo was deliberately NOT registered, because taking it would remove the copied files from \(group.keeper.name) \(effect)"
                + (trashedForUndo == nil ? "" : "; ⌘Z offers only the restore of the copies whose Trash location is known"))
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
        // Every file, in parallel. The call site explains why this can't be narrowed to the hash
        // candidates, so only the speed can change: over 20,000 real paths, 0.50 s serial against
        // 0.18 s across the cores.
        //
        // `concurrentPerform` over chunks, not per path: the work per item is one stat, so per-item
        // dispatch would cost more than it saves. Results merge under a lock once per chunk, into a
        // Set, so order doesn't matter.
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
    /// keeper doesn't provably have, mapped to their destination under the keeper, plus a
    /// `sourceSnapshot` of the redundant copy's full file set (relative path → size+mtime) at plan
    /// time, so the trash step can prove nothing appeared or changed since.
    ///
    /// `vouchedKeeperPaths` is the other half of that proof: the keeper-side path of every source
    /// file this plan skipped, the file whose existence is why no step was emitted. The merge never
    /// writes those, so the gate stats them. Both skip branches report: the same-relative-path hash
    /// match (`keeperHashByRel`) and the retry-idempotence match, whose keeper file has a
    /// uniquified name. Relative paths come from the tree walk, not string prefix math, so path
    /// canonicalization quirks (`/var` vs `/private/var`) can't mangle the destinations.
    nonisolated static func planMerge(
        from rURL: URL, into kURL: URL, caseSensitiveVolume: Bool = true, fileManager fm: FileManaging,
        cache: ContentHashCache? = .shared,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> (steps: [(src: URL, dst: URL)], sourceSnapshot: [String: MergeFileSnapshot],
                blockedLinkedDirs: [String], vouchedKeeperPaths: [String], unreadDirs: [String]) {
        let kTree = await buildTree(url: kURL, sortOption: .name, fileManager: fm, maxDepth: nil)
        // Keeper content hash keyed by relative path, so "already have it" means this exact content
        // at the same location, not merely somewhere. "Same location" follows the keeper volume's
        // name rules: case folds on a case-insensitive volume ("A.txt" and "a.txt" are one name
        // there), and Unicode always precomposes (APFS/HFS+ lookups ignore normalization, and
        // providers mix NFC and NFD, the same reason nearNameKey folds NFC).
        let relKey: (String) -> String = caseSensitiveVolume
            ? { $0.precomposedStringWithCanonicalMapping }
            : { $0.precomposedStringWithCanonicalMapping.lowercased() }

        // One pruning walk builds the keeper's whole view, so the symlink rule has one choke point:
        // a symlink entry (file or directory, lstat semantics) vouches for nothing. Its name still
        // counts as taken (fileExists collides with a link), but its content, and a linked
        // directory's followed subtree (which buildTree walks as ordinary files), must feed neither
        // hash map nor the name set. Counting through-the-link content as present would skip bytes
        // whose only real copy is the folder about to be trashed, leaving the keeper a dangling
        // link.
        //
        // keeperNames holds every surviving rel (files, folders, unhashable files) for the "name
        // taken" check, because the copy loop decides collisions with fileExists. The per-parent
        // hash sets serve the retry-skip: hashFiles omits unhashable files, so a set hit is always
        // a real SHA-256 match.
        var kItems: [(rel: String, id: String)] = []
        var keeperNames = Set<String>()
        // Folded rels of keeper entries that are symlinked directories. Pruning them from the maps
        // is only half the rule: a step aimed under one would still write through the link
        // (fileExists, uniquify and the copy's temp staging all resolve intermediate links), into
        // an external folder or the source itself. Such steps are returned as blocked instead, and
        // the caller refuses.
        var linkedDirRels = Set<String>()
        // Whether the walk's own symlink flag can be trusted for this manager. The real-filesystem
        // walk records `isSymbolicLink` from `.isSymbolicLinkKey`; the mock branch never sets it,
        // so injected managers keep the explicit stat.
        let walkKnowsSymlinks = fm is FileManager
        func isSymlinkEntry(_ n: FileNode) -> Bool {
            // The walk already lstat'ed every entry, so asking again is a second syscall per node,
            // per copy: the largest cost in the planner on a big keeper. Equivalent, not just
            // similar: `.isSymbolicLinkKey` and `attributesOfItem`'s `.type` are both lstat of the
            // entry, and the walk drops broken links before they get here.
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

        // Walked before either side is hashed, so each side hashes only files the other side has a
        // same-size file for: equal digests need equal sizes, so anything else can match nothing. A
        // size the walk couldn't state, or a symlink entry, matches anything, and then the whole
        // other side is hashed, the cautious answer.
        let rTree = await buildTree(url: rURL, sortOption: .name, fileManager: fm, maxDepth: nil)
        let rItems = flattenFilesWithRelativePaths(rTree)
        var walkedSizes: [String: Int] = [:]
        func recordSizes(_ nodes: [FileNode]) {
            for n in nodes {
                if n.isDirectory { recordSizes(n.children ?? []) }
                else if n.isSymbolicLink != true, let size = n.fileSize { walkedSizes[n.id] = size }
            }
        }
        recordSizes(kTree)
        recordSizes(rTree)
        func worthHashing(_ ids: [String], against others: [String]) -> [String] {
            var otherSizes = Set<Int>()
            for id in others {
                guard let size = walkedSizes[id] else { return ids }
                otherSizes.insert(size)
            }
            return ids.filter { walkedSizes[$0].map(otherSizes.contains) ?? true }
        }
        let kIDs = kItems.map { $0.id }
        let rIDs = rItems.map { $0.id }

        let kHashesByPath = await hashFiles(worthHashing(kIDs, against: rIDs), fileManager: fm,
                                            cache: cache, isCancelled: isCancelled)
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

        let rHashes = await hashFiles(worthHashing(rIDs, against: kIDs), fileManager: fm,
                                      cache: cache, isCancelled: isCancelled)
        // Save the digests: both trees were just read in full, and as for the scan and Verify, the
        // reads have happened whatever the plan below decides.
        await cache?.save()

        var steps: [(src: URL, dst: URL)] = []
        var blockedLinkedDirs = Set<String>()
        var vouchedKeeperPaths: [String] = []
        for item in rItems {
            // Skip only when the keeper already has this exact content at the same relative path. A
            // file with a different name or location is folded in even when its bytes also live
            // elsewhere in the keeper: losing a filename is worse than a byte-duplicate a later
            // scan can reconcile. An unhashable source file (unreadable, cloud-only) is re-planned
            // every run: its content can't be proven landed, and the trash step relies on this
            // run's own copy. A cancelled run's earlier copy then sits as a junk sibling, the price
            // of never skipping unverified content.
            if let h = rHashes[item.id] {
                if keeperHashByRel[relKey(item.rel)] == h {
                    if let vouch = keeperPathByRel[relKey(item.rel)] { vouchedKeeperPaths.append(vouch) }
                    continue
                }
                // Retry idempotence: the destination name is taken (by anything fileExists collides
                // with) and the same bytes already live in that folder under another name, the
                // uniquified result of an earlier cancelled or failed run of this merge. Copying
                // again would mint "x 2", "x 3" on every retry. Name preservation still holds: with
                // the name taken, this fold could only land junk-named.
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
        return (steps, fileSnapshotsByRelativePath(rTree), blockedLinkedDirs.sorted(), vouchedKeeperPaths,
                unexploredRelativePaths(rTree))
    }

    /// What the drift check knows about one file in the merge source: size and modification date.
    /// Size alone would pass a same-length rewrite of a plan-skipped file during the minutes-long
    /// hash/copy window, and the rewrite's only copy would be trashed. Both come from the same
    /// walk, so an unchanged file always compares equal. Same blind spots as `copyDriftedInPlace`:
    /// coarse volume timestamps (FAT, some SMB), mtime-preserving writers, and xattr or Finder-tag
    /// edits.
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

    /// The folders under a walked tree that were NOT read — a listing the volume refused, or a
    /// cloud folder whose app missed the deadline. Each comes back with no children, which every
    /// flatten below reads as "empty" — so a merge that trusted it would trash what it never saw.
    nonisolated static func unexploredRelativePaths(_ nodes: [FileNode], prefix: String = "") -> [String] {
        var out: [String] = []
        for n in nodes where n.isDirectory && n.isSymbolicLink != true {
            let rel = prefix.isEmpty ? n.name : prefix + "/" + n.name
            if n.isUnexplored == true { out.append(rel); continue }
            out.append(contentsOf: unexploredRelativePaths(n.children ?? [], prefix: rel))
        }
        return out
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
        // Every group holding the path, not the first: one file can legitimately be in two, since a
        // same-text group can be anchored on an identical group's keeper (`sameTextFileGroups`).
        // Updating only one would leave the other listing a file that is now in the Trash.
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
    /// `skipping` drops every node so named, with all it holds.
    nonisolated static func flattenFiles(_ nodes: [FileNode],
                                         skipping ignoredNames: Set<String> = []) -> [FileNode] {
        var out: [FileNode] = []
        for n in nodes where !ignoredNames.contains(n.name) {
            if n.isDirectory {
                out.append(contentsOf: flattenFiles(n.children ?? [], skipping: ignoredNames))
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
        var skippedCloudOnly = 0
        var unverifiable = 0
    }

    /// Hashes files with bounded concurrency, returning path → SHA-256 hex (missing when a file
    /// can't be hashed — cloud-only, unreadable). Off-main via ``FileContentVerifier``.
    nonisolated static func hashFiles(
        _ paths: [String],
        fileManager: FileManaging,
        maxConcurrent: Int = 6,
        cache: ContentHashCache?,
        onProgress: (@Sendable (Int) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> [String: String] {
        await hashFilesCounting(paths, fileManager: fileManager, maxConcurrent: maxConcurrent,
                                cache: cache, onProgress: onProgress, isCancelled: isCancelled).hashes
    }

    /// ``hashFiles`` plus per-reason skip counts. `isCloudOnly` is injectable for tests (a dataless
    /// file can't be fabricated; the flag is provider-set).
    ///
    /// `cache` is required, not defaulted, because the right answer differs per caller. The entry
    /// points (``findDuplicates`` and ``planMerge``) pass the session cache Verify uses, so a scan
    /// after a Verify, a second scan, or a merge re-walking the keeper per copy doesn't re-hash
    /// unchanged files.
    ///
    /// A cache hit bypasses `isCloudOnly`: the cache holds digests, and `isCloudOnly` only decides
    /// whether computing one needs a download. A file with a known digest is grouped even if it is
    /// now cloud-only (the better answer), so a caller varying that knob across calls must not
    /// share a cache. Only tests vary it.
    nonisolated static func hashFilesCounting(
        _ paths: [String],
        fileManager: FileManaging,
        maxConcurrent: Int = 6,
        isCloudOnly: @escaping @Sendable (String) -> Bool = { MaterializationStatus.isCloudOnly(atPath: $0) },
        cache: ContentHashCache?,
        onProgress: (@Sendable (Int) -> Void)? = nil,
        // After `onProgress`, so the scan's trailing progress closure still binds to that.
        isCancelled: @escaping @Sendable () -> Bool = { false }
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
                                                                 isCloudOnly: isCloudOnly,
                                                                 isCancelled: isCancelled))
                }
            }
            let initial = min(maxConcurrent, paths.count)
            while next < initial { schedule(paths[next]); next += 1 }
            for await (path, outcome) in group {
                switch outcome {
                case .hashed(let hash): result.hashes[path] = hash
                case .skippedCloudOnly: result.skippedCloudOnly += 1
                // Counted, not dropped. See `DuplicateScanSkips.unverifiable`.
                case .unverifiable: result.unverifiable += 1
                // Not a skip: the scan was stopped, and a stopped scan publishes nothing.
                case .cancelled: break
                }
                completed += 1
                onProgress?(completed)
                // Cancellation stops scheduling new work, and the hashes in flight stop at their
                // next chunk (`cancelAll` reaches them through ``FileContentVerifier/hashOutcome``;
                // `isCancelled` they ask themselves).
                if Task.isCancelled || isCancelled() {
                    group.cancelAll()
                    continue
                }
                if next < paths.count { schedule(paths[next]); next += 1 }
            }
        }
        return result
    }

    /// The size past which a duplicate candidate's two ends are sampled before it is read whole:
    /// 100 MB.
    ///
    /// The scan reads every candidate that shares its size with another, unasked, across a whole
    /// tree. Above this size, two same-size files that are not copies (disk images, pre-allocated
    /// containers) would be read in full, gigabytes each, to learn they differ. Their first and
    /// last megabyte almost always differ, and a difference anywhere is proof, so only files whose
    /// ends match another's are read whole. Copies always match there, so sampling never hides a
    /// duplicate.
    public nonisolated static let duplicateEdgeSampleAbove = 100_000_000

    /// ``FileContentVerifier/edgeSample`` of each file, with bounded concurrency: path → sample,
    /// missing where none could be taken. The same width and lane as ``hashFilesCounting``.
    ///
    /// A size whose every file already has its digest in `cache` is not sampled: the full hash
    /// answers each from the cache without a read, so sampling buys nothing (every large candidate,
    /// on a warm rescan). It stays whole for the full hash (``candidatesNeedingFullHash``). A size
    /// with any uncached file is sampled whole, since samples compare only with samples.
    nonisolated static func edgeSamples(
        _ files: [(path: String, size: Int)],
        maxConcurrent: Int = 6,
        fileManager: FileManaging,
        cache: ContentHashCache?,
        isCloudOnly: @escaping @Sendable (String) -> Bool
    ) async -> [String: String] {
        var files = files
        if let cache {
            var cached = Set<String>()
            await withTaskGroup(of: (String, Bool).self) { group in
                var next = 0
                func schedule(_ path: String) {
                    group.addTask {
                        (path, await FileContentVerifier.cachedDigest(filePath: path, fileManager: fileManager,
                                                                      cache: cache) != nil)
                    }
                }
                while next < min(maxConcurrent, files.count) { schedule(files[next].path); next += 1 }
                for await (path, isCached) in group {
                    if isCached { cached.insert(path) }
                    if Task.isCancelled { group.cancelAll(); continue }
                    if next < files.count { schedule(files[next].path); next += 1 }
                }
            }
            let sizes = Dictionary(grouping: files, by: \.size)
            let fullyCached = Set(sizes.filter { $0.value.allSatisfy { cached.contains($0.path) } }.keys)
            files = files.filter { !fullyCached.contains($0.size) }
        }
        var samples: [String: String] = [:]
        var next = 0
        await withTaskGroup(of: (String, String?).self) { group in
            func schedule(_ file: (path: String, size: Int)) {
                group.addTask {
                    (file.path, await FileContentVerifier.edgeSample(filePath: file.path, size: file.size,
                                                                     isCloudOnly: isCloudOnly))
                }
            }
            while next < min(maxConcurrent, files.count) { schedule(files[next]); next += 1 }
            for await (path, sample) in group {
                if let sample { samples[path] = sample }
                if Task.isCancelled { group.cancelAll(); continue }
                if next < files.count { schedule(files[next]); next += 1 }
            }
        }
        return samples
    }

    /// The candidates still worth a full hash once the large ones' edge samples are in, in their
    /// original order. Every candidate at or under `sampleAbove` stays; a larger one is dropped
    /// only when its sample is unlike every other same-size candidate's, proof it is a copy of
    /// none.
    ///
    /// A size with any unsampled member keeps all its members: no sample means unknown, not
    /// different. A cloud-only copy is never opened here, but its digest may be cached, and
    /// dropping its local twin would lose the pair. An unreadable one goes on to the full hash,
    /// which counts it as a skip.
    nonisolated static func candidatesNeedingFullHash(
        _ candidates: [(path: String, size: Int)],
        samples: [String: String],
        sampleAbove: Int
    ) -> [String] {
        var bySize: [Int: [String]] = [:]
        for c in candidates where c.size > sampleAbove { bySize[c.size, default: []].append(c.path) }
        var dropped = Set<String>()
        for paths in bySize.values {
            let taken = paths.compactMap { samples[$0] }
            guard taken.count == paths.count else { continue }
            var count: [String: Int] = [:]
            for sample in taken { count[sample, default: 0] += 1 }
            for path in paths where count[samples[path]!] == 1 { dropped.insert(path) }
        }
        return candidates.map(\.path).filter { !dropped.contains($0) }
    }

    /// Built once and used under a lock: `formatBytes` is called from view bodies on every render,
    /// and `ByteCountFormatter` is not cheap to build. The lock because `formatBytes` is
    /// `nonisolated` and Apple documents no thread safety for this formatter; uncontended, it costs
    /// next to nothing. (`FileSizeFormat.byteCount` stays `@MainActor` instead, which this can't.)
    private nonisolated(unsafe) static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()
    private nonisolated static let byteFormatterLock = NSLock()

    public nonisolated static func formatBytes(_ n: Int) -> String {
        byteFormatterLock.lock()
        defer { byteFormatterLock.unlock() }
        return byteFormatter.string(fromByteCount: Int64(max(0, n)))
    }
}
