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

    /// Clears the current report, so a stale report from one provider is never shown under
    /// another. Reached from ``clearLensResultsForProviderSwitch()`` — which, until the audit that
    /// added this line, did not call it: the claim in this comment was simply untrue for as long
    /// as it had been written.
    ///
    /// Deliberately does NOT delete the stored snapshot: this runs on an ordinary provider switch,
    /// and forgetting the other provider's saved report every time the user looked away would make
    /// restoring nearly useless. ``forgetStoredStorageLens(root:)`` is the explicit erase.
    public func clearStorageLens() {
        storageLensTask?.cancel()
        storageLensReport = nil
        storageLensRoot = nil
        storageLensLifecycle.completedAt = nil
        storageLensLifecycle.isRestored = false
        hasBuiltStorageLens = false
    }

    // MARK: Restore

    /// Where Storage Lens snapshots persist. nil (the default) disables restoring entirely — the
    /// same injection rule the verdict cache and the hash index follow, so no test and no CLI run
    /// can read or write the real file.
    public var storageLensStoreURL: URL? {
        get { _storageLensStoreURL }
        set { _storageLensStoreURL = newValue }
    }

    /// Shows the last saved report for `root`, if there is one, without scanning.
    ///
    /// Returns whether anything was restored. Refuses while a build is running and refuses to
    /// replace results already on screen: a restore is a way to start from something rather than
    /// nothing, never a way to overwrite something newer.
    ///
    /// Reads the file on each attempt rather than memoizing it. That is a real cost — the app
    /// calls this whenever the workspace, or the focused root, changes — but a bounded one: the
    /// store holds at most `maxRoots` snapshots of `topN` rows each, so it is tens of kilobytes,
    /// and the guards above mean it is only ever reached while nothing is displayed. A memo would
    /// be a fourth piece of cache state to keep in step with a background writer, which is a worse
    /// trade than the read it saves.
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
        Logger.shared.info("Storage Lens: showing the saved report for \(root.lastPathComponent) "
            + "(scanned \(ageMinutes) minute(s) ago) — re-analyze for current numbers")
        return true
    }

    /// Erases the saved report for `root`, or every saved report when `root` is nil.
    public func forgetStoredStorageLens(root: String? = nil) {
        guard let url = storageLensStoreURL else { return }
        StorageLensStore.clearInBackground(root: root, from: url)
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
        let tree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager, maxDepth: nil)
        if Task.isCancelled { return }

        // 2. Analyze (pure, no disk) — DETACHED, like the hashing phase of the duplicate scan:
        // the analyzer walks the whole tree, which on a 40k-node provider blocked the main actor
        // for the full pass. Only the @Published writes below happen back on the main actor.
        // Staleness guard: a newer build cancels this task (startBuildStorageLens), so the
        // isCancelled check after the hop plays the role the duplicate scan's lifecycle epoch
        // plays for its unstructured progress hops — a stale report can never land after a
        // newer build started. Date() is captured before the hop so staleness is measured from now.
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
        Logger.shared.info("Storage Lens: analyzed \(root.lastPathComponent) — \(Self.formatBytes(report.totalBytes)) across \(report.treemap.count) area(s), \(report.reclaimCandidates.count) reclaim candidate(s)")
    }
}
