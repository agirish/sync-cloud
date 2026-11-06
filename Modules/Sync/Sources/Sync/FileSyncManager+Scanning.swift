import Events
import Foundation

/// A span measured on two clocks, because a wall clock also counts time the Mac spent asleep.
/// With one clock, a slow walk and a lid closed mid-walk print the same number, and the sleeps
/// drown out the slow walks worth finding.
///
/// `SuspendingClock` stops while the system sleeps; `ContinuousClock` doesn't. This reports the
/// first and names the difference when it matters. It can't separate a process that was merely
/// descheduled or App-Napped: both clocks run then, so a large `active` means "took long", not
/// necessarily "did long work".
struct Elapsed {
    private let active: SuspendingClock.Instant
    private let wall: ContinuousClock.Instant

    init() {
        active = SuspendingClock.now
        wall = ContinuousClock.now
    }

    /// `nnn.n ms` under a second, `n.nn s` above it, as ``FileSyncManager/durationText(since:)``
    /// prints, so log lines read alike. A span the machine slept through gains a clause rather than
    /// a bigger number.
    var text: String {
        Self.describe(active: Self.seconds(SuspendingClock.now - active),
                      wall: Self.seconds(ContinuousClock.now - wall))
    }

    /// The formatting, apart from the clocks so tests can feed it spans no test could wait for,
    /// such as an hour of sleep.
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
            // The pane's load token, on every line this load emits, so a start line can be matched
            // to its outcome: the panes interleave, navigations supersede loads, and a progressive
            // load publishes twice. Reuses the spinner's generation rather than a second identity
            // that could disagree with it.
            let tag = "\(isLeft ? "left" : "right") #\(loadToken)"
            let startedAt = Elapsed()
            Logger.shared.debug("[load] \(tag) start \(path)\(relativeSuffix(isLeft: isLeft))")

            // What this load ended up doing, set at every exit. The default names an exit that
            // set nothing. Only the `defer` below writes the outcome line, so no `return` skips it.
            //
            // Node counts are raw walked nodes (`countItems`), not the filtered item count, because
            // a walk's cost is per node walked. Counting costs one main-actor traversal (~5 ms per
            // 40k nodes), which the reported duration includes.
            var outcome = "ended without reaching a known exit"

            // Whatever exit this load takes (completion, cache hit, or cancellation between the
            // walks), release the loading spinner, but only while this load is still the pane's
            // current one: a newer load owns the flag. Otherwise a load cancelled with no
            // successor would leave the spinner up until the next navigation.
            defer {
                let stillCurrent = isLeft ? (leftLoadGeneration == loadToken) : (rightLoadGeneration == loadToken)
                let wasLoading = isLeft ? isLoadingLeftTree : isLoadingRightTree
                var strandedSpinner = false
                if stillCurrent, wasLoading {
                    if isLeft { isLoadingLeftTree = false } else { isLoadingRightTree = false }
                    strandedSpinner = Task.isCancelled
                }
                // The one line per load with its outcome and duration, from the `defer` so every
                // exit is covered.
                Logger.shared.debug(
                    "[load] \(tag) \(outcome) in \(startedAt.text)"
                    + (strandedSpinner ? "; cleared its stale loading spinner" : ""))
            }

            let relPath = isLeft ? leftRelativePath : rightRelativePath
            let rootURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            // See `focusURL(root:relative:fallback:links:)` — the link resolution is the point.
            let links = self.linkedFolders
            let focusURL = Self.focusURL(root: path, relative: relPath, fallback: rootURL, links: links)
            let focusPath = focusURL.path
            // Before anything is read: the watcher moves to this folder first, so the id taken
            // next orders every change after it against this load (`PaneWatchState`).
            let walkMark = self.noteFolderWatchLoad(isLeft: isLeft, focusPath: focusPath)

            // Fast path: serve the focus from the cache without touching the disk, as a direct hit
            // or a slice of the cached root tree (deep, so drill-down and breadcrumbs are instant).
            // File operations, sort changes and force refresh clear the cache, so this never
            // serves stale post-operation state.
            let direct = prefetchedTrees[focusPath]
            let cached = direct ?? Self.subtree(atPath: focusPath, under: rootURL.path,
                                                in: prefetchedTrees[rootURL.path], links: links)
            if let cached {
                // A slice inherits the root walk's stopped bit, since it may hold some of what went
                // unwalked. Over-inheriting is harmless: the warm scan re-checks for unexplored
                // directories before it banners.
                if prefetchedTreeWalkStopped.contains(rootURL.path) {
                    prefetchedTreeWalkStopped.insert(focusPath)
                }
                prefetchedTrees[focusPath] = cached
                // The read stamp travels the same way: a slice is as old as the root's walk. Only
                // when missing, since a direct hit carries its own, newer one.
                if prefetchedTreeReadAt[focusPath] == nil {
                    prefetchedTreeReadAt[focusPath] = prefetchedTreeReadAt[rootURL.path]
                }
                if prefetchedTreeReadMark[focusPath] == nil {
                    prefetchedTreeReadMark[focusPath] = prefetchedTreeReadMark[rootURL.path]
                }
                // And the folder links the root's walk followed. Liberally, like the stopped bit:
                // the record doesn't say where each link sits, so a slice inherits them all, which
                // can cost a needless drop but never a stale tree. A direct hit has its own record.
                if direct == nil {
                    prefetchedTreeLinkTargets[focusPath] = prefetchedTreeLinkTargets[rootURL.path]
                }
                // An entry with no stamp (one a test wrote) gets `Date()`. One with no mark counts
                // as the oldest walk there is, so any change the watcher reports postdates it.
                self.adoptRawTree(cached, isLeft: isLeft, focusPath: focusPath,
                                  readAt: prefetchedTreeReadAt[focusPath] ?? Date(),
                                  readMark: prefetchedTreeReadMark[focusPath] ?? 0,
                                  linkTargets: prefetchedTreeLinkTargets[focusPath] ?? [])
                await self.applyFilters()
                outcome = "served \(Self.countItems(in: cached)) nodes from cache"
                // The deferred cleanup above releases any spinner a cancelled slow load left up.
                return
            }

            // Slow Path: Load actively
            if isLeft { isLoadingLeftTree = true }
            else { isLoadingRightTree = true }

            // buildTree detaches its own worker (and forwards cancellation into it),
            // so no extra detached hop is needed here.
            let fm = self.fileManager
            let reads = self.datalessFolderReads
            let sortOp = self.sortOption
            // Config epoch before the walks: if a file operation (or any scan-affecting change)
            // lands while they run, this load's tree predates it and must not be cached.
            let configToken = self.scanConfigGeneration

            // Progressive first paint: publish the immediate children (one listing), then the deep
            // tree when the walk finishes, but only when the pane has nothing valid for this focus.
            // A same-focus refresh keeps the current deep tree until the new one lands, rather than
            // flashing shallow rows. The loading flag stays up until the deep tree lands, which
            // keeps pruneSelection off the interim tree.
            let currentTree = isLeft ? rawLeftTree : rawRightTree
            let lastFocus = isLeft ? lastLoadedLeftFocusPath : lastLoadedRightFocusPath
            if currentTree.isEmpty || lastFocus != focusPath {
                let shallowStart = Elapsed()
                let shallowLinks = FollowedLinks()
                let shallowTree = await Self.buildTree(url: focusURL, sortOption: sortOp, fileManager: fm, maxDepth: 1,
                                                       linkedFolders: links, followedLinks: shallowLinks,
                                                       datalessReads: reads)
                let shallowWalk = shallowStart.text
                guard !Task.isCancelled else {
                    outcome = "superseded during the shallow walk (walk \(shallowWalk))"
                    return
                }
                let shallowPublishStart = CFAbsoluteTimeGetCurrent()
                self.adoptRawTree(shallowTree, isLeft: isLeft, focusPath: focusPath,
                                  readMark: walkMark, linkTargets: shallowLinks.targets)
                await self.applyFilters()
                // The shallow pass is its own `buildTree`, a separate cost from the deep walk, so
                // it gets its own line.
                Logger.shared.debug(
                    "[load] \(tag) shallow first paint \(Self.countItems(in: shallowTree)) nodes"
                    + " (walk \(shallowWalk), publish \(Self.durationText(since: shallowPublishStart)))")
            }

            let deepStart = Elapsed()
            // Held, not inlined: after the walk, `didStopADescent` says whether this tree is the
            // whole folder. The warm scan needs it to report partial coverage (the walk-stopped
            // overload of `PartialComparison.of`); without it a truncated tree reads `.complete`.
            let paneBudget = NodeBudget(Self.paneNodeBudget,
                                        note: "Scan: this folder is larger than a pane walks in one pass — the rest is shown as unexplored, not empty, and columns load it when you open them")
            // Held for the same reason: the next write through a followed folder link must find
            // this entry (`FollowedLinks`).
            let followedLinks = FollowedLinks()
            let tree = await Self.buildTree(
                url: focusURL, sortOption: sortOp, fileManager: fm, budget: paneBudget, linkedFolders: links,
                followedLinks: followedLinks, datalessReads: reads)
            let deepWalk = deepStart.text

            guard !Task.isCancelled else {
                outcome = "superseded during the deep walk (walk \(deepWalk))"
                return
            }

            let publishStart = CFAbsoluteTimeGetCurrent()
            let published = await self.adoptFreshDeepTree(tree, builtWith: sortOp, isLeft: isLeft, focusPath: focusPath,
                                                          loadToken: loadToken, configToken: configToken,
                                                          walkStopped: paneBudget.didStopADescent,
                                                          readMark: walkMark,
                                                          linkTargets: followedLinks.targets)
            // `adoptFreshDeepTree` can bail without publishing (cancelled during its re-sort), and
            // that is not a completion.
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
    /// `builtWith` is the sort option the walk captured; it can change during the walk, leaving
    /// the tree in the old order and, for the Tags sort, without the tags only that sort fetches.
    /// On a mismatch the tree is re-sorted off the main actor before publishing, and is not
    /// cached: `sortOption.didSet` cleared the cache for a fresh walk, and the fast path serves
    /// cached trees as-is, so writing this one back would poison it.
    /// - Returns: Whether the tree was published. The one early exit (cancelled during the
    ///   re-sort) leaves the previous tree, and `loadTree` reports a superseded load.
    @discardableResult
    /// - Parameter walkStopped: whether `paneNodeBudget` stopped the walk that built `tree`,
    ///   recorded beside the cache entry so a later warm scan can report partial coverage. False
    ///   by default, for tests that adopt hand-built trees.
    /// - Parameter linkTargets: where that walk read through a folder link (`FollowedLinks`),
    ///   published with the pane and recorded beside the entry. Empty by default, for those tests.
    /// - Parameter readMark: the FSEvents id read before that walk started; see `adoptRawTree`.
    func adoptFreshDeepTree(_ tree: [FileNode], builtWith sortOp: SortOption, isLeft: Bool, focusPath: String,
                            loadToken: Int, configToken: Int, walkStopped: Bool = false,
                            readMark: UInt64? = nil, linkTargets: Set<String> = []) async -> Bool {
        var tree = tree
        let liveSort = sortOption
        if liveSort != sortOp {
            let stale = tree
            tree = await Task.detached(priority: .userInitiated) {
                Self.sort(nodes: stale, by: liveSort)
            }.value
            guard !Task.isCancelled else { return false }
        }
        adoptRawTree(tree, isLeft: isLeft, focusPath: focusPath, readMark: readMark, linkTargets: linkTargets)
        // The option can change again during the re-sort, and this adopt's generation bump
        // discards the resort that change scheduled, so re-sort once more (generation-guarded).
        if sortOption != liveSort {
            Task { await self.resortTreesAndRefilter() }
        }
        await applyFilters()
        // Release the spinner only while this load is still current, as in loadTree. A superseded
        // load resuming after applyFilters would clear its successor's spinner mid-walk, and so
        // let pruneSelection wipe selections deeper than the interim shallow tree.
        let stillCurrent = isLeft ? (leftLoadGeneration == loadToken) : (rightLoadGeneration == loadToken)
        if stillCurrent {
            if isLeft {
                isLoadingLeftTree = false
            } else {
                isLoadingRightTree = false
            }
        }
        // Cache the deep tree for this focus (never the shallow one: cache consumers, the
        // in-memory diff included, rely on cached trees being fully walked), and only when:
        //  - the sort option never moved during this load (cached trees are served verbatim);
        //  - the scan-config epoch never moved (a file operation finishing mid-load cleared the
        //    cache, and writing this pre-operation tree back would serve stale state as current);
        //  - `liveSort == sortOp`, so no re-sort happened above. A re-sorted tree has the new
        //    order but the old option's metadata (a Name-built tree has no tags), and would poison
        //    the fast path once the option returns. Cache only the unmodified build.
        if sortOption == sortOp, liveSort == sortOp, scanConfigGeneration == configToken, !Task.isCancelled {
            prefetchedTrees[focusPath] = tree
            // Reuse the pane's own stamp rather than a second `Date()`, so the entry and the pane
            // agree exactly and a later cache hit reproduces this moment.
            prefetchedTreeReadAt[focusPath] = (isLeft ? leftTreeReadAt : rightTreeReadAt) ?? Date()
            prefetchedTreeReadMark[focusPath] = (isLeft ? leftWatch : rightWatch).readMark
            // Both directions: a fresh complete walk must also clear a stale stopped mark, or the
            // banner would outlive the truncation.
            if walkStopped {
                prefetchedTreeWalkStopped.insert(focusPath)
            } else {
                prefetchedTreeWalkStopped.remove(focusPath)
            }
            // Both directions here too: a re-walk that no longer meets a link retires the record.
            prefetchedTreeLinkTargets[focusPath] = linkTargets.isEmpty ? nil : linkTargets
        }
        return true
    }

    /// `nnn.n ms` under a second, `n.nn s` above it: one shape for every load duration, so the log
    /// can be read and parsed without guessing units.
    ///
    /// - Note: prefer ``Elapsed`` for anything that can run long. This reads one wall clock and so
    ///   cannot say whether a large number is work or a sleeping Mac; see that type.
    nonisolated static func durationText(since start: CFAbsoluteTime) -> String {
        let seconds = CFAbsoluteTimeGetCurrent() - start
        return seconds < 1 ? String(format: "%.1f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }

    /// How long ago a cached walk read its folder, for the scan's line: "just now", "42 s ago",
    /// "12 min ago", "4 h 3 min ago". Whole units: the question is whether the comparison is
    /// minutes or hours old. nil reads "at an unrecorded time".
    nonisolated static func ageText(since date: Date?, now: Date) -> String {
        guard let date else { return "at an unrecorded time" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<1: return "just now"
        case ..<60: return "\(seconds) s ago"
        case ..<3600: return "\(seconds / 60) min ago"
        default: return "\(seconds / 3600) h \(seconds % 3600 / 60) min ago"
        }
    }

    /// The pane's relative path, for the load's start line: the same root at a different focus is
    /// a different load.
    func relativeSuffix(isLeft: Bool) -> String {
        let relative = isLeft ? leftRelativePath : rightRelativePath
        return relative.isEmpty ? "" : " (focus: \(relative))"
    }

    /// Whether `tree` is a walk of `folder` that couldn't list it: `buildTree` returns the folder
    /// itself marked unexplored, never a bare `[]`, so the cache and the diff know its contents are
    /// unknown, not empty. Each consumer handles the shape: a pane unwraps it, a column graft leaves
    /// it alone, and a source switch doesn't keep it.
    nonisolated static func isUnreadableRootWalk(_ tree: [FileNode], at folder: String) -> Bool {
        tree.count == 1 && tree[0].isUnexplored == true && tree[0].id == folder
    }

    /// Publishes a freshly built (or cache-served) raw tree for one pane. Also bumps
    /// `rawTreeGeneration`, which invalidates any off-main resort snapshot in flight —
    /// this tree was built with the current sort option already applied.
    /// - Parameter readAt: when the walk behind `tree` read the disk. Defaults to now; the cache
    ///   fast path passes the walk's own stamp, since a served tree is as old as its walk and
    ///   Browse's freshness segment would otherwise claim a re-read.
    /// - Parameter linkTargets: where that walk read through a folder link (see
    ///   `leftTreeLinkTargets`). Empty by default, for a hand-built tree.
    /// - Parameter readMark: the FSEvents id read before that walk started, which the folder
    ///   watcher's changes are ordered against (`PaneWatchState`). nil reads the id now.
    func adoptRawTree(_ tree: [FileNode], isLeft: Bool, focusPath: String,
                      readAt: Date = Date(), readMark: UInt64? = nil, linkTargets: Set<String> = []) {
        // An unreadable root comes back as itself marked unexplored (`isUnreadableRootWalk`).
        // The pane must not show the folder nested inside itself, so unwrap it and show it empty.
        var tree = tree
        if Self.isUnreadableRootWalk(tree, at: focusPath) {
            tree = []
        }
        rawTreeGeneration += 1
        // A fresh walk is when an unreadable folder may have become readable: ask again.
        columnGraftsUnreadable = columnGraftsUnreadable.filter { $0.isLeft != isLeft }
        if isLeft {
            rawLeftTree = tree
            lastLoadedLeftFocusPath = focusPath
            leftTreeReadAt = readAt
            leftTreeLinkTargets = linkTargets
        } else {
            rawRightTree = tree
            lastLoadedRightFocusPath = focusPath
            rightTreeReadAt = readAt
            rightTreeLinkTargets = linkTargets
        }
        noteFolderWatchRead(isLeft: isLeft, readMark: readMark ?? FolderWatcher.currentEventId())
    }

    /// The children of the directory at `path` inside a deep tree walked at `root`, or nil when
    /// the path isn't there (or `tree` is nil), so navigation can drill down from an ancestor's
    /// cached tree without a walk. An `isUnexplored` node is a miss, not an empty folder: served as
    /// a deep tree, its `[]` would make the diff report the whole other side as missing. A miss
    /// sends the caller to a fresh walk rooted at that path.
    ///
    /// Found by the names down from `root` (`TreeShape.position`), not by id prefix: below a folder
    /// symlink, or under a root reached through one, the walk spells ids differently from `path`.
    nonisolated static func subtree(atPath path: String, under root: String, in tree: [FileNode]?,
                                    links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders)
    -> [FileNode]? {
        guard let tree, let position = TreeShape.position(of: path, under: root, in: tree, links: links),
              let folder = TreeShape.node(at: position, in: tree) else { return nil }
        return folder.isUnexplored == true ? nil : (folder.children ?? [])
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
    /// - Parameter reloading: which panes need their tree walked again. `.both` (the default) for
    ///   anything that changes what a walk would produce: a file operation, a forced rescan, a sort
    ///   or hidden-files change, a provider switch.
    ///
    ///   A tab switch re-points one pane and asks for that one only. The caller says so; this
    ///   never infers "looks unchanged", because staleness sources clear only `prefetchedTrees`,
    ///   not the live tree or `lastLoadedFocusPath`, so an inferred skip would serve pre-operation
    ///   state. The scan still compares both panes, using the tree the other already holds.
    ///
    /// - Parameter comparing: whether the reload is followed by the two-pane comparison (`true` by
    ///   default). `false` when the comparison wouldn't be displayed: the single-source workspaces
    ///   (Browse, the lenses, Editor) show one tree and no differences.
    ///
    ///   A skipped comparison is owed, not cancelled: the focus has moved, so the differences in
    ///   hand describe the wrong folder. The caller must have it made before anything displays it
    ///   (`ContentView.owedComparison`).
    public func refreshTreesAndScan(left: CloudProvider, right: CloudProvider,
                                    reloading requested: PaneReloadScope = .both,
                                    comparing: Bool = true) async {
        // **A narrower refresh must never cancel a wider one down to nothing.** This supersedes
        // whatever is in flight: a one-pane refresh cancelling a two-pane load would leave the
        // other pane blank until something refreshed it. So scopes are unioned: any disagreement
        // with the running refresh widens this one to `.both`. Identical scopes stay, which keeps
        // the dedupe below working for a repeated one-pane switch.
        let inFlightScope = activeRefreshKey?.reloading
        let widenedBy: PaneReloadScope? = {
            // Only a one-pane request is widened; a `.both` request is already as wide as it goes,
            // and announcing a widening for it would be false.
            guard let inFlightScope, inFlightScope != requested, requested != .both else { return nil }
            return inFlightScope
        }()
        let reloading: PaneReloadScope =
            (inFlightScope != nil && inFlightScope != requested) ? .both : requested
        let key = makeRefreshKey(left: left, right: right, reloading: reloading)
        // Launch fires several identical refreshes. One already in flight for the same target
        // does the work, so skip the duplicate rather than cancel and restart it, which could
        // strand a pane's load and leave it blank. A different target still supersedes, and the
        // target includes the scan-config epoch (RefreshKey.config), so a refresh after a config
        // change or invalidation isn't swallowed as a duplicate.
        if activeRefreshKey == key {
            Logger.shared.debug("Skipping duplicate in-flight refresh for the same target")
            return
        }
        // Explains a walk the request didn't name (a `.leftOnly` switch followed by
        // `[load] right #N start`). Logged after the dedupe, because a widened request can equal
        // the key in flight and return without walking anything. `.info`, not `.debug`, since it
        // accounts for a visible reload and `.debug` is dropped at the Info level.
        if let widenedBy {
            Logger.shared.info("Widening a \(requested) refresh to both panes: a "
                               + "\(widenedBy) refresh was already in flight")
        }
        activeRefreshTask?.cancel()
        activeRefreshKey = key

        let task = Task {
            let leftRoot = (left.rootPath as NSString).expandingTildeInPath
            let rightRoot = (right.rootPath as NSString).expandingTildeInPath

            // The two pane loads are independent (disjoint state, each on its own detached
            // worker), so they run concurrently. Cancelling this task cancels both.
            switch reloading {
            case .both:
                async let leftLoad: Void = self.loadTree(path: leftRoot, isLeft: true)
                async let rightLoad: Void = self.loadTree(path: rightRoot, isLeft: false)
                _ = await (leftLoad, rightLoad)
            case .leftOnly:
                await self.loadTree(path: leftRoot, isLeft: true)
            case .rightOnly:
                await self.loadTree(path: rightRoot, isLeft: false)
            }
            guard !Task.isCancelled else { return }
            
            if comparing {
                // The pane's own focus expression, so the scan finds what the pane cached. A folder
                // the root only links to (iCloud Drive → Documents) is cached under its real path
                // (`focusURL`); joined lexically, the scan would walk the link, list nothing, and
                // report everything opposite as missing.
                let links = self.linkedFolders
                let currentLeftFull = Self.focusURL(root: leftRoot, relative: leftRelativePath,
                                                    fallback: URL(fileURLWithPath: leftRoot, isDirectory: true),
                                                    links: links).path
                let currentRightFull = Self.focusURL(root: rightRoot, relative: rightRelativePath,
                                                     fallback: URL(fileURLWithPath: rightRoot, isDirectory: true),
                                                     links: links).path

                await scanDirectories(
                    left: left, leftPath: currentLeftFull,
                    right: right, rightPath: currentRightFull
                )
                guard !Task.isCancelled else { return }
            }
            self.scheduleSelectionPrune()
            self.sweepOrphanedTempArtifacts()
        }
        
        activeRefreshTask = task
        await task.value
        // Release the key only while this refresh is current; a superseding one owns the cleanup.
        // Matched by task identity, not key alone: a stale refresh unwinding late must not clear
        // the key of a newer refresh for the same target, or a duplicate could cancel and restart
        // it and strand a pane.
        if activeRefreshKey == key, activeRefreshTask == task {
            activeRefreshKey = nil
            // A change the folder watcher reported while this ran was held for now.
            tellOwedPaneChanges()
        }
    }

    /// Post-refresh hygiene: removes `.tmp_<UUID>` working files a crashed or force-quit safe
    /// copy/move left behind (normal exits clean up via `defer`). Candidates come from the trees
    /// this refresh just walked, so no extra I/O. `.rollback_<UUID>` backups stay: they are the
    /// undo stack's handle and may be the only copy of a replaced file.
    ///
    /// **Never runs while a file operation is in flight.** The age gate alone doesn't make a temp
    /// safe: a staged temp inherits its source's modification date, so it can be past
    /// `minimumAge` at birth, and a sweep during a slow `replaceItem` would trash the operation's
    /// only staged copy. The counter covers the whole operation. Waiting loses nothing; only a
    /// quiet moment tells an orphan from a temp in use.
    ///
    /// Deliberately outside `enqueueFileOperation` and doesn't bump `fileOperationsEpoch`. Safe for
    /// the hashing passes: `trashItem` only renames an artifact away, never rewriting bytes, so no
    /// removal turns a differing pair into "identical". Safe for `confirmVerifiedCopy`: a swept
    /// `.tmp_<UUID>` can't be a pair in the offer, which needs the same name, UUID included, on
    /// both sides. A bump would discard the checksum batch hashing at the same moment and refuse a
    /// standing copy offer. Enqueueing would also block Verify All, hold the quit guard and trigger
    /// another full refresh. Pinned by
    /// `AutoVerifyOnScanTests.testOrphanSweepDuringTheHashDoesNotDiscardTheBatch`.
    ///
    /// - Returns: Whether the sweep was allowed to look. Removal is detached, so this is the only
    ///   part a caller or test can observe synchronously; without it "nothing swept" and "nothing
    ///   swept yet" look the same.
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
                // The swept entries are in the cached trees; drop the cache so navigation
                // doesn't serve ghost entries.
                self.dropPrefetchedTrees()
            }
        }
        return true
    }

    /// User-triggered sweep from Settings → Advanced. Same age-gated, `.rollback_`-preserving
    /// pass as the automatic post-refresh sweep, plus a banner so the click visibly did
    /// something (the automatic pass logs quietly).
    public func sweepOrphanedTempArtifactsNow() {
        // The automatic pass declines silently during operations; a click must say so, or the
        // success banner would claim a check that never happened.
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

    /// Runs the request now, or queues it when a scan holds the slot (the drain at the end of
    /// `executeScan` picks it up). Separate from `scanDirectories` so the drain can re-enter without
    /// a new generation: a re-queued request must stay older than any scan started while it waited,
    /// so the generation-gated publish still discards it.
    private func runOrQueueScan(_ request: ScanRequest) async {
        if isScanning {
            // Only ever queue forward: a drain re-queueing an older request must not clobber
            // a newer one that arrived while the drain's task was waiting to run.
            if let queued = pendingScanRequest, queued.generation > request.generation { return }
            pendingScanRequest = request
            // Routine coalescing, so a diagnostic, not a warning. Tagged with the generation of the
            // request, whose start line appears later when the drain runs it.
            Logger.shared.debug("[scan] #\(request.generation) queued behind a scan already in progress")
            return
        }
        await executeScan(request)
    }

    /// Stops the running scan (and the tree loads in front of it) at the user's request.
    ///
    /// A scan runs one of two ways, and both must be cancellable. Usually it is inside
    /// `refreshTreesAndScan`'s task, behind the pane loads, so cancelling that task stops all of
    /// it. A scan queued behind a superseded one is drained on an unstructured task
    /// (`scanDrainTask`) after its refresh has finished, where cancelling `activeRefreshTask` does
    /// nothing. Both are cancelled unconditionally; cancelling a finished task is a no-op.
    ///
    /// Liveness is `isScanning` or a live `activeRefreshKey`, never `activeRefreshTask`, which is
    /// only ever overwritten, so a finished one lingers. The key covers the loads before a scan;
    /// `isScanning` covers a drained scan, which has no key. The Stop shows only from
    /// `isScanShown` on, always inside that window.
    ///
    /// The queued request goes too, or the drain would start a fresh scan the moment this one
    /// unwound. `activeRefreshKey` is left for the cancelled task's own cleanup, which would race
    /// a clear here. A retry isn't deduped away: user rescans go through `forceRefreshAction`,
    /// whose `prepareForcedRescan()` bumps the config epoch in `RefreshKey`. `executeScan`'s
    /// publish gate discards the cancelled results and still clears `isScanning`.
    public func cancelScan() {
        guard isScanning || activeRefreshKey != nil else { return }
        Logger.shared.info("[scan] cancelled by the user")
        pendingScanRequest = nil
        activeRefreshTask?.cancel()
        scanDrainTask?.cancel()
    }

    private func executeScan(_ request: ScanRequest) async {
        isScanning = true
        let started = Date()
        scanStartedAt = started
        // `isScanShown` rises only if this scan is still running when the wait ends. Keyed on its
        // start time, so a wait outliving its scan can't light up the next one early.
        scanShownTask?.cancel()
        scanShownTask = Task { [scanShownWait] in
            await scanShownWait()
            guard !Task.isCancelled, isScanning, scanStartedAt == started else { return }
            isScanShown = true
        }
        // Tagged with the request generation, like the load lines, so a start line pairs with its
        // outcome even when a refresh supersedes the scan mid-flight.
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

        // In-memory fast path: when both focused folders have deep trees in the prefetch cache
        // (file operations clear it, so cached means current), derive the comparison maps from
        // the trees instead of walking the disk. The saving is modest (~15–20% at 40k nodes),
        // since building the `[String: FileInfo]` map dominates both branches
        // (`TreeWalkBenchmark`).
        //
        // Both sources report symlinked entries with the target's size and date; but the tree
        // builder walks into symlinked directories (as the panes show them), while the disk
        // enumerator reports the linked directory without its contents.
        // Both compute branches run detached, so the diff never blocks the main actor, and
        // forward cancellation explicitly as `buildTree` does: detached tasks don't inherit it,
        // and a superseded scan would hold `isScanning` through a walk that will be discarded.
        /// What a completed compute produces, carried together so the coverage lands under the same
        /// publish gate as its rows. Published separately, a superseded scan could overwrite a newer
        /// scan's coverage, and the banner would describe a comparison nobody ran.
        struct ScanOutcome: Sendable {
            let differences: [FileDifference]
            let coverage: PartialComparison
        }
        let newDifferences: ScanOutcome?
        // When the cached trees were read, so the publish below dates the comparison by its walks
        // (`lastScanReadAt`). nil when the scan walks the disk itself.
        var walksReadAt: Date?
        if let cachedLeft = prefetchedTrees[leftURL.path], let cachedRight = prefetchedTrees[rightURL.path] {
            // Whether each cached tree's walk was budget-stopped, read on the main actor with the
            // trees. The maps alone can't say (the root is readable, so there is no `""` record),
            // and without it a warm scan of a truncated tree would read `.complete` with no banner.
            let leftWalkStopped = prefetchedTreeWalkStopped.contains(leftURL.path)
            let rightWalkStopped = prefetchedTreeWalkStopped.contains(rightURL.path)
            // Read here too, since the entries can be dropped while the compute runs. An entry with
            // no stamp stands for "now", as on a pane.
            let leftReadAt = prefetchedTreeReadAt[leftURL.path]
            let rightReadAt = prefetchedTreeReadAt[rightURL.path]
            walksReadAt = [leftReadAt, rightReadAt].compactMap { $0 }.min()
            // At Info, with the walks' ages: the branch can change the answer, not only the time,
            // since a budget-stopped disk walk and a pane walk can stop in different places. Its
            // own record, like `[filter]`'s, not a suffix on the completed line.
            let now = Date()
            Logger.shared.info("[scan] \(scanTag) compares the panes' cached walks of “\(leftURL.path)” "
                               + "(walked \(Self.ageText(since: leftReadAt, now: now))) and “\(rightURL.path)” "
                               + "(walked \(Self.ageText(since: rightReadAt, now: now))), reading neither folder")

            let computeTask = Task.detached(priority: .userInitiated) { () -> ScanOutcome? in
                guard !Task.isCancelled else { return nil }
                // No disk at all: `filesInfo(fromTree:)` and the diff's one-sided rows hint each URL
                // with its type. An unhinted file URL looks its path up on disk, one lookup per node
                // and ~4x slower (`TreeWalkBenchmark`). The phases are timed apart so a slow run
                // says which half moved.
                let flattenStart = CFAbsoluteTimeGetCurrent()
                let leftFilesInfo = FileDiffEngine.filesInfo(fromTree: cachedLeft, basePath: leftURL.path)
                let rightFilesInfo = FileDiffEngine.filesInfo(fromTree: cachedRight, basePath: rightURL.path)
                let flatten = Self.durationText(since: flattenStart)
                // Say when the comparison is partial. A pane tree can be cut short by
                // `paneNodeBudget`, and the cold branch warns about its own truncation, so a silent
                // warm scan would make "no differences" mean two things. A warning, because it
                // changes what the result means. Read off the maps in this detached task: walking
                // the trees on the main actor would cost up to 200k nodes per scan there.
                for (side, info) in [("left", leftFilesInfo), ("right", rightFilesInfo)]
                where info.values.contains(where: { $0.isDirectory && $0.isUnexplored }) {
                    Logger.shared.warning("Scan: the \(side) tree is incomplete — this comparison covers what was walked, and reports nothing under an unread folder as missing")
                }
                guard !Task.isCancelled else { return nil }
                let diffStart = CFAbsoluteTimeGetCurrent()
                defer {
                    let diff = Self.durationText(since: diffStart)
                    let counts = "\(leftFilesInfo.count) vs \(rightFilesInfo.count) entries"
                    Logger.shared.debug("[scan] \(scanTag) cached-tree compute: flatten \(flatten), diff \(diff) (\(counts))")
                }
                return ScanOutcome(
                    differences: FileDiffEngine.computeDifferences(
                        left: request.left,
                        leftURL: leftURL,
                        right: request.right,
                        rightURL: rightURL,
                        leftFilesInfo: leftFilesInfo,
                        rightFilesInfo: rightFilesInfo,
                        caseInsensitive: caseInsensitive,
                        dateToleranceSeconds: dateTolerance
                    ),
                    coverage: PartialComparison.of(left: leftFilesInfo, right: rightFilesInfo,
                                                   leftWalkStopped: leftWalkStopped,
                                                   rightWalkStopped: rightWalkStopped))
            }
            newDifferences = await withTaskCancellationHandler {
                await computeTask.value
            } onCancel: {
                computeTask.cancel()
            }
        } else {
            // The Info twin of the cached branch's line, naming the side that missed: after a
            // source switch, a miss on the pane that stayed means its walk wasn't kept.
            let missing = [prefetchedTrees[leftURL.path] == nil ? "left" : nil,
                           prefetchedTrees[rightURL.path] == nil ? "right" : nil].compactMap { $0 }
            Logger.shared.info("[scan] \(scanTag) walks “\(leftURL.path)” and “\(rightURL.path)” from disk: "
                               + "no cached walk of \(missing.count == 1 ? "the \(missing[0]) one" : "either folder")")
            // Read before detaching: inside, each would hop back to the main actor and queue the
            // walk behind whatever it was doing, before the clock below starts.
            let fm = fileManager
            let reads = datalessFolderReads
            let walkTask = Task.detached(priority: .userInitiated) { () -> ScanOutcome? in
                do {
                    // The two walks are independent and FileManager is thread-safe, so they run
                    // concurrently, detached, with cancellation forwarded into both.
                    // The clock starts before the tasks exist, since a detached task starts at once.
                    let walkStart = Elapsed()
                    // **Must share `paneNodeBudget`** with the warm branch, which compares cached
                    // pane trees capped by it. Two caps would make one folder pair compare
                    // differently depending only on cache state. See the constant's note.
                    let leftWalk = Task.detached(priority: .userInitiated) {
                        try FileDiffEngine.getFilesInDirectory(leftURL, fileManager: fm,
                                                               maxEntries: Self.paneNodeBudget,
                                                               datalessReads: reads)
                    }
                    let rightWalk = Task.detached(priority: .userInitiated) {
                        try FileDiffEngine.getFilesInDirectory(rightURL, fileManager: fm,
                                                               maxEntries: Self.paneNodeBudget,
                                                               datalessReads: reads)
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
                        Logger.shared.debug("[scan] \(scanTag) disk-walk compute: walk \(walk), diff \(diff) (\(counts))")
                    }

                    return ScanOutcome(
                        differences: FileDiffEngine.computeDifferences(
                            left: request.left,
                            leftURL: leftURL,
                            right: request.right,
                            rightURL: rightURL,
                            leftFilesInfo: leftFilesInfo,
                            rightFilesInfo: rightFilesInfo,
                            caseInsensitive: caseInsensitive,
                            dateToleranceSeconds: dateTolerance
                        ),
                        coverage: PartialComparison.of(left: leftFilesInfo, right: rightFilesInfo))

                } catch is CancellationError {
                    // Superseded mid-walk; the publish gate below discards the scan anyway.
                    return nil
                } catch {
                    let msg = "Error scanning directories: \(error)"
                    Logger.shared.error(msg)
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
        // Both terms are needed. The generation discards a scan a newer scanDirectories (or
        // invalidateComparisonState) superseded. Task.isCancelled covers the gap before that: a
        // superseding refresh cancels this task first and bumps the generation only after its
        // pane loads, while this scan's results describe folders the panes are leaving.
        if !Task.isCancelled, isLatestRequest, let outcome = newDifferences {
            let results = outcome.differences
            // Published with the rows, so the banner and the count always describe one scan.
            self.lastScanCoverage = outcome.coverage
            self.rawDifferences = results
            self.lastRightProviderType = request.right.type
            // The provider pair the destination name check attributes transfer targets to.
            self.lastScanProviders = (request.left, request.right)
            // Dated by what it compared, not when it ran. From cached trees the comparison is as old
            // as the older walk, which can be hours old after a source switch, and "just now" would
            // hide that. Walked from disk, the two dates agree.
            let completedAt = Date()
            let readAt = walksReadAt.map { min($0, completedAt) } ?? completedAt
            self.lastScanReadAt = readAt
            self.lastScanDate = completedAt
            self.verifiedSameDifferenceIds.removeAll()
            // A fresh scan regenerates every row id, so a kept failure set would match nothing and
            // leave the Failed filter at zero, selected into an empty list.
            self.lastTransferFailures = nil
            // A "copy verified-identical left→right" offer from the previous scan references
            // superseded rows; drop it (as swapPanes does) so confirming can't copy stale pairs.
            self.verifiedIdenticalForCopy = nil
            await self.applyFilters()
            // The compared folders' names, so the Path column keeps naming the scanned roots if the
            // panes navigate on. Set after the filter pass on purpose: the pass suspends while the
            // previous rows are still published, and names set before it would label those old
            // rows. `applyFilters` publishes synchronously before returning, so no render can pair
            // new rows with old names either.
            self.lastScanRootNames = (leftURL.lastPathComponent, rightURL.lastPathComponent)
            hasScanned = true
            // Recorded from this request's paths, not the panes', which may have navigated on
            // during the scan. `results.count` is the unfiltered output, not `differences.count`,
            // which moves with the hidden/ignored filter after the scan.
            recordLastScanSummary(LastScanSummary(
                // The comparison's age, as on the pill: "Last scanned 3 days ago" is a claim about
                // the folders, not the scan.
                date: readAt,
                differenceCount: results.count,
                leftProviderID: request.left.id,
                // The request's path, tilde-expanded, as `PaneLogic.fullPath` produces it, rather
                // than `leftURL.path` after `URL` normalization, so the two sides start equal
                // without relying on `describes` trimming separators.
                leftPath: (request.leftPath as NSString).expandingTildeInPath,
                rightProviderID: request.right.id,
                rightPath: (request.rightPath as NSString).expandingTildeInPath
            ))

            // `.info`, matching the start line: at different levels, an Info log would show scans
            // starting and never ending.
            Logger.shared.info("[scan] \(scanTag) completed: found \(results.count) differences in \(scanStart.text)")
            // Its own record, so the line above stays half of a started/completed pair. `[filter]`
            // so it greps on its own.
            Logger.shared.info("[filter] \(filterGateSummary(rawDifferenceCount: results.count))")

            if autoVerifySameSizeDuringScan {
                // Unstructured on purpose: hashing must not extend the scan (isScanning would
                // hold the slot); the pass re-checks the generation before publishing.
                Task { await self.autoVerifySameSizePairs(scanGeneration: request.generation) }
            }
        } else {
            // A discarded scan logs too, or it would look like one still running.
            Logger.shared.info(
                "[scan] \(scanTag) discarded after \(scanStart.text)"
                + " (\(Task.isCancelled ? "cancelled" : isLatestRequest ? "no result" : "superseded by #\(scanRequestGeneration)"))")
        }

        isScanning = false
        scanStartedAt = nil
        scanShownTask?.cancel()
        scanShownTask = nil
        if isScanShown { isScanShown = false }

        if let pending = pendingScanRequest {
            pendingScanRequest = nil
            if pending.generation > request.generation {
                // Drain on a fresh unstructured task, never this one: a request is queued only by
                // a superseding refresh that already cancelled this task, so draining inline would
                // inherit that cancellation and discard the fresh results. Re-enters through
                // runOrQueueScan, so a scan that took the slot meanwhile re-queues it.
                //
                // Held, because this scan runs outside any refresh task, and `cancelScan` (the Stop
                // button) has no other way to reach it.
                scanDrainTask = Task { await self.runOrQueueScan(pending) }
            }
        }
    }
    
    // MARK: - Internal Engine Operations
    
    /// Where a pane's deep walk stops; every directory past it is marked unexplored, still
    /// expandable, and loaded by `PaneColumnsView` when a column opens it.
    ///
    /// A pane can be pointed at any folder in one click, so it needs a ceiling. The largest real
    /// source walks ~40k nodes in ~700 ms (`TreeWalkBenchmark`), so this is 5x that: only a tree
    /// that would hang is cut. On `~` it costs ~1.3 s warm, where an unbounded walk ran for
    /// minutes (`PaneNodeBudgetBenchmark`). Exhaustion is checked before a listing, so a spent
    /// budget stops the next descent, not the current level.
    ///
    /// **The comparison scan's cold branch must use the same number.** Its warm branch compares
    /// the cached pane trees this caps; two caps would make one folder pair compare differently
    /// depending only on cache state.
    ///
    /// Not a bound for the storage lens or the Organize passes: they total sizes and group
    /// duplicates, where a truncated tree is a wrong answer, not a partial view.
    nonisolated static let paneNodeBudget = 200_000

    /// The directory a pane's load actually walks: its root, focused down to its relative path.
    ///
    /// `PathBoundary.join`, not lexical composition: a focus on a folder the root only links to
    /// must walk where that folder really is. Composed lexically (`<iCloud Drive>/Documents`), the
    /// walk would never see the container listing where `childURLs(of:)` substitutes the link, so
    /// it would spell every node the link way, while the pane's `currentPath` (also via `join`)
    /// spells them `~/Documents/…`. `PaneChildrenIndex` would miss, and columns past the root
    /// would show "Empty" over full folders.
    ///
    /// `fallback` covers the `""` that `join` answers for an empty root (a provider removed from
    /// settings while its tree is still on screen).
    nonisolated static func focusURL(root: String, relative: String, fallback: URL,
                                     links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> URL {
        let focused = PathBoundary.join(root: root, relative: relative, links: links)
        return focused.isEmpty ? fallback : URL(fileURLWithPath: focused, isDirectory: true)
    }


    /// Walks the directory tree off the main actor. Cancelling the calling task aborts the walk:
    /// the detached worker doesn't inherit cancellation, so it is forwarded explicitly below —
    /// that is what makes the `Task.isCancelled` checks inside `buildNode` effective.
    ///
    /// `maxDepth` caps the walk (1 = immediate children) for the progressive first paint; capped
    /// directories come back with `children: []` and `isUnexplored: true`, never mistakable for an
    /// empty folder. nil means unlimited, apart from the cycle guard and hard depth cap, which mark
    /// the same way. A root that can't be listed comes back as `[root node]` marked unexplored,
    /// never a bare `[]`, which would read as truly empty.
    ///
    /// `budget` caps the walk by size, marking the same way. Depth caps guard deep trees, but the
    /// tree that hangs the app is wide: the home folder holds ~200k directories against ~40k nodes
    /// for the largest cloud source, and the sidebar puts it one click away. Opt-in: whole-tree
    /// analyses (duplicates, the storage lens, the filing taxonomy) must stay unbounded, since a
    /// partial tree there is a wrong answer.
    ///
    /// On the real filesystem an unlimited walk fans sibling subtrees across cores at the first two
    /// levels with siblings (`TreeBuilder.maxFanLevel`, bounded by `maxConcurrentSubtrees`), and
    /// fetches Finder tags only when sorting by them. The fan-out is worth only ~1.2x
    /// (`TreeWalkBenchmark`): the walk is bound by directory enumeration, one volume's syscalls,
    /// which don't divide across cores. Don't expect more from more parallelism.
    /// - Parameter linkedFolders: the folders macOS links into a root from outside it, listed as
    ///   the real folders they point at (`PathBoundary.LinkedFolders`). The machine's table by
    ///   default; a fixture passes its own.
    /// - Parameter followedLinks: where to record the folder symlinks this walk lists outside its
    ///   root (`FollowedLinks`). A pane load and a column graft pass one; other walks pass none.
    /// - Parameter datalessReads: where a folder whose contents aren't on this Mac is read, off the
    ///   cooperative pool and for at most its deadline, after which it comes back unexplored
    ///   (`DatalessFolderReads`). The shared one by default; a pane load passes its manager's.
    nonisolated static func buildTree(url: URL, sortOption: SortOption, fileManager fm: FileManaging = FileManager.default, maxDepth: Int? = nil, budget: NodeBudget? = nil, linkedFolders: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders, followedLinks: FollowedLinks? = nil, datalessReads: DatalessFolderReads = .shared) async -> [FileNode] {
        let buildTask = Task.detached(priority: .userInitiated) {
            struct TreeBuilder: Sendable {
                let fileManager: FileManaging
                let sortOption: SortOption
                let maxDepth: Int?
                /// Reading Finder tags is a separate xattr fetch per file, so tags are fetched
                /// only when the sort reads them. Switching to the Tags sort reloads the trees
                /// from disk (`sortOption.didSet`) rather than re-sorting nodes with no `tags`.
                /// The fetch roughly doubles the walk (`TreeWalkBenchmark`), the biggest single
                /// saving in it.
                let includeTags: Bool
                /// Keys prefetched when listing a directory so each child's resourceValues in
                /// buildNode is a cache hit rather than a separate stat.
                let metadataKeys: [URLResourceKey]
                let metadataKeySet: Set<URLResourceKey>
                /// Metadata re-fetched from a symlink's target (type keys stay on the link).
                let symlinkTargetKeySet: Set<URLResourceKey>

                /// Logs only the first unreadable (permission-denied) directory per scan, since a
                /// subtree can hold thousands. A reference shared by the fan-out's copies of the
                /// value-type builder; the lock makes "only the first" race-free.
                final class UnreadableListingLog: @unchecked Sendable {
                    private let lock = NSLock()
                    private var logged = false
                    func note(_ path: String) {
                        lock.lock()
                        let first = !logged
                        logged = true
                        lock.unlock()
                        guard first else { return }
                        Logger.shared.warning("Scan: could not list “\(path)” (permission denied or unreadable) — shown as unexplored, not empty; further unreadable directories in this scan are not logged individually")
                    }
                }
                let unreadableLog = UnreadableListingLog()

                /// `nil` for every unbounded walk; see `FileSyncManager.NodeBudget`.
                let budget: FileSyncManager.NodeBudget?
                /// See `buildTree(url:…linkedFolders:)`.
                let linkedFolders: PathBoundary.LinkedFolders
                /// Linked-folder targets this walk also reaches directly, normalized.
                ///
                /// A linked folder is substituted by the real folder it points at (`childURLs`), so
                /// a real folder under the walk root is reached twice, with one id. It depends on
                /// the root: under `~`, `~/Documents` has both routes; under the iCloud container
                /// the link is the only route, and marking it would drop that folder from the
                /// source's totals. So it is decided once per walk, from the root.
                let coveredTargets: Set<String>

                /// `nil` for every walk nobody asked; see `buildTree(url:…followedLinks:)`.
                let followedLinks: FileSyncManager.FollowedLinks?
                /// The root in both spellings: as handed over, and as `resolvingSymlinksInPath`
                /// spells it. A followed link whose target lies under either is already listed under
                /// the root and isn't recorded. Empty without `followedLinks`, so nothing resolves.
                let rootSpellings: [String]
                /// Where the root itself resolves when that is somewhere else (a pane on a link, or
                /// focused below one); `nil` when it resolves to itself. The `/private` alias alone
                /// (`/private/var/…` → `/var/…`) isn't a link and isn't recorded: it names the root.
                let rootLinkTarget: String?
                /// See `buildTree(url:…datalessReads:)`.
                let datalessReads: FileSyncManager.DatalessFolderReads

                init(fileManager: FileManaging, sortOption: SortOption, maxDepth: Int?,
                     budget: FileSyncManager.NodeBudget?,
                     linkedFolders: PathBoundary.LinkedFolders,
                     followedLinks: FileSyncManager.FollowedLinks?,
                     datalessReads: FileSyncManager.DatalessFolderReads,
                     root: URL) {
                    self.fileManager = fileManager
                    self.sortOption = sortOption
                    self.maxDepth = maxDepth
                    self.budget = budget
                    self.datalessReads = datalessReads
                    self.linkedFolders = linkedFolders
                    let rootPath = PathBoundary.normalizedRoot(root.path)
                    self.coveredTargets = Set(
                        linkedFolders.values.flatMap(\.values)
                            .map(PathBoundary.normalizedRoot)
                            .filter { PathBoundary.contains($0, under: rootPath) })
                    self.followedLinks = followedLinks
                    if followedLinks != nil {
                        let resolved = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
                        self.rootSpellings = resolved == rootPath ? [rootPath] : [rootPath, resolved]
                        let isTheRoot = resolved == rootPath || "/private" + resolved == rootPath
                        self.rootLinkTarget = isTheRoot ? nil : resolved
                    } else {
                        self.rootSpellings = []
                        self.rootLinkTarget = nil
                    }
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

                /// Sibling directory subtrees fan out across cores at the first two levels that
                /// have siblings, each recursing sequentially below; more only adds task overhead.
                /// A single-entry level doesn't count, so a root holding one big folder (a common
                /// cloud layout) still parallelizes inside it.
                static let maxFanLevel = 2

                /// At most this many subtree tasks per fan-out group. Each blocks a cooperative-pool
                /// thread in synchronous filesystem calls, so the headroom keeps one slow volume
                /// from pinning the whole pool and starving the other pane's walk. It also caps the
                /// pending child tasks a huge level allocates.
                static let maxConcurrentSubtrees = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

                /// What `directoryIdentity(of:)` returns: Hashable for the cycle-guard set, Sendable
                /// so ancestor snapshots can cross into the fan-out's child tasks. The wrapped
                /// identifiers are immutable NSNumber/NSData, safe to share.
                enum DirectoryIdentity: Hashable, @unchecked Sendable {
                    case fileResource(volume: NSObject, file: NSObject)
                    case path(String)
                }

                /// Stable identity of the directory a URL ultimately refers to (through
                /// symlinks), used to break symlink cycles. Real filesystem: volume + file
                /// resource identifiers of the resolved target. Injected mocks — where
                /// resourceValues would hit the real disk — fall back to the resolved path,
                /// which is exact for mock disks (they contain no symlinks).
                ///
                /// - Parameter isSymbolicLink: whether `dirURL`'s last component is itself a link.
                ///   Only then is the path resolved. `resourceValues` reports a symlink's own
                ///   identity, not its target's, and cycles always pass through a link, so that
                ///   case must resolve or the guard fails. Any other directory reports its target
                ///   identity either way, even below a symlinked ancestor, since the kernel resolves
                ///   intermediate components. The walk knows this per node (`ItemStat.isSymlink`);
                ///   skipping the resolve halves the per-directory cost. Defaults to `true`.
                func directoryIdentity(of dirURL: URL, isSymbolicLink: Bool = true) -> DirectoryIdentity {
                    if fileManager is FileManager {
                        let target = isSymbolicLink ? dirURL.resolvingSymlinksInPath() : dirURL
                        if let rv = try? target.resourceValues(forKeys: [.volumeIdentifierKey, .fileResourceIdentifierKey]),
                           let volume = rv.volumeIdentifier as? NSObject,
                           let file = rv.fileResourceIdentifier as? NSObject {
                            return .fileResource(volume: volume, file: file)
                        }
                    }
                    // The mock fallback always resolves, unlike the branch above. A `.path` identity
                    // is a string, and a set holding two spellings of one directory wouldn't
                    // recognize its own ancestor; a temp root under `/var/folders/…` resolves to
                    // `/private/var/folders/…`, exactly the paths tests use.
                    return .path(dirURL.resolvingSymlinksInPath().standardizedFileURL.path)
                }

                /// Records a folder symlink this walk is about to list, unless its root already
                /// covers where it leads. Only for a directory whose last component is a link
                /// (`ItemStat.isSymlink`), once its listing succeeded: a link a cap or the budget
                /// stopped at lists nothing, so no write there can stale this tree. Nested links are
                /// each recorded where met; a substituted link never gets here (`childURLs`).
                func noteFollowedLink(_ dirURL: URL) {
                    guard let followedLinks else { return }
                    let target = dirURL.resolvingSymlinksInPath().path
                    guard !rootSpellings.contains(where: { PathBoundary.lexicalRelativize(target, under: $0) != nil })
                    else { return }
                    followedLinks.note(target)
                }

                /// Immediate children of a directory. On the real filesystem this prefetches child
                /// metadata in one call; for injected mocks it builds child URLs from the
                /// enumerator names.
                ///
                /// `listingFailed` means the directory couldn't be listed at all (permission denied,
                /// I/O error), as opposed to empty. Treated as empty, the diff would report phantom
                /// "Missing" rows for its unseen contents.
                ///
                /// `unanswered` is the one failure that isn't the folder's own: a cloud provider
                /// didn't hand over its contents in time (`DatalessFolderReads`). It always comes
                /// with `listingFailed` and only picks the log sentence.
                func childURLs(of dirURL: URL) async -> (urls: [URL], listingFailed: Bool, unanswered: Bool, coveredElsewhere: Set<String>) {
                    let listing = await rawChildURLs(of: dirURL)
                    guard !listing.unanswered else { return ([], true, true, []) }
                    // A folder linked into this directory from outside is listed as the folder it
                    // points at, not as the link. iCloud Drive's container holds `Desktop` and
                    // `Documents` as hidden symlinks to `~/Desktop` and `~/Documents`; walked as
                    // links, every node would carry a spelling no stored path uses, and
                    // `enumerator(at:)` lists nothing through a URL whose last component is a link.
                    // Substituted here, so `stat` sees a real directory and ids are real paths. For
                    // every other directory this is one dictionary lookup.
                    let table = PathBoundary.linkedFolders(atRoot: dirURL.path, in: linkedFolders)
                    guard !table.isEmpty else { return (listing.urls, listing.listingFailed, false, []) }
                    // Which substitutions land on a folder this walk also reaches directly. Only
                    // reported: the substitution must still happen, so the duplicate is marked on
                    // the node for consumers that add the tree up (`FileNode.isCoveredElsewhere`).
                    var covered: Set<String> = []
                    let urls = listing.urls.map { child -> URL in
                        guard let target = table[child.lastPathComponent] else { return child }
                        if coveredTargets.contains(PathBoundary.normalizedRoot(target)) {
                            covered.insert(target)
                        }
                        return URL(fileURLWithPath: target, isDirectory: true)
                    }
                    return (urls, listing.listingFailed, false, covered)
                }

                /// `childURLs(of:)` before the linked-folder substitution: the listing as the
                /// directory holds it.
                ///
                /// A folder whose contents aren't on this Mac is listed off the cooperative pool,
                /// for at most the reads' deadline (`DatalessFolderReads` says why). Any other
                /// folder is listed here, since it never asks its provider. The test costs a `stat`.
                func rawChildURLs(of dirURL: URL) async -> (urls: [URL], listingFailed: Bool, unanswered: Bool) {
                    guard fileManager.isDataless(at: dirURL) else {
                        let listing = listNow(dirURL)
                        return (listing.urls, listing.listingFailed, false)
                    }
                    let builder = self
                    guard let listing = await datalessReads.read(dirURL.path, { builder.listNow(dirURL) }) else {
                        return ([], true, true)
                    }
                    return (listing.urls, listing.listingFailed, false)
                }

                /// One directory's listing, on whatever thread asks for it.
                func listNow(_ dirURL: URL) -> (urls: [URL], listingFailed: Bool) {
                    if let realFm = fileManager as? FileManager {
                        // Fast path: one call prefetches every child's metadata so buildNode's
                        // resourceValues are cache hits. The URL-based API doesn't traverse a
                        // symlinked directory, so fall back to the path-based listing (which follows
                        // symlinks) when it yields nothing.
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
                        // Injected `FileManaging`: an unlistable directory must report
                        // `listingFailed`, as the real-filesystem branch does, never `([], false)`,
                        // which would cache it as empty.
                        // Not through the reads: for a dataless folder `rawChildURLs` already asked,
                        // and this is the read's own body, so asking again would join it.
                        let listing = fileManager.listingForARead(of: dirURL)
                        // Switched, not compared with `!=`, so a new `DirectoryListingOutcome` case
                        // is a compile error here rather than silently treated as fine.
                        switch listing.outcome {
                        case .unreadable:
                            return ([], true)
                        case .listed, .listedWithUnreadableDescendants:
                            return (listing.urls.map { dirURL.appendingPathComponent($0.lastPathComponent) }, false)
                        }
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
                            // resourceValues reports on the link itself, not its target. Resolve via
                            // fileExists so linked directories recurse and broken links are dropped.
                            var isDir: ObjCBool = false
                            guard fileManager.fileExists(atPath: fullURL.path, isDirectory: &isDir) else { return nil }
                            s.isDirectory = isDir.boolValue
                            // Metadata must be the target's too: the link's own size and date mean
                            // nothing for diffing, and the disk-walk scan reports the target, so the
                            // same file must classify the same whichever scan branch runs.
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
                        // existence and type; metadata stays nil.
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
                    let identity = directoryIdentity(of: fullURL, isSymbolicLink: s.isSymlink)
                    if visited.contains(identity) || depth >= Self.hardDepthCap {
                        return cappedNode(fullURL, s)
                    }
                    var branchVisited = visited
                    branchVisited.insert(identity)
                    // Budget check before the listing, the expensive half, so a spent budget pays
                    // for no more. Marked as the depth cap marks it, so nothing downstream needs a
                    // new state.
                    if let budget, budget.isExhausted {
                        budget.noteStopped(fullURL.path)
                        return cappedNode(fullURL, s)
                    }
                    let listing = await childURLs(of: fullURL)
                    // A directory whose listing failed isn't empty: mark it unexplored, like the
                    // depth cap, so the diff never reports phantom Missing rows for contents nobody
                    // could see. One its provider didn't answer for is marked the same way; the
                    // reads already logged why.
                    if listing.listingFailed {
                        if !listing.unanswered { unreadableLog.note(fullURL.path) }
                        return cappedNode(fullURL, s)
                    }
                    if s.isSymlink { noteFollowedLink(fullURL) }
                    budget?.charge(listing.urls.count)
                    var children = await walkChildren(listing.urls, depth: depth + 1, fanLevel: fanLevel, visited: branchVisited)
                    children = FileSyncManager.sortLevel(nodes: children, by: sortOption)
                    // Marked here, the one place that knows both which children were substituted
                    // and what they became. Ids are unique within one listing (the collision this
                    // flag is for is across branches), so matching on id is exact.
                    children = Self.marking(children, coveredElsewhere: listing.coveredElsewhere)
                    return folderNode(fullURL, s, children: children)
                }

                /// Sets ``FileNode/isCoveredElsewhere`` on the children a listing substituted for a
                /// folder the walk also reaches directly. A no-op for every directory but the one
                /// or two per machine that link a folder in — the empty-set guard keeps it free.
                static func marking(_ children: [FileNode], coveredElsewhere: Set<String>) -> [FileNode] {
                    guard !coveredElsewhere.isEmpty else { return children }
                    return children.map { child in
                        guard coveredElsewhere.contains(child.id) else { return child }
                        var marked = child
                        marked.isCoveredElsewhere = true
                        return marked
                    }
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

            let builder = TreeBuilder(fileManager: fm, sortOption: sortOption, maxDepth: maxDepth, budget: budget,
                                      linkedFolders: linkedFolders, followedLinks: followedLinks,
                                      datalessReads: datalessReads, root: url)

            let rootListing = await builder.childURLs(of: url)
            // The walk returns the root's children, so an unreadable root has no child to carry
            // the unexplored marker, and a bare [] would read as empty: the diff would report
            // everything opposite as Missing. Return the root as one unexplored node, which the
            // diff, duplicates and storage treat as unknown contents; `adoptRawTree` unwraps it
            // for the panes.
            if rootListing.listingFailed {
                if !rootListing.unanswered { builder.unreadableLog.note(url.path) }
                let s = builder.stat(at: url) ?? TreeBuilder.ItemStat(isDirectory: true)
                return [builder.cappedNode(url, s)]
            }
            // A root reached through a link lists where it leads, from its first level down.
            if let target = builder.rootLinkTarget { builder.followedLinks?.note(target) }
            // Seed the walk root's identity so a symlink pointing back at the root is
            // recognized as a cycle immediately.
            let visited: Set<TreeBuilder.DirectoryIdentity> = [builder.directoryIdentity(of: url)]
            var rootChildren = await builder.walkChildren(rootListing.urls, depth: 1, fanLevel: 0, visited: visited)
            rootChildren = FileSyncManager.sortLevel(nodes: rootChildren, by: sortOption)
            // The same marking pass as every other directory. A no-op in practice (a root that
            // links a folder in can't also contain it), but it keeps the rule in one place.
            rootChildren = TreeBuilder.marking(rootChildren, coveredElsewhere: rootListing.coveredElsewhere)
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
    /// `URL.path` returns a string lazily bridged from `NSString`, with no contiguous UTF-8 buffer,
    /// so hashing it misses Swift's fast path. `id` is the app's universal dictionary and set key,
    /// and bridged it hashes ~10x slower. Converting once per node here costs ~3% of a walk and
    /// saves far more in `filesInfo` and the main-actor `PaneChildrenIndex` build. See
    /// `docs/string-bridging.md` and `BridgedStringBenchmark`.
    ///
    /// `name` is deliberately left bridged: nothing is keyed on it, and `sortLevel`'s
    /// `localizedStandardCompare` is an `NSString` method, so a native name would have to be
    /// bridged back, which measured slower. Don't "finish the job".
    ///
    /// Byte-identical: decoding valid UTF-8 gives back the same scalars, so equality, ordering and
    /// hashing are unchanged. **Don't** substitute `String(cString: url.fileSystemRepresentation)`:
    /// it may not be normalization-identical to `URL.path`, and an NFC/NFD shift in a diff key is
    /// the failure `nearNameKey` exists to compensate for.
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
                // Break ties by name, like .kind and .tags: equal dates are common after a bulk
                // copy, and the unstable sort would otherwise follow listing order, which can differ
                // between panes or scans and trigger a spurious republish.
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
