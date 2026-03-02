import Foundation

extension DocumentSyncManager {
    
    // MARK: - File Operations
    
    /// Copies multiple files or folders between the Source and Destination panes.
    func copyItems(nodes: [FileNode], fromSource: Bool, sourceRoot: String, destinationRoot: String) async {
        let fromRoot = ((fromSource ? sourceRoot : destinationRoot) as NSString).expandingTildeInPath
        let toRoot = ((!fromSource ? sourceRoot : destinationRoot) as NSString).expandingTildeInPath
        
        // Use enqueueFileOperation to guarantee ordering
        let result = await enqueueFileOperation { () -> (errors: [Error], copiedURLs: [URL]) in
            var taskErrors: [Error] = []
            var targetURLs: [URL] = []
            let fm = FileManager.default
            
            for node in nodes {
                let relativePath = node.id.replacingOccurrences(of: fromRoot, with: "")
                let targetPath = (toRoot as NSString).appendingPathComponent(relativePath)
                
                do {
                    let sourceURL = URL(fileURLWithPath: node.id)
                    let targetURL = URL(fileURLWithPath: targetPath)
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.safeCopyItem(at: sourceURL, to: targetURL, fileManager: fm)
                    targetURLs.append(targetURL)
                } catch {
                    taskErrors.append(error)
                }
            }
            return (taskErrors, targetURLs)
        }
        
        let copied = result.copiedURLs
        if !copied.isEmpty {
            // An item Appearing needs an Undo that Trashes it.
            self.registerTrashItems(urls: copied, actionName: "Copy \(copied.count) Items")
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
    func copyItems(nodes: [FileNode], toPath destinationPath: String) async {
        let result = await enqueueFileOperation { () -> (errors: [Error], copiedURLs: [URL]) in
            var taskErrors: [Error] = []
            var targetURLs: [URL] = []
            let fm = FileManager.default
            
            for node in nodes {
                let sourceURL = URL(fileURLWithPath: node.id)
                let targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                
                do {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.safeCopyItem(at: sourceURL, to: targetURL, fileManager: fm)
                    targetURLs.append(targetURL)
                } catch {
                    taskErrors.append(error)
                }
            }
            return (taskErrors, targetURLs)
        }
        
        let copied = result.copiedURLs
        if !copied.isEmpty {
            self.registerTrashItems(urls: copied, actionName: "Copy \(copied.count) Items")
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
    func moveItems(nodes: [FileNode], toPath destinationPath: String) async {
        let result = await enqueueFileOperation { () -> (errors: [Error], moved: [(original: URL, new: URL)]) in
            var taskErrors: [Error] = []
            var movedItems: [(original: URL, new: URL)] = []
            let fm = FileManager.default
            
            for node in nodes {
                let sourceURL = URL(fileURLWithPath: node.id)
                let targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                
                do {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.safeMoveItem(at: sourceURL, to: targetURL, fileManager: fm)
                    movedItems.append((original: sourceURL, new: targetURL))
                } catch {
                    taskErrors.append(error)
                }
            }
            return (taskErrors, movedItems)
        }
        
        let moved = result.moved
        if !moved.isEmpty {
            let mapping = moved.map { (from: $0.new, to: $0.original) }
            self.registerReversibleMove(items: mapping, actionName: "Move \(moved.count) Items")
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
    func renameItem(at path: String, to newName: String) async {
        let url = URL(fileURLWithPath: path)
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        
        let error = await enqueueFileOperation { () -> Error? in
            let fm = FileManager.default
            do {
                try Self.safeMoveItem(at: url, to: newURL, fileManager: fm)
                return nil
            } catch {
                return error
            }
        }
        
        if let err = error {
            let msg = "Error renaming item: \(err.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else {
            Logger.shared.info("Renamed item to \(newName)")
            self.registerReversibleMove(items: [(from: newURL, to: url)], actionName: "Rename Item")
        }
    }
    
    /// Creates a new empty directory on disk.
    func createFolder(named name: String, in path: String) async {
        let createdURL = URL(fileURLWithPath: path).appendingPathComponent(name)
        
        let error = await enqueueFileOperation { () -> Error? in
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: createdURL, withIntermediateDirectories: true)
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
            self.registerTrashItems(urls: [createdURL], actionName: "New Folder")
        }
    }

    /// Permanently deletes files or directories from disk.
    func deleteItems(at paths: [String]) async {
        let result = await enqueueFileOperation { () -> (errors: [Error], items: [(original: URL, trashed: URL?)]) in
            var taskErrors: [Error] = []
            var trashedItems: [(original: URL, trashed: URL?)] = []
            let fm = FileManager.default
            
            for path in paths {
                do {
                    if fm.fileExists(atPath: path) {
                        let url = URL(fileURLWithPath: path)
                        var trashedURL: NSURL? = nil
                        do {
                            try fm.trashItem(at: url, resultingItemURL: &trashedURL)
                            trashedItems.append((original: url, trashed: trashedURL as? URL))
                        } catch {
                            trashedItems.append((original: url, trashed: nil)) // Mark as failed trash so we align
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
            let initialResolver = AsyncTrashResolver()
            // We immediately resolve it because we know the sync result of the initial operation
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
    
    // MARK: - Safe Atomic Replacements
    
    /// Safely copies a file, atomically replacing the destination if it exists to prevent corruption.
    nonisolated static func safeCopyItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManager = .default) throws {
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.copyItem(at: sourceURL, to: tempURL)
        
        if fileManager.fileExists(atPath: destinationURL.path) {
            var trashedURL: NSURL? = nil
            try fileManager.trashItem(at: destinationURL, resultingItemURL: &trashedURL)
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }
    }
    
    /// Safely moves a file, atomically replacing the destination if it exists.
    nonisolated static func safeMoveItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            var trashedURL: NSURL? = nil
            try fileManager.trashItem(at: destinationURL, resultingItemURL: &trashedURL)
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }
    
    // MARK: - Undo/Redo Native Registration Stack
    
    /// Symmetrical Undo/Redo registration for Move/Rename operations
    private func registerReversibleMove(items: [(from: URL, to: URL)], actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            // Registration for the NEXT inverse action (Redo if this is Undo, Undo if this is Redo)
            let inverseItems = items.map { (from: $0.to, to: $0.from) }
            target.registerReversibleMove(items: inverseItems, actionName: actionName)
            
            // Execute the operation sequentially guarantees safe execution against rapid Cmd+Z
            Task {
                await target.enqueueFileOperation {
                    for item in items {
                        do { try Self.safeMoveItem(at: item.from, to: item.to) } catch {}
                    }
                }
            }
        }
        // Native UndoManager correctly maps this to either Undo or Redo Action Name based on isUndoing/isRedoing state internally
        undoManager?.setActionName(actionName)
    }
    
    /// Registers an action on the Undo stack that will Trash the specified items.
    /// Used as the Undo mechanism for Create/Copy, and the Redo mechanism for Delete.
    private func registerTrashItems(urls: [URL], actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            let nextResolver = AsyncTrashResolver()
            // The inverse of Trashing is Restoring. Synchronously build the next callback!
            target.registerRestoreItems(urls: urls, trashResolver: nextResolver, actionName: actionName)
            
            Task {
                await target.enqueueFileOperation {
                    let fm = FileManager.default
                    var trashedItems: [URL?] = []
                    for url in urls {
                        var t: NSURL?
                        if fm.fileExists(atPath: url.path), (try? fm.trashItem(at: url, resultingItemURL: &t)) != nil, let trashed = t as? URL {
                            trashedItems.append(trashed)
                        } else {
                            trashedItems.append(nil)
                        }
                    }
                    // Asynchronously resolve the box that the NEXT chained Undo block will consume!
                    await nextResolver.resolve(trashedItems)
                }
            }
        }
        undoManager?.setActionName(actionName)
    }

    /// Registers an action on the Undo stack that will Restore items from the Trash back to their original locations.
    /// Used as the Undo mechanism for Delete, and the Redo mechanism for Create/Copy.
    private func registerRestoreItems(urls: [URL], trashResolver: AsyncTrashResolver, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            // The inverse of Restoring is Trashing
            target.registerTrashItems(urls: urls, actionName: actionName)
            
            Task {
                await target.enqueueFileOperation {
                    // Safely await the dynamic trash paths resolved by the PREVIOUS async task block!
                    let trashedItems = await trashResolver.get()
                    for (idx, targetURL) in urls.enumerated() {
                        if let trashedURL = trashedItems[idx] {
                            try? FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try? FileManager.default.moveItem(at: trashedURL, to: targetURL)
                        }
                    }
                }
            }
        }
        undoManager?.setActionName(actionName)
    }
}

/// A highly robust Async resolution actor that allows an asynchronous detached task 
/// to compute the dynamic result of moving an item to the macOS Trash, 
/// and allowing subsequent synchronous Undo/Redo blocks to safely enqueue wait commands for those dynamically generated Trash URLs.
actor AsyncTrashResolver {
    private var result: [URL?]?
    private var continuations: [CheckedContinuation<[URL?], Never>] = []
    
    func resolve(_ value: [URL?]) {
        if result != nil { return }
        result = value
        for cont in continuations { cont.resume(returning: value) }
        continuations.removeAll()
    }
    
    func get() async -> [URL?] {
        if let value = result { return value }
        return await withCheckedContinuation { cont in
            continuations.append(cont)
        }
    }
}
