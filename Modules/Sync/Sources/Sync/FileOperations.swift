import Events
import Foundation
import AppKit

extension FileSyncManager {

    private enum ReplacementBackup {
        case trash(URL)
        case temporary(URL)
    }
    
    // MARK: - Safe Atomic Replacements
    
    enum FileOperationError: LocalizedError {
        case identicalSourceAndDestination
        case nestingViolation
        
        var errorDescription: String? {
            switch self {
            case .identicalSourceAndDestination:
                return "Source and destination are the same."
            case .nestingViolation:
                return "Cannot move or copy a directory into itself or its subdirectories."
            }
        }
    }
    
    nonisolated static func validateFileOperation(source: URL, destination: URL) throws {
        let src = source.standardizedFileURL.path
        let dst = destination.standardizedFileURL.path
        
        if src == dst {
            throw FileOperationError.identicalSourceAndDestination
        }
        
        // Ensure trailing slash for prefix check to avoid /a matching /abc
        let srcWithSlash = src.hasSuffix("/") ? src : src + "/"
        if dst.hasPrefix(srcWithSlash) {
            throw FileOperationError.nestingViolation
        }
    }
    
    // MARK: - Collision Resolution
    
    public enum CollisionResolution: Sendable {
        case replace
        case keepBoth
        case skip
    }
    
    @MainActor
    public static func promptForCollision(fileName: String, isMove: Bool) -> CollisionResolution {
        let alert = NSAlert()
        alert.messageText = "An item named \"\(fileName)\" already exists in this location."
        alert.informativeText = "Do you want to replace it with the one you're \(isMove ? "moving" : "copying")?"
        
        // Buttons added right to left.
        alert.addButton(withTitle: "Keep Both") // First added (Rightmost, Return key default)
        alert.addButton(withTitle: "Skip")      // Second added (Middle)
        alert.addButton(withTitle: "Replace")   // Third added (Leftmost)
        
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .keepBoth
        case .alertSecondButtonReturn:
            return .skip
        case .alertThirdButtonReturn:
            return .replace
        default:
            return .skip
        }
    }
    
    private nonisolated static func generateUniqueURL(for url: URL, fileManager: FileManaging = FileManager.default) -> URL {
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
    
    
    private nonisolated static func isCaseOnlyRenaming(source: URL, destination: URL) -> Bool {
        return source.deletingLastPathComponent() == destination.deletingLastPathComponent() &&
               source.lastPathComponent.lowercased() == destination.lastPathComponent.lowercased()
    }

    // MARK: - File Operations
    
    /// Copies multiple files or folders between the Left and Right panes.
    /// - Returns: Nodes that were successfully copied.
    @discardableResult
    public func copyItems(nodes: [FileNode], fromLeft: Bool, leftRoot: String, rightRoot: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        let fromRoot = ((fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        let toRoot = ((!fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        
        let prunedNodes = nodes.pruneNestedNodes()
        let total = Int64(prunedNodes.count)
        
        let progress: Progress? = total > 0 ? Progress(totalUnitCount: total) : nil
        if let progress {
            progress.localizedDescription = "Copying \(total) Items"
            progress.isCancellable = true
            self.activeProgress = progress
        }
        
        let result = await enqueueFileOperation { [weak self, progress] () -> (errors: [Error], copied: [(source: URL, destination: URL, overwritten: URL?)]) in
            guard let self else { return ([], []) }
            var taskErrors: [Error] = []
            var targetItems: [(source: URL, destination: URL, overwritten: URL?)] = []
            
            for (index, node) in prunedNodes.enumerated() {
                if progress?.isCancelled == true { break }
                
                await MainActor.run {
                    progress?.localizedAdditionalDescription = node.name
                }
                var relativePath = node.id
                if relativePath.hasPrefix(fromRoot) {
                    relativePath = String(relativePath.dropFirst(fromRoot.count))
                }
                if relativePath.hasPrefix("/") { relativePath.removeFirst() }
                
                let targetPath = (toRoot as NSString).appendingPathComponent(relativePath)
                
                let sourceURL = URL(fileURLWithPath: node.id)
                var targetURL = URL(fileURLWithPath: targetPath)
                
                if sourceURL == targetURL {
                    targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                } else if fm.fileExists(atPath: targetURL.path) {
                    let tName = targetURL.lastPathComponent
                    let resolution = await MainActor.run { self.collisionResolver(tName, false) }
                    switch resolution {
                    case .replace: break
                    case .keepBoth: targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                    case .skip: continue
                    }
                }
                
                do {
                    try Self.validateFileOperation(source: sourceURL, destination: targetURL)
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let trashed = try Self.safeCopyItem(at: sourceURL, to: targetURL, fileManager: fm)
                    targetItems.append((source: sourceURL, destination: targetURL, overwritten: trashed))
                } catch {
                    taskErrors.append(error)
                }
                await MainActor.run {
                    progress?.completedUnitCount = Int64(index + 1)
                }
            }
            return (taskErrors, targetItems)
        }
        
        let copied = result.copied
        if !copied.isEmpty {
            let initialResolver = AsyncValueResolver<[CopyItemState]>()
            Task { await initialResolver.resolve(copied) }
            self.registerCopyUndo(stateResolver: initialResolver, actionName: "Copy \(copied.count) Items", fileManager: fm)
        }
        
        self.activeProgress = nil
        
        let copiedNodes = copied.compactMap { copiedItem in
            prunedNodes.first { $0.id == copiedItem.source.path }
        }
        
        if let firstError = result.errors.first {
            let msg = "Error copying items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !nodes.isEmpty {
            if copiedNodes.count == prunedNodes.count {
                Logger.shared.debug("Copied \(copiedNodes.count) items between panes")
            } else {
                Logger.shared.debug("Copied \(copiedNodes.count) of \(prunedNodes.count) items between panes")
            }
        }
        
        return copiedNodes
    }
    
    /// Moves multiple files or folders between the Left and Right panes.
    /// - Returns: Nodes that were successfully moved.
    @discardableResult
    public func moveItems(nodes: [FileNode], fromLeft: Bool, leftRoot: String, rightRoot: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        let fromRoot = ((fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        let toRoot = ((!fromLeft ? leftRoot : rightRoot) as NSString).expandingTildeInPath
        
        let prunedNodes = nodes.pruneNestedNodes()
        let total = Int64(prunedNodes.count)
        
        let progress: Progress? = total > 0 ? Progress(totalUnitCount: total) : nil
        if let progress {
            progress.localizedDescription = "Moving \(total) Items"
            progress.isCancellable = true
            self.activeProgress = progress
        }
        
        let result = await enqueueFileOperation { [weak self, progress] () -> (errors: [Error], moved: [(from: URL, to: URL, overwritten: URL?)]) in
            guard let self else { return ([], []) }
            var taskErrors: [Error] = []
            var targetItems: [(from: URL, to: URL, overwritten: URL?)] = []
            
            for (index, node) in prunedNodes.enumerated() {
                if progress?.isCancelled == true { break }
                
                await MainActor.run {
                    progress?.localizedAdditionalDescription = node.name
                }
                var relativePath = node.id
                if relativePath.hasPrefix(fromRoot) {
                    relativePath = String(relativePath.dropFirst(fromRoot.count))
                }
                if relativePath.hasPrefix("/") { relativePath.removeFirst() }
                
                let targetPath = (toRoot as NSString).appendingPathComponent(relativePath)
                
                let sourceURL = URL(fileURLWithPath: node.id)
                var targetURL = URL(fileURLWithPath: targetPath)
                
                if sourceURL == targetURL {
                    continue
                } else if fm.fileExists(atPath: targetURL.path) {
                    let tName = targetURL.lastPathComponent
                    let resolution = await MainActor.run { self.collisionResolver(tName, true) }
                    switch resolution {
                    case .replace: break
                    case .keepBoth: targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                    case .skip: continue
                    }
                }
                
                do {
                    try Self.validateFileOperation(source: sourceURL, destination: targetURL)
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let trashed = try Self.safeMoveItem(at: sourceURL, to: targetURL, fileManager: fm)
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
        
        let moved = result.moved
        if !moved.isEmpty {
            let initialResolver = AsyncValueResolver<[MoveItemState]>()
            Task { await initialResolver.resolve(moved) }
            self.registerMoveUndo(stateResolver: initialResolver, actionName: "Move \(moved.count) Items", fileManager: fm)
        }
        
        self.activeProgress = nil

        let movedNodes = moved.compactMap { moved in
            prunedNodes.first { $0.id == moved.from.path }
        }

        if let firstError = result.errors.first {
            let msg = "Error moving items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !nodes.isEmpty {
            if movedNodes.count == prunedNodes.count {
                Logger.shared.debug("Moved \(movedNodes.count) items between panes")
            } else {
                Logger.shared.debug("Moved \(movedNodes.count) of \(prunedNodes.count) items between panes")
            }
        }

        return movedNodes
    }
    
    /// Copies multiple files to a specific absolute destination directory path.
    /// - Returns: Nodes that were successfully copied.
    @discardableResult
    public func copyItems(nodes: [FileNode], toPath destinationPath: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        let prunedNodes = nodes.pruneNestedNodes()
        let total = Int64(prunedNodes.count)
        
        let progress: Progress? = total > 0 ? Progress(totalUnitCount: total) : nil
        if let progress {
            progress.localizedDescription = "Copying \(total) Items"
            progress.isCancellable = true
            self.activeProgress = progress
        }
        
        let result = await enqueueFileOperation { [weak self, progress] () -> (errors: [Error], copied: [(source: URL, destination: URL, overwritten: URL?)]) in
            guard let self else { return ([], []) }
            var taskErrors: [Error] = []
            var targetItems: [(source: URL, destination: URL, overwritten: URL?)] = []
            
            for (index, node) in prunedNodes.enumerated() {
                if progress?.isCancelled == true { break }
                
                await MainActor.run {
                    progress?.localizedAdditionalDescription = node.name
                }
                let sourceURL = URL(fileURLWithPath: node.id)
                var targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                
                if sourceURL == targetURL {
                    targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                } else if fm.fileExists(atPath: targetURL.path) {
                    let tName = targetURL.lastPathComponent
                    let resolution = await MainActor.run { self.collisionResolver(tName, false) }
                    switch resolution {
                    case .replace: break
                    case .keepBoth: targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                    case .skip: continue
                    }
                }
                
                do {
                    try Self.validateFileOperation(source: sourceURL, destination: targetURL)
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let trashed = try Self.safeCopyItem(at: sourceURL, to: targetURL, fileManager: fm)
                    targetItems.append((source: sourceURL, destination: targetURL, overwritten: trashed))
                } catch {
                    taskErrors.append(error)
                }
                await MainActor.run {
                    progress?.completedUnitCount = Int64(index + 1)
                }
            }
            return (taskErrors, targetItems)
        }
        
        self.activeProgress = nil
        let copied = result.copied
        if !copied.isEmpty {
            let initialResolver = AsyncValueResolver<[CopyItemState]>()
            Task { await initialResolver.resolve(copied) }
            self.registerCopyUndo(stateResolver: initialResolver, actionName: "Copy \(copied.count) Items", fileManager: fm)
        }
        
        let copiedNodes = copied.compactMap { copiedItem in
            prunedNodes.first { $0.id == copiedItem.source.path }
        }
        
        if let firstError = result.errors.first {
            let msg = "Error copying items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !nodes.isEmpty {
            if copiedNodes.count == prunedNodes.count {
                Logger.shared.debug("Copied \(copiedNodes.count) items to \(destinationPath)")
            } else {
                Logger.shared.debug("Copied \(copiedNodes.count) of \(prunedNodes.count) items to \(destinationPath)")
            }
        }
        
        return copiedNodes
    }
    
    /// Moves multiple files to a specific absolute destination directory path, removing them from their origin.
    /// - Returns: Nodes that were successfully moved.
    @discardableResult
    public func moveItems(nodes: [FileNode], toPath destinationPath: String, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        let prunedNodes = nodes.pruneNestedNodes()
        let total = Int64(prunedNodes.count)
        
        let progress: Progress? = total > 0 ? Progress(totalUnitCount: total) : nil
        if let progress {
            progress.localizedDescription = "Moving \(total) Items"
            progress.isCancellable = true
            self.activeProgress = progress
        }
        
        let result = await enqueueFileOperation { [weak self, progress] () -> (errors: [Error], moved: [(from: URL, to: URL, overwritten: URL?)]) in
            guard let self else { return ([], []) }
            var taskErrors: [Error] = []
            var targetItems: [(from: URL, to: URL, overwritten: URL?)] = []
            
            for (index, node) in prunedNodes.enumerated() {
                if progress?.isCancelled == true { break }
                
                await MainActor.run {
                    progress?.localizedAdditionalDescription = node.name
                }
                let sourceURL = URL(fileURLWithPath: node.id)
                var targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                
                if sourceURL == targetURL {
                    continue
                } else if fm.fileExists(atPath: targetURL.path) {
                    let tName = targetURL.lastPathComponent
                    let resolution = await MainActor.run { self.collisionResolver(tName, true) }
                    switch resolution {
                    case .replace: break
                    case .keepBoth: targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                    case .skip: continue
                    }
                }
                
                do {
                    try Self.validateFileOperation(source: sourceURL, destination: targetURL)
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let trashed = try Self.safeMoveItem(at: sourceURL, to: targetURL, fileManager: fm)
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
        
        let moved = result.moved
        if !moved.isEmpty {
            let initialResolver = AsyncValueResolver<[MoveItemState]>()
            Task { await initialResolver.resolve(moved) }
            self.registerMoveUndo(stateResolver: initialResolver, actionName: "Move \(moved.count) Items", fileManager: fm)
        }
        
        self.activeProgress = nil
        
        let movedNodes = result.moved.compactMap { moved in prunedNodes.first { $0.id == moved.from.path } }

        if let firstError = result.errors.first {
            let msg = "Error moving items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !nodes.isEmpty {
            Logger.shared.debug("Moved \(nodes.count) items to \(destinationPath)")
        }
        
        return movedNodes
    }
    
    /// Renames a specific file or folder on disk.
    public func renameItem(at path: String, to newName: String, fileManager fm: FileManaging = FileManager.default) async {
        let url = URL(fileURLWithPath: path)
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        
        let isCaseOnly = url.lastPathComponent.lowercased() == newName.lowercased()
        if !isCaseOnly && fm.fileExists(atPath: newURL.path) {
            let msg = "Error renaming item: An item named \"\(newName)\" already exists."
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
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
            Logger.shared.error(msg, showAlert: false)
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
            Logger.shared.error(msg, showAlert: false)
        } else {
            Logger.shared.debug("Created folder \(name) at \(path)")
            self.registerCreateFolderUndo(url: createdURL, fileManager: fm)
        }
    }

    /// Permanently deletes files or directories from disk.
    public func deleteItems(at paths: [String], fileManager fm: FileManaging = FileManager.default) async {
        let result = await enqueueFileOperation { [weak self] () -> (errors: [Error], items: [(original: URL, trashed: URL?)]) in
            guard let self else { return ([], []) }
            var taskErrors: [Error] = []
            var trashedItems: [(original: URL, trashed: URL?)] = []
            var trashFailures: [URL] = []
            
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
                await MainActor.run {
                    progress.localizedDescription = "Deleting \(total) Items"
                    progress.isCancellable = true
                    self.activeProgress = progress
                }
            }
            
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
                    NativeAlerts.confirmPermanentDelete(itemNames: trashFailures.map { $0.lastPathComponent })
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
            Logger.shared.error(msg, showAlert: false)
        } else if !items.isEmpty {
            Logger.shared.debug("Deleted \(items.count) items")
            let name = items.first?.original.lastPathComponent ?? "item"
            self.bannerMessage = items.count == 1
                ? "Deleted \"\(name)\""
                : "Deleted \(items.count) items"
        }
        
        self.activeProgress = nil
    }
}
