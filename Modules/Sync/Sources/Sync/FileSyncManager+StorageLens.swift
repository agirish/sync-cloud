import Events
import Foundation

/// Storage Lens — the read-only "where does my space go?" analyzer. Reuses the existing full tree
/// walk to feed the pure ``StorageLensAnalyzer``, then publishes the report for the UI. This
/// surface never mutates files: its only action is a Finder reveal handled up in the app layer.
extension FileSyncManager {

    /// Starts a cancellable Storage Lens build, replacing any in-flight one.
    public func startBuildStorageLens(root: URL, options: StorageLensOptions = .init()) {
        storageLensTask = restartedScanTask(replacing: storageLensTask) { [weak self] in
            await self?.buildStorageLens(root: root, options: options)
        }
    }

    /// Cancels a running Storage Lens build; the previous report (if any) is left intact.
    public func cancelBuildStorageLens() {
        storageLensTask?.cancel()
    }

    /// Clears the current report, so one provider's report is never shown under another. Called
    /// from ``clearLensResultsForProviderSwitch()``. Keeps the stored snapshot: this runs on every
    /// provider switch, and erasing saved reports then would make restoring nearly useless.
    /// ``forgetStoredStorageLens(root:)`` is the explicit erase.
    public func clearStorageLens() {
        storageLensTask?.cancel()
        storageLensReport = nil
        storageLensRoot = nil
        storageLensLifecycle.completedAt = nil
        storageLensLifecycle.isRestored = false
        storageLensLifecycle.hasCompleted = false
    }

    // MARK: Restore

    /// Where Storage Lens snapshots persist. nil (the default) disables restoring, as for the
    /// verdict cache and the hash index, so no test or CLI run touches the real file.
    public var storageLensStoreURL: URL? {
        get { _storageLensStoreURL }
        set { _storageLensStoreURL = newValue }
    }

    /// Shows the last saved report for `root`, if there is one, without scanning, and returns
    /// whether it did. Refuses while a build runs or results are on screen: a restore starts from
    /// something, never overwrites something newer.
    ///
    /// The read is memoised in the store against the file's modification date and size
    /// (`StorageLensStore.load(from:)`). A root with no snapshot leaves `storageLensReport` nil, so
    /// every trigger calls this again; without the memo each would decode the whole file on the
    /// main actor. The writer saves atomically, so a save invalidates the memo by itself.
    @discardableResult
    public func restoreStorageLens(root: URL) -> Bool {
        guard let url = storageLensStoreURL,
              !isBuildingStorageLens, storageLensReport == nil,
              let snapshot = StorageLensStore.snapshot(for: root.path, from: url)
        else { return false }
        storageLensReport = snapshot.report
        restoreScan(\.storageLensLifecycle, root: root, completedAt: snapshot.completedAt)
        // Age in whole minutes rather than through `ScanFreshness`: that lives in Design, and Sync
        // stays free of the UI modules. The view renders the same instant properly.
        let ageMinutes = Int(Date().timeIntervalSince(snapshot.completedAt) / 60)
        Logger.shared.info("Storage: showing the saved report for \(root.lastPathComponent) "
            + "(scanned \(ageMinutes) minute(s) ago) — re-analyze for current numbers")
        return true
    }

    /// Erases the saved report for `root`, or every saved report when `root` is nil. Called from
    /// Settings ▸ Advanced ▸ *Saved scan data*. Leaves the report on screen, since it is still
    /// true; `clearStorageLens()` clears the view.
    public func forgetStoredStorageLens(root: String? = nil) {
        guard let url = storageLensStoreURL else { return }
        StorageLensStore.clearInBackground(root: root, from: url)
    }

    /// Bytes the saved Storage Lens reports occupy, or nil when nothing is saved — the Advanced
    /// tab's readout.
    public func storedStorageLensSizeOnDisk() -> Int? {
        storageLensStoreURL.flatMap { StorageLensStore.sizeOnDisk(at: $0) }
    }

    /// Walks `root` in full, analyzes it (pure), and publishes the report on the main actor.
    func buildStorageLens(
        root: URL,
        options: StorageLensOptions = .init(),
        fileManager fm: FileManaging? = nil
    ) async {
        guard !isBuildingStorageLens else { return }
        let fileManager = fm ?? self.fileManager
        beginScan(\.storageLensLifecycle, status: "Analyzing \(root.lastPathComponent)…")
        storageLensProgress = 0
        // hasCompleted flips only on completion (below), so a cancelled build leaves the
        // prior state intact rather than flashing an empty report.
        defer {
            endScan(\.storageLensLifecycle)
            storageLensProgress = 0
        }

        // 1. Walk the full subtree (off-main inside buildTree). maxDepth: nil = unlimited.
        //
        // Budgeted first, as a probe. A storage total from part of a tree is a wrong number, so
        // the answer can't be budgeted, but the probe finds out how big the tree is. Under the
        // budget the probe is the tree and nothing is walked twice. Over it, the real pass would
        // take minutes (the home folder or boot volume is one click away), so ask first.
        let probe = NodeBudget(wholeTreeProbeBudget)
        var tree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager,
                                        maxDepth: nil, budget: probe)
        if Task.isCancelled { return }
        if probe.didStopADescent {
            let preflight = LargeWalkPreflight(pass: .storageLens, rootPath: root.path,
                                               probeLimit: probe.limit)
            guard largeWalkConfirmer(preflight) else {
                // Logged, and the previous report stays on screen: `hasCompleted` never flips, as
                // for a cancelled build.
                Logger.shared.info("Storage: “\(preflight.rootName)” holds more than \(preflight.probeLimit) entries — not analysed")
                return
            }
            // Confirmed: walk again in full. The probe's tree can't be extended, because its
            // unexplored nodes look the same as cycle-guarded and permission-denied ones.
            tree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager,
                                        maxDepth: nil)
            if Task.isCancelled { return }
        }

        // 2. Analyze (pure, no disk), detached: the analyzer walks the whole tree, too long for the
        // main actor on a large provider. Only the @Published writes below run on the main actor.
        // A newer build cancels this task (startBuildStorageLens), so the isCancelled check after
        // the hop keeps a stale report from landing. `now` is captured before the hop so staleness
        // is measured from the build.
        let now = Date()
        let report = await Task.detached(priority: .userInitiated) {
            StorageLensAnalyzer.analyze(tree: tree, now: now, options: options)
        }.value
        if Task.isCancelled { return }

        // Published with the results, not at build start: the root labels what's on screen, and a
        // cancelled rebuild of a different folder must not relabel the previous report.
        self.storageLensReport = report
        let completedAt = Date()
        completeScan(\.storageLensLifecycle, root: root, at: completedAt)
        if let url = storageLensStoreURL {
            StorageLensStore.saveInBackground(
                StorageLensSnapshot(root: root.path, report: report, completedAt: completedAt),
                to: url)
        }
        Logger.shared.info("Storage: analyzed \(root.lastPathComponent) — \(Self.formatBytes(report.totalBytes)) across \(report.treemap.count) area(s), \(report.reclaimCandidates.count) reclaim candidate(s)")
    }
}
