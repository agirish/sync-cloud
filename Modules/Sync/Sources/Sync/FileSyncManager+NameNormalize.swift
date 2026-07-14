import Events
import Foundation

/// Name Normalizer (X8) — the bulk counterpart to the transfer pre-flight name check. The app
/// already knew, one file at a time and only at write, which names a provider forbids; this scans a
/// whole subtree, lists every risky file AND folder name, and normalizes the selected ones in a
/// single undoable pass — before they break a cloud sync. Mirrors ``FileSyncManager`` +Duplicates
/// and +Filing: a cancellable scan Task publishing `@Published` state, an apply path routed through
/// the serial `enqueueFileOperation` queue with ONE grouped undo.
extension FileSyncManager {

    // MARK: Scan

    /// Starts a cancellable Name Normalizer scan of `root` for `provider`, replacing any in-flight
    /// one. `provider` is remembered so the "Fix all" pass can honor the same ruleset.
    public func startNameScan(root: URL, provider: CloudProvider.ProviderType) {
        let previous = nameScanTask
        previous?.cancel()
        nameScanProvider = provider
        nameScanTask = Task { [weak self] in
            // Let a cancelled scan fully unwind (its defer clears isScanningNames) before the new one
            // runs, so scanNames' re-entrancy guard doesn't silently drop the restart.
            _ = await previous?.value
            await self?.scanNames(root: root, provider: provider)
        }
    }

    /// Cancels a running Name Normalizer scan; results are left as they were.
    public func cancelNameScan() {
        nameScanTask?.cancel()
    }

    /// Walks `root`, detects every risky name via the pure ``NameNormalizer``, and publishes them.
    /// `fileManager` is injectable for tests; production uses the manager's own.
    func scanNames(root: URL, provider: CloudProvider.ProviderType, fileManager fm: FileManaging? = nil) async {
        guard !isScanningNames else { return }
        let fileManager = fm ?? self.fileManager
        isScanningNames = true
        nameScanStatus = "Scanning \(root.lastPathComponent)…"
        // hasScannedNames flips only on completion (below), so a cancelled scan leaves the prior
        // state intact rather than flashing an empty "no risky names".
        defer {
            isScanningNames = false
            nameScanStatus = ""
        }

        let tree = await Self.buildTree(url: root, sortOption: .name, fileManager: fileManager, maxDepth: nil)
        if Task.isCancelled { return }
        let risky = NameNormalizer.scan(nodes: tree, provider: provider)
        if Task.isCancelled { return }

        riskyNames = risky
        // Published with the results, not at scan start: the root labels what's on screen, and a
        // cancelled rescan of a different folder must not relabel the previous results.
        nameScanRoot = root
        hasScannedNames = true
        Logger.shared.info("Name normalizer: scanned \(root.lastPathComponent) for \(provider.rawValue) — \(risky.count) risky name(s)")
    }

    /// Clears the current results (e.g. when switching providers), cancelling any in-flight scan so
    /// it can't republish stale results after the switch.
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
        // Verify All's write-exclusion guard, mirrored here (same rationale as syncFile / Filing):
        // a rename moves an item Verify All may be hashing.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before normalizing names")
            return
        }
        guard !selected.isEmpty, !isNormalizingNames else { return }
        isNormalizingNames = true
        defer { isNormalizingNames = false }

        let fm = fileManager
        // Apply deepest paths first so renaming a parent folder can never invalidate a child's
        // stored absolute path before we reach the child (the child renames inside the still-named
        // parent, then the parent folder is renamed around it).
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
                banner = .warning("Couldn't normalize \(result.failed) name\(result.failed == 1 ? "" : "s").")
            }
            return
        }

        // ONE grouped undo for the whole pass. Register it SHALLOWEST-first so a ⌘Z restores a
        // renamed parent folder before the children renamed inside it — the reverse of the
        // deepest-first apply order — keeping nested renames fully reversible.
        let undoItems = result.moves.sorted { pathDepth($0.from.path) < pathDepth($1.from.path) }
        let n = result.moves.count
        registerMoveUndo(items: undoItems, actionName: "Normalize \(n) Name\(n == 1 ? "" : "s")", fileManager: fm)

        // Drop the fixed rows; anything that failed stays listed for a retry.
        let doneSet = Set(result.doneIDs)
        riskyNames.removeAll { doneSet.contains($0.id) }

        Logger.shared.info("Name normalizer: normalized \(n) name(s)\(result.failed > 0 ? ", \(result.failed) failed" : "")")
        banner = result.failed > 0
            ? .warning("Normalized \(n) name\(n == 1 ? "" : "s"); \(result.failed) couldn't be fixed. Press ⌘Z to undo")
            : .success("Normalized \(n) name\(n == 1 ? "" : "s"). Press ⌘Z to undo")
    }

    /// Removes one risky name from the list without touching disk ("Skip" / leave it as-is).
    public func dismissRiskyName(_ risky: RiskyName) {
        riskyNames.removeAll { $0.id == risky.id }
    }

    // MARK: Helpers

    /// Number of path components — the sort key for deepest/shallowest-first ordering.
    private nonisolated static func componentCount(_ path: String) -> Int {
        URL(fileURLWithPath: path).pathComponents.count
    }
    private func pathDepth(_ path: String) -> Int { Self.componentCount(path) }

    /// Flattens a walked tree into `(relativePath, absolutePath, name, isDirectory)` for EVERY node —
    /// directories included, unlike ``flattenFiles(_:)`` / ``flattenFilesWithRelativePaths(_:prefix:)``
    /// which emit only leaves. Each directory is emitted WITH its own relative path first, then its
    /// children are recursed, so a risky folder name is flagged alongside the risky files inside it.
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
