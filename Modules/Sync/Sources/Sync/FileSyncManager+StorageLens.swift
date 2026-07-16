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

    /// Clears the current report (called when switching providers, so a stale report from one
    /// provider can never be shown under another).
    public func clearStorageLens() {
        storageLensTask?.cancel()
        storageLensReport = nil
        storageLensRoot = nil
        hasBuiltStorageLens = false
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
        completeScan(\.storageLensLifecycle, root: root)
        Logger.shared.info("Storage Lens: analyzed \(root.lastPathComponent) — \(Self.formatBytes(report.totalBytes)) across \(report.treemap.count) area(s), \(report.reclaimCandidates.count) reclaim candidate(s)")
    }
}
