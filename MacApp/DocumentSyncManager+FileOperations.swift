import Foundation

extension DocumentSyncManager {
    
    /// Copies multiple files or folders between the Source and Destination panes.
    /// - Parameters:
    ///   - nodes: The array of `FileNode` items to copy.
    ///   - fromSource: A boolean indicating if the copy originates from the source provider (true) or destination provider (false).
    ///   - sourceRoot: The expanded root URL path of the source provider.
    ///   - destinationRoot: The expanded root URL path of the destination provider.
    func copyItems(nodes: [FileNode], fromSource: Bool, sourceRoot: String, destinationRoot: String) async {
        let fromRoot = ((fromSource ? sourceRoot : destinationRoot) as NSString).expandingTildeInPath
        let toRoot = ((!fromSource ? sourceRoot : destinationRoot) as NSString).expandingTildeInPath
        
        let result = await Task.detached(priority: .userInitiated) { () -> (errors: [Error], copied: [(source: URL, destination: URL)]) in
            var taskErrors: [Error] = []
            var targetItems: [(source: URL, destination: URL)] = []
            let fm = FileManager.default
            
            for node in nodes {
                let relativePath = node.id.replacingOccurrences(of: fromRoot, with: "")
                let targetPath = (toRoot as NSString).appendingPathComponent(relativePath)
                
                do {
                    let sourceURL = URL(fileURLWithPath: node.id)
                    let targetURL = URL(fileURLWithPath: targetPath)
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.safeCopyItem(at: sourceURL, to: targetURL, fileManager: fm)
                    targetItems.append((source: sourceURL, destination: targetURL))
                } catch {
                    taskErrors.append(error)
                }
            }
            return (taskErrors, targetItems)
        }.value
        
        // Register Undo Action
        let copied = result.copied
        if !copied.isEmpty {
            undoManager?.registerUndo(withTarget: self) { target in
                // 1. Register REDO
                target.undoManager?.registerUndo(withTarget: target) { t in
                    Task {
                        let fm = FileManager.default
                        for item in copied {
                            do {
                                try fm.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                                try Self.safeCopyItem(at: item.source, to: item.destination, fileManager: fm)
                            } catch {}
                        }
                        await t.refreshCallback?()
                    }
                }
                target.undoManager?.setActionName("Copy \\(copied.count) Items")
                
                // 2. Execute UNDO logic
                Task {
                    for item in copied {
                        do {
                            var trashedURL: NSURL? = nil
                            try FileManager.default.trashItem(at: item.destination, resultingItemURL: &trashedURL)
                        } catch {
                            Logger.shared.error("Failed to undo cross-pane copy for \\(item.destination.lastPathComponent): \\(error.localizedDescription)", showAlert: false)
                        }
                    }
                    await target.refreshCallback?()
                }
            }
            undoManager?.setActionName("Copy \\(copied.count) Items")
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
    /// - Parameters:
    ///   - nodes: The array of `FileNode` items to copy.
    ///   - destinationPath: The absolute string path to the target directory.
    func copyItems(nodes: [FileNode], toPath destinationPath: String) async {
        let result = await Task.detached(priority: .userInitiated) { () -> (errors: [Error], copied: [(source: URL, destination: URL)]) in
            var taskErrors: [Error] = []
            var targetItems: [(source: URL, destination: URL)] = []
            let fm = FileManager.default
            
            for node in nodes {
                let sourceURL = URL(fileURLWithPath: node.id)
                let targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                
                do {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.safeCopyItem(at: sourceURL, to: targetURL, fileManager: fm)
                    targetItems.append((source: sourceURL, destination: targetURL))
                } catch {
                    taskErrors.append(error)
                }
            }
            return (taskErrors, targetItems)
        }.value
        
        // Register Undo Action
        let copied = result.copied
        if !copied.isEmpty {
            self.registerCopyUndo(items: copied, actionName: "Copy \\(copied.count) Items")
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
    /// - Parameters:
    ///   - nodes: The array of `FileNode` items to move.
    ///   - destinationPath: The absolute string path to the target directory.
    func moveItems(nodes: [FileNode], toPath destinationPath: String) async {
        let result = await Task.detached(priority: .userInitiated) { () -> (errors: [Error], moved: [(original: URL, new: URL)]) in
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
        }.value
        
        // Register Undo Action
        let moved = result.moved
        if !moved.isEmpty {
            let mapping = moved.map { (from: $0.new, to: $0.original) }
            self.registerReversibleMove(items: mapping, actionName: "Move \\(moved.count) Items")
        }
        
        if let firstError = result.errors.first {
            let msg = "Error moving items: \(firstError.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else if !nodes.isEmpty {
            Logger.shared.info("Moved \(nodes.count) items to \(destinationPath)")
        }
    }
    
    // MARK: - File Operations

    /// Renames a specific file or folder on disk.
    /// - Parameters:
    ///   - path: The absolute path of the item to rename.
    ///   - newName: The new local filename (not a full path).
    func renameItem(at path: String, to newName: String) async {
        let error = await Task.detached(priority: .userInitiated) { () -> Error? in
            let fm = FileManager.default
            let url = URL(fileURLWithPath: path)
            let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
            
            do {
                try Self.safeMoveItem(at: url, to: newURL, fileManager: fm)
                return nil
            } catch {
                return error
            }
        }.value
        
        let url = URL(fileURLWithPath: path)
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        let originalName = url.lastPathComponent
        
        if let err = error {
            let msg = "Error renaming item: \(err.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else {
            Logger.shared.info("Renamed item to \(newName)")
            
            // Register Undo Action
            self.registerReversibleMove(items: [(from: newURL, to: url)], actionName: "Rename Item")
        }
    }
    
    /// Creates a new empty directory on disk.
    /// - Parameters:
    ///   - name: The local name of the new folder.
    ///   - path: The absolute path of the parent directory where the folder should be created.
    func createFolder(named name: String, in path: String) async {
        let error = await Task.detached(priority: .userInitiated) { () -> Error? in
            let fm = FileManager.default
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                return nil
            } catch {
                return error
            }
        }.value
        
        let createdURL = URL(fileURLWithPath: path).appendingPathComponent(name)
        if let err = error {
            let msg = "Error creating folder: \(err.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else {
            Logger.shared.info("Created folder \(name) at \(path)")
            
            // Register Undo Action
            self.registerCreateFolderUndo(url: createdURL)
        }
    }

    /// Permanently deletes files or directories from disk.
    /// - Parameter paths: An array of absolute string paths to remove from the filesystem.
    func deleteItems(at paths: [String]) async {
        let result = await Task.detached(priority: .userInitiated) { () -> (errors: [Error], trashed: [(original: URL, trashed: URL)]) in
            var taskErrors: [Error] = []
            var trashedItems: [(original: URL, trashed: URL)] = []
            let fm = FileManager.default
            
            for path in paths {
                do {
                    if fm.fileExists(atPath: path) {
                        let url = URL(fileURLWithPath: path)
                        var trashedURL: NSURL? = nil
                        try fm.trashItem(at: url, resultingItemURL: &trashedURL)
                        
                        if let trashed = trashedURL as? URL {
                            trashedItems.append((original: url, trashed: trashed))
                        }
                    }
                } catch {
                    taskErrors.append(error)
                }
            }
            return (taskErrors, trashedItems)
        }.value
        
        // Register Undo Action
        let trashed = result.trashed
        if !trashed.isEmpty {
            let box = TrashedItemsBox(items: trashed)
            self.registerDeleteUndo(box: box, actionName: "Delete \\(trashed.count) Items")
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
    
    // MARK: - Undo/Redo Registration Helpers
    
    private func registerCopyUndo(items: [(source: URL, destination: URL)], actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerCopyRedo(items: items, actionName: actionName)
            Task {
                for item in items {
                    try? FileManager.default.trashItem(at: item.destination, resultingItemURL: nil)
                }
                await target.refreshCallback?()
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    private func registerCopyRedo(items: [(source: URL, destination: URL)], actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerCopyUndo(items: items, actionName: actionName)
            Task {
                let fm = FileManager.default
                for item in items {
                    try? fm.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? Self.safeCopyItem(at: item.source, to: item.destination, fileManager: fm)
                }
                await target.refreshCallback?()
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    private func registerReversibleMove(items: [(from: URL, to: URL)], actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            let inverseItems = items.map { (from: $0.to, to: $0.from) }
            target.registerReversibleMove(items: inverseItems, actionName: actionName)
            Task {
                for item in items {
                    do { try Self.safeMoveItem(at: item.from, to: item.to) } catch {}
                }
                await target.refreshCallback?()
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    private func registerCreateFolderUndo(url: URL) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerCreateFolderRedo(url: url)
            Task { try? FileManager.default.trashItem(at: url, resultingItemURL: nil); await target.refreshCallback?() }
        }
        undoManager?.setActionName("New Folder")
    }
    
    private func registerCreateFolderRedo(url: URL) {
        undoManager?.registerUndo(withTarget: self) { target in
            target.registerCreateFolderUndo(url: url)
            Task { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); await target.refreshCallback?() }
        }
        undoManager?.setActionName("New Folder")
    }
    
    private class TrashedItemsBox {
        var items: [(original: URL, trashed: URL)] = []
        init(items: [(original: URL, trashed: URL)] = []) {
            self.items = items
        }
    }
    
    private func registerDeleteUndo(box: TrashedItemsBox, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            let originalURLs = box.items.map { $0.original }
            target.registerDeleteRedo(originalURLs: originalURLs, actionName: actionName)
            Task {
                for item in box.items {
                    try? FileManager.default.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.moveItem(at: item.trashed, to: item.original)
                }
                await target.refreshCallback?()
            }
        }
        undoManager?.setActionName(actionName)
    }
    
    private func registerDeleteRedo(originalURLs: [URL], actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            let nextBox = TrashedItemsBox()
            target.registerDeleteUndo(box: nextBox, actionName: actionName)
            Task {
                let fm = FileManager.default
                for url in originalURLs {
                    var trashed: NSURL?
                    if (try? fm.trashItem(at: url, resultingItemURL: &trashed)) != nil, let t = trashed as? URL {
                        nextBox.items.append((original: url, trashed: t))
                    }
                }
                await target.refreshCallback?()
            }
        }
        undoManager?.setActionName(actionName)
    }
}
