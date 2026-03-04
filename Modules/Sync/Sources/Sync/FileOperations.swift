import Events
import Foundation
import AppKit

extension FileSyncManager {
    
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
        
        if dst.hasPrefix(src + "/") {
            throw FileOperationError.nestingViolation
        }
    }
    
    // MARK: - Collision Resolution
    
    enum CollisionResolution {
        case replace
        case keepBoth
        case skip
    }
    
    @MainActor
    private static func promptForCollision(fileName: String, isMove: Bool) -> CollisionResolution {
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
    
    /// Safely copies a file, atomically replacing the destination if it exists to prevent corruption.
    /// Returns the URL of the overwritten item in the Trash, if any.
    @discardableResult
    public nonisolated static func safeCopyItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging = FileManager.default) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL)
        
        var trashedOriginal: URL? = nil
        let targetDirectory = destinationURL.deletingLastPathComponent()
        let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")
        
        defer { try? fileManager.removeItem(at: tempURL) }
        
        try fileManager.copyItem(at: sourceURL, to: tempURL)
        
        if !isCaseOnlyRenaming(source: sourceURL, destination: destinationURL) && fileManager.fileExists(atPath: destinationURL.path) {
            var trashedURL: NSURL? = nil
            try fileManager.trashItem(at: destinationURL, resultingItemURL: &trashedURL)
            trashedOriginal = trashedURL as URL?
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }
        return trashedOriginal
    }
    
    /// Safely moves a file, atomically replacing the destination if it exists.
    /// Returns the URL of the overwritten item in the Trash, if any.
    @discardableResult
    public nonisolated static func safeMoveItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManaging = FileManager.default) throws -> URL? {
        try validateFileOperation(source: sourceURL, destination: destinationURL)
        
        var trashedOriginal: URL? = nil
        if !isCaseOnlyRenaming(source: sourceURL, destination: destinationURL) && fileManager.fileExists(atPath: destinationURL.path) {
            var trashedURL: NSURL? = nil
            try fileManager.trashItem(at: destinationURL, resultingItemURL: &trashedURL)
            trashedOriginal = trashedURL as URL?
        }
        
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            // Fallback for Cross-Volume moves (EXDEV) or other similar access issues.
            // Wrap in a temporary UUID directory mathematically guaranteed to be on the *same volume*
            // to ensure atomic replacement and prevent corrupted half-files.
            let targetDirectory = destinationURL.deletingLastPathComponent()
            let tempURL = targetDirectory.appendingPathComponent(".tmp_\(UUID().uuidString)")
            
            defer { try? fileManager.removeItem(at: tempURL) }
            
            try fileManager.copyItem(at: sourceURL, to: tempURL)
            try fileManager.moveItem(at: tempURL, to: destinationURL)
            try? fileManager.trashItem(at: sourceURL, resultingItemURL: nil)
        }
        
        return trashedOriginal
    }
    
    
    private nonisolated static func isCaseOnlyRenaming(source: URL, destination: URL) -> Bool {
        return source.deletingLastPathComponent() == destination.deletingLastPathComponent() &&
               source.lastPathComponent.lowercased() == destination.lastPathComponent.lowercased()
    }

    // MARK: - File Operations
    
    /// Copies multiple files or folders between the Source and Destination panes.
    public func copyItems(nodes: [FileNode], fromSource: Bool, sourceRoot: String, destinationRoot: String, fileManager fm: FileManaging = FileManager.default) async {
        let fromRoot = ((fromSource ? sourceRoot : destinationRoot) as NSString).expandingTildeInPath
        let toRoot = ((!fromSource ? sourceRoot : destinationRoot) as NSString).expandingTildeInPath
        
        let result = await enqueueFileOperation { () -> (errors: [Error], copied: [(source: URL, destination: URL, overwritten: URL?)]) in
            var taskErrors: [Error] = []
            var targetItems: [(source: URL, destination: URL, overwritten: URL?)] = []
            
            for node in nodes {
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
                    let resolution = await MainActor.run { Self.promptForCollision(fileName: tName, isMove: false) }
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
            }
            return (taskErrors, targetItems)
        }
        
        let copied = result.copied
        if !copied.isEmpty {
            let initialResolver = AsyncValueResolver<[CopyItemState]>()
            Task { await initialResolver.resolve(copied) }
            self.registerCopyUndo(stateResolver: initialResolver, actionName: "Copy \(copied.count) Items")
        }
        
        if let firstError = result.errors.first {
            let msg = "Error copying items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !nodes.isEmpty {
            Logger.shared.info("Copied \(nodes.count) items between panes")
        }
    }
    
    /// Copies multiple files to a specific absolute destination directory path.
    public func copyItems(nodes: [FileNode], toPath destinationPath: String, fileManager fm: FileManaging = FileManager.default) async {
        let result = await enqueueFileOperation { () -> (errors: [Error], copied: [(source: URL, destination: URL, overwritten: URL?)]) in
            var taskErrors: [Error] = []
            var targetItems: [(source: URL, destination: URL, overwritten: URL?)] = []
            
            for node in nodes {
                let sourceURL = URL(fileURLWithPath: node.id)
                var targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                
                if sourceURL == targetURL {
                    targetURL = Self.generateUniqueURL(for: targetURL, fileManager: fm)
                } else if fm.fileExists(atPath: targetURL.path) {
                    let tName = targetURL.lastPathComponent
                    let resolution = await MainActor.run { Self.promptForCollision(fileName: tName, isMove: false) }
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
            }
            return (taskErrors, targetItems)
        }
        
        let copied = result.copied
        if !copied.isEmpty {
            let initialResolver = AsyncValueResolver<[CopyItemState]>()
            Task { await initialResolver.resolve(copied) }
            self.registerCopyUndo(stateResolver: initialResolver, actionName: "Copy \(copied.count) Items")
        }
        
        if let firstError = result.errors.first {
            let msg = "Error copying items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !nodes.isEmpty {
            Logger.shared.info("Copied \(nodes.count) items to \(destinationPath)")
        }
    }
    
    /// Moves multiple files to a specific absolute destination directory path, removing them from their origin.
    public func moveItems(nodes: [FileNode], toPath destinationPath: String, fileManager fm: FileManaging = FileManager.default) async {
        let result = await enqueueFileOperation { () -> (errors: [Error], moved: [(from: URL, to: URL, overwritten: URL?)]) in
            var taskErrors: [Error] = []
            var targetItems: [(from: URL, to: URL, overwritten: URL?)] = []
            
            for node in nodes {
                let sourceURL = URL(fileURLWithPath: node.id)
                var targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                
                if sourceURL == targetURL {
                    continue
                } else if fm.fileExists(atPath: targetURL.path) {
                    let tName = targetURL.lastPathComponent
                    let resolution = await MainActor.run { Self.promptForCollision(fileName: tName, isMove: true) }
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
            }
            return (taskErrors, targetItems)
        }
        
        let moved = result.moved
        if !moved.isEmpty {
            let initialResolver = AsyncValueResolver<[MoveItemState]>()
            Task { await initialResolver.resolve(moved) }
            self.registerMoveUndo(stateResolver: initialResolver, actionName: "Move \(moved.count) Items")
        }
        
        if let firstError = result.errors.first {
            let msg = "Error moving items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !nodes.isEmpty {
            Logger.shared.info("Moved \(nodes.count) items to \(destinationPath)")
        }
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
            Logger.shared.info("Renamed item to \(newName)")
            let initialResolver = AsyncValueResolver<[MoveItemState]>()
            Task { await initialResolver.resolve([(from: url, to: newURL, overwritten: result.trashed)]) }
            self.registerMoveUndo(stateResolver: initialResolver, actionName: "Rename Item")
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
            } catch {
                return error
            }
        }
        
        if let err = error {
            let msg = "Error creating folder: \(err.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else {
            Logger.shared.info("Created folder \(name) at \(path)")
            self.registerCreateFolderUndo(url: createdURL)
        }
    }

    /// Permanently deletes files or directories from disk.
    public func deleteItems(at paths: [String], fileManager fm: FileManaging = FileManager.default) async {
        let result = await enqueueFileOperation { () -> (errors: [Error], items: [(original: URL, trashed: URL?)]) in
            var taskErrors: [Error] = []
            var trashedItems: [(original: URL, trashed: URL?)] = []
            var trashFailures: [URL] = []
            
            for path in paths {
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
            
            self.registerRestoreItems(urls: urls, trashResolver: initialResolver, actionName: "Delete \(successfullyTrashed.count) Items")
        }
        
        if let firstError = result.errors.first {
            let msg = "Error deleting items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !paths.isEmpty {
            Logger.shared.info("Deleted \(paths.count) items")
        }
    }
}
