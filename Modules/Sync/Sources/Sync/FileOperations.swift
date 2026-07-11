import Events
import Foundation

extension FileSyncManager {
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
        // Expand once, and use the expanded value for both the root-existence guard and the
        // per-item targets (mirroring paneTargetURL): the guard stats the expanded path, so a
        // "~/…" caller must not derive its targets from the raw string.
        let expandedDestination = (destinationPath as NSString).expandingTildeInPath
        return await transferItems(
            nodes: nodes,
            isMove: false,
            destinationDescription: "to \(destinationPath)",
            destinationRoot: expandedDestination,
            targetURL: { node in URL(fileURLWithPath: expandedDestination).appendingPathComponent(node.name) },
            fileManager: fm
        )
    }

    /// Moves multiple files to a specific absolute destination directory path, removing them from their origin.
    /// - Returns: Nodes that were successfully moved.
    @discardableResult
    public func moveItems(nodes: [FileNode], toPath destinationPath: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        // Same single expansion as copyItems(toPath:) — a move also removes the sources, so a
        // misdirected target would be worse than a stray copy.
        let expandedDestination = (destinationPath as NSString).expandingTildeInPath
        return await transferItems(
            nodes: nodes,
            isMove: true,
            destinationDescription: "to \(destinationPath)",
            destinationRoot: expandedDestination,
            targetURL: { node in URL(fileURLWithPath: expandedDestination).appendingPathComponent(node.name) },
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
                        // A skipped item still counts as completed (like syncAll's skip
                        // accounting): a trailing skip must not strand the bar below 100%.
                        _ = await MainActor.run {
                            Logger.shared.debug("Skipping move of \"\(node.name)\": source and destination are the same location.")
                            progress?.completedUnitCount = Int64(index + 1)
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
                        case .skip:
                            // Same accounting as the move-onto-itself skip above.
                            await MainActor.run { progress?.completedUnitCount = Int64(index + 1) }
                            continue
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
                self.registerMoveUndo(items: transferred, actionName: "Move \(transferred.count) Items", fileManager: fm)
            } else {
                self.registerCopyUndo(items: transferred.map { (source: $0.from, destination: $0.to, overwritten: $0.overwritten) }, actionName: "Copy \(transferred.count) Items", fileManager: fm)
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
        await renameItem(
            at: path,
            to: newName,
            fileManager: fm,
            caseSensitiveVolume: Self.volumeSupportsCaseSensitiveNames(for: URL(fileURLWithPath: path))
        )
    }

    /// Testable core; production resolves `caseSensitiveVolume` from the item's volume.
    func renameItem(at path: String, to newName: String, fileManager fm: FileManaging, caseSensitiveVolume: Bool) async {
        if let reason = Self.validateItemName(newName) {
            // Deterministic — the same name would be rejected again, so not retryable.
            present(SyncError(title: "Rename Failed", message: reason, path: path))
            return
        }
        let url = URL(fileURLWithPath: path)
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)

        // A case-only rename skips the collision check only where the destination stat would
        // hit the source itself (case-insensitive volumes). On a case-sensitive volume the
        // case variant is a distinct item and must trigger the collision alert like any other.
        let isCaseOnly = !caseSensitiveVolume && url.lastPathComponent.lowercased() == newName.lowercased()
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
                let trashed = try Self.safeMoveItem(at: url, to: newURL, fileManager: fm, caseSensitiveVolume: caseSensitiveVolume)
                return (nil, trashed)
            } catch {
                return (error, nil)
            }
        }
        
        if let err = result.error {
            present(.renameFailed(reason: err.localizedDescription, path: url.path))
        } else {
            Logger.shared.info("Renamed item to \(newName)")
            self.registerMoveUndo(items: [(from: url, to: newURL, overwritten: result.trashed)], actionName: "Rename Item", fileManager: fm)
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
            self.registerRestoreItems(urls: urls, trashedItems: successfullyTrashed.map { $0.trashed }, actionName: "Delete \(successfullyTrashed.count) Items", fileManager: fm)
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
