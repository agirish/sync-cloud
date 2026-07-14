import Events
import Foundation

/// Storage Lens — the read-only "where does my space go?" analyzer. Reuses the existing full tree
/// walk to feed the pure ``StorageLensAnalyzer``, then publishes the report for the UI. This
/// surface never mutates files: its only action is a Finder reveal handled up in the app layer.
extension FileSyncManager {

    /// Starts a cancellable Storage Lens build, replacing any in-flight one.
    public func startBuildStorageLens(root: URL, options: StorageLensOptions = .init()) {
        let previous = storageLensTask
        previous?.cancel()
        storageLensTask = Task { [weak self] in
            // Let a cancelled build fully unwind (its defer clears isBuildingStorageLens) before the
            // new one runs, so the re-entrancy guard below doesn't silently drop the restart.
            _ = await previous?.value
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
        isBuildingStorageLens = true
        storageLensStatus = "Analyzing \(root.lastPathComponent)…"
        storageLensProgress = 0
        // hasBuiltStorageLens flips only on completion (below), so a cancelled build leaves the
        // prior state intact rather than flashing an empty report.
        defer {
            isBuildingStorageLens = false
            storageLensStatus = ""
            storageLensProgress = 0
        }

        // 1. Walk the full subtree (off-main inside buildTree). maxDepth: nil = unlimited.
        let tree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager, maxDepth: nil)
        if Task.isCancelled { return }

        // 2. Analyze (pure, no disk). Date() is captured here so staleness is measured from now.
        let report = StorageLensAnalyzer.analyze(tree: tree, now: Date(), options: options)
        if Task.isCancelled { return }

        // Published with the results, not at build start: the root labels what's on screen, and a
        // cancelled rebuild of a different folder must not relabel the previous report.
        self.storageLensReport = report
        self.storageLensRoot = root
        self.hasBuiltStorageLens = true
        Logger.shared.info("Storage Lens: analyzed \(root.lastPathComponent) — \(Self.formatBytes(report.totalBytes)) across \(report.treemap.count) area(s), \(report.reclaimCandidates.count) reclaim candidate(s)")
    }
}
