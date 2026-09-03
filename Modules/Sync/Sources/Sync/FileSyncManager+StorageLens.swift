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
        storageLensLifecycle.hasCompleted = false
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
    /// **The read is memoised in the store, against the file's own modification stamp** — see
    /// `StorageLensStore.load(from:)`.
    ///
    /// This said the opposite, and the reasoning had one hole: "the guards above mean it is only
    /// ever reached while nothing is displayed", offered as a bound. It is not a bound. When the
    /// current root has no saved snapshot, nothing is *ever* displayed, so `storageLensReport == nil`
    /// stays true and every one of the six triggers — the workspace change, appearance, the scan
    /// root moving, the rail lens changing, a scope change — re-read the file and ran two
    /// `JSONDecoder` passes over every saved root's report, on the main actor, for the life of the
    /// session. That is the common case, not the rare one: it is what a root nobody has analysed
    /// looks like.
    ///
    /// The objection the old note raised — "a fourth piece of cache state to keep in step with a
    /// background writer" — is answered rather than accepted: the memo is keyed on the file's
    /// modification date and size, and the background writer writes atomically, so a save
    /// invalidates it by construction. There is no rule for anyone to remember.
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

    /// Erases the saved report for `root`, or every saved report when `root` is nil.
    ///
    /// Called from Settings ▸ Advanced ▸ *Saved scan data*. It shipped with no caller at all for a
    /// release — documented from ``clearStorageLens()`` as "the explicit erase" while there was no
    /// way to reach it, which also left saved reports as the one on-disk store the user could
    /// neither see nor clear.
    ///
    /// Deliberately does NOT take the report off screen: a reading you are looking at does not
    /// become untrue because you stopped saving it, and `clearStorageLens()` is the one that
    /// clears the view.
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
        // **Budgeted first, as a probe.** This pass cannot take a budget for its answer — a storage
        // total computed from part of a tree is a wrong number, not a partial picture — but it can
        // use one to find out how big the tree is before committing. Under the budget the probe IS
        // the tree and nothing is spent twice, which is every ordinary source. Over it, the walk
        // stopped early and we now know the real pass would cost minutes, so we ask before paying.
        //
        // This exists because the sidebar's Locations section puts the home folder and the boot
        // volume one click from this workspace, and on 2026-08-24 the equivalent walk behind a pane
        // hung the app for ten minutes on a 196,726-directory home folder.
        let probe = NodeBudget(wholeTreeProbeBudget)
        var tree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager,
                                        maxDepth: nil, budget: probe)
        if Task.isCancelled { return }
        if probe.didStopADescent {
            let preflight = LargeWalkPreflight(pass: .storageLens, rootPath: root.path,
                                               probeLimit: probe.limit)
            guard largeWalkConfirmer(preflight) else {
                // Not silent, and the previous report stays on screen rather than being replaced by
                // an empty one — `hasCompleted` never flips, exactly as for a cancelled build.
                Logger.shared.info("Storage: “\(preflight.rootName)” holds more than \(preflight.probeLimit) entries — not analysed")
                return
            }
            // Confirmed: pay for the real walk. The probe's tree is discarded rather than extended,
            // because a budgeted walk's unexplored nodes are indistinguishable from the cycle guard's
            // and the permission-denied ones, so there is no honest way to resume from it.
            tree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager,
                                        maxDepth: nil)
            if Task.isCancelled { return }
        }

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
        Logger.shared.info("Storage: analyzed \(root.lastPathComponent) — \(Self.formatBytes(report.totalBytes)) across \(report.treemap.count) area(s), \(report.reclaimCandidates.count) reclaim candidate(s)")
    }
}
