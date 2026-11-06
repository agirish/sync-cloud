import Events
import Foundation

/// What the folder watcher has said about one pane's listing: two FSEvents ids, compared.
/// `readMark` is read just before the walk behind the published tree started; `changeMark` is the
/// newest change reported in the pane's folder. A greater change id means the walk may have
/// missed it.
///
/// Ids, not times: FSEvents delivers a change up to its latency late, so ordering by delivery would
/// read the pane's own refresh as stale at once. Ids are assigned when the change is made and when
/// the walk starts, so they order exactly.
///
/// Not another freshness counter (`REFACTOR.md`, the freshness family): it guards no publish and
/// dedupes no refresh, only adds a warning. Its work goes through the existing entry points, a
/// targeted cache drop and `noteScanConfigChanged`. It orders only when the app hears of a change
/// (`owedPaneChanges`): held while a refresh runs, and no oftener than `paneNewsInterval`.
struct PaneWatchState: Equatable, Sendable {
    /// The folder the pane's newest load is for, as the load composed it; changes are matched
    /// against it. A load for another folder starts the change record over.
    var focus: String?
    /// The id read before the walk behind the published tree started; nil while the pane holds none.
    var readMark: UInt64?
    /// The newest change reported in `focus` since the pane moved there; 0 for none.
    var changeMark: UInt64 = 0
    /// The newest change to a hidden item there, kept apart: it is news only while the pane shows
    /// hidden items, and turning them on must not reveal stale ones unannounced.
    var hiddenChangeMark: UInt64 = 0

    func changedSinceRead(showingHidden: Bool) -> Bool {
        guard let readMark else { return false }
        return max(changeMark, showingHidden ? hiddenChangeMark : 0) > readMark
    }
}

extension FileSyncManager {

    // MARK: - Enabling

    /// Starts watching the panes' folders with a ``FolderWatcher``. A change on disk under either
    /// pane then sets `leftChangedOnDisk` / `rightChangedOnDisk` until a later walk lands, drops
    /// the cached walks it makes stale, and tells `onPanesChangedOnDisk`.
    ///
    /// Off by default (tests and the CLI run without it) and idempotent. The timing parameters are
    /// for tests. `history` has no default because only the real app may write the real defaults
    /// domain.
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

    /// Stops watching and clears both flags: with nothing watching, nothing can be claimed.
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
    /// is ordered by. In that order, so any change after the id is one the stream already watches.
    ///
    /// A load for a new folder takes that id as the read mark at once. Measured against the old
    /// folder's walk, the new folder's replayed history would read as news, flagging a loading pane
    /// and bumping the epoch so the walk in flight is never cached.
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

    /// Republishes the two flags, writing only one that moved: each write re-renders every view
    /// observing the manager.
    func publishDiskChanges() {
        let left = leftWatch.changedSinceRead(showingHidden: showHiddenFiles)
        let right = rightWatch.changedSinceRead(showingHidden: showHiddenFiles)
        if leftChangedOnDisk != left { leftChangedOnDisk = left }
        if rightChangedOnDisk != right { rightChangedOnDisk = right }
    }

    /// The folders the watcher covers: each pane's folder, the folders macOS links into it from
    /// outside (iCloud Drive's Desktop and Documents, `linkedFolders`), and the folder links the
    /// pane's walk followed out of it. The panes' folders, not their sources' roots: a source can
    /// be the home folder or the startup disk, where a file-level stream is every write the Mac
    /// makes. So a cached walk elsewhere goes unwatched while no pane is on it, and moving there
    /// replays the history since that walk (``folderWatchReplayMark(for:)``).
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
        // A network volume is never watched: FSEvents reports nothing made on the server, and
        // pointing a stream at one resolves its path on the main thread, which a sleeping server
        // holds until it times out.
        return Set(paths.filter(FolderWatcher.isOnLocalVolume).map(FolderWatchRoot.init(path:)))
    }

    /// The oldest walk over `root` that anything on screen or in the cache relies on: where a new
    /// stream must replay from, so a change made while unwatched is still reported. nil when
    /// nothing relies on one (a pane load reads its id after the stream is up), and then no replay
    /// is asked, since a replay returns this process's own writes without the mark that says so.
    ///
    /// "Over `root`" includes links: a walk of the iCloud Drive container lists `~/Documents`
    /// through one, so a stream on `~/Documents` replays from the container's walk. Matched on the
    /// folders each walk lists from (`listedRoots`).
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

    /// Whether a change touched nothing but extended attributes (whatever kind of item it is).
    nonisolated static func onlyExtendedAttributes(_ change: FolderWatchEvent.Change) -> Bool {
        change.isOnlyExtendedAttributes
    }

    /// Applies one coalesced batch: marks the panes whose folder it touched, drops the cached walks
    /// it made stale, bumps the scan-config epoch so the next refresh isn't swallowed as a
    /// duplicate of one running, and tells the app which panes now show a stale listing.
    ///
    /// This process's own writes are left out: the app already accounts for them
    /// (`prepareReread(afterWritingAt:)`), and autosave would keep its pane forever "changed".
    ///
    /// Hidden items count only when the pane shows them, since Finder rewrites `.DS_Store` whenever
    /// a window opens a folder. They are kept apart (`hiddenChangeMark`), not dropped, so showing
    /// hidden items later shows the warning. Cached walks hold hidden items, so they drop either
    /// way.
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
        // A change only to extended attributes (a "last opened" stamp, a quarantine mark, a Finder
        // tag) is news only while the panes read tags, which they do only when sorting by them.
        let tagsListed = sortOption == .tags
        var newest: [String: FolderWatchEvent] = [:]
        for event in batch.events where !event.isOwn && (tagsListed || !Self.onlyExtendedAttributes(event.change)) {
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

        // Moved past its walk, not merely moved: a new stream replays history that mostly predates
        // the pane's walk, and counting it would bump the epoch on every navigation, so the walk in
        // flight would never be cached. Hidden news counts here whether or not the pane shows it:
        // the walk lists hidden items either way.
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
        // Info, once per pane as it turns: the one line that answers "why does it say changed?"
        // at the log level most people keep.
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

    /// Tells `onPanesChangedOnDisk` which panes now show a stale listing (the app's opt-in rescan
    /// answers it), but never while a refresh or file operation runs, and no oftener than
    /// `paneNewsInterval`.
    ///
    /// - A refresh cancels and restarts the one in flight, so a folder changing every few seconds
    ///   would never finish a walk. The refresh's end delivers the news
    ///   (``tellOwedPaneChanges()``).
    /// - A file operation re-reads when it ends, or, declined at its confirmation, never runs, so a
    ///   wake asks again rather than holding the news for good.
    /// - A folder that never stops changing (the home folder, a download, a provider rewriting
    ///   attributes) gets at most one rescan per interval.
    func tellPanesChanged(left: Bool, right: Bool) {
        guard left || right, onPanesChangedOnDisk != nil else { return }
        owedPaneChanges.left = owedPaneChanges.left || left
        owedPaneChanges.right = owedPaneChanges.right || right
        tellOwedPaneChanges()
    }

    /// Delivers what ``tellPanesChanged(left:right:)`` holds if nothing stops it now, otherwise
    /// schedules one wake to ask again. Also called as a refresh lets go of `activeRefreshKey`.
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
