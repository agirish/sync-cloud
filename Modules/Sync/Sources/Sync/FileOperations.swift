import Events
import Foundation
import AppKit
import Design

extension FileSyncManager {

    private enum ReplacementBackup {
        case trash(URL)
        case temporary(URL)
    }
    
    // MARK: - Safe Atomic Replacements
    
    enum FileOperationError: LocalizedError, Equatable {
        case identicalSourceAndDestination
        case nestingViolation
        /// Parent of destination exists as a file (e.g. cloud placeholder); sync the parent folder first.
        case parentExistsAsFile(parentName: String)

        var errorDescription: String? {
            switch self {
            case .identicalSourceAndDestination:
                return "The two paths are the same."
            case .nestingViolation:
                return "Cannot move or copy a directory into itself or its subdirectories."
            case .parentExistsAsFile(let parentName):
                return "A file named \"\(parentName)\" already exists on the destination. Sync the parent folder first (use Replace) to replace it with the package, then sync this item."
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
    nonisolated static func volumeSupportsCaseSensitiveNames(for url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    }
    
    
    public nonisolated static func generateUniqueURL(for url: URL, fileManager: FileManaging = FileManager.default) -> URL {
        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let extensionStr = url.pathExtension
        
        var counter = 2
        var newURL = url
        
        while fileManager.fileExists(atPath: newURL.path) {
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

    /// Moves a pre-existing destination out of the way and returns a restorable backup handle.
    /// Prefers Trash when available; falls back to a temporary in-place move when Trash is unsupported.
    private nonisolated static func backupDestinationForReplacement(
        sourceURL: URL,
        destinationURL: URL,
        fileManager: FileManaging
    ) throws -> ReplacementBackup? {
        guard !isCaseOnlyRenaming(source: sourceURL, destination: destinationURL),
              fileManager.fileExists(atPath: destinationURL.path) else {
            return nil
        }

        var trashedURL: NSURL? = nil
        do {
            try fileManager.trashItem(at: destinationURL, resultingItemURL: &trashedURL)
            if let trashed = trashedURL as URL? {
                return .trash(trashed)
            }
            return nil
        } catch {
            // Some volumes do not support Trash. Keep a temporary rollback copy in-place.
            let backupURL = destinationURL.deletingLastPathComponent().appendingPathComponent(".rollback_\(UUID().uuidString)")
            try fileManager.moveItem(at: destinationURL, to: backupURL)
            return .temporary(backupURL)
        }
    }

    /// Attempts to restore destination from backup after a failed replacement.
    private nonisolated static func rollbackDestination(
        from backup: ReplacementBackup?,
        to destinationURL: URL,
        fileManager: FileManaging
    ) {
        try? fileManager.removeItem(at: destinationURL)
        guard let backup else { return }
        switch backup {
        case .trash(let url), .temporary(let url):
            try? fileManager.moveItem(at: url, to: destinationURL)
        }
    }

    /// Finalizes a backup after successful replacement, returning overwritten Trash URL when available.
    private nonisolated static func finalizeBackup(
        _ backup: ReplacementBackup?,
        fileManager: FileManaging
    ) -> URL? {
        guard let backup else { return nil }

        switch backup {
        case .trash(let url):
            return url
        case .temporary(let url):
            // Try to preserve undo ability by moving to Trash; if unavailable, remove temporary backup.
            var trashedURL: NSURL? = nil
            if (try? fileManager.trashItem(at: url, resultingItemURL: &trashedURL)) != nil {
                return trashedURL as URL?
            }
            try? fileManager.removeItem(at: url)
            return nil
        }
    }
    
    /// Safely copies a file, atomically replacing the destination if it exists to prevent corruption.
    /// Returns the URL of the overwritten item in the Trash, if any.
    @discardableResult
    public nonisolated static func safeCopyItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging = FileManager.default) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL)
        
        let targetDirectory = destinationURL.deletingLastPathComponent()
        let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")
        
        defer { try? fileManager.removeItem(at: tempURL) }
        
        try fileManager.copyItem(at: sourceURL, to: tempURL)
        let backup = try backupDestinationForReplacement(sourceURL: sourceURL, destinationURL: destinationURL, fileManager: fileManager)
        
        do {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } catch {
            rollbackDestination(from: backup, to: destinationURL, fileManager: fileManager)
            throw error
        }
        
        return finalizeBackup(backup, fileManager: fileManager)
    }
    
    /// Safely moves a file, atomically replacing the destination if it exists.
    /// Returns the URL of the overwritten item in the Trash, if any.
    @discardableResult
    public nonisolated static func safeMoveItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging = FileManager.default) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL)
        
        let backup = try backupDestinationForReplacement(sourceURL: sourceURL, destinationURL: destinationURL, fileManager: fileManager)
        
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            // Fallback for Cross-Volume moves (EXDEV) or other similar access issues.
            // Wrap in a temporary UUID directory mathematically guaranteed to be on the *same volume*
            // to ensure atomic replacement and prevent corrupted half-files.
            let targetDirectory = destinationURL.deletingLastPathComponent()
            let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")
            
            defer { try? fileManager.removeItem(at: tempURL) }
            
                do {
                    try fileManager.copyItem(at: sourceURL, to: tempURL)
                    try fileManager.moveItem(at: tempURL, to: destinationURL)
                
                // Cleanup source: Try trash first, fall back to direct remove if volume doesn't support trash.
                do {
                    try fileManager.trashItem(at: sourceURL, resultingItemURL: nil)
                    } catch {
                        do {
                            try fileManager.removeItem(at: sourceURL)
                        } catch let cleanupError {
                            rollbackDestination(from: backup, to: destinationURL, fileManager: fileManager)
                            throw cleanupError
                        }
                    }
                } catch let fallbackError {
                    rollbackDestination(from: backup, to: destinationURL, fileManager: fileManager)
                    throw fallbackError
                }
        }
        
        return finalizeBackup(backup, fileManager: fileManager)
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
            targetURL: { node in URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name) },
            fileManager: fm
        )
    }

    /// Derives the cross-pane destination for a node: its path relative to the source pane root,
    /// re-rooted under the opposite pane's root.
    private nonisolated static func paneTargetURL(fromLeft: Bool, leftRoot: String, rightRoot: String) -> @Sendable (FileNode) -> URL {
        let fromRoot = ((fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        let toRoot = ((!fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        return { node in
            var relativePath = node.id
            if relativePath.hasPrefix(fromRoot) {
                relativePath = String(relativePath.dropFirst(fromRoot.count))
            }
            if relativePath.hasPrefix("/") { relativePath.removeFirst() }
            return URL(fileURLWithPath: (toRoot as NSString).appendingPathComponent(relativePath))
        }
    }

    /// Shared implementation behind the four copy/move entry points. The variants differ only in
    /// how the destination URL is derived (`targetURL`), the primitive (`isMove` selects
    /// safeMoveItem/safeCopyItem, the Move/Copy undo registrar, and the log wording), and the
    /// same-URL policy: a copy onto itself keeps both under a uniquified name, a move onto
    /// itself is skipped.
    /// - Returns: The nodes that were successfully transferred, in processing order.
    private func transferItems(
        nodes: [FileNode],
        isMove: Bool,
        destinationDescription: String,
        targetURL deriveTargetURL: @escaping @Sendable (FileNode) -> URL,
        fileManager fm: FileManaging
    ) async -> [FileNode] {
        let resolveCollision = collisionResolver
        let prunedNodes = nodes.pruneNestedNodes()
        let total = Int64(prunedNodes.count)

        let progress: Progress? = total > 0 ? Progress(totalUnitCount: total) : nil
        if let progress {
            progress.localizedDescription = "\(isMove ? "Moving" : "Copying") \(total) Items"
            progress.isCancellable = true
        }

        let result = await enqueueFileOperation { [weak self, progress] () -> (errors: [Error], transferred: [(from: URL, to: URL, overwritten: URL?)]) in
            guard self != nil else { return ([], []) }
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
                var targetURL = deriveTargetURL(node)

                if sourceURL == targetURL {
                    if isMove {
                        _ = await MainActor.run {
                            Logger.shared.debug("Skipping move of \"\(node.name)\": source and destination are the same location.")
                        }
                        continue
                    }
                    targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                } else if fm.fileExists(atPath: targetURL.path) {
                    let tName = targetURL.lastPathComponent
                    let resolution = await MainActor.run { resolveCollision(tName, isMove) }
                    switch resolution {
                    case .replace: break
                    case .keepBoth: targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                    case .skip: continue
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

        let transferredNodes = transferred.compactMap { item in
            prunedNodes.first { $0.id == item.from.path }
        }

        if let firstError = result.errors.first {
            let msg = "Error \(isMove ? "moving" : "copying") items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg)
        } else if !nodes.isEmpty {
            let verb = isMove ? "Moved" : "Copied"
            if transferredNodes.count == prunedNodes.count {
                Logger.shared.debug("\(verb) \(transferredNodes.count) items \(destinationDescription)")
            } else {
                Logger.shared.debug("\(verb) \(transferredNodes.count) of \(prunedNodes.count) items \(destinationDescription)")
            }
        }

        return transferredNodes
    }
    
    /// Renames a specific file or folder on disk.
    public func renameItem(at path: String, to newName: String, fileManager fm: FileManaging = FileManager.default) async {
        let url = URL(fileURLWithPath: path)
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        
        let isCaseOnly = url.lastPathComponent.lowercased() == newName.lowercased()
        if !isCaseOnly && fm.fileExists(atPath: newURL.path) {
            let msg = "Error renaming item: An item named \"\(newName)\" already exists."
            self.currentError = msg
            Logger.shared.error(msg)
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
            let msg = "Error renaming item: \(err.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg)
        } else {
            Logger.shared.debug("Renamed item to \(newName)")
            let initialResolver = AsyncValueResolver<[MoveItemState]>()
            Task { await initialResolver.resolve([(from: url, to: newURL, overwritten: result.trashed)]) }
            self.registerMoveUndo(stateResolver: initialResolver, actionName: "Rename Item", fileManager: fm)
        }
    }
    
    /// Creates a new empty directory on disk.
    public func createFolder(named name: String, in path: String, fileManager fm: FileManaging = FileManager.default) async {
        let createdURL = URL(fileURLWithPath: path).appendingPathComponent(name)
        
        let error = await enqueueFileOperation { () -> Error? in
            do {
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
            let msg = "Error creating folder: \(err.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg)
        } else {
            Logger.shared.debug("Created folder \(name) at \(path)")
            self.registerCreateFolderUndo(url: createdURL, fileManager: fm)
        }
    }

    /// Permanently deletes files or directories from disk.
    public func deleteItems(at paths: [String], fileManager fm: FileManaging = FileManager.default) async {
        let confirmPermanentDelete = permanentDeleteConfirmer

        // Prune nested paths to avoid redundant operations on children if parent is trashed
        let sortedPaths = paths.sorted { $0.count < $1.count }
        var prunedPaths: [String] = []
        for path in sortedPaths {
            if !prunedPaths.contains(where: { path.hasPrefix($0 + "/") }) {
                prunedPaths.append(path)
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
            let msg = "Error deleting items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg)
        } else if !items.isEmpty {
            Logger.shared.debug("Deleted \(items.count) items")
            let name = items.first?.original.lastPathComponent ?? "item"
            self.bannerMessage = items.count == 1
                ? "Deleted \"\(name)\""
                : "Deleted \(items.count) items"
        }

        if let progress, self.activeProgress === progress {
            self.activeProgress = nil
        }
    }
}
