import Events
import Foundation

extension FileSyncManager {
    
    // MARK: - Core Scanning Operations

    /// Loads the file tree for one pane — served from the prefetch cache when the focused
    /// folder (or an ancestor's cached deep tree containing it) is available, otherwise from
    /// disk with a shallow-first progressive paint.
    /// - Parameters:
    ///   - path: Absolute path of the pane root (e.g. expanded tilde).
    ///   - isLeft: `true` for the left pane, `false` for the right pane.
    public func loadTree(path: String, isLeft: Bool) async {
        if isLeft { activeLoadLeftTask?.cancel() }
        else { activeLoadRightTask?.cancel() }

        // Token for this load; the next load for the same pane bumps it. The deferred cleanup
        // below uses it to release the spinner only while this load is still the current one.
        let loadToken: Int
        if isLeft { leftLoadGeneration += 1; loadToken = leftLoadGeneration }
        else { rightLoadGeneration += 1; loadToken = rightLoadGeneration }

        let task = Task {
            let label = isLeft ? "Left" : "Right"
            Logger.shared.debug("Loading \(label) Tree for path: \(path)")

            // Whatever exit this load takes — normal completion, cache-hit return, or
            // cancellation between the disk walks — release the loading spinner, but only if
            // this load is still the pane's current one (a newer load owns the flag once it
            // starts). Without this, a load cancelled with no successor stranded the spinner
            // (the "stuck Scanning Directory…" bug); it self-healed only on re-navigation.
            defer {
                let stillCurrent = isLeft ? (leftLoadGeneration == loadToken) : (rightLoadGeneration == loadToken)
                let wasLoading = isLeft ? isLoadingLeftTree : isLoadingRightTree
                if stillCurrent, wasLoading {
                    if isLeft { isLoadingLeftTree = false } else { isLoadingRightTree = false }
                    if Task.isCancelled {
                        Logger.shared.debug("\(label) tree load cancelled before completing; cleared its stale loading spinner")
                    }
                }
            }

            let relPath = isLeft ? leftRelativePath : rightRelativePath
            let rootURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let focusURL = relPath.isEmpty ? rootURL : rootURL.appendingPathComponent(relPath)
            let focusPath = focusURL.path

            // Fast path: serve the focus from the cache without touching the disk — a direct
            // hit, or a slice of the cached root tree (deep by construction, so drill-down and
            // breadcrumb navigation are instant). File operations, sort changes, and force
            // refresh clear the cache, so this never serves stale post-operation state.
            let cached = prefetchedTrees[focusPath]
                ?? Self.subtree(atPath: focusPath, in: prefetchedTrees[rootURL.path])
            if let cached {
                Logger.shared.debug("Serving \(label) tree for \(focusPath) from cache")
                prefetchedTrees[focusPath] = cached
                self.adoptRawTree(cached, isLeft: isLeft, focusPath: focusPath)
                await self.applyFilters()
                // The spinner (set by a slow load this one just cancelled) is released by the
                // deferred cleanup above.
                return
            }

            // Slow Path: Load actively
            if isLeft { isLoadingLeftTree = true }
            else { isLoadingRightTree = true }

            // buildTree detaches its own worker (and forwards cancellation into it),
            // so no extra detached hop is needed here.
            let fm = self.fileManager
            let sortOp = self.sortOption

            // Progressive first paint: publish the immediate children right away (one
            // directory listing), then swap in the deep tree when the full walk finishes —
            // but only when the pane has nothing valid to show for this focus (first load,
            // or navigation to an uncached folder). A same-focus refresh keeps the current
            // deep tree visible until the new one lands (stale-while-revalidate) instead of
            // collapsing rows to a shallow flash. The loading flag stays up until the deep
            // tree lands, which also keeps pruneSelection off the interim tree.
            let currentTree = isLeft ? rawLeftTree : rawRightTree
            let lastFocus = isLeft ? lastLoadedLeftFocusPath : lastLoadedRightFocusPath
            if currentTree.isEmpty || lastFocus != focusPath {
                let shallowTree = await Self.buildTree(url: focusURL, sortOption: sortOp, fileManager: fm, maxDepth: 1)
                guard !Task.isCancelled else { return }
                self.adoptRawTree(shallowTree, isLeft: isLeft, focusPath: focusPath)
                await self.applyFilters()
            }

            let tree = await Self.buildTree(url: focusURL, sortOption: sortOp, fileManager: fm)

            guard !Task.isCancelled else { return }

            self.adoptRawTree(tree, isLeft: isLeft, focusPath: focusPath)
            await self.applyFilters()
            if isLeft {
                isLoadingLeftTree = false
            } else {
                isLoadingRightTree = false
            }
            // Cache the deep tree for this focus (never the shallow one — cache consumers,
            // including the in-memory diff scan, rely on cached trees being fully walked).
            self.prefetchedTrees[focusPath] = tree
            Logger.shared.debug("\(label) Tree Loaded. Count: \(isLeft ? leftItemCount : rightItemCount)")
        }

        if isLeft { activeLoadLeftTask = task }
        else { activeLoadRightTask = task }

        // `task` is unstructured, so the caller's cancellation (e.g. a cancelled refresh)
        // does not reach it on its own — forward it explicitly.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
    
    /// Publishes a freshly built (or cache-served) raw tree for one pane. Also bumps
    /// `rawTreeGeneration`, which invalidates any off-main resort snapshot in flight —
    /// this tree was built with the current sort option already applied.
    func adoptRawTree(_ tree: [FileNode], isLeft: Bool, focusPath: String) {
        rawTreeGeneration += 1
        if isLeft {
            rawLeftTree = tree
            lastLoadedLeftFocusPath = focusPath
        } else {
            rawRightTree = tree
            lastLoadedRightFocusPath = focusPath
        }
    }

    /// The children of the directory at `path` inside a cached deep tree, or nil when the path
    /// is not present (or `tree` is nil). Lets navigation serve a drill-down from an ancestor's
    /// cached tree without re-walking the disk. A cycle- or depth-capped node (`isUnexplored`)
    /// is a MISS, not an empty folder: its `[]` children are a construction artifact, and
    /// serving them as the folder's deep tree would make the in-memory diff report the entire
    /// other side as "missing". The miss sends the caller back to a fresh disk walk, which —
    /// rooted at that path, with a fresh cycle-visited set and depth budget — walks correctly.
    nonisolated static func subtree(atPath path: String, in tree: [FileNode]?) -> [FileNode]? {
        guard let tree else { return nil }
        for node in tree where node.isDirectory {
            if node.id == path { return node.isUnexplored == true ? nil : (node.children ?? []) }
            if path.hasPrefix(node.id + "/") { return subtree(atPath: path, in: node.children) }
        }
        return nil
    }

    nonisolated static func countItems(in tree: [FileNode]) -> Int {
        var count = 0
        for node in tree {
            count += 1
            if let children = node.children {
                count += countItems(in: children)
            }
        }
        return count
    }
    
    /// Loads both pane trees then runs a diff scan between the current left/right paths. Cancels any in-flight refresh.
    /// - Parameters:
    ///   - left: Cloud provider for the left pane (root path and display name).
    ///   - right: Cloud provider for the right pane.
    public func refreshTreesAndScan(left: CloudProvider, right: CloudProvider) async {
        let key = RefreshKey(
            leftId: left.id, leftPath: left.path,
            rightId: right.id, rightPath: right.path,
            leftRel: leftRelativePath, rightRel: rightRelativePath
        )
        // The launch bootstrap fires several identical refreshes (the explicit initial one plus
        // the provider-id onChange that resets navigation). A refresh already in flight for the
        // exact same target loads both panes on its own, so skip the duplicate rather than
        // cancel-and-restart it — that race could strand a pane's load, leaving it blank until
        // the user re-navigated. A different target is real navigation and still supersedes.
        if activeRefreshKey == key {
            Logger.shared.debug("Skipping duplicate in-flight refresh for the same target")
            return
        }
        activeRefreshTask?.cancel()
        activeRefreshKey = key

        let task = Task {
            let leftRoot = (left.path as NSString).expandingTildeInPath
            let rightRoot = (right.path as NSString).expandingTildeInPath

            // The two pane loads are independent — disjoint published state, and each walks
            // the disk on its own detached worker — so run them concurrently. Serially they
            // doubled time-to-first-render, and panes on different volumes don't even
            // contend for I/O. Cancelling this task cancels both child loads.
            async let leftLoad: Void = self.loadTree(path: leftRoot, isLeft: true)
            async let rightLoad: Void = self.loadTree(path: rightRoot, isLeft: false)
            _ = await (leftLoad, rightLoad)
            guard !Task.isCancelled else { return }
            
            let currentLeftFull = (leftRoot as NSString).appendingPathComponent(leftRelativePath)
            let currentRightFull = (rightRoot as NSString).appendingPathComponent(rightRelativePath)
            
            await scanDirectories(
                left: left, leftPath: currentLeftFull,
                right: right, rightPath: currentRightFull
            )
            guard !Task.isCancelled else { return }
            self.scheduleSelectionPrune()
            self.sweepOrphanedTempArtifacts()
        }
        
        activeRefreshTask = task
        await task.value
        // Release the key when this refresh is still the current one; a superseding refresh
        // will have overwritten it and owns the cleanup. Matched by task identity (Task's ==),
        // not key equality alone: a stale refresh unwinding late must not clear the key of a
        // NEWER refresh for the same target (A(K1) superseded, C(K1) registers K1 again, A
        // unwinds while C runs) — that would break the dedupe and let a duplicate
        // cancel-restart C, reopening the strand race documented above.
        if activeRefreshKey == key, activeRefreshTask == task {
            activeRefreshKey = nil
        }
    }

    /// Post-refresh hygiene: removes `.tmp_<UUID>` working files that a crashed or
    /// force-quit safe copy/move left behind (every normal exit path cleans them up via
    /// `defer`). Candidates come from the pane trees this refresh just walked — no extra
    /// disk I/O — and only artifacts older than `OrphanSweeper.minimumAge` are reaped, so
    /// an in-flight operation's staging file is never touched; running from the
    /// post-refresh path also means no operation is mutating these panes right now.
    /// `.rollback_<UUID>` replacement backups are deliberately left in place: they are
    /// the undo stack's restorable handle and may be the only copy of a replaced file.
    func sweepOrphanedTempArtifacts(now: Date = Date()) {
        let scan = OrphanSweeper.findArtifacts(
            inTrees: [rawLeftTree, rawRightTree],
            olderThan: now.addingTimeInterval(-OrphanSweeper.minimumAge)
        )
        if scan.rollbackCount > 0 {
            Logger.shared.debug("Leaving \(scan.rollbackCount) .rollback_ replacement backup(s) in place (restorable copies of replaced files)")
        }
        guard !scan.tempPaths.isEmpty else { return }

        let fm = fileManager
        let paths = scan.tempPaths
        Task.detached(priority: .utility) { [weak self] in
            let removed = OrphanSweeper.removeTempArtifacts(atPaths: paths, fileManager: fm)
            guard removed > 0, let self else { return }
            await MainActor.run {
                Logger.shared.debug("Swept \(removed) orphaned .tmp_ working file(s)")
                // The swept entries are baked into the cached deep trees; drop the cache
                // so navigation reloads from disk instead of serving ghost entries.
                self.prefetchedTrees.removeAll()
            }
        }
    }

    /// User-triggered sweep from Settings → Advanced. Same age-gated, `.rollback_`-preserving
    /// pass as the automatic post-refresh sweep, plus a banner so the click visibly did
    /// something (the automatic pass logs quietly).
    public func sweepOrphanedTempArtifactsNow() {
        sweepOrphanedTempArtifacts()
        banner = .success("Checked for orphaned temporary files")
    }

    /// Runs a diff scan between the two given directory paths on a background thread. Queues a single scan if one is already running.
    /// - Parameters:
    ///   - left: Cloud provider for the left pane.
    ///   - leftPath: Absolute path of the left pane’s current folder (may be a subfolder).
    ///   - right: Cloud provider for the right pane.
    ///   - rightPath: Absolute path of the right pane’s current folder.
    public func scanDirectories(left: CloudProvider, leftPath: String, right: CloudProvider, rightPath: String) async {
        scanRequestGeneration += 1
        let request = ScanRequest(
            left: left,
            leftPath: leftPath,
            right: right,
            rightPath: rightPath,
            generation: scanRequestGeneration
        )
        await runOrQueueScan(request)
    }

    /// Runs the request now, or queues it when a scan already holds the slot (the drain at the
    /// end of `executeScan` picks it up). Separate from `scanDirectories` so the drain can
    /// re-enter without minting a new generation — a re-queued request must stay OLDER than any
    /// scan that started while it waited, so the generation-gated publish still discards it.
    private func runOrQueueScan(_ request: ScanRequest) async {
        if isScanning {
            // Only ever queue forward: a drain re-queueing an older request must not clobber
            // a newer one that arrived while the drain's task was waiting to run.
            if let queued = pendingScanRequest, queued.generation > request.generation { return }
            pendingScanRequest = request
            Logger.shared.warning("Scan already in progress, queueing latest request.")
            return
        }
        await executeScan(request)
    }

    private func executeScan(_ request: ScanRequest) async {
        isScanning = true
        Logger.shared.info("Internal scan comparing \(request.left.displayName) and \(request.right.displayName)")

        let leftURL = URL(fileURLWithPath: (request.leftPath as NSString).expandingTildeInPath)
        let rightURL = URL(fileURLWithPath: (request.rightPath as NSString).expandingTildeInPath)

        // Case-variant paths only collapse into one pair when neither volume distinguishes
        // case; with mixed sensitivity the engine keeps exact-case matching.
        let caseInsensitive = !Self.volumeSupportsCaseSensitiveNames(for: leftURL)
            && !Self.volumeSupportsCaseSensitiveNames(for: rightURL)
        // Snapshot on the main actor; the compute branches below run detached.
        let dateTolerance = dateToleranceSeconds

        // In-memory fast path: when both focused folders have deep trees in the prefetch
        // cache (file operations clear it, so cached ⇒ current), derive the comparison maps
        // from the trees instead of re-walking both directories on disk — the scan becomes
        // near-instant after navigation. Both sources report symlinked entries with the
        // TARGET's size/date; the one remaining divergence is that the tree builder walks
        // INTO symlinked directories (as the panes display them) while the disk enumerator
        // reports the linked directory itself but not its contents.
        // Both compute branches run detached (so the diff never blocks the main actor) and
        // forward this task's cancellation in explicitly, mirroring `buildTree`: detached tasks
        // don't inherit cancellation, and a superseded scan otherwise holds `isScanning` for a
        // full double disk walk whose results are guaranteed to be discarded.
        let newDifferences: [FileDifference]?
        if let cachedLeft = prefetchedTrees[leftURL.path], let cachedRight = prefetchedTrees[rightURL.path] {
            Logger.shared.debug("Scanning from cached trees (no disk walk)")
            let computeTask = Task.detached(priority: .userInitiated) { () -> [FileDifference]? in
                guard !Task.isCancelled else { return nil }
                let leftFilesInfo = FileDiffEngine.filesInfo(fromTree: cachedLeft, basePath: leftURL.path)
                let rightFilesInfo = FileDiffEngine.filesInfo(fromTree: cachedRight, basePath: rightURL.path)
                guard !Task.isCancelled else { return nil }
                return FileDiffEngine.computeDifferences(
                    left: request.left,
                    leftURL: leftURL,
                    right: request.right,
                    rightURL: rightURL,
                    leftFilesInfo: leftFilesInfo,
                    rightFilesInfo: rightFilesInfo,
                    caseInsensitive: caseInsensitive,
                    dateToleranceSeconds: dateTolerance
                )
            }
            newDifferences = await withTaskCancellationHandler {
                await computeTask.value
            } onCancel: {
                computeTask.cancel()
            }
        } else {
            let walkTask = Task.detached(priority: .userInitiated) { () -> [FileDifference]? in
                do {
                    let fm = await MainActor.run { self.fileManager }

                    // The two walks are independent and FileManager is thread-safe, so run them
                    // concurrently — serially they doubled the scan's disk phase. They are
                    // detached too, so cancellation is forwarded into both.
                    let leftWalk = Task.detached(priority: .userInitiated) {
                        try FileDiffEngine.getFilesInDirectory(leftURL, fileManager: fm)
                    }
                    let rightWalk = Task.detached(priority: .userInitiated) {
                        try FileDiffEngine.getFilesInDirectory(rightURL, fileManager: fm)
                    }
                    let (leftFilesInfo, rightFilesInfo) = try await withTaskCancellationHandler {
                        (try await leftWalk.value, try await rightWalk.value)
                    } onCancel: {
                        leftWalk.cancel()
                        rightWalk.cancel()
                    }

                    return FileDiffEngine.computeDifferences(
                        left: request.left,
                        leftURL: leftURL,
                        right: request.right,
                        rightURL: rightURL,
                        leftFilesInfo: leftFilesInfo,
                        rightFilesInfo: rightFilesInfo,
                        caseInsensitive: caseInsensitive,
                        dateToleranceSeconds: dateTolerance
                    )

                } catch is CancellationError {
                    // Superseded mid-walk; the publish gate below discards the scan anyway.
                    return nil
                } catch {
                    let msg = "Error scanning directories: \(error)"
                    Task { @MainActor in Logger.shared.error(msg) }
                    return nil
                }
            }
            newDifferences = await withTaskCancellationHandler {
                await walkTask.value
            } onCancel: {
                walkTask.cancel()
            }
        }

        let isLatestRequest = request.generation == scanRequestGeneration
        // Both gate terms are load-bearing. The generation check discards a scan any newer
        // scanDirectories call (or invalidateComparisonState) has superseded. Task.isCancelled
        // covers a window the generation can't: a superseding refresh cancels this task first
        // and only reaches its own scanDirectories (bumping the generation) after both pane
        // loads finish — until then this scan is still "latest" but its results are for
        // folders the panes are navigating away from.
        if !Task.isCancelled, isLatestRequest, let results = newDifferences {
            self.rawDifferences = results
            self.lastRightProviderType = request.right.type
            // The provider pair the destination name check attributes transfer targets to.
            self.lastScanProviders = (request.left, request.right)
            self.verifiedSameDifferenceIds.removeAll()
            await self.applyFilters()
            hasScanned = true

            Logger.shared.debug("Scan completed: found \(results.count) differences.")

            if autoVerifySameSizeDuringScan {
                // Unstructured on purpose: hashing must not extend the scan (isScanning would
                // hold the slot); the pass re-checks the generation before publishing.
                Task { await self.autoVerifySameSizePairs(scanGeneration: request.generation) }
            }
        }

        isScanning = false

        if let pending = pendingScanRequest {
            pendingScanRequest = nil
            if pending.generation > request.generation {
                // Drain on a fresh unstructured task, never on this one: the only production
                // path that queues a request is a superseding refresh that has already
                // cancelled THIS scan's task before queueing. Draining inline would make the
                // pending scan's publish gate see that inherited cancellation and silently
                // discard its fresh results (the Differences list stuck on the previous
                // folder). Re-enters through runOrQueueScan so a scan that claims the slot
                // in the meantime re-queues it instead of two scans running at once.
                Task { await self.runOrQueueScan(pending) }
            }
        }
    }
    
    // MARK: - Internal Engine Operations
    
    /// Walks the directory tree off the main actor. Cancelling the calling task aborts the walk:
    /// the detached worker doesn't inherit cancellation, so it is forwarded explicitly below —
    /// that is what makes the `Task.isCancelled` checks inside `buildNode` effective.
    /// `maxDepth` caps the walk (1 = immediate children only) for the progressive first paint;
    /// capped directories come back with `children: []` and `isUnexplored: true` — present and
    /// expandable-looking, but never mistakable for a genuinely empty folder — and nil means
    /// unlimited (subject to the cycle guard and hard depth cap, which mark the same way).
    ///
    /// On the real filesystem an unlimited walk fans sibling subtrees out across cores at the
    /// top two levels (`TreeBuilder.fanoutMaxDepth`), and Finder tags are fetched only when
    /// sorting by them — together roughly an order of magnitude faster on large directories.
    nonisolated static func buildTree(url: URL, sortOption: SortOption, fileManager fm: FileManaging = FileManager.default, maxDepth: Int? = nil) async -> [FileNode] {
        let buildTask = Task.detached(priority: .userInitiated) {
            struct TreeBuilder: Sendable {
                let fileManager: FileManaging
                let sortOption: SortOption
                let maxDepth: Int?
                /// Reading Finder tags is a separate xattr fetch per file that benchmarked at
                /// ~4x the cost of everything else in the walk combined, so tags are fetched
                /// only when the sort actually reads them. Switching to the Tags sort reloads
                /// the trees from disk (see `sortOption.didSet`) rather than re-sorting nodes
                /// whose `tags` were never populated.
                let includeTags: Bool
                /// Keys prefetched when listing a directory so each child's resourceValues in
                /// buildNode is a cache hit rather than a separate stat.
                let metadataKeys: [URLResourceKey]
                let metadataKeySet: Set<URLResourceKey>
                /// Metadata re-fetched from a symlink's target (type keys stay on the link).
                let symlinkTargetKeySet: Set<URLResourceKey>

                init(fileManager: FileManaging, sortOption: SortOption, maxDepth: Int?) {
                    self.fileManager = fileManager
                    self.sortOption = sortOption
                    self.maxDepth = maxDepth
                    let includeTags = sortOption == .tags
                    self.includeTags = includeTags
                    var keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .typeIdentifierKey]
                    var targetKeys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .typeIdentifierKey]
                    if includeTags {
                        keys.append(.tagNamesKey)
                        targetKeys.append(.tagNamesKey)
                    }
                    self.metadataKeys = keys
                    self.metadataKeySet = Set(keys)
                    self.symlinkTargetKeySet = Set(targetKeys)
                }

                /// Hard ceiling on recursion depth — a backstop for a cycle the identity check
                /// misses (or any pathological nesting). Directories at the cap come back with
                /// `children: []`, same as the shallow-pass cap.
                static let hardDepthCap = 64

                /// Sibling subtrees at this depth or shallower walk concurrently in a task
                /// group (each recursing sequentially below the horizon); two levels is enough
                /// to spread even a tree dominated by one large top-level folder across cores,
                /// while deeper fan-out just adds task overhead.
                static let fanoutMaxDepth = 2

                /// What `directoryIdentity(of:)` returns — Hashable for the cycle-guard set and
                /// Sendable so ancestor-chain snapshots can cross into the fan-out's child
                /// tasks. The wrapped identifiers are immutable Foundation value objects
                /// (NSNumber/NSData), safe to share across tasks.
                enum DirectoryIdentity: Hashable, @unchecked Sendable {
                    case fileResource(volume: NSObject, file: NSObject)
                    case path(String)
                }

                /// Stable identity of the directory a URL ultimately refers to (through
                /// symlinks), used to break symlink cycles. Real filesystem: volume + file
                /// resource identifiers of the resolved target. Injected mocks — where
                /// resourceValues would hit the real disk — fall back to the resolved path,
                /// which is exact for mock disks (they contain no symlinks).
                func directoryIdentity(of dirURL: URL) -> DirectoryIdentity {
                    let resolved = dirURL.resolvingSymlinksInPath()
                    if fileManager is FileManager,
                       let rv = try? resolved.resourceValues(forKeys: [.volumeIdentifierKey, .fileResourceIdentifierKey]),
                       let volume = rv.volumeIdentifier as? NSObject,
                       let file = rv.fileResourceIdentifier as? NSObject {
                        return .fileResource(volume: volume, file: file)
                    }
                    return .path(resolved.standardizedFileURL.path)
                }

                /// Immediate children of a directory. For the real filesystem this batch-prefetches
                /// child metadata in a single call; for injected mocks it reconstructs child URLs from
                /// the enumerator names exactly as before.
                func childURLs(of dirURL: URL) -> [URL] {
                    if let realFm = fileManager as? FileManager {
                        // Fast path: one call prefetches every child's metadata so buildNode's
                        // resourceValues are cache hits. The URL-based API does not traverse a
                        // symlinked directory, so fall back to the path-based listing (which follows
                        // symlinks, as the tree always has) when it yields nothing.
                        if let prefetched = try? realFm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: metadataKeys, options: []) {
                            if !prefetched.isEmpty {
                                return prefetched
                            }
                            // An empty result is either a genuinely empty directory or a symlinked
                            // directory the URL-based API refused to traverse. Only the symlink case
                            // needs the fallback listing; for plain empty directories the symlink
                            // check is a cache hit (isSymbolicLinkKey is in metadataKeys) or one lstat,
                            // cheaper than a second directory listing.
                            let isSymlink = (try? dirURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                            if !isSymlink {
                                return prefetched
                            }
                        }
                        let names = (try? realFm.contentsOfDirectory(atPath: dirURL.path)) ?? []
                        return names.map { dirURL.appendingPathComponent($0) }
                    } else {
                        var urls: [URL] = []
                        if let enumerator = fileManager.enumerator(at: dirURL, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: nil) {
                            for case let u as URL in enumerator {
                                urls.append(dirURL.appendingPathComponent(u.lastPathComponent))
                            }
                        }
                        return urls
                    }
                }

                /// Type and metadata of one item, shared by the sequential and parallel node
                /// builders. nil means the item vanished mid-walk or is a broken symlink — drop it.
                struct ItemStat {
                    var isDirectory = false
                    var modificationDate: Date?
                    var fileSize: Int?
                    var tags: [String]?
                    var kind: String?
                }

                func stat(at fullURL: URL) -> ItemStat? {
                    var s = ItemStat()
                    if fileManager is FileManager {
                        // Real filesystem: a single resourceValues fetch covers existence, type, and
                        // metadata (the same keys the diff scan reads), avoiding a separate
                        // fileExists stat per node.
                        guard let rv = try? fullURL.resourceValues(forKeys: metadataKeySet) else { return nil }
                        s.modificationDate = rv.contentModificationDate
                        s.fileSize = rv.fileSize
                        s.tags = includeTags ? rv.tagNames : nil
                        s.kind = rv.typeIdentifier
                        if rv.isSymbolicLink == true {
                            // resourceValues reports on the link itself, not its target. Preserve the
                            // prior fileExists behavior for symlinks: resolve to the target so linked
                            // directories still recurse and broken links are still dropped.
                            var isDir: ObjCBool = false
                            guard fileManager.fileExists(atPath: fullURL.path, isDirectory: &isDir) else { return nil }
                            s.isDirectory = isDir.boolValue
                            // Metadata must be the TARGET's too: the link's own size/mtime are
                            // meaningless for diffing, and the disk-walk scan reports the target —
                            // carrying the link's stat here made the same file classify differently
                            // depending on which scan branch ran.
                            if let target = try? fullURL.resolvingSymlinksInPath().resourceValues(forKeys: symlinkTargetKeySet) {
                                s.modificationDate = target.contentModificationDate
                                s.fileSize = target.fileSize
                                s.tags = includeTags ? target.tagNames : nil
                                s.kind = target.typeIdentifier
                            }
                        } else {
                            s.isDirectory = rv.isDirectory ?? false
                        }
                    } else {
                        // Injected mock: resourceValues hits the real disk, so use the mock for
                        // existence/type (metadata stays nil, as before).
                        var isDir: ObjCBool = false
                        guard fileManager.fileExists(atPath: fullURL.path, isDirectory: &isDir) else { return nil }
                        s.isDirectory = isDir.boolValue
                    }
                    return s
                }

                /// `visited` holds the identities of every directory on the current path (the
                /// root is seeded by the caller); it is restored before returning, so it always
                /// reflects the ancestor chain, not everything ever walked.
                func buildNode(at fullURL: URL, depth: Int, visited: inout Set<DirectoryIdentity>) -> FileNode? {
                    guard !Task.isCancelled, let s = stat(at: fullURL) else { return nil }

                    let name = fullURL.lastPathComponent

                    if s.isDirectory {
                        // Depth-capped (shallow) pass: report the directory but don't walk into
                        // it — empty children keep it rendering as a folder until the deep pass.
                        if let maxDepth, depth >= maxDepth {
                            return FileNode(id: fullURL.path, name: name, isDirectory: true, children: [], modificationDate: s.modificationDate, fileSize: s.fileSize, tags: s.tags, kind: s.kind, isUnexplored: true)
                        }
                        // Symlinked directories are deliberately followed (the panes display
                        // linked content), but a link back into a directory already on the
                        // current path is a cycle (A/loop -> A) that would recurse forever.
                        // Show such a directory once, unexplored — same shape as the depth cap.
                        // `isUnexplored` keeps cache consumers from mistaking the artificial
                        // empty children for a genuinely empty (authoritative) deep tree.
                        let identity = directoryIdentity(of: fullURL)
                        if visited.contains(identity) || depth >= Self.hardDepthCap {
                            return FileNode(id: fullURL.path, name: name, isDirectory: true, children: [], modificationDate: s.modificationDate, fileSize: s.fileSize, tags: s.tags, kind: s.kind, isUnexplored: true)
                        }
                        visited.insert(identity)
                        var children: [FileNode] = []
                        for childURL in childURLs(of: fullURL) {
                            if let childNode = buildNode(at: childURL, depth: depth + 1, visited: &visited) {
                                children.append(childNode)
                            }
                        }
                        visited.remove(identity)
                        children = FileSyncManager.sortLevel(nodes: children, by: sortOption)
                        return FileNode(id: fullURL.path, name: name, isDirectory: true, children: children, modificationDate: s.modificationDate, fileSize: s.fileSize, tags: s.tags, kind: s.kind)
                    } else {
                        return FileNode(id: fullURL.path, name: name, isDirectory: false, children: nil, modificationDate: s.modificationDate, fileSize: s.fileSize, tags: s.tags, kind: s.kind)
                    }
                }

                /// Async twin of `buildNode` used above the fan-out horizon: identical
                /// metadata, depth-cap, and cycle handling, but the children of a directory
                /// walk through `walkChildren`, which keeps fanning out until the horizon.
                /// `visited` is an immutable snapshot of the ancestor chain — each branch
                /// extends its own copy, which is exactly the per-path semantics the
                /// sequential builder maintains with insert/remove.
                func buildNodeParallel(at fullURL: URL, depth: Int, visited: Set<DirectoryIdentity>) async -> FileNode? {
                    guard !Task.isCancelled, let s = stat(at: fullURL) else { return nil }

                    let name = fullURL.lastPathComponent
                    guard s.isDirectory else {
                        return FileNode(id: fullURL.path, name: name, isDirectory: false, children: nil, modificationDate: s.modificationDate, fileSize: s.fileSize, tags: s.tags, kind: s.kind)
                    }
                    let identity = directoryIdentity(of: fullURL)
                    if visited.contains(identity) || depth >= Self.hardDepthCap {
                        return FileNode(id: fullURL.path, name: name, isDirectory: true, children: [], modificationDate: s.modificationDate, fileSize: s.fileSize, tags: s.tags, kind: s.kind, isUnexplored: true)
                    }
                    var branchVisited = visited
                    branchVisited.insert(identity)
                    var children = await walkChildren(childURLs(of: fullURL), depth: depth + 1, visited: branchVisited)
                    children = FileSyncManager.sortLevel(nodes: children, by: sortOption)
                    return FileNode(id: fullURL.path, name: name, isDirectory: true, children: children, modificationDate: s.modificationDate, fileSize: s.fileSize, tags: s.tags, kind: s.kind)
                }

                /// Builds the nodes for one directory level. At or above the fan-out horizon
                /// each sibling walks in its own child task (bounded by the global executor's
                /// core count — the tasks never suspend mid-walk); below it, and always for
                /// depth-capped shallow passes and injected mocks (not guaranteed
                /// thread-safe), the level recurses sequentially. Returns the level in listing
                /// order — callers apply `sortLevel`, but equal-key ties must not depend on
                /// task completion order.
                func walkChildren(_ urls: [URL], depth: Int, visited: Set<DirectoryIdentity>) async -> [FileNode] {
                    guard fileManager is FileManager, maxDepth == nil, depth <= Self.fanoutMaxDepth, urls.count > 1 else {
                        var v = visited
                        var children: [FileNode] = []
                        children.reserveCapacity(urls.count)
                        for url in urls {
                            if let node = buildNode(at: url, depth: depth, visited: &v) {
                                children.append(node)
                            }
                        }
                        return children
                    }
                    return await withTaskGroup(of: (Int, FileNode?).self) { group in
                        for (index, url) in urls.enumerated() {
                            group.addTask {
                                (index, await self.buildNodeParallel(at: url, depth: depth, visited: visited))
                            }
                        }
                        var results: [(Int, FileNode?)] = []
                        results.reserveCapacity(urls.count)
                        for await result in group {
                            results.append(result)
                        }
                        return results.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
                    }
                }
            }

            let builder = TreeBuilder(fileManager: fm, sortOption: sortOption, maxDepth: maxDepth)
            // Batch logging to avoid MainActor overhead in recursion
            // (Removed per-node logging)

            let rootChildURLs = builder.childURLs(of: url)
            await Logger.shared.debug("buildTree contents count: \(rootChildURLs.count)")
            // Seed the walk root's identity so a symlink pointing back at the root is
            // recognized as a cycle immediately.
            let visited: Set<TreeBuilder.DirectoryIdentity> = [builder.directoryIdentity(of: url)]
            var rootChildren = await builder.walkChildren(rootChildURLs, depth: 1, visited: visited)
            rootChildren = FileSyncManager.sortLevel(nodes: rootChildren, by: sortOption)
            return rootChildren
        }
        return await withTaskCancellationHandler {
            await buildTask.value
        } onCancel: {
            buildTask.cancel()
        }
    }
    
    /// Recursively sorts a whole tree (children first, then each level). Use when re-sorting an
    /// already-built tree, e.g. when the sort option changes.
    nonisolated static func sort(nodes: [FileNode], by option: SortOption) -> [FileNode] {
        var sorted = nodes

        // Recursively sort children first
        for i in 0..<sorted.count {
            if let children = sorted[i].children {
                sorted[i].children = sort(nodes: children, by: option)
            }
        }

        return sortLevel(nodes: sorted, by: option)
    }

    /// Sorts one level only, leaving children untouched. `buildNode` sorts each subtree as it is
    /// built (bottom-up), so sorting the current level is enough there — the recursive `sort`
    /// would re-sort every subtree once per ancestor level.
    nonisolated static func sortLevel(nodes: [FileNode], by option: SortOption) -> [FileNode] {
        var sorted = nodes
        sorted.sort { a, b in
            // Typically preserve folder precedence
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            
            switch option {
            case .name:
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .kind:
                let kA = a.kind ?? ""
                let kB = b.kind ?? ""
                if kA == kB { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return kA.localizedStandardCompare(kB) == .orderedAscending
            case .dateModified:
                let dA = a.modificationDate ?? Date.distantPast
                let dB = b.modificationDate ?? Date.distantPast
                return dA > dB
            case .size:
                let sA = a.fileSize ?? 0
                let sB = b.fileSize ?? 0
                return sA > sB
            case .tags:
                let tA = a.tags?.joined() ?? ""
                let tB = b.tags?.joined() ?? ""
                if tA == tB { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return tA.localizedStandardCompare(tB) == .orderedAscending
            }
        }
        return sorted
    }
}
