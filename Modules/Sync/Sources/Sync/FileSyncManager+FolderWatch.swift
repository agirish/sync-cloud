import Events
import Foundation

/// **What the folder watcher has said about one pane's listing** (ROADMAP item 5): two FSEvents
/// ids, compared.
///
/// `readMark` is the id read just before the walk behind the published tree started; `changeMark`
/// is the newest change the watcher reported in the pane's folder. A change with a greater id than
/// the walk's happened after the walk began, so the walk may not have seen it.
///
/// **Ids, not times.** FSEvents delivers a change up to its latency after it happened, so ordering
/// by delivery would read the pane's own refresh — re-walked straight after a change, its events
/// arriving a moment later — as stale again at once. An id is assigned when the change is made, and
/// a walk's id when the walk starts, so the two order exactly.
///
/// **Not a seventh counter for REFACTOR.md item 8.** Nothing here guards a publish or dedupes a
/// refresh: it is a stamp the OS issues, carried beside `leftTreeReadAt` the way that stamp is, and
/// it can only add a warning. The work it causes goes through the entry points that family already
/// has — a targeted cache drop and `noteScanConfigChanged`, which is what
/// `prepareReread(afterWritingAt:)` does for a file the app wrote, and a refresh the app asks for.
/// The one thing it does order is when the app HEARS about a change (`owedPaneChanges`): held while
/// a refresh runs, and no oftener than `paneNewsInterval`.
struct PaneWatchState: Equatable, Sendable {
    /// The folder the pane's newest load is for, as the load composed it — what changes are matched
    /// against. A load for another folder starts the change record over.
    var focus: String?
    /// The id read before the walk behind the published tree started; nil while the pane holds none.
    var readMark: UInt64?
    /// The newest change reported in `focus` since the pane moved there; 0 for none.
    var changeMark: UInt64 = 0
    /// The newest change to a HIDDEN item there — kept apart, because it is news only while the
    /// pane shows hidden items, and turning them on must not reveal stale ones unannounced.
    var hiddenChangeMark: UInt64 = 0

    func changedSinceRead(showingHidden: Bool) -> Bool {
        guard let readMark else { return false }
        return max(changeMark, showingHidden ? hiddenChangeMark : 0) > readMark
    }
}

extension FileSyncManager {

    // MARK: - Enabling

    /// Starts watching the panes' folders with a ``FolderWatcher``: from here on a change on disk
    /// under either pane sets `leftChangedOnDisk` / `rightChangedOnDisk` until a walk that started
    /// after it lands, drops the cached walks it makes stale, and tells `onPanesChangedOnDisk`.
    ///
    /// Off by default — every test, and the CLI, run with no watcher and see no difference — and
    /// idempotent. The parameters are the watcher's, for a test that cannot wait on the defaults.
    /// `history` has no default for `persistedUIStateDefaults`' reason: only the real app may write
    /// the real defaults domain, so it is the app that hands it over.
    public func enableFolderWatching(history: FolderWatchHistory,
                                     latency: TimeInterval = 0.3, quiet: TimeInterval = 1,
                                     maxDelay: TimeInterval = 5) {
        guard folderWatcher == nil else { return }
        folderWatcher = FolderWatcher(history: history, latency: latency, quiet: quiet,
                                      maxDelay: maxDelay) { [weak self] batch in
            Task { @MainActor in self?.absorbFolderChanges(batch) }
        }
        updateFolderWatch()
    }

    /// Stops watching and clears both flags — nothing is watching, so nothing can be claimed.
    public func disableFolderWatching() {
        folderWatcher?.stop()
        folderWatcher = nil
        for isLeft in [true, false] {
            if isLeft { leftWatch.changeMark = 0; leftWatch.hiddenChangeMark = 0 }
            else { rightWatch.changeMark = 0; rightWatch.hiddenChangeMark = 0 }
        }
        owedPaneChanges = (false, false)
        publishDiskChanges()
    }

    // MARK: - The panes' side

    /// A pane load is starting for `focusPath`: point the watcher at it, then read the id the load
    /// is ordered by. In that order, so a change made after the id was read is one the stream is
    /// already watching for.
    ///
    /// A load for a new folder also takes that id as the pane's read mark at once. The tree on
    /// screen is the old folder's until the load publishes, and measured against the old walk the
    /// new folder's replayed history would read as news — a flag on a pane that is loading, and an
    /// epoch bump that leaves the walk in flight uncached.
    func noteFolderWatchLoad(isLeft: Bool, focusPath: String) -> UInt64 {
        folderWatchLoadWitness?(isLeft)
        var state = isLeft ? leftWatch : rightWatch
        guard state.focus != focusPath else { return FolderWatcher.currentEventId() }
        state.focus = focusPath
        state.changeMark = 0
        state.hiddenChangeMark = 0
        if isLeft { leftWatch = state } else { rightWatch = state }
        updateFolderWatch()
        let mark = FolderWatcher.currentEventId()
        if isLeft { leftWatch.readMark = mark } else { rightWatch.readMark = mark }
        publishDiskChanges()
        return mark
    }

    /// A tree was published for one pane, from a walk that started at `readMark`.
    func noteFolderWatchRead(isLeft: Bool, readMark: UInt64) {
        if isLeft { leftWatch.readMark = readMark } else { rightWatch.readMark = readMark }
        // The walk may have followed a folder link out of the pane's folder; watch where it leads.
        updateFolderWatch()
        publishDiskChanges()
    }

    /// Republishes the two flags, writing only one that moved — each write re-renders every view
    /// observing the manager.
    func publishDiskChanges() {
        let left = leftWatch.changedSinceRead(showingHidden: showHiddenFiles)
        let right = rightWatch.changedSinceRead(showingHidden: showHiddenFiles)
        if leftChangedOnDisk != left { leftChangedOnDisk = left }
        if rightChangedOnDisk != right { rightChangedOnDisk = right }
    }

    /// The folders the watcher covers: each pane's folder, the folders macOS links into it from
    /// outside (iCloud Drive's Desktop and Documents, `linkedFolders`), and the folder links the
    /// pane's walk followed out of it. **The panes' folders, not their sources' roots**: a source can
    /// be the home folder or the startup disk, and a file-level stream there is every write the Mac
    /// makes. The cost is that a cached walk elsewhere is not watched while no pane is on it — so
    /// a move there replays the history since that walk (``folderWatchReplayMark(for:)``).
    func folderWatchRoots() -> Set<FolderWatchRoot> {
        var paths: Set<String> = []
        for (state, linkTargets) in [(leftWatch, leftTreeLinkTargets), (rightWatch, rightTreeLinkTargets)] {
            guard let focus = state.focus, !focus.isEmpty else { continue }
            let folders = [focus] + linkTargets
            paths.formUnion(folders)
            for (container, targets) in linkedFolders
            where folders.contains(where: { PathBoundary.lexicalRelativize(container, under: $0) != nil }) {
                paths.formUnion(targets.values)
            }
        }
        return Set(paths.map(FolderWatchRoot.init(path:)))
    }

    /// The oldest walk anything on screen or in the cache over `root` still relies on — where a
    /// stream newly pointed at it has to replay from, so a change made while nothing watched it is
    /// still reported. nil when nothing relies on one: a pane load reads its id after the stream is
    /// up (``noteFolderWatchLoad(isLeft:focusPath:)``), so it needs no replay, and none is asked —
    /// a replay brings back this process's own writes without the mark that says so.
    ///
    /// **"Over `root`" through links too**: a walk of the iCloud Drive container lists `~/Documents`
    /// through the link, so a stream on `~/Documents` started when a pane comes back to the
    /// container must replay from the container's cached walk. Matched on the folders each walk
    /// lists from (`listedRoots`), not on its own path alone.
    func folderWatchReplayMark(for root: FolderWatchRoot) -> UInt64? {
        let links = linkedFolders
        func related(_ folder: String?, _ linkTargets: Set<String>) -> Bool {
            guard let folder else { return false }
            return Self.listedRoots(of: folder, links: links, linkTargets: linkTargets).contains {
                PathBoundary.lexicalRelativize($0, under: root.path) != nil
                    || PathBoundary.lexicalRelativize(root.path, under: $0) != nil
            }
        }
        var marks: [UInt64] = []
        for (state, targets) in [(leftWatch, leftTreeLinkTargets), (rightWatch, rightTreeLinkTargets)]
        where related(state.focus, targets) {
            if let mark = state.readMark { marks.append(mark) }
        }
        for (key, mark) in prefetchedTreeReadMark where related(key, prefetchedTreeLinkTargets[key] ?? []) {
            marks.append(mark)
        }
        return marks.min()
    }

    func updateFolderWatch() {
        guard let folderWatcher else { return }
        let roots = folderWatchRoots()
        guard roots != folderWatcher.roots else { return }
        folderWatcher.watch(Dictionary(uniqueKeysWithValues: roots.map { root in
            (root, folderWatchReplayMark(for: root).map(FolderWatchReplay.since) ?? .none)
        }))
    }

    // MARK: - Absorbing a batch

    /// Applies one coalesced batch: marks the panes whose folder it touched, drops the cached walks
    /// it made stale, bumps the scan-config epoch so a refresh asked for next is not swallowed as a
    /// duplicate of one already running (`prepareForcedRescan`'s reason), and tells the app which
    /// panes now show a stale listing.
    ///
    /// **This process's own writes are left out.** The file-operation queue and Edit's re-read
    /// already account for every write the app makes (`prepareReread(afterWritingAt:)`), and an
    /// autosave every few seconds would otherwise keep the pane it is in permanently "changed".
    ///
    /// **Hidden items count only when the pane shows them**: Finder rewrites `.DS_Store` whenever a
    /// window opens a folder, and a pane that lists no hidden file has no row that change could be
    /// about. They are kept apart rather than dropped (`hiddenChangeMark`), so showing hidden items
    /// later shows the warning with them. The cached walks go either way — they hold hidden items
    /// whatever the pane shows.
    func absorbFolderChanges(_ batch: FolderWatchBatch) {
        guard folderWatcher != nil else { return }
        let links = linkedFolders
        let showHidden = showHiddenFiles
        let wasChanged = (leftChangedOnDisk, rightChangedOnDisk)
        let before = (leftWatch, rightWatch)

        // Where each pane's walk lists from, worked out once per batch rather than once per event:
        // a provider's first sync is thousands of events, and this runs on the main actor.
        let panes: [(isLeft: Bool, focus: String, listed: [String])] = [true, false].compactMap { isLeft in
            guard let focus = (isLeft ? leftWatch : rightWatch).focus else { return nil }
            return (isLeft, focus, Self.listedRoots(of: focus, links: links,
                                                    linkTargets: isLeft ? leftTreeLinkTargets : rightTreeLinkTargets))
        }
        func bump(_ isLeft: Bool, to id: UInt64, hidden: Bool) {
            switch (isLeft, hidden) {
            case (true, false): leftWatch.changeMark = max(leftWatch.changeMark, id)
            case (true, true): leftWatch.hiddenChangeMark = max(leftWatch.hiddenChangeMark, id)
            case (false, false): rightWatch.changeMark = max(rightWatch.changeMark, id)
            case (false, true): rightWatch.hiddenChangeMark = max(rightWatch.hiddenChangeMark, id)
            }
        }

        // One pass per path: a burst names the same item many times, and only its newest id counts.
        var newest: [String: FolderWatchEvent] = [:]
        for event in batch.events where !event.isOwn {
            if let seen = newest[event.path], seen.id >= event.id { continue }
            newest[event.path] = event
        }
        var changes: [(paths: [String], below: Bool, id: UInt64)] = []
        for event in newest.values {
            for pane in panes {
                guard let tail = Self.tail(of: event.path, in: pane.listed)
                        ?? Self.tail(of: event.realPath, in: pane.listed) else { continue }
                bump(pane.isLeft, to: event.id, hidden: Self.isHiddenPath(tail))
            }
            // A folder that went takes the walks below it along; no event of theirs will say so.
            let folderWent = event.change.contains(.isDirectory)
                && !event.change.isDisjoint(with: [.removed, .renamed])
            changes.append(([event.path, event.realPath], folderWent, event.id))
        }
        for rescan in batch.rescans {
            for pane in panes {
                if let tail = Self.tail(of: rescan.path, in: pane.listed) {
                    // A rescan of a hidden folder (`.git`) is hidden news, like any change there.
                    bump(pane.isLeft, to: rescan.id, hidden: Self.isHiddenPath(tail))
                } else if PathBoundary.lexicalRelativize(pane.focus, under: rescan.path) != nil {
                    bump(pane.isLeft, to: rescan.id, hidden: false)
                }
            }
            changes.append(([rescan.path], true, rescan.id))
        }
        let dropped = dropPrefetchedTrees(changedBy: changes)

        // **Moved past its walk, not merely moved.** A stream pointed somewhere new replays the
        // history since the oldest walk anything relies on, and most of it predates the pane's own
        // walk: counting that as news would bump the epoch on every navigation, and the walk in
        // flight would then never be cached.
        //
        // Hidden news counts here whether or not the pane shows it: the walk in flight lists hidden
        // items either way, so it must not be cached over one that changed.
        func movedPastRead(_ state: PaneWatchState, from old: PaneWatchState) -> Bool {
            let read = state.readMark ?? 0
            return (state.changeMark != old.changeMark && state.changeMark > read)
                || (state.hiddenChangeMark != old.hiddenChangeMark && state.hiddenChangeMark > read)
        }
        let leftMoved = movedPastRead(leftWatch, from: before.0)
        let rightMoved = movedPastRead(rightWatch, from: before.1)
        guard leftMoved || rightMoved || dropped > 0 else { return }
        noteScanConfigChanged()
        publishDiskChanges()
        // **Info, once per pane as it turns**: it is what the user sees change on screen, and the
        // one line that answers "why does it say changed?" at the level most people keep.
        for (isLeft, was, now) in [(true, wasChanged.0, leftChangedOnDisk), (false, wasChanged.1, rightChangedOnDisk)]
        where now && !was {
            let focus = (isLeft ? leftWatch : rightWatch).focus ?? ""
            let example = newest.values.filter { Self.tail(of: $0.path, in: [focus]) != nil }.max { $0.id < $1.id }
            Logger.shared.info("[watch] the \(isLeft ? "left" : "right") pane's folder changed on disk since it was read"
                               + (example.map { ": “\(($0.path as NSString).lastPathComponent)”" } ?? "")
                               + (batch.rescans.isEmpty ? "" : " (FSEvents asked for a rescan)"))
        }

        let reasons = Set(batch.rescans.map { "\($0.reason)" }).sorted()
        Logger.shared.debug("[watch] \(batch.events.count) change(s)"
                            + (reasons.isEmpty ? "" : ", rescan: \(reasons.joined(separator: ", "))")
                            + "; dropped \(dropped) cached walk(s); left \(leftChangedOnDisk ? "changed" : "current"),"
                            + " right \(rightChangedOnDisk ? "changed" : "current")")

        tellPanesChanged(left: leftMoved && leftChangedOnDisk, right: rightMoved && rightChangedOnDisk)
    }

    // MARK: - Telling the app

    /// Tells `onPanesChangedOnDisk` which panes now show a stale listing — the app's opt-in rescan
    /// answers it — **but never while a refresh or a file operation runs, and no oftener than
    /// `paneNewsInterval`.**
    ///
    /// - A refresh supersedes the one in flight by cancelling and restarting it, so a folder that
    ///   changes every few seconds would never finish a walk. The news waits; the refresh's own end
    ///   delivers it (``tellOwedPaneChanges()``), to whichever pane that refresh still left stale.
    /// - A file operation re-reads when it ends — or, declined at its confirmation, never runs, so
    ///   a wake a moment later asks again rather than leaving the news held for good.
    /// - A folder that never stops changing — a pane on the home folder, a download landing, a
    ///   provider rewriting attributes — would otherwise start the next walk the moment each one
    ///   lands. One rescan per interval is the most it gets.
    func tellPanesChanged(left: Bool, right: Bool) {
        guard left || right, onPanesChangedOnDisk != nil else { return }
        owedPaneChanges.left = owedPaneChanges.left || left
        owedPaneChanges.right = owedPaneChanges.right || right
        tellOwedPaneChanges()
    }

    /// Delivers what ``tellPanesChanged(left:right:)`` holds, if nothing stops it now; otherwise
    /// schedules one wake to ask again. Called as a refresh lets go of `activeRefreshKey`, too.
    func tellOwedPaneChanges() {
        guard owedPaneChanges.left || owedPaneChanges.right, onPanesChangedOnDisk != nil else { return }
        let busy = activeRefreshKey != nil || activeFileOperationsCount > 0
        let wait = lastPaneNewsAt.map { paneNewsInterval - Date().timeIntervalSince($0) } ?? 0
        guard !busy, wait <= 0 else {
            // While busy the refresh's end is the usual delivery; the wake is for a file operation
            // that never ran, so it need not be prompt.
            scheduleOwedPaneNews(after: busy ? max(wait, 2) : wait)
            return
        }
        let owed = owedPaneChanges
        owedPaneChanges = (false, false)
        let left = owed.left && leftChangedOnDisk
        let right = owed.right && rightChangedOnDisk
        guard left || right else { return }
        lastPaneNewsAt = Date()
        onPanesChangedOnDisk?(left && right ? .both : (left ? .leftOnly : .rightOnly))
    }

    private func scheduleOwedPaneNews(after seconds: TimeInterval) {
        guard owedPaneNewsWake == nil else { return }
        owedPaneNewsWake = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard let self else { return }
            self.owedPaneNewsWake = nil
            self.tellOwedPaneChanges()
        }
    }
}
