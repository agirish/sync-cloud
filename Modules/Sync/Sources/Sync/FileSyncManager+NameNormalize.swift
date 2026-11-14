import Events
import Foundation

/// Name Normalizer: the bulk counterpart to the per-file name check at transfer. The Filing pass
/// lists every risky file and folder name a provider forbids, and the selected ones are normalized
/// in one undoable pass, before they break a cloud sync: an apply routed through the serial
/// `enqueueFileOperation` queue with one grouped undo.
extension FileSyncManager {

    // MARK: Scan

    /// True when a walk came back as nothing but the unreadable root itself. `buildTree` reports
    /// a permission-denied root as one unexplored marker with the root's own path, which the
    /// detector can't tell from a real entry. It would flag the root, and "Fix all" would rename a
    /// folder it can't list (a rename needs only parent-write), dangling the pane focus, the
    /// provider root and everything aimed at the old path. Every name scan must check it.
    static func isUnreadableRootMarker(_ tree: [FileNode], root: URL) -> Bool {
        tree.count == 1 && tree.first?.isUnexplored == true && tree.first?.id == root.path
    }

    /// Flags provider-hostile names on a tree the caller has already walked. The Filing scan walks
    /// the whole provider anyway, so risky names come back on that pass with no second walk or
    /// button. Detached, to keep the main actor free.
    /// - Parameter isCancelled: the staleness check, injectable so a test can assert that a stale
    ///   scan publishes nothing. Real cancellation is a race no test can stage, and a bulk rename
    ///   must never act on results for the wrong ruleset.
    func detectRiskyNames(in tree: [FileNode], root: URL, provider: CloudProvider.ProviderType,
                          isCancelled: @Sendable () -> Bool = { Task.isCancelled }) async {
        // Never offer to rename an unreadable provider root.
        if Self.isUnreadableRootMarker(tree, root: root) {
            riskyNames = []
            completeScan(\.nameScanLifecycle, root: root)
            Logger.shared.warning("Filing scan: could not read \(root.lastPathComponent) — permission denied; no names checked")
            return
        }

        let risky = await Task.detached(priority: .userInitiated) {
            NameNormalizer.scan(nodes: tree, provider: provider)
        }.value
        // The caller cancels on a newer scan; this keeps a stale result from landing over it.
        if isCancelled() { return }

        riskyNames = reportable(risky)
        completeScan(\.nameScanLifecycle, root: root)
        Logger.shared.info("Filing scan flagged \(risky.count) risky name(s) under \(root.lastPathComponent) for \(provider.rawValue), \(riskyNames.count) reported")
    }

    /// Clears the current results, cancelling any in-flight scan so it can't republish stale
    /// results afterwards. Called by ``clearLensResultsForProviderSwitch()``, which is the one
    /// place a provider switch drops a lens's findings.
    public func clearNameScan() {
        nameScanTask?.cancel()
        riskyNames = []
        nameScanRoot = nil
        hasScannedNames = false
    }

    // MARK: Normalize (apply)

    /// Renames every selected risky name to its cloud-safe form in one undoable pass. Never
    /// overwrites: a name collision keeps both by uniquifying (" 2", " 3", …). All renames land as a
    /// single grouped Undo, so one ⌘Z reverts the whole pass.
    public func normalizeNames(_ selected: [RiskyName]) async {
        // Verify All's write exclusion, as in syncFile and Filing: a rename moves an item Verify
        // All may be hashing.
        guard !isVerifyAllRunning else {
            banner = .refusal("Wait for Verify All to finish before normalizing names", log: .info)
            return
        }
        guard !selected.isEmpty, !isNormalizingNames else { return }
        isNormalizingNames = true
        defer { isNormalizingNames = false }

        let fm = fileManager
        // Deepest paths first, so renaming a parent never invalidates a child's stored path before
        // the child is renamed.
        let ordered = selected.sorted { pathDepth($0.id) > pathDepth($1.id) }
        let logger = Logger.shared   // captured on the main actor; its methods are nonisolated

        let result: (moves: [MoveItemState], doneIDs: [String], failed: Int) = await enqueueFileOperation {
            var moves: [MoveItemState] = []
            var doneIDs: [String] = []
            var failed = 0
            for item in ordered {
                let src = URL(fileURLWithPath: item.id)
                // Vanished since the scan (deleted, or already renamed via a parent) — skip, don't fail.
                guard fm.fileExists(atPath: src.path) else { continue }
                var dst = src.deletingLastPathComponent().appendingPathComponent(item.sanitizedName)
                // NEVER overwrite: if a file already occupies the safe name, keep both by uniquifying.
                if fm.fileExists(atPath: dst.path) {
                    dst = FileSyncManager.generateUniqueURL(for: dst, fileManager: fm)
                }
                // Defensive: the scan already skips sanitized == current, but a uniquify could in
                // theory land back on the source — never rename a thing onto itself.
                if src.standardizedFileURL.path == dst.standardizedFileURL.path { continue }
                do {
                    try FileSyncManager.ensureParentDirectoryExists(for: dst, fileManager: fm)
                    let overwritten = try FileSyncManager.safeMoveItem(at: src, to: dst, fileManager: fm)
                    moves.append((from: src, to: dst, overwritten: overwritten))
                    doneIDs.append(item.id)
                } catch {
                    // Record the cause — the banner only reports a count.
                    logger.warning("Name normalizer: renaming “\(item.currentName)” → “\(item.sanitizedName)” failed: \(error.localizedDescription)")
                    failed += 1
                }
            }
            return (moves, doneIDs, failed)
        }

        guard !result.moves.isEmpty else {
            if result.failed > 0 {
                banner = .warning("Couldn’t normalize \(result.failed) name\(result.failed == 1 ? "" : "s").", log: .warn)
            }
            return
        }

        // One grouped undo for the whole pass, registered shallowest-first (the reverse of the
        // apply order) so ⌘Z restores a parent before the children renamed inside it.
        let undoItems = result.moves.sorted { pathDepth($0.from.path) < pathDepth($1.from.path) }
        let n = result.moves.count
        registerMoveUndo(items: undoItems, actionName: "Normalize \(CountedNoun.phrase(n, "Name"))", fileManager: fm)

        // Drop the fixed rows; anything that failed stays listed for a retry.
        let doneSet = Set(result.doneIDs)
        riskyNames.removeAll { doneSet.contains($0.id) }

        Logger.shared.info("Name normalizer: normalized \(n) name(s)\(result.failed > 0 ? ", \(result.failed) failed" : "")")
        // `undoable: true` on both branches: `invalidateUndoableBanner` reads the flag to retire
        // the ⌘Z offer once the undo stack moves on, or the banner would offer to undo a later
        // operation. The partial branch is a warning and still undoable; the undo above is always
        // registered on this path.
        banner = result.failed > 0
            ? .warning("Normalized \(n) name\(n == 1 ? "" : "s"); \(result.failed) couldn’t be fixed",
                       undoable: true, log: .warn)
            : .success("Normalized \(n) name\(n == 1 ? "" : "s")", undoable: true)
    }

    // MARK: Helpers

    /// Number of path components — the sort key for deepest/shallowest-first ordering.
    private nonisolated static func componentCount(_ path: String) -> Int {
        URL(fileURLWithPath: path).pathComponents.count
    }
    private func pathDepth(_ path: String) -> Int { Self.componentCount(path) }

    /// Flattens a walked tree into `(relativePath, absolutePath, name, isDirectory)` for every
    /// node, folders included (``flattenFiles(_:)`` and
    /// ``flattenFilesWithRelativePaths(_:prefix:)`` emit only leaves), so a risky folder name is
    /// flagged alongside the files inside it.
    nonisolated static func flattenNodesWithRelativePaths(
        _ nodes: [FileNode], prefix: String = ""
    ) -> [(rel: String, id: String, name: String, isDirectory: Bool)] {
        var out: [(rel: String, id: String, name: String, isDirectory: Bool)] = []
        for n in nodes {
            let rel = prefix.isEmpty ? n.name : prefix + "/" + n.name
            out.append((rel: rel, id: n.id, name: n.name, isDirectory: n.isDirectory))
            if n.isDirectory {
                out.append(contentsOf: flattenNodesWithRelativePaths(n.children ?? [], prefix: rel))
            }
        }
        return out
    }
}
