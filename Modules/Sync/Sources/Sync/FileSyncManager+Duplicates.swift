import Foundation

/// Tidy — the in-provider duplicate finder. Reuses the existing tree walk and content hasher to
/// gather input for the pure ``DuplicateFinder``, and routes removals through ``deleteItems`` so
/// they land in the Trash with the same one-step Undo as every other destructive action.
extension FileSyncManager {

    /// Aggregate headline numbers for the Duplicates results view.
    public struct DuplicateSummary: Sendable, Equatable {
        public var groupCount: Int
        public var reclaimableBytes: Int
        public var redundantCopyCount: Int
        public var needsReviewCount: Int
    }

    /// Summary derived from the current ``duplicateGroups``. The headline "reclaimable" and
    /// "redundant" figures count only batch-eligible (identical) groups, so they match exactly
    /// what "Apply recommended" delivers — overlapping (merge deferred) and name-only (different
    /// content) groups never inflate them.
    public var duplicateSummary: DuplicateSummary {
        var reclaimable = 0, redundant = 0, review = 0
        for g in duplicateGroups {
            if g.isRecommendedForBatch {
                reclaimable += g.reclaimableBytes
                redundant += g.copies.count - 1
            }
            if case .nameOnly = g.matchType { review += 1 }
        }
        return DuplicateSummary(groupCount: duplicateGroups.count,
                                reclaimableBytes: reclaimable,
                                redundantCopyCount: redundant,
                                needsReviewCount: review)
    }

    // MARK: Scan

    /// Walks one provider subtree, hashes duplicate-candidate files, and groups the results.
    /// - Parameters:
    ///   - root: The provider root (or focused folder) to scan.
    ///   - options: Detection tuning.
    public func findDuplicates(
        root: URL,
        options: DuplicateFinderOptions = .init(),
        fileManager fm: FileManaging? = nil
    ) async {
        guard !isFindingDuplicates else { return }
        let fileManager = fm ?? self.fileManager
        isFindingDuplicates = true
        duplicateScanStatus = "Scanning \(root.lastPathComponent)…"
        duplicateScanRoot = root.path
        defer {
            isFindingDuplicates = false
            duplicateScanStatus = nil
            hasFoundDuplicates = true
        }

        // 1. Walk the full subtree (off-main inside buildTree).
        let tree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager, maxDepth: nil)

        // 2. Only files whose size collides with another can possibly be identical — hash just
        //    those. Everything else gets a unique placeholder so folder signatures still compute
        //    but never falsely match.
        let allFiles = Self.flattenFiles(tree)
        var sizeCount: [Int: Int] = [:]
        for f in allFiles where (f.fileSize ?? -1) >= 0 {
            sizeCount[f.fileSize!, default: 0] += 1
        }
        let candidatePaths = allFiles
            .filter { ($0.fileSize ?? -1) >= 0 && sizeCount[$0.fileSize!, default: 0] >= 2 }
            .map { $0.id }

        duplicateScanStatus = "Hashing \(candidatePaths.count) candidates…"
        let realHashes = await Self.hashFiles(candidatePaths, fileManager: fileManager)

        var fileHashes: [String: String] = [:]
        fileHashes.reserveCapacity(allFiles.count)
        for f in allFiles {
            fileHashes[f.id] = realHashes[f.id] ?? ("u:" + f.id)
        }

        // 3. Group (pure).
        let groups = DuplicateFinder.findGroups(tree: tree, fileHashes: fileHashes, options: options)
        self.duplicateGroups = groups
    }

    /// Clears the current results (called when switching providers, so stale groups from one
    /// provider can never be shown — or acted on — under another).
    public func clearDuplicates() {
        duplicateGroups = []
        duplicateScanRoot = nil
        hasFoundDuplicates = false
    }

    // MARK: Resolve

    /// Applies a single group's recommended removal (Trash the fully-redundant / older copies).
    /// No-op for groups that need a merge or manual review. Reversible via Undo (⌘Z).
    @discardableResult
    public func resolveDuplicateGroup(_ group: DuplicateGroup) async -> Bool {
        let paths = group.recommendedRemovalPaths
        guard !paths.isEmpty else { return false }
        let bytes = group.reclaimableBytes
        let removed = await deleteItems(at: paths, fileManager: fileManager)
        // Only drop the group and claim success if items actually left the disk — a declined or
        // failed trash must not vanish the group behind a false "Reclaimed" banner.
        guard removed > 0 else { return false }
        duplicateGroups.removeAll { $0.id == group.id }
        if currentError == nil {
            banner = .success("Reclaimed \(Self.formatBytes(bytes)) — press ⌘Z to undo")
        }
        return true
    }

    /// Applies the recommended removal for every batch-eligible group (byte-identical only).
    /// Versions, name-only, and overlapping groups are deliberately left for a per-group look.
    public func applyRecommendedDuplicates() async {
        let batch = duplicateGroups.filter { $0.isRecommendedForBatch }
        let paths = batch.flatMap { $0.recommendedRemovalPaths }
        guard !paths.isEmpty else { return }
        let bytes = batch.reduce(0) { $0 + $1.reclaimableBytes }
        let ids = Set(batch.map { $0.id })
        let removed = await deleteItems(at: paths, fileManager: fileManager)
        guard removed > 0 else { return }
        duplicateGroups.removeAll { ids.contains($0.id) }
        if currentError == nil {
            banner = .success("Reclaimed \(Self.formatBytes(bytes)) from \(batch.count) groups — press ⌘Z to undo")
        }
    }

    /// Removes a group from the list without touching disk ("Keep separate").
    public func dismissDuplicateGroup(_ group: DuplicateGroup) {
        duplicateGroups.removeAll { $0.id == group.id }
    }

    // MARK: Helpers

    /// Recursively collects leaf file nodes from a walked tree.
    nonisolated static func flattenFiles(_ nodes: [FileNode]) -> [FileNode] {
        var out: [FileNode] = []
        for n in nodes {
            if n.isDirectory {
                out.append(contentsOf: flattenFiles(n.children ?? []))
            } else {
                out.append(n)
            }
        }
        return out
    }

    /// Hashes files with bounded concurrency, returning path → SHA-256 hex (missing when a file
    /// can't be hashed — too large, unreadable). Off-main via ``FileContentVerifier``.
    nonisolated static func hashFiles(
        _ paths: [String],
        fileManager: FileManaging,
        maxConcurrent: Int = 6
    ) async -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        var result: [String: String] = [:]
        result.reserveCapacity(paths.count)
        var next = 0
        await withTaskGroup(of: (String, String?).self) { group in
            func schedule(_ path: String) {
                group.addTask {
                    (path, await FileContentVerifier.sha256Hex(filePath: path, fileManager: fileManager))
                }
            }
            let initial = min(maxConcurrent, paths.count)
            while next < initial { schedule(paths[next]); next += 1 }
            for await (path, hash) in group {
                if let hash { result[path] = hash }
                if next < paths.count { schedule(paths[next]); next += 1 }
            }
        }
        return result
    }

    public nonisolated static func formatBytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: Int64(max(0, n)))
    }
}
