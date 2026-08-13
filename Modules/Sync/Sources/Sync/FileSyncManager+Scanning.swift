import Events
import Foundation

/// A span measured on two clocks, because one of them counts time the Mac spent asleep.
///
/// **`[load] left #1 shallow first paint 19 nodes (walk 8887.98 s …)`** — a listing of nineteen
/// entries, reported as taking two and a half hours. The same log holds **1.4 s** for the identical
/// walk, and 25s, 85s, 191s, 334s and 990s besides. `CFAbsoluteTimeGetCurrent` is a wall clock: it
/// keeps running while the machine sleeps, so the number spans everything that happened between two
/// lines of code rather than the work between them. With one clock a genuinely slow walk and a
/// laptop lid closed mid-walk print the same thing — and the slow ones are the ones worth finding.
/// The five-figure entries have been drowning out whatever the real spread is.
///
/// `SuspendingClock` stops while the system is asleep; `ContinuousClock` does not. Reporting the
/// first and naming the difference when it is material separates the two.
///
/// **What it does not separate:** a process that is merely descheduled or App-Napped. Both clocks
/// keep running through that, because the machine is awake — so a large `active` still means "this
/// took a long time", not necessarily "this did a long time's work". That distinction needs a CPU
/// clock and is a different question from the one this answers.
struct Elapsed {
    private let active: SuspendingClock.Instant
    private let wall: ContinuousClock.Instant

    init() {
        active = SuspendingClock.now
        wall = ContinuousClock.now
    }

    /// `nnn.n ms` under a second, `n.nn s` above it — the shape ``FileSyncManager/durationText(since:)``
    /// established, so a log line reads the same whichever measured it. A span the machine slept
    /// through gains a clause rather than a bigger number.
    var text: String {
        Self.describe(active: Self.seconds(SuspendingClock.now - active),
                      wall: Self.seconds(ContinuousClock.now - wall))
    }

    /// The formatting, separated from the clocks so it can be tested against spans no test could
    /// produce by waiting — the interesting one being an hour of sleep, which is exactly the case
    /// that motivated the type.
    static func describe(active: Double, wall: Double) -> String {
        let asleep = wall - active
        // A tenth of a second is below the resolution anything here cares about, and is the order
        // of the skew two separate clock reads produce on their own.
        guard asleep >= 0.1 else { return format(active) }
        return "\(format(active)) + \(format(asleep)) asleep"
    }

    private static func format(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.1f ms", seconds * 1000)
                    : String(format: "%.2f s", seconds)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

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
            // The pane's own load token, printed on every line this load emits. Without it a
            // start line could not be attributed to an outcome line: the two panes interleave,
            // a navigation supersedes the load already in flight, and a progressive load emits
            // two publishes — so "the Nth start" and "the Nth completion" are unrelated events.
            // Durations derived by pairing them positionally were off by orders of magnitude
            // (a 6 s load read as 6,095 s). Reuses the spinner's existing per-load generation
            // rather than minting a second identity that could disagree with it.
            let tag = "\(isLeft ? "left" : "right") #\(loadToken)"
            let startedAt = Elapsed()
            Logger.shared.debug("[load] \(tag) start \(path)\(relativeSuffix(isLeft: isLeft))")

            // What this load ended up doing. Set at every exit; the default is what an exit that
            // reaches none of them would print, so an unaccounted path names itself in the log
            // instead of vanishing. Read by the `defer` below, which is the only writer of the
            // outcome line — a `return` cannot skip it.
            //
            // The node counts these outcomes carry are RAW walked nodes (`countItems`), not the
            // filtered `leftItemCount` the old completion line printed: the walk's cost is per
            // node walked, and a count that hidden-file filtering has already thinned is the
            // wrong denominator for it. It costs one extra main-actor traversal — ~5 ms per 40k
            // nodes, measured — which the reported duration therefore includes. Against the real
            // loads it appears in (36-425 ms on the cache path, seconds on a cold walk) that is
            // 1-6%, small enough to keep for a number the record is useless without.
            var outcome = "ended without reaching a known exit"

            // Whatever exit this load takes — normal completion, cache-hit return, or
            // cancellation between the disk walks — release the loading spinner, but only if
            // this load is still the pane's current one (a newer load owns the flag once it
            // starts). Without this, a load cancelled with no successor stranded the spinner
            // (the "stuck Scanning Directory…" bug); it self-healed only on re-navigation.
            defer {
                let stillCurrent = isLeft ? (leftLoadGeneration == loadToken) : (rightLoadGeneration == loadToken)
                let wasLoading = isLeft ? isLoadingLeftTree : isLoadingRightTree
                var strandedSpinner = false
                if stillCurrent, wasLoading {
                    if isLeft { isLoadingLeftTree = false } else { isLoadingRightTree = false }
                    strandedSpinner = Task.isCancelled
                }
                // The one line per load that carries its outcome AND its duration. Emitted from
                // the `defer` so every exit is covered, including ones added later.
                Logger.shared.debug(
                    "[load] \(tag) \(outcome) in \(startedAt.text)"
                    + (strandedSpinner ? "; cleared its stale loading spinner" : ""))
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
                prefetchedTrees[focusPath] = cached
                self.adoptRawTree(cached, isLeft: isLeft, focusPath: focusPath)
                await self.applyFilters()
                outcome = "served \(Self.countItems(in: cached)) nodes from cache"
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
            // Config epoch before the walks: if a file operation (or any scan-affecting change)
            // lands while they run, this load's tree predates it and must not be cached.
            let configToken = self.scanConfigGeneration

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
                let shallowStart = Elapsed()
                let shallowTree = await Self.buildTree(url: focusURL, sortOption: sortOp, fileManager: fm, maxDepth: 1)
                let shallowWalk = shallowStart.text
                guard !Task.isCancelled else {
                    outcome = "superseded during the shallow walk (walk \(shallowWalk))"
                    return
                }
                let shallowPublishStart = CFAbsoluteTimeGetCurrent()
                self.adoptRawTree(shallowTree, isLeft: isLeft, focusPath: focusPath)
                await self.applyFilters()
                // The shallow pass is a SEPARATE cost from the deep one, not a prefix of it —
                // it is its own `buildTree` over the same directory — so it gets its own line
                // rather than being folded into the outcome's duration.
                Logger.shared.debug(
                    "[load] \(tag) shallow first paint \(Self.countItems(in: shallowTree)) nodes"
                    + " (walk \(shallowWalk), publish \(Self.durationText(since: shallowPublishStart)))")
            }

            let deepStart = Elapsed()
            let tree = await Self.buildTree(url: focusURL, sortOption: sortOp, fileManager: fm)
            let deepWalk = deepStart.text

            guard !Task.isCancelled else {
                outcome = "superseded during the deep walk (walk \(deepWalk))"
                return
            }

            let publishStart = CFAbsoluteTimeGetCurrent()
            let published = await self.adoptFreshDeepTree(tree, builtWith: sortOp, isLeft: isLeft, focusPath: focusPath,
                                                          loadToken: loadToken, configToken: configToken)
            // `adoptFreshDeepTree` can bail without publishing (cancelled during its off-actor
            // re-sort), which the old "Tree Loaded. Count:" line reported as a completion
            // regardless — it ran unconditionally on the line after. Distinguish them.
            outcome = published
                ? "walked \(Self.countItems(in: tree)) nodes (walk \(deepWalk), publish \(Self.durationText(since: publishStart)))"
                : "superseded during the publish re-sort (walk \(deepWalk))"
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
    
    /// Publishes a fully walked deep tree for one pane and releases its loading spinner.
    /// `builtWith` is the sort option the walk captured at entry; the option can change while
    /// the walk runs (seconds on large panes), and the tree's ORDER then matches the stale
    /// option — worse, for the Tags sort its nodes may lack the tags metadata only that
    /// sort's walks fetch. On a mismatch the tree is re-sorted to the live option before
    /// publishing (off the main actor; a full-tree sort froze the UI on large panes) so a
    /// stale load can never clobber a newer sort choice, and the tree is NOT cached:
    /// `sortOption.didSet` cleared the cache expecting the next walk to rebuild it for the
    /// new option, and writing this one back would poison the cache fast path, which serves
    /// cached trees as-is (for Tags, with no way to ever recover the missing metadata).
    /// - Returns: Whether the tree was published. The one early exit here (cancelled during the
    ///   off-actor re-sort) leaves the pane showing the previous tree, and `loadTree` reports it
    ///   as a superseded load rather than a completion — its old completion line sat on the
    ///   statement after this call and so claimed a load that had published nothing.
    @discardableResult
    func adoptFreshDeepTree(_ tree: [FileNode], builtWith sortOp: SortOption, isLeft: Bool, focusPath: String,
                            loadToken: Int, configToken: Int) async -> Bool {
        var tree = tree
        let liveSort = sortOption
        if liveSort != sortOp {
            let stale = tree
            tree = await Task.detached(priority: .userInitiated) {
                Self.sort(nodes: stale, by: liveSort)
            }.value
            guard !Task.isCancelled else { return false }
        }
        adoptRawTree(tree, isLeft: isLeft, focusPath: focusPath)
        // The option can move AGAIN while the re-sort/publish above runs, and this adopt's
        // generation bump discards any resort that change scheduled — re-sort once more in
        // memory (generation-guarded, so it in turn yields to anything fresher).
        if sortOption != liveSort {
            Task { await self.resortTreesAndRefilter() }
        }
        await applyFilters()
        // Release the spinner only while this load is still the pane's current one (mirrors
        // loadTree's deferred cleanup). A superseded load resuming here after the applyFilters
        // suspension would otherwise clear the SUCCESSOR's spinner mid-walk — and, since the
        // loading flag is what keeps pruneSelection off the interim shallow tree, let a prune
        // wipe valid selections deeper than the shallow tree can see.
        let stillCurrent = isLeft ? (leftLoadGeneration == loadToken) : (rightLoadGeneration == loadToken)
        if stillCurrent {
            if isLeft {
                isLoadingLeftTree = false
            } else {
                isLoadingRightTree = false
            }
        }
        // Cache the deep tree for this focus (never the shallow one — cache consumers,
        // including the in-memory diff scan, rely on cached trees being fully walked), and
        // only when BOTH invariants re-checked after every await above still hold:
        //  - the sort option never moved while this load ran (cached trees are served
        //    verbatim, so they must match the current option's order and metadata exactly);
        //  - the scan-config epoch never moved (a file operation finishing mid-load cleared
        //    this cache and bumped the epoch; writing this pre-operation tree back would
        //    resurrect it, and the cache fast path would then serve pre-op state as current
        //    until the next invalidation).
        //  - `liveSort == sortOp` guarantees NO re-sort happened above: if one did, `tree` carries
        //    liveSort's ORDER but only sortOp's metadata (e.g. a Name-built tree re-sorted to Tags
        //    has no tag xattrs), and `sortOption == sortOp` alone would still cache it whenever the
        //    option later returns to sortOp — poisoning the fast path with a mis-ordered / metadata-
        //    poor tree. Cache only the genuine, unmodified build.
        if sortOption == sortOp, liveSort == sortOp, scanConfigGeneration == configToken, !Task.isCancelled {
            prefetchedTrees[focusPath] = tree
        }
        return true
    }

    /// `nnn.n ms` under a second, `n.nn s` above it — one shape for every duration the load
    /// records print, so the log can be scanned (and parsed) without unit guessing.
    ///
    /// - Note: prefer ``Elapsed`` for anything that can run long. This reads one wall clock and so
    ///   cannot say whether a large number is work or a sleeping Mac; see that type.
    nonisolated static func durationText(since start: CFAbsoluteTime) -> String {
        let seconds = CFAbsoluteTimeGetCurrent() - start
        return seconds < 1 ? String(format: "%.1f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }

    /// The pane's relative path, for the load's start line — a load of the same root at a
    /// different focus is a different load, and the root alone cannot tell them apart.
    func relativeSuffix(isLeft: Bool) -> String {
        let relative = isLeft ? leftRelativePath : rightRelativePath
        return relative.isEmpty ? "" : " (focus: \(relative))"
    }

    /// Publishes a freshly built (or cache-served) raw tree for one pane. Also bumps
    /// `rawTreeGeneration`, which invalidates any off-main resort snapshot in flight —
    /// this tree was built with the current sort option already applied.
    func adoptRawTree(_ tree: [FileNode], isLeft: Bool, focusPath: String) {
        // An unreadable-root walk comes back as the root itself marked unexplored (see
        // `buildTree`), so the cache and the diff know the contents are UNKNOWN rather than
        // empty. The pane must not render the focused folder nested inside itself, though —
        // unwrap the marker and show the folder empty, exactly as before the marker existed.
        var tree = tree
        if tree.count == 1, let only = tree.first, only.isUnexplored == true, only.id == focusPath {
            tree = []
        }
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
        let key = makeRefreshKey(left: left, right: right)
        // The launch bootstrap fires several identical refreshes (the explicit initial one plus
        // the provider-id onChange that resets navigation). A refresh already in flight for the
        // exact same target loads both panes on its own, so skip the duplicate rather than
        // cancel-and-restart it — that race could strand a pane's load, leaving it blank until
        // the user re-navigated. A different target is real navigation and still supersedes —
        // and "target" includes the scan-config epoch (see RefreshKey.config), so a refresh
        // requested after a config change or invalidation supersedes too instead of being
        // swallowed as a duplicate.
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
    /// disk I/O. `.rollback_<UUID>` replacement backups are deliberately left in place: they
    /// are the undo stack's restorable handle and may be the only copy of a replaced file.
    ///
    /// Refuses to run at all while any file operation is in flight. The age gate alone does
    /// NOT make a live staging file safe, though this comment used to claim it did: a temp
    /// staged by a same-volume rename inherits the SOURCE's modification date (and so does a
    /// cross-volume `copyItem`, which preserves attributes), so staging any file untouched for
    /// an hour produces a temp that is already past `minimumAge` at birth. A refresh landing
    /// while `replaceItem` is still in flight — the whole reason that call can take real time
    /// is a slow network volume — could then Trash the live operation's only staged copy out
    /// from under it, and the resulting failure would report the content as lost to a system
    /// item-replacement folder rather than sitting in the Trash. The counter is bumped before
    /// the operation is enqueued and cleared after it completes, so it covers the entire
    /// window; refreshes are explicitly allowed to walk mid-operation disk state, which is why
    /// the sibling "no operation is mutating these panes right now" claim was false too.
    /// Nothing is lost by waiting: an orphan is still an orphan at the next refresh, and only
    /// a quiescent moment can tell an orphan from a staging file in use.
    ///
    /// Deliberately outside `enqueueFileOperation`, and deliberately does NOT bump
    /// `fileOperationsEpoch` — this is the one filesystem write in the app that is neither, and
    /// that is a decision, not an oversight. The exemption has to hold for all three of the
    /// epoch's consumers (see its doc comment), which pose two different questions.
    ///
    /// Against the hashing passes (`autoVerifySameSizePairs`, `verifyAllWithChecksum`), the
    /// question is whether something REWROTE the bytes they hashed: a verdict taken before a
    /// copy/move/replace is a false claim about the file now sitting at that path, and folding
    /// it into `verifiedSameDifferenceIds` hides a real difference. A removal cannot produce
    /// that failure. The sweep's only mutation is `trashItem`, a rename of a whole artifact away
    /// from its path: it never creates, truncates, or overwrites, so it cannot touch the bytes
    /// behind any OTHER path, and against a path it does take, the hash either fails outright
    /// (`nil`, never counted identical) or completes against the inode it already opened — a
    /// true statement about the bytes that were there. No sequence of removals turns a genuinely
    /// differing pair into an "identical" verdict.
    ///
    /// Against `confirmVerifiedCopy`, the question is different — whether the bulk copy the user
    /// is about to confirm could overwrite bytes some operation has changed since they were
    /// verified — and the exemption holds there for a narrower, sharper reason: the sweep only
    /// ever trashes `.tmp_<UUID>` staging artifacts. Those are not, and cannot be, the
    /// `rightItemPath` of any difference in the offer: `OrphanSweeper.isTempArtifactName`
    /// requires the `.tmp_` prefix AND a parseable UUID after it, while the offer holds only
    /// pairs found at the same relative path under BOTH panes — so a swept artifact would have
    /// to exist under the identical `.tmp_<UUID>` name, same UUID, on both sides at once. The
    /// files the copy would write over are ones the sweep provably never touched, and the copy's
    /// own sources and destinations are unaffected by anything this pass can do.
    ///
    /// Joining in would cost real behaviour for that non-problem. This runs at the tail of EVERY
    /// refresh (`refreshTreesAndScan`), the same moment the checksum pass is hashing — the pass is
    /// spawned unstructured a few lines earlier, inside the `scanDirectories` this sweep follows —
    /// so a bump here would discard that batch on essentially every refresh that finds an orphan
    /// on disk, and nothing pins the order of the two, so it would do so nondeterministically.
    /// It would cost the confirm-time consumer too: a background sweep landing while the copy
    /// dialog is up would move the epoch out from under the standing offer and refuse the user's
    /// click, with a banner blaming a file operation that was never theirs.
    /// Routing it through `enqueueFileOperation` is worse still: the non-zero
    /// `activeFileOperationsCount` would bounce the user's own Verify All ("Wait for the current
    /// operation to finish before verifying"), refuse a verified copy on the same count term,
    /// and hold the app-level quit guard, and the queue's completion handler sends
    /// `refreshSubject` — a whole extra double-pane walk and scan for background hygiene nobody
    /// asked for. Pinned by
    /// `AutoVerifyOnScanTests.testOrphanSweepDuringTheHashDoesNotDiscardTheBatch`.
    ///
    /// - Returns: Whether the sweep was allowed to look. Removal itself is detached, so this is
    ///   the only part of the decision a caller (or a test) can observe synchronously — without
    ///   it, "nothing was swept" and "nothing has been swept YET" are indistinguishable, and a
    ///   test asserting the former passes vacuously against the latter.
    @discardableResult
    func sweepOrphanedTempArtifacts(now: Date = Date()) -> Bool {
        guard activeFileOperationsCount == 0 else {
            Logger.shared.debug("Skipping the orphaned-temp sweep: \(activeFileOperationsCount) file operation(s) in flight")
            return false
        }
        let scan = OrphanSweeper.findArtifacts(
            inTrees: [rawLeftTree, rawRightTree],
            olderThan: now.addingTimeInterval(-OrphanSweeper.minimumAge)
        )
        if scan.rollbackCount > 0 {
            Logger.shared.debug("Leaving \(scan.rollbackCount) .rollback_ replacement backup(s) in place (restorable copies of replaced files)")
        }
        guard !scan.tempPaths.isEmpty else { return true }

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
        return true
    }

    /// User-triggered sweep from Settings → Advanced. Same age-gated, `.rollback_`-preserving
    /// pass as the automatic post-refresh sweep, plus a banner so the click visibly did
    /// something (the automatic pass logs quietly).
    public func sweepOrphanedTempArtifactsNow() {
        // The automatic pass declines silently while operations are in flight; a click must say
        // so instead, or the success banner would claim a check that never happened.
        guard activeFileOperationsCount == 0 else {
            banner = .warning("Wait for the current operation to finish before checking for orphaned files")
            return
        }
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
            // Routine coalescing (the user triggered scans in quick succession, or a refresh
            // landed mid-scan) — a diagnostic, not a warning, so it stays out of the warnings filter.
            // Tagged like every other scan line: without the generation this said that SOMETHING
            // was queued but not what, and the request it names is the one whose start line
            // appears later, when the drain finally runs it.
            Logger.shared.debug("[scan] #\(request.generation) queued behind a scan already in progress")
            return
        }
        await executeScan(request)
    }

    /// Stops the running scan (and the tree loads in front of it) at the user's request.
    ///
    /// Every lens scan has had a Cancel since it shipped — `cancelFindDuplicates`,
    /// `cancelBuildStorageLens`, `cancelFindFilingSuggestions`, `cancelAutomationDryRun` — and the
    /// Compare scan, which walks *two* whole trees and is the longest operation in the app, had
    /// none. Starting one against the wrong pair of roots meant waiting it out or quitting.
    ///
    /// **A scan can be reached two ways, and both have to be cancellable.** Ordinarily it runs
    /// inside `refreshTreesAndScan`'s task, behind the two pane loads — one structured chain, so
    /// cancelling the refresh task cancels the loads and the scan together, and cancelling only the
    /// scan would leave the loads running. But a scan queued behind a superseded one is **drained
    /// on an unstructured task after its refresh has already finished and released its key**
    /// (`scanDrainTask`, at the end of `executeScan`); there, `activeRefreshTask` points at a
    /// completed task and cancelling it does nothing at all. Both handles are cancelled
    /// unconditionally — cancelling a finished or absent task is a no-op, so no branch has to
    /// decide which one is live.
    ///
    /// **Liveness is `isScanning` or a live `activeRefreshKey` — never `activeRefreshTask`.** That
    /// handle is never nilled out, only overwritten, so a finished refresh leaves a completed task
    /// sitting there and a guard on it would report a cancel long after there was anything to
    /// cancel. The key covers the load phase in front of a scan (where `isScanning` is still
    /// false); `isScanning` covers the drained scan (which has no key). Together they are exactly
    /// the window in which the UI offers Stop.
    ///
    /// **The queued request has to go too.** `pendingScanRequest` holds a scan that has not started
    /// yet; leaving it would let the drain start a *fresh* scan the instant the cancelled one
    /// unwound, so Cancel would look like it did nothing at all.
    ///
    /// `activeRefreshKey` is deliberately **not** cleared here. The cancelled task's own cleanup
    /// releases it, matched by task identity, so clearing it here would only race that. Nor does
    /// holding it briefly swallow the retry: every user-facing rescan goes through
    /// `forceRefreshAction`, which calls `prepareForcedRescan()` and bumps the config epoch that
    /// `RefreshKey` carries — so a Scan pressed while the cancelled refresh is still unwinding
    /// builds a *different* key and is not deduped away.
    ///
    /// `executeScan`'s publish gate already discards a cancelled scan's results and still runs its
    /// `isScanning = false`, so nothing here has to unwind state.
    public func cancelScan() {
        guard isScanning || activeRefreshKey != nil else { return }
        Logger.shared.info("[scan] cancelled by the user")
        pendingScanRequest = nil
        activeRefreshTask?.cancel()
        scanDrainTask?.cancel()
    }

    private func executeScan(_ request: ScanRequest) async {
        isScanning = true
        scanStartedAt = Date()
        // Same identity discipline as the load records: the scan's own request generation, so a
        // start line pairs with its outcome even when a refresh supersedes the scan mid-flight
        // (which publishes nothing and, before this, logged nothing at all).
        let scanTag = "#\(request.generation)"
        let scanStart = Elapsed()
        Logger.shared.info("Internal scan \(scanTag) comparing \(request.left.displayName) and \(request.right.displayName)")

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
        // from the trees instead of re-walking both directories on disk.
        //
        // It is worth less than this comment used to claim ("the scan becomes near-instant
        // after navigation"). Measured on the two real pane roots at ~40k nodes each, building
        // the map from the tree costs 0.78 s / 1.19 s against 0.99 s / 1.41 s for the disk walk
        // that produces the same map — a 15–21% saving, not a different order of magnitude,
        // because BOTH branches are dominated by building the `[String: FileInfo]` map rather
        // than by reading directories. See `TreeWalkBenchmark`, which measures both.
        //
        // Both sources report symlinked entries with the
        // TARGET's size/date; the one remaining divergence is that the tree builder walks
        // INTO symlinked directories (as the panes display them) while the disk enumerator
        // reports the linked directory itself but not its contents.
        // Both compute branches run detached (so the diff never blocks the main actor) and
        // forward this task's cancellation in explicitly, mirroring `buildTree`: detached tasks
        // don't inherit cancellation, and a superseded scan otherwise holds `isScanning` for a
        // full double disk walk whose results are guaranteed to be discarded.
        let newDifferences: [FileDifference]?
        if let cachedLeft = prefetchedTrees[leftURL.path], let cachedRight = prefetchedTrees[rightURL.path] {
            Logger.shared.debug("[scan] \(scanTag) from cached trees (no directory enumeration)")
            let computeTask = Task.detached(priority: .userInitiated) { () -> [FileDifference]? in
                guard !Task.isCancelled else { return nil }
                // This branch skips the directory ENUMERATION, which is not the same as touching
                // no disk — the line above used to claim "no disk walk". `filesInfo(fromTree:)`
                // builds each entry's `URL(fileURLWithPath:)` with no `isDirectory:` hint, and
                // that initializer resolves the path against the file system: one lookup per
                // node, ~40k per pane here, measured at 4x the cost of the hinted form
                // (TreeWalkBenchmark's `+ map, hinted URL` vs `+ map, unhinted URL`). So its
                // wall time is still exposed to cache state — which is the likeliest reason it
                // varied 4x across otherwise identical runs. Split the phases so the next
                // occurrence says which half moved instead of leaving it to inference.
                let flattenStart = CFAbsoluteTimeGetCurrent()
                let leftFilesInfo = FileDiffEngine.filesInfo(fromTree: cachedLeft, basePath: leftURL.path)
                let rightFilesInfo = FileDiffEngine.filesInfo(fromTree: cachedRight, basePath: rightURL.path)
                let flatten = Self.durationText(since: flattenStart)
                guard !Task.isCancelled else { return nil }
                let diffStart = CFAbsoluteTimeGetCurrent()
                defer {
                    let diff = Self.durationText(since: diffStart)
                    let counts = "\(leftFilesInfo.count) vs \(rightFilesInfo.count) entries"
                    Task { @MainActor in
                        Logger.shared.debug("[scan] \(scanTag) cached-tree compute: flatten \(flatten), diff \(diff) (\(counts))")
                    }
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
                    // Before the tasks are created, not after: a detached task starts running as
                    // soon as it exists, so a clock started below them would already have missed
                    // the beginning of the work it claims to measure.
                    let walkStart = Elapsed()
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
                    let walk = walkStart.text
                    let diffStart = CFAbsoluteTimeGetCurrent()
                    defer {
                        let diff = Self.durationText(since: diffStart)
                        let counts = "\(leftFilesInfo.count) vs \(rightFilesInfo.count) entries"
                        Task { @MainActor in
                            Logger.shared.debug("[scan] \(scanTag) disk-walk compute: walk \(walk), diff \(diff) (\(counts))")
                        }
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
            self.lastScanDate = Date()
            self.verifiedSameDifferenceIds.removeAll()
            // A fresh scan regenerates every row id, so a kept failure set would match nothing —
            // harmless, but it would leave the Failed filter in the menu with a count of zero and
            // the user selected into an empty list. Same reasoning as the line above.
            self.lastTransferFailures = nil
            // A fresh scan regenerates every row's id, so a "copy verified-identical left→right"
            // offer built from the previous scan now references superseded differences — drop it
            // (same reason swapPanes clears it), so confirming can't bulk-copy stale pairs.
            self.verifiedIdenticalForCopy = nil
            await self.applyFilters()
            // The compared folders' names, captured with the results they describe — the Path
            // column must keep naming the scanned roots even if the panes navigate on. Set AFTER
            // the filter pass on purpose: the pass suspends on a detached compute while the
            // PREVIOUS scan's rows are still published (they stay visible through navigation by
            // design), and the `lastScanDate` write above re-renders the view — assigning the
            // new names before the pass would label those old rows with the new scan's anchor
            // for the pass's whole duration. `applyFilters` publishes the rows synchronously
            // before returning, so this write shares its main-actor slot with them: no render
            // can interleave and pair new rows with old names either.
            self.lastScanRootNames = (leftURL.lastPathComponent, rightURL.lastPathComponent)
            hasScanned = true
            // Recorded from THIS request's own paths, not from the panes: the panes can have
            // navigated on while the scan ran (that is why `lastScanRootNames` is set from the
            // request too), and a summary stamped with where the panes ended up would claim a
            // count for folders that were never compared.
            //
            // `results.count`, the unfiltered scan output, not `differences.count`: the published
            // list is `rawDifferences` minus the hidden/ignored filter, and it keeps moving after
            // the scan — toggling ⇧⌘. or ignoring a row would leave the summary disagreeing with a
            // number it was never measuring.
            recordLastScanSummary(LastScanSummary(
                date: self.lastScanDate ?? Date(),
                differenceCount: results.count,
                leftProviderID: request.left.id,
                // The request's own path, tilde-expanded — the same expression the pane's
                // `PaneLogic.fullPath` produces — rather than `leftURL.path`, which is that string
                // after `URL`'s normalization. `describes` trims trailing separators anyway, so
                // this is belt and braces; it is written this way so the two sides START equal
                // rather than relying on the trim to reconcile them.
                leftPath: (request.leftPath as NSString).expandingTildeInPath,
                rightProviderID: request.right.id,
                rightPath: (request.rightPath as NSString).expandingTildeInPath
            ))

            // `.info`, matching the start line above rather than the `.debug` this used to be.
            // A start and an outcome at different levels is the unpairable state this whole
            // change set exists to remove, just triggered by a setting instead of by omission:
            // at `minimumLevel == .info` every scan would log that it began and none that it
            // ended. The two lines are one record and must live or die together.
            Logger.shared.info("[scan] \(scanTag) completed: found \(results.count) differences in \(scanStart.text)")

            if autoVerifySameSizeDuringScan {
                // Unstructured on purpose: hashing must not extend the scan (isScanning would
                // hold the slot); the pass re-checks the generation before publishing.
                Task { await self.autoVerifySameSizePairs(scanGeneration: request.generation) }
            }
        } else {
            // The discarded case, which used to leave the log with a scan that started and never
            // said anything again — indistinguishable from one still running, and the reason the
            // "Internal scan" lines outnumbered the "Scan completed" ones.
            Logger.shared.info(
                "[scan] \(scanTag) discarded after \(scanStart.text)"
                + " (\(Task.isCancelled ? "cancelled" : isLatestRequest ? "no result" : "superseded by #\(scanRequestGeneration)"))")
        }

        isScanning = false
        scanStartedAt = nil

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
                //
                // HELD, because this is the one scan that runs outside a refresh task: the refresh
                // that queued it has already finished and released its key, so `cancelScan` has
                // no other way to reach it — and the Stop button, which shows for as long as
                // `isScanning`, would be a dead control for this whole scan.
                scanDrainTask = Task { await self.runOrQueueScan(pending) }
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
    /// A root that cannot be LISTED at all (permission denied) comes back as `[root node]`
    /// marked unexplored — never a bare `[]`, which would read as authoritatively empty.
    ///
    /// On the real filesystem an unlimited walk fans sibling directory subtrees out across
    /// cores at the first two levels that have siblings (`TreeBuilder.maxFanLevel`, bounded
    /// by `maxConcurrentSubtrees`), and Finder tags are fetched only when sorting by them.
    ///
    /// This used to claim the two were "together roughly an order of magnitude faster on large
    /// directories". Measured (`TreeWalkBenchmark`, Release, the two real ~40k-node pane roots):
    /// the fan-out is worth **~1.15-1.25x**, not 10x — this walk lands at 690-740 ms against
    /// 770-910 ms for a single-threaded listing+stat of the same tree, so it does strictly more
    /// work slightly faster and no more. The reason is that the walk is bounded by the directory
    /// ENUMERATION (a listing alone costs 690-830 ms of it), which is one volume's syscalls and
    /// does not divide across cores. The tags saving is the larger of the two and is measured at
    /// the declaration of `includeTags` below.
    ///
    /// Kept anyway: 1.2x on the pane's slowest phase is worth having, and none of it is on the
    /// main actor. But do not reach for more parallelism here expecting the missing 10x — it was
    /// never there, and the enumeration is the floor.
    nonisolated static func buildTree(url: URL, sortOption: SortOption, fileManager fm: FileManaging = FileManager.default, maxDepth: Int? = nil) async -> [FileNode] {
        let buildTask = Task.detached(priority: .userInitiated) {
            struct TreeBuilder: Sendable {
                let fileManager: FileManaging
                let sortOption: SortOption
                let maxDepth: Int?
                /// Reading Finder tags is a separate xattr fetch per file, so tags are fetched
                /// only when the sort actually reads them. Switching to the Tags sort reloads
                /// the trees from disk (see `sortOption.didSet`) rather than re-sorting nodes
                /// whose `tags` were never populated.
                ///
                /// The cost this avoids was recorded here as "~4x the cost of everything else in
                /// the walk combined". Measured (`TreeWalkBenchmark`, Release, the real pane
                /// roots, all four figures from ONE quiet run — the tags/name ratio is stable but
                /// the absolute numbers move with machine load, so mixing runs would invent a
                /// margin): the same walk is 690 ms / 730 ms sorting by name and 1,520 ms /
                /// 1,600 ms sorting by tags, so the xattr fetch costs about **1.2x** the rest of
                /// the walk — it roughly DOUBLES it rather than quintupling it. Still the biggest
                /// single saving in the walk, and still worth gating; just not by the margin the
                /// comment claimed.
                let includeTags: Bool
                /// Keys prefetched when listing a directory so each child's resourceValues in
                /// buildNode is a cache hit rather than a separate stat.
                let metadataKeys: [URLResourceKey]
                let metadataKeySet: Set<URLResourceKey>
                /// Metadata re-fetched from a symlink's target (type keys stay on the link).
                let symlinkTargetKeySet: Set<URLResourceKey>

                /// Once-per-scan logging for unreadable (permission-denied) directories. A shared
                /// reference across the fan-out's branch copies of the (value-type) builder; the
                /// lock makes the "log only the first" decision race-free. Per-directory logging
                /// would spam a scan of a subtree with thousands of denied entries.
                final class UnreadableListingLog: @unchecked Sendable {
                    private let lock = NSLock()
                    private var logged = false
                    func note(_ path: String) {
                        lock.lock()
                        let first = !logged
                        logged = true
                        lock.unlock()
                        guard first else { return }
                        // Hop to the main actor for the logger, same as the walk's other
                        // detached-context log sites.
                        Task { @MainActor in
                            Logger.shared.warning("Scan: could not list “\(path)” (permission denied or unreadable) — shown as unexplored, not empty; further unreadable directories in this scan are not logged individually")
                        }
                    }
                }
                let unreadableLog = UnreadableListingLog()

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

                /// Sibling DIRECTORY subtrees fan out across cores at the first two levels
                /// that actually have siblings (each subtree recursing sequentially below the
                /// horizon); more fan-out just adds task overhead. Counted in WIDE levels, not
                /// raw depth: a level with a single entry doesn't advance the fan level, so a
                /// pane root holding one big folder — a common cloud-storage layout — still
                /// parallelizes at the first level inside it.
                static let maxFanLevel = 2

                /// At most this many subtree tasks live per fan-out group. Each task blocks a
                /// cooperative-pool thread in synchronous filesystem calls, so leaving
                /// headroom keeps one slow volume from pinning the whole width-limited pool
                /// (and starving the other pane's walk and every other detached task); it
                /// also caps how many pending child tasks a huge level allocates at once.
                static let maxConcurrentSubtrees = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

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
                ///
                /// `listingFailed` is true when the directory could not be LISTED at all (permission
                /// denied, I/O error) as opposed to being legitimately empty. Both used to come back
                /// as a bare `[]`, so a permission-denied directory cached as a plain empty node and
                /// the diff minted phantom actionable "Missing" rows for its (invisible) contents.
                func childURLs(of dirURL: URL) -> (urls: [URL], listingFailed: Bool) {
                    if let realFm = fileManager as? FileManager {
                        // Fast path: one call prefetches every child's metadata so buildNode's
                        // resourceValues are cache hits. The URL-based API does not traverse a
                        // symlinked directory, so fall back to the path-based listing (which follows
                        // symlinks, as the tree always has) when it yields nothing.
                        if let prefetched = try? realFm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: metadataKeys, options: []) {
                            if !prefetched.isEmpty {
                                return (prefetched, false)
                            }
                            // An empty result is either a genuinely empty directory or a symlinked
                            // directory the URL-based API refused to traverse. Only the symlink case
                            // needs the fallback listing; for plain empty directories the symlink
                            // check is a cache hit (isSymbolicLinkKey is in metadataKeys) or one lstat,
                            // cheaper than a second directory listing.
                            let isSymlink = (try? dirURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                            if !isSymlink {
                                return (prefetched, false)
                            }
                        }
                        do {
                            let names = try realFm.contentsOfDirectory(atPath: dirURL.path)
                            return (names.map { dirURL.appendingPathComponent($0) }, false)
                        } catch {
                            return ([], true)
                        }
                    } else {
                        var urls: [URL] = []
                        guard let enumerator = fileManager.enumerator(at: dirURL, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: nil) else {
                            return ([], true)
                        }
                        for case let u as URL in enumerator {
                            urls.append(dirURL.appendingPathComponent(u.lastPathComponent))
                        }
                        return (urls, false)
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
                    var isSymlink = false
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
                            s.isSymlink = true
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

                // The three node shapes, in one place each: any change to FileNode's fields
                // or `isUnexplored` semantics lands on every walk path at once. Every one of
                // them stores `nativePath(fullURL)` rather than `fullURL.path` — see the note
                // on that function for why, and for why `name` deliberately does NOT.

                func leafNode(_ fullURL: URL, _ s: ItemStat) -> FileNode {
                    FileNode(id: FileSyncManager.nativePath(fullURL), name: fullURL.lastPathComponent, isDirectory: false, children: nil, modificationDate: s.modificationDate, fileSize: s.fileSize, tags: s.tags, kind: s.kind, isSymbolicLink: s.isSymlink)
                }

                /// A directory reported but not walked into (shallow-pass cap, cycle guard, or
                /// hard depth cap). `isUnexplored` keeps cache consumers from mistaking the
                /// artificial empty children for a genuinely empty (authoritative) deep tree.
                func cappedNode(_ fullURL: URL, _ s: ItemStat) -> FileNode {
                    FileNode(id: FileSyncManager.nativePath(fullURL), name: fullURL.lastPathComponent, isDirectory: true, children: [], modificationDate: s.modificationDate, fileSize: s.fileSize, tags: s.tags, kind: s.kind, isUnexplored: true, isSymbolicLink: s.isSymlink)
                }

                func folderNode(_ fullURL: URL, _ s: ItemStat, children: [FileNode]) -> FileNode {
                    FileNode(id: FileSyncManager.nativePath(fullURL), name: fullURL.lastPathComponent, isDirectory: true, children: children, modificationDate: s.modificationDate, fileSize: s.fileSize, tags: s.tags, kind: s.kind, isSymbolicLink: s.isSymlink)
                }

                /// The one node builder for every regime — fanned-out and sequential, real
                /// filesystem and mocks, deep and shallow passes — so their behavior can never
                /// drift apart. `visited` holds the identities of every directory on the
                /// current path (the root is seeded by the caller) as an immutable per-branch
                /// snapshot: each branch extends its own copy, giving exactly the
                /// ancestor-chain semantics a shared set with insert/remove would.
                func buildNode(at fullURL: URL, depth: Int, fanLevel: Int, visited: Set<DirectoryIdentity>) async -> FileNode? {
                    guard !Task.isCancelled, let s = stat(at: fullURL) else { return nil }
                    guard s.isDirectory else { return leafNode(fullURL, s) }
                    return await buildDirectoryNode(at: fullURL, stat: s, depth: depth, fanLevel: fanLevel, visited: visited)
                }

                /// The directory branch of `buildNode`, split out so the fan-out — which has
                /// already statted the child to decide it's a directory — can enter without a
                /// second stat.
                func buildDirectoryNode(at fullURL: URL, stat s: ItemStat, depth: Int, fanLevel: Int, visited: Set<DirectoryIdentity>) async -> FileNode {
                    // Depth-capped (shallow) pass: report the directory but don't walk into
                    // it — empty children keep it rendering as a folder until the deep pass.
                    if let maxDepth, depth >= maxDepth {
                        return cappedNode(fullURL, s)
                    }
                    // Symlinked directories are deliberately followed (the panes display
                    // linked content), but a link back into a directory already on the
                    // current path is a cycle (A/loop -> A) that would recurse forever.
                    // Show such a directory once, unexplored — same shape as the depth cap.
                    let identity = directoryIdentity(of: fullURL)
                    if visited.contains(identity) || depth >= Self.hardDepthCap {
                        return cappedNode(fullURL, s)
                    }
                    var branchVisited = visited
                    branchVisited.insert(identity)
                    let listing = childURLs(of: fullURL)
                    // A directory whose LISTING failed (permission denied, I/O error) is not an
                    // empty directory: mark it unexplored — the same shape as the depth cap — so
                    // cache consumers and the diff never mistake "couldn't look" for "empty" and
                    // mint phantom Missing rows for contents nobody could see.
                    if listing.listingFailed {
                        unreadableLog.note(fullURL.path)
                        return cappedNode(fullURL, s)
                    }
                    var children = await walkChildren(listing.urls, depth: depth + 1, fanLevel: fanLevel, visited: branchVisited)
                    children = FileSyncManager.sortLevel(nodes: children, by: sortOption)
                    return folderNode(fullURL, s, children: children)
                }

                /// Builds the nodes for one directory level, in listing order (callers apply
                /// `sortLevel`, but equal-key ties must not depend on task completion order).
                ///
                /// On the real filesystem's unlimited walks, levels within the fan-out horizon
                /// stat every child inline — plain files resolve right here, costing no task —
                /// and give each DIRECTORY subtree its own child task, at most
                /// `maxConcurrentSubtrees` live at a time (a sliding window: each completion
                /// admits the next). Everything else — injected mocks (not guaranteed
                /// thread-safe), depth-capped shallow passes (nothing to spread), and levels
                /// below the horizon — recurses sequentially within the current task.
                func walkChildren(_ urls: [URL], depth: Int, fanLevel: Int, visited: Set<DirectoryIdentity>) async -> [FileNode] {
                    // Diagnostic only, and off unless someone asks for it — see `WalkStall`.
                    await WalkStall.perDirectory()

                    // A single-entry level doesn't advance the fan level: parallelism should
                    // engage at the first level that actually HAS siblings to spread.
                    let childFanLevel = urls.count > 1 ? fanLevel + 1 : fanLevel

                    guard fileManager is FileManager, maxDepth == nil, fanLevel < Self.maxFanLevel, urls.count > 1 else {
                        var children: [FileNode] = []
                        children.reserveCapacity(urls.count)
                        for url in urls {
                            if let node = await buildNode(at: url, depth: depth, fanLevel: childFanLevel, visited: visited) {
                                children.append(node)
                            }
                        }
                        return children
                    }

                    // Inline stat pass: files resolve immediately; directories reserve their
                    // listing-order slot and queue for the bounded fan-out below.
                    var nodes: [FileNode?] = []
                    nodes.reserveCapacity(urls.count)
                    var subtrees: [(slot: Int, url: URL, stat: ItemStat)] = []
                    for url in urls {
                        if Task.isCancelled { break }
                        guard let s = stat(at: url) else { continue }
                        if s.isDirectory {
                            nodes.append(nil)
                            subtrees.append((slot: nodes.count - 1, url: url, stat: s))
                        } else {
                            nodes.append(leafNode(url, s))
                        }
                    }

                    if !subtrees.isEmpty {
                        let filled: [(Int, FileNode)] = await withTaskGroup(of: (Int, FileNode).self) { group in
                            var iterator = subtrees.makeIterator()
                            func addNext() -> Bool {
                                guard let item = iterator.next() else { return false }
                                group.addTask {
                                    (item.slot, await self.buildDirectoryNode(at: item.url, stat: item.stat, depth: depth, fanLevel: childFanLevel, visited: visited))
                                }
                                return true
                            }
                            var started = 0
                            while started < Self.maxConcurrentSubtrees, addNext() { started += 1 }
                            var results: [(Int, FileNode)] = []
                            results.reserveCapacity(subtrees.count)
                            for await result in group {
                                results.append(result)
                                _ = addNext()
                            }
                            return results
                        }
                        for (slot, node) in filled {
                            nodes[slot] = node
                        }
                    }
                    return nodes.compactMap { $0 }
                }
            }

            let builder = TreeBuilder(fileManager: fm, sortOption: sortOption, maxDepth: maxDepth)
            // Batch logging to avoid MainActor overhead in recursion
            // (Removed per-node logging)

            let rootListing = builder.childURLs(of: url)
            // The walk returns the root's CHILDREN, so an unreadable ROOT has no child node to
            // carry the unexplored marker — a bare [] read downstream as an authoritatively
            // empty tree, and the diff minted phantom actionable Missing rows for everything
            // the other side holds (the per-subdirectory marking above never fires for the
            // root itself). Return the root as a single unexplored node instead: the diff
            // (via `filesInfo(fromTree:)`), duplicates, and storage all treat it like any
            // other directory whose contents are unknown, and `adoptRawTree` unwraps the
            // marker so the panes still render the folder as empty rather than showing it
            // nested inside itself.
            if rootListing.listingFailed {
                builder.unreadableLog.note(url.path)
                let s = builder.stat(at: url) ?? TreeBuilder.ItemStat(isDirectory: true)
                return [builder.cappedNode(url, s)]
            }
            // Seed the walk root's identity so a symlink pointing back at the root is
            // recognized as a cycle immediately.
            let visited: Set<TreeBuilder.DirectoryIdentity> = [builder.directoryIdentity(of: url)]
            var rootChildren = await builder.walkChildren(rootListing.urls, depth: 1, fanLevel: 0, visited: visited)
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

    /// `url.path` with its storage forced native, for `FileNode.id`.
    ///
    /// `URL.path` hands back a string lazily bridged from `NSString`, which has no contiguous
    /// UTF-8 buffer — so every consumer that reaches for bytes pays to materialize them, and Swift's
    /// cheap path for hashing a string (which wants exactly that buffer) is unavailable. `id` is
    /// the app's universal dictionary and set key, so it is spent almost entirely on hashing:
    /// measured in Release over this Mac's two provider roots, a lookup runs 13x slower bridged, a
    /// dictionary build 9-10x, and a plain `for byte in path.utf8` loop 7.5x — the last of which is
    /// the tell that the cause is the missing buffer rather than ObjC dispatch.
    ///
    /// Paying the round-trip once per node, here, converts that. Per pane it costs 11.0-13.4 ms of
    /// a 395-423 ms walk and returns 122-165 ms across one load and one scan — `filesInfo` -101 to
    /// -131 ms, the `PaneChildrenIndex` build -30 to -44 ms on the main actor. See
    /// `docs/string-bridging.md` and `BridgedStringBenchmark`.
    ///
    /// **`name` is deliberately left bridged.** Nothing is keyed on it, and its one whole-tree
    /// consumer is `sortLevel`'s `localizedStandardCompare` — an `NSString` method that a bridged
    /// string hands itself to for free and a native one must be bridged out for. Nativizing it too
    /// measured 16-18 ms per pane WORSE. The asymmetry is the finding; do not "finish the job".
    ///
    /// Byte-identical by construction: `String.utf8` is valid UTF-8 and decoding valid UTF-8 gives
    /// back the same scalars, so equality, ordering, hashing, `hasPrefix` and every byte-level scan
    /// see exactly what they saw before. Do NOT substitute
    /// `String(cString: url.fileSystemRepresentation)`, which would be cheaper but is not obviously
    /// normalization-identical to `URL.path` — and a silent NFC/NFD shift in a diff key is the very
    /// failure `nearNameKey` exists to compensate for.
    nonisolated static func nativePath(_ url: URL) -> String {
        String(decoding: Array(url.path.utf8), as: UTF8.self)
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
                // Break ties by name (like .kind/.tags): equal dates are common after a bulk copy,
                // and without a tiebreaker the non-stable sort would order such siblings by input
                // listing order — which can differ between panes or shift between scans and trigger
                // a spurious tree republish.
                if dA == dB { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return dA > dB
            case .size:
                let sA = a.fileSize ?? 0
                let sB = b.fileSize ?? 0
                if sA == sB { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
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
