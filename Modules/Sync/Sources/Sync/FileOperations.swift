import Events
import Foundation

extension FileSyncManager {

    // MARK: - Safe Atomic Replacements
    
    enum FileOperationError: LocalizedError, Equatable {
        case identicalSourceAndDestination
        case nestingViolation
        /// Parent of destination exists as a file (e.g. cloud placeholder); sync the parent folder first.
        case parentExistsAsFile(parentName: String)
        /// The source pane's root path is empty — its provider vanished from settings while the
        /// pane still showed a stale tree. An empty root prefix-matches every node, so proceeding
        /// would resolve destinations against the process working directory.
        case sourceRootUnavailable
        /// The node's path is not inside the source pane's root (a stale tree after a pane swap
        /// or root edit). Grafting its absolute path under the destination would misdirect it.
        case itemOutsideSourceRoot(itemName: String)
        /// The destination root is empty or no longer on disk (provider unmounted or removed).
        /// Recreating it would land files in a dead local tree the provider never syncs.
        case destinationRootUnavailable

        var errorDescription: String? {
            switch self {
            case .identicalSourceAndDestination:
                return "The two paths are the same."
            case .nestingViolation:
                return "Cannot move or copy a directory into itself or its subdirectories."
            case .parentExistsAsFile(let parentName):
                return "A file named \"\(parentName)\" already exists on the destination. Sync the parent folder first (use Replace) to replace it with the package, then sync this item."
            case .sourceRootUnavailable:
                return "The source pane's folder is no longer available. Rescan before copying or moving items."
            case .itemOutsideSourceRoot(let itemName):
                return "\"\(itemName)\" is not inside the source pane's folder. Rescan and try again."
            case .destinationRootUnavailable:
                return "The destination folder is no longer available. Rescan before copying or moving items."
            }
        }
    }
    
    nonisolated static func validateFileOperation(source: URL, destination: URL) throws {
        try validateFileOperation(
            source: source,
            destination: destination,
            caseSensitiveVolume: volumeSupportsCaseSensitiveNames(for: source)
        )
    }

    /// Testable core; production resolves `caseSensitiveVolume` from the source volume.
    nonisolated static func validateFileOperation(source: URL, destination: URL, caseSensitiveVolume: Bool) throws {
        // Resolve symlinks so an aliased destination path cannot smuggle a directory into itself.
        let src = symlinkResolvedPath(for: source)
        let dst = symlinkResolvedPath(for: destination)

        // Deliberately case-sensitive: a case-only rename ("foo" -> "Foo") is a legitimate
        // operation on case-insensitive volumes and must not be rejected as identical.
        if src == dst {
            throw FileOperationError.identicalSourceAndDestination
        }

        // Ensure trailing slash for prefix check to avoid /a matching /abc
        let srcWithSlash = src.hasSuffix("/") ? src : src + "/"
        let isNested: Bool
        if caseSensitiveVolume {
            isNested = dst.hasPrefix(srcWithSlash)
        } else {
            // APFS is case-insensitive by default: /a/Dir/child and /a/dir/child are the same
            // directory, so a case-variant path must not slip past the prefix check.
            isNested = dst.range(of: srcWithSlash, options: [.anchored, .caseInsensitive]) != nil
        }
        if isNested {
            throw FileOperationError.nestingViolation
        }
    }

    /// Symlink-free path for `url`. `resolvingSymlinksInPath()` alone returns the path
    /// unresolved whenever a trailing component does not exist (realpath fails), and a
    /// destination usually does not exist yet - so resolve the deepest existing ancestor and
    /// re-append the missing components.
    private nonisolated static func symlinkResolvedPath(for url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.path
    }

    /// True when the volume containing `url` distinguishes names by case. Falls back to false
    /// (the macOS default is case-insensitive) when the volume cannot be queried, e.g. for a
    /// destination that does not exist yet - the stricter comparison is the safe default.
    public nonisolated static func volumeSupportsCaseSensitiveNames(for url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    }
    
    
    /// Finds a free name near `url` by appending " 2", " 3", … A name counts as taken when it
    /// exists on disk OR is in `reserved` — the latter lets a bulk run that resolves every
    /// destination up front (before its parallel copy phase) avoid handing two items the same
    /// path when a keep-both suffix would otherwise collide with another item's real target.
    public nonisolated static func generateUniqueURL(for url: URL, fileManager: FileManaging = FileManager.default, reserved: Set<String> = []) -> URL {
        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let extensionStr = url.pathExtension
        
        var counter = 2
        var newURL = url
        
        while fileManager.fileExists(atPath: newURL.path) || reserved.contains(newURL.path) {
            let newFilename = "\(filename) \(counter)"
            if extensionStr.isEmpty {
                newURL = directory.appendingPathComponent(newFilename)
            } else {
                newURL = directory.appendingPathComponent(newFilename).appendingPathExtension(extensionStr)
            }
            counter += 1
        }
        
        return newURL
    }

    /// True when `destinationURL` holds a distinct item that a copy/move must replace. A case-only
    /// rename ("foo" -> "Foo") on a case-insensitive volume reports its own source as the
    /// destination, so it is excluded: it is not a replacement, and backing it up would move the
    /// only copy of the data aside.
    private nonisolated static func destinationExistsForReplacement(
        source: URL,
        destination: URL,
        fileManager: FileManaging
    ) -> Bool {
        !isCaseOnlyRenaming(source: source, destination: destination)
            && fileManager.fileExists(atPath: destination.path)
    }

    /// Finalizes the in-place `.rollback_<UUID>` backup that the atomic replace left beside the
    /// destination, returning a restorable URL for the overwritten item. Prefers the Trash so the
    /// backup shows up where users expect. When the volume has no Trash (network shares), KEEP the
    /// backup where it is: deleting it here would make Replace permanently destroy the old file the
    /// instant the operation succeeds. The dot-prefixed name hides it from the panes; undo restores
    /// it to its original location, and an unused backup is simply left behind once the undo stack
    /// drops — recoverable by hand beats silently destroyed. Returns nil when nothing was replaced.
    private nonisolated static func finalizeBackup(
        _ backupURL: URL?,
        replacing destinationURL: URL,
        fileManager: FileManaging
    ) -> URL? {
        guard let backupURL else { return nil }
        var trashedURL: NSURL? = nil
        let recovered: URL?
        if (try? fileManager.trashItem(at: backupURL, resultingItemURL: &trashedURL)) != nil {
            recovered = trashedURL as URL?
        } else {
            recovered = backupURL
        }
        if let recovered {
            // Recovery breadcrumb: the single line that lets a replaced file be found again after
            // an overwrite (or a bad sync). Logged at .info so it survives a normal-level trace.
            // Hopped to the MainActor logger, matching the other nonisolated logging in this file.
            Task { @MainActor in Logger.shared.info("Replaced \(destinationURL.path) — previous version recoverable at \(recovered.path)") }
        }
        return recovered
    }

    /// Safely copies a file, atomically replacing the destination if it exists to prevent corruption.
    /// Returns a restorable URL for the overwritten item, if any (Trash, or a hidden in-place
    /// backup on volumes without Trash).
    @discardableResult
    public nonisolated static func safeCopyItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging = FileManager.default) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL)

        let targetDirectory = destinationURL.deletingLastPathComponent()
        let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")

        defer { try? fileManager.removeItem(at: tempURL) }

        try fileManager.copyItem(at: sourceURL, to: tempURL)

        if destinationExistsForReplacement(source: sourceURL, destination: destinationURL, fileManager: fileManager) {
            // Atomically swap the staged copy into place, preserving the old destination as a
            // sibling backup. The destination is never momentarily absent, so a crash or forced
            // quit mid-replace cannot strand the old file in Trash with nothing at the destination.
            // A throw here leaves the destination untouched (the primitive is atomic); the staged
            // temp is cleaned up by `defer`.
            let backupURL = try fileManager.replaceItem(
                at: destinationURL,
                withItemAt: tempURL,
                backupItemName: ".rollback_\(UUID().uuidString)"
            )
            return finalizeBackup(backupURL, replacing: destinationURL, fileManager: fileManager)
        }

        // Brand-new destination (or a case-only rename whose "destination" is the source itself on
        // a case-insensitive volume): a single rename into place, no backup, no replacement window.
        try fileManager.moveItem(at: tempURL, to: destinationURL)
        return nil
    }
    
    /// Safely moves a file, atomically replacing the destination if it exists.
    /// Returns a restorable URL for the overwritten item, if any (Trash, or a hidden in-place
    /// backup on volumes without Trash).
    @discardableResult
    public nonisolated static func safeMoveItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging = FileManager.default) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL)

        if destinationExistsForReplacement(source: sourceURL, destination: destinationURL, fileManager: fileManager) {
            return try replaceDestinationByMoving(sourceURL: sourceURL, destinationURL: destinationURL, fileManager: fileManager)
        }

        // No existing destination (or a case-only rename whose "destination" is the source itself):
        // a plain single rename. Nothing is backed up, so there is no replacement window.
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            // Fallback for cross-volume moves (EXDEV) or other similar access issues. Stage into a
            // temp mathematically guaranteed to be on the destination's volume, then rename into
            // place — an atomic install that avoids corrupted half-files.
            let targetDirectory = destinationURL.deletingLastPathComponent()
            let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")

            defer { try? fileManager.removeItem(at: tempURL) }

            try fileManager.copyItem(at: sourceURL, to: tempURL)
            try fileManager.moveItem(at: tempURL, to: destinationURL)

            // Cleanup source: try trash first, fall back to direct remove if the volume has no Trash.
            do {
                try fileManager.trashItem(at: sourceURL, resultingItemURL: nil)
            } catch {
                do {
                    try fileManager.removeItem(at: sourceURL)
                } catch let cleanupError {
                    // The move already landed, so the item at the destination is this operation's
                    // own copy - removing it is a clean revert when the source can't be cleaned up.
                    try? fileManager.removeItem(at: destinationURL)
                    throw cleanupError
                }
            }
        }
        return nil
    }

    /// Replaces an existing destination with `sourceURL`'s contents atomically. Stages the source
    /// onto the destination's volume (a same-volume rename consumes it; a cross-volume move copies
    /// it), then swaps it into place via `replaceItem`, preserving the old destination as a
    /// recoverable backup. Because the swap is atomic the destination is never momentarily absent —
    /// the crash window Finding 1 flagged. A failed swap leaves the destination untouched; if the
    /// same-volume staging had already consumed the source, it is restored so no data is lost.
    private nonisolated static func replaceDestinationByMoving(
        sourceURL: URL,
        destinationURL: URL,
        fileManager: FileManaging
    ) throws -> URL? {
        let targetDirectory = destinationURL.deletingLastPathComponent()
        let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: tempURL) }

        // Stage the source onto the destination's volume. Same-volume: a rename consumes the
        // source. Cross-volume (EXDEV): copy, and remember the original still needs cleanup.
        var sourceConsumed = true
        do {
            try fileManager.moveItem(at: sourceURL, to: tempURL)
        } catch {
            try fileManager.copyItem(at: sourceURL, to: tempURL)
            sourceConsumed = false
        }

        let backupURL: URL?
        do {
            backupURL = try fileManager.replaceItem(
                at: destinationURL,
                withItemAt: tempURL,
                backupItemName: ".rollback_\(UUID().uuidString)"
            )
        } catch {
            // The atomic replace failed with the destination intact. But a same-volume rename has
            // already moved the source into the staged temp (which `defer` will delete), so restore
            // it — a failed replace must never destroy the source.
            if sourceConsumed {
                try? fileManager.moveItem(at: tempURL, to: sourceURL)
            }
            throw error
        }

        // Cross-volume: the source was copied, not consumed, so remove the original now that the
        // destination holds its data. Trash first; fall back to a permanent remove.
        if !sourceConsumed {
            do {
                try fileManager.trashItem(at: sourceURL, resultingItemURL: nil)
            } catch {
                do {
                    try fileManager.removeItem(at: sourceURL)
                } catch let cleanupError {
                    // Neither Trash nor remove worked, so this cross-volume move can't complete.
                    // Undo the replace and fail — matching the dest-absent cross-volume path, and
                    // avoiding a "moved" undo entry for a source still on disk.
                    if let backupURL {
                        revertReplace(destinationURL: destinationURL, from: backupURL, fileManager: fileManager)
                    }
                    throw cleanupError
                }
            }
        }

        return finalizeBackup(backupURL, replacing: destinationURL, fileManager: fileManager)
    }

    /// Atomically restores a just-replaced `destinationURL` to `backupURL`'s (pre-replace) content,
    /// then discards the redundant fresh backup the restore takes. Used to undo a replace whose
    /// cross-volume source-cleanup failed: the restore goes back through `replaceItem`, so the
    /// destination is never momentarily absent, and the fresh backup is a copy of that
    /// still-present source, so it can be dropped.
    private nonisolated static func revertReplace(
        destinationURL: URL,
        from backupURL: URL,
        fileManager: FileManaging
    ) {
        guard let staleBackup = try? fileManager.replaceItem(
            at: destinationURL,
            withItemAt: backupURL,
            backupItemName: ".rollback_\(UUID().uuidString)"
        ) else {
            // The revert itself failed: the destination may hold the new content while the source
            // is still on disk. Log loudly — this is the one spot where a replace can leave the
            // two panes inconsistent without surfacing an error to the caller.
            Task { @MainActor in Logger.shared.error("Could not revert a partial replace at \(destinationURL.path) from backup \(backupURL.path); the destination may hold new content while the original source is still present") }
            return
        }
        try? fileManager.removeItem(at: staleBackup)
    }
    
    /// Ensures the parent of `destinationURL` can be used as a directory (creates it or throws if it exists as a file).
    /// Call before copying into a path like `.../Package.pages-tef/Previews` so we don't fail with "file already exists".
    public nonisolated static func ensureParentDirectoryExists(
        for destinationURL: URL,
        fileManager: FileManaging
    ) throws {
        let parentURL = destinationURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw FileOperationError.parentExistsAsFile(parentName: parentURL.lastPathComponent)
            }
            return
        }
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    }

    /// Performs only the file I/O for a single sync (create directory + copy or move).
    /// Used by bulk sync to run multiple operations in parallel without going through the serial queue per file.
    /// - Returns: On success, (nil, trashed, from, to). On failure, (error, nil, nil, nil).
    public nonisolated static func performFileSyncIO(
        from sourceURL: URL,
        to destinationURL: URL,
        isMove: Bool,
        fileManager: FileManaging = FileManager.default
    ) throws -> (trashed: URL?, from: URL, to: URL) {
        try ensureParentDirectoryExists(for: destinationURL, fileManager: fileManager)
        let trashed: URL?
        if isMove {
            trashed = try safeMoveItem(at: sourceURL, to: destinationURL, fileManager: fileManager)
        } else {
            trashed = try safeCopyItem(at: sourceURL, to: destinationURL, fileManager: fileManager)
        }
        return (trashed, sourceURL, destinationURL)
    }
    
    private nonisolated static func isCaseOnlyRenaming(source: URL, destination: URL) -> Bool {
        return source.deletingLastPathComponent() == destination.deletingLastPathComponent() &&
               source.lastPathComponent.lowercased() == destination.lastPathComponent.lowercased()
    }

    // MARK: - File Operations

    /// Copies the given nodes from one pane to the other (left → right or right → left). Resolves collisions via `collisionResolver`.
    /// - Returns: The nodes that were successfully copied (may be fewer if user skips or errors occur).
    @discardableResult
    public func copyItems(nodes: [FileNode], fromLeft: Bool, leftRoot: String, rightRoot: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        await transferItems(
            nodes: nodes,
            isMove: false,
            destinationDescription: "between panes",
            destinationRoot: fromLeft ? rightRoot : leftRoot,
            targetURL: Self.paneTargetURL(fromLeft: fromLeft, leftRoot: leftRoot, rightRoot: rightRoot),
            fileManager: fm
        )
    }

    /// Moves the given nodes to the opposite pane (removes from source). Collisions handled via `collisionResolver`.
    /// - Returns: The nodes that were successfully moved.
    @discardableResult
    public func moveItems(nodes: [FileNode], fromLeft: Bool, leftRoot: String, rightRoot: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        await transferItems(
            nodes: nodes,
            isMove: true,
            destinationDescription: "between panes",
            destinationRoot: fromLeft ? rightRoot : leftRoot,
            targetURL: Self.paneTargetURL(fromLeft: fromLeft, leftRoot: leftRoot, rightRoot: rightRoot),
            fileManager: fm
        )
    }

    /// Copies multiple files to a specific absolute destination directory path.
    /// - Returns: Nodes that were successfully copied.
    @discardableResult
    public func copyItems(nodes: [FileNode], toPath destinationPath: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        await transferItems(
            nodes: nodes,
            isMove: false,
            destinationDescription: "to \(destinationPath)",
            destinationRoot: destinationPath,
            targetURL: { node in URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name) },
            fileManager: fm
        )
    }

    /// Moves multiple files to a specific absolute destination directory path, removing them from their origin.
    /// - Returns: Nodes that were successfully moved.
    @discardableResult
    public func moveItems(nodes: [FileNode], toPath destinationPath: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        await transferItems(
            nodes: nodes,
            isMove: true,
            destinationDescription: "to \(destinationPath)",
            destinationRoot: destinationPath,
            targetURL: { node in URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name) },
            fileManager: fm
        )
    }

    /// Derives the cross-pane destination for a node: its path relative to the source pane root,
    /// re-rooted under the opposite pane's root. Throws instead of guessing when the node is not
    /// actually inside the source root — including the empty-root case (a provider dropped from
    /// settings mid-session) and prefix aliasing ("/data/foo" must not claim "/data/foobar/x").
    /// The old fallback kept the node's near-absolute path and grafted it under the destination
    /// root, which is how pane swaps produced misdirected `<newRoot>/Users/…/<oldRoot>/…` copies.
    private nonisolated static func paneTargetURL(fromLeft: Bool, leftRoot: String, rightRoot: String) -> @Sendable (FileNode) throws -> URL {
        let fromRoot = ((fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        let toRoot = ((!fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        return { node in
            guard !fromRoot.isEmpty else { throw FileOperationError.sourceRootUnavailable }
            guard !toRoot.isEmpty else { throw FileOperationError.destinationRootUnavailable }
            let fromRootWithSlash = fromRoot.hasSuffix("/") ? fromRoot : fromRoot + "/"
            let relativePath: String
            if node.id == fromRoot {
                relativePath = ""
            } else if node.id.hasPrefix(fromRootWithSlash) {
                relativePath = String(node.id.dropFirst(fromRootWithSlash.count))
            } else {
                throw FileOperationError.itemOutsideSourceRoot(itemName: node.name)
            }
            return URL(fileURLWithPath: (toRoot as NSString).appendingPathComponent(relativePath))
        }
    }

    /// Shared implementation behind the four copy/move entry points. The variants differ only in
    /// how the destination URL is derived (`targetURL`), the primitive (`isMove` selects
    /// safeMoveItem/safeCopyItem, the Move/Copy undo registrar, and the log wording), and the
    /// same-URL policy: a copy onto itself keeps both under a uniquified name, a move onto
    /// itself is skipped.
    ///
    /// `destinationRoot` is the pane root or drop directory the transfer targets. It must
    /// already exist on disk: silently recreating a vanished provider root (e.g.
    /// `~/Library/CloudStorage/…` after the cloud app unmounted) would land files in a dead
    /// local tree the provider never syncs — and a move would also remove the originals.
    /// Missing intermediate folders UNDER a live root are still created per item by
    /// `ensureParentDirectoryExists`; only the root itself is never auto-created.
    /// - Returns: The nodes that were successfully transferred, in processing order.
    private func transferItems(
        nodes: [FileNode],
        isMove: Bool,
        destinationDescription: String,
        destinationRoot: String,
        targetURL deriveTargetURL: @escaping @Sendable (FileNode) throws -> URL,
        fileManager fm: FileManaging
    ) async -> [FileNode] {
        let resolveCollision = collisionResolver
        let prunedNodes = nodes.pruneNestedNodes()
        let total = Int64(prunedNodes.count)
        // Standardize away a trailing slash for the existence stat; an empty root must stay
        // empty (URL(fileURLWithPath: "") would resolve against the process CWD).
        let destinationRootPath = destinationRoot.isEmpty
            ? ""
            : URL(fileURLWithPath: (destinationRoot as NSString).expandingTildeInPath).path

        let progress: Progress? = total > 0 ? Progress(totalUnitCount: total) : nil
        if let progress {
            progress.localizedDescription = "\(isMove ? "Moving" : "Copying") \(total) Items"
            progress.isCancellable = true
        }

        let result = await enqueueFileOperation { [weak self, progress] () -> (errors: [Error], transferred: [(from: URL, to: URL, overwritten: URL?)]) in
            guard self != nil else { return ([], []) }
            // One stat, before any I/O: a missing destination root fails the whole operation
            // rather than being recreated by the per-item intermediate-directory pass below.
            guard !destinationRootPath.isEmpty, fm.fileExists(atPath: destinationRootPath) else {
                return ([FileOperationError.destinationRootUnavailable], [])
            }
            // Publish progress only once this operation actually starts; setting it at enqueue
            // time would clobber the progress of an operation still running ahead in the queue.
            if let progress {
                await MainActor.run { [weak self] in self?.activeProgress = progress }
            }
            var taskErrors: [Error] = []
            var targetItems: [(from: URL, to: URL, overwritten: URL?)] = []

            for (index, node) in prunedNodes.enumerated() {
                if progress?.isCancelled == true { break }

                await MainActor.run {
                    progress?.localizedAdditionalDescription = node.name
                }
                let sourceURL = URL(fileURLWithPath: node.id)
                var targetURL: URL
                do {
                    targetURL = try deriveTargetURL(node)
                } catch {
                    taskErrors.append(error)
                    await MainActor.run {
                        progress?.completedUnitCount = Int64(index + 1)
                    }
                    continue
                }

                if sourceURL == targetURL {
                    if isMove {
                        _ = await MainActor.run {
                            Logger.shared.debug("Skipping move of \"\(node.name)\": source and destination are the same location.")
                        }
                        continue
                    }
                    targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                } else {
                    // Stat with isDirectory so the collision prompt can warn that replacing a
                    // folder replaces its whole contents (Finder-style), not just a same-named file.
                    var targetIsDir: ObjCBool = false
                    if fm.fileExists(atPath: targetURL.path, isDirectory: &targetIsDir) {
                        let tName = targetURL.lastPathComponent
                        let tIsDir = targetIsDir.boolValue
                        let resolution = await MainActor.run { resolveCollision(tName, isMove, tIsDir) }
                        switch resolution {
                        case .replace: break
                        case .keepBoth: targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                        case .skip: continue
                        }
                    }
                }

                do {
                    try Self.validateFileOperation(source: sourceURL, destination: targetURL)
                    try Self.ensureParentDirectoryExists(for: targetURL, fileManager: fm)
                    let trashed = isMove
                        ? try Self.safeMoveItem(at: sourceURL, to: targetURL, fileManager: fm)
                        : try Self.safeCopyItem(at: sourceURL, to: targetURL, fileManager: fm)
                    targetItems.append((from: sourceURL, to: targetURL, overwritten: trashed))
                } catch {
                    taskErrors.append(error)
                }
                await MainActor.run {
                    progress?.completedUnitCount = Int64(index + 1)
                }
            }
            return (taskErrors, targetItems)
        }

        let transferred = result.transferred
        if !transferred.isEmpty {
            if isMove {
                let initialResolver = AsyncValueResolver<[MoveItemState]>()
                Task { await initialResolver.resolve(transferred) }
                self.registerMoveUndo(stateResolver: initialResolver, actionName: "Move \(transferred.count) Items", fileManager: fm)
            } else {
                let initialResolver = AsyncValueResolver<[CopyItemState]>()
                Task { await initialResolver.resolve(transferred.map { (source: $0.from, destination: $0.to, overwritten: $0.overwritten) }) }
                self.registerCopyUndo(stateResolver: initialResolver, actionName: "Copy \(transferred.count) Items", fileManager: fm)
            }
        }

        // Clear only if still ours: a queued operation may have started and published its own.
        if let progress, self.activeProgress === progress {
            self.activeProgress = nil
        }

        // Keyed lookup instead of a linear scan per transferred item; first-wins matches what
        // `first(where:)` returned should an id ever repeat in the selection.
        let nodesByID = Dictionary(prunedNodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let transferredNodes = transferred.compactMap { nodesByID[$0.from.path] }

        if let firstError = result.errors.first {
            let reason = firstError.localizedDescription
            // The errors here carry no item pairing, so the alert can't name the first item the
            // way the bulk-sync aggregate does — but the wording still reflects the whole run
            // (count in the message, remaining reasons logged) instead of pretending the first
            // error was the only one.
            let items = result.errors.count == 1 ? "the selected items" : "\(result.errors.count) items"
            for error in result.errors.dropFirst() {
                Logger.shared.error("\(isMove ? "Move" : "Copy") Failed: \(error.localizedDescription)")
            }
            present(isMove
                ? .moveFailed(items: items, reason: reason)
                : .copyFailed(items: items, reason: reason))
        } else if !nodes.isEmpty {
            let verb = isMove ? "Moved" : "Copied"
            // .info, not .debug: a copy/move is a data mutation that belongs in a normal-level
            // audit trail, not just a diagnostic one.
            if transferredNodes.count == prunedNodes.count {
                Logger.shared.info("\(verb) \(transferredNodes.count) items \(destinationDescription)")
            } else {
                Logger.shared.info("\(verb) \(transferredNodes.count) of \(prunedNodes.count) items \(destinationDescription)")
            }
        }

        return transferredNodes
    }
    
    /// Renames a specific file or folder on disk.
    public func renameItem(at path: String, to newName: String, fileManager fm: FileManaging = FileManager.default) async {
        if let reason = Self.validateItemName(newName) {
            // Deterministic — the same name would be rejected again, so not retryable.
            present(SyncError(title: "Rename Failed", message: reason, path: path))
            return
        }
        let url = URL(fileURLWithPath: path)
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        
        let isCaseOnly = url.lastPathComponent.lowercased() == newName.lowercased()
        if !isCaseOnly && fm.fileExists(atPath: newURL.path) {
            // Deterministic collision — renaming to the same existing name would just fail again,
            // so it is not retryable. Reveal points at the item that is in the way.
            present(SyncError(
                title: "Rename Failed",
                message: "An item named \"\(newName)\" already exists.",
                path: newURL.path
            ))
            return
        }
        
        let result = await enqueueFileOperation { () -> (error: Error?, trashed: URL?) in
            do {
                let trashed = try Self.safeMoveItem(at: url, to: newURL, fileManager: fm)
                return (nil, trashed)
            } catch {
                return (error, nil)
            }
        }
        
        if let err = result.error {
            present(.renameFailed(reason: err.localizedDescription, path: url.path))
        } else {
            Logger.shared.info("Renamed item to \(newName)")
            let initialResolver = AsyncValueResolver<[MoveItemState]>()
            Task { await initialResolver.resolve([(from: url, to: newURL, overwritten: result.trashed)]) }
            self.registerMoveUndo(stateResolver: initialResolver, actionName: "Rename Item", fileManager: fm)
        }
    }
    
    /// Creates a new empty directory on disk.
    public func createFolder(named name: String, in path: String, fileManager fm: FileManaging = FileManager.default) async {
        if let reason = Self.validateItemName(name) {
            present(SyncError(title: "Couldn't Create Folder", message: reason, path: path))
            return
        }
        // Same guard as transferItems: an empty parent path (a provider that vanished from
        // settings while its stale tree was showing) must stay empty — URL(fileURLWithPath: "")
        // would resolve against the process CWD and create the folder there.
        let parentPath = path.isEmpty
            ? ""
            : URL(fileURLWithPath: (path as NSString).expandingTildeInPath).path
        guard !parentPath.isEmpty else {
            present(.createFolderFailed(reason: FileOperationError.destinationRootUnavailable.localizedDescription, path: path))
            return
        }
        let createdURL = URL(fileURLWithPath: parentPath).appendingPathComponent(name)

        let error = await enqueueFileOperation { () -> Error? in
            do {
                // One stat, before any I/O (matching transferItems): a parent that no longer
                // exists on disk (provider unmounted or removed) fails the operation rather
                // than surfacing a raw file-system error.
                guard fm.fileExists(atPath: parentPath) else {
                    throw FileOperationError.destinationRootUnavailable
                }
                if fm.fileExists(atPath: createdURL.path) {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSLocalizedDescriptionKey : "An item named \"\(name)\" already exists."])
                }
                try fm.createDirectory(at: createdURL, withIntermediateDirectories: false)
                return nil
            } catch let createError {
                return createError
            }
        }
        
        if let err = error {
            present(.createFolderFailed(reason: err.localizedDescription, path: path))
        } else {
            Logger.shared.info("Created folder \(name) at \(path)")
            self.registerCreateFolderUndo(url: createdURL, fileManager: fm)
        }
    }

    /// Permanently deletes files or directories from disk.
    public func deleteItems(at paths: [String], fileManager fm: FileManaging = FileManager.default) async {
        let confirmPermanentDelete = permanentDeleteConfirmer

        // Prune nested paths to avoid redundant operations on children if parent is trashed
        let sortedPaths = paths.sorted { $0.count < $1.count }
        var prunedPaths: [String] = []
        var acceptedPaths = Set<String>()
        for path in sortedPaths {
            if !path.isInsideDirectory(anyOf: acceptedPaths) {
                prunedPaths.append(path)
                acceptedPaths.insert(path)
            }
        }

        let total = Int64(prunedPaths.count)
        let progress: Progress? = total > 0 ? Progress(totalUnitCount: total) : nil
        if let progress {
            progress.localizedDescription = "Deleting \(total) Items"
            progress.isCancellable = true
        }

        let result = await enqueueFileOperation { [weak self, progress, prunedPaths] () -> (errors: [Error], items: [(original: URL, trashed: URL?)]) in
            guard self != nil else { return ([], []) }
            // Publish progress only once this operation actually starts (see copyItems above).
            if let progress {
                await MainActor.run { [weak self] in self?.activeProgress = progress }
            }
            var taskErrors: [Error] = []
            var trashedItems: [(original: URL, trashed: URL?)] = []
            var trashFailures: [URL] = []

            for (index, path) in prunedPaths.enumerated() {
                if progress?.isCancelled == true { break }
                
                await MainActor.run {
                    progress?.localizedAdditionalDescription = (path as NSString).lastPathComponent
                }
                if fm.fileExists(atPath: path) {
                    let url = URL(fileURLWithPath: path)
                    var trashedURL: NSURL? = nil
                    do {
                        try fm.trashItem(at: url, resultingItemURL: &trashedURL)
                        trashedItems.append((original: url, trashed: trashedURL as? URL))
                    } catch {
                        trashFailures.append(url)
                    }
                }
                await MainActor.run {
                    progress?.completedUnitCount = Int64(index + 1)
                }
            }
            
            if !trashFailures.isEmpty {
                let confirmed = await MainActor.run {
                    confirmPermanentDelete(trashFailures.map { $0.lastPathComponent })
                }
                
                if confirmed {
                    for url in trashFailures {
                        do {
                            try fm.removeItem(at: url)
                            trashedItems.append((original: url, trashed: nil))
                        } catch {
                            taskErrors.append(error)
                        }
                    }
                }
            }
            return (taskErrors, trashedItems)
        }
        
        let items = result.items
        let successfullyTrashed = items.compactMap { $0.trashed != nil ? $0 : nil }
        if !successfullyTrashed.isEmpty {
            let urls = successfullyTrashed.map { $0.original }
            let initialResolver = AsyncValueResolver<[URL?]>()
            Task { await initialResolver.resolve(successfullyTrashed.map { $0.trashed }) }
            
            self.registerRestoreItems(urls: urls, trashResolver: initialResolver, actionName: "Delete \(successfullyTrashed.count) Items", fileManager: fm)
        }
        
        if let firstError = result.errors.first {
            present(.deleteFailed(reason: firstError.localizedDescription))
        } else if !items.isEmpty {
            // Distinguish recoverable (Trash) from irreversible (permanent) deletes: a permanent
            // delete happens only on Trash-less volumes after the user confirmed, and cannot be
            // undone — it deserves a named, warning-level record, not a lumped debug line.
            let permanentlyDeleted = items.filter { $0.trashed == nil }
            if permanentlyDeleted.isEmpty {
                Logger.shared.info("Moved \(items.count) item(s) to Trash")
            } else {
                let names = permanentlyDeleted.map { $0.original.lastPathComponent }.joined(separator: ", ")
                Logger.shared.warning("Permanently deleted \(permanentlyDeleted.count) item(s) that could not be moved to Trash (unrecoverable): \(names)")
                let trashedCount = items.count - permanentlyDeleted.count
                if trashedCount > 0 {
                    Logger.shared.info("Moved \(trashedCount) other item(s) to Trash")
                }
            }
            let name = items.first?.original.lastPathComponent ?? "item"
            self.banner = .success(items.count == 1
                ? "Deleted \"\(name)\""
                : "Deleted \(items.count) items")
        }

        if let progress, self.activeProgress === progress {
            self.activeProgress = nil
        }
    }
}
