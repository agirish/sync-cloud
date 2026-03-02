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
                
                // 2. Execute UNDO
                Task {
                    for item in copied {
                        do {
                            var trashedURL: NSURL? = nil
                            try FileManager.default.trashItem(at: item.destination, resultingItemURL: &trashedURL)
                        } catch {
                            Logger.shared.error("Failed to undo copy for \\(item.destination.lastPathComponent): \\(error.localizedDescription)", showAlert: false)
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
            undoManager?.registerUndo(withTarget: self) { target in
                // 1. Register REDO action BEFORE executing Undo
                target.undoManager?.registerUndo(withTarget: target) { t in
                    Task {
                        // Redo move: move items back from original to new locations
                        for item in moved {
                            do {
                                try Self.safeMoveItem(at: item.original, to: item.new, fileManager: FileManager.default)
                            } catch {}
                        }
                        await t.refreshCallback?()
                    }
                }
                target.undoManager?.setActionName("Move \\(moved.count) Items")
                
                // 2. Execute UNDO
                Task {
                    // Undo move: move items back to their original locations
                    for item in moved {
                        do {
                            try Self.safeMoveItem(at: item.new, to: item.original)
                        } catch {
                            Logger.shared.error("Failed to undo move for \\(item.original.lastPathComponent): \\(error.localizedDescription)", showAlert: false)
                        }
                    }
                    await target.refreshCallback?()
                }
            }
            undoManager?.setActionName("Move \(moved.count) Items")
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
            undoManager?.registerUndo(withTarget: self) { target in
                // 1. Register REDO
                target.undoManager?.registerUndo(withTarget: target) { t in
                    Task {
                        do {
                            try Self.safeMoveItem(at: url, to: newURL)
                        } catch {}
                        await t.refreshCallback?()
                    }
                }
                target.undoManager?.setActionName("Rename Item")
                
                // 2. Execute UNDO
                Task {
                    do {
                        try Self.safeMoveItem(at: newURL, to: url)
                    } catch {
                        Logger.shared.error("Failed to undo rename for \\(newName): \\(error.localizedDescription)", showAlert: false)
                    }
                    await target.refreshCallback?()
                }
            }
            undoManager?.setActionName("Rename Item")
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
            undoManager?.registerUndo(withTarget: self) { target in
                // 1. Register REDO
                target.undoManager?.registerUndo(withTarget: target) { t in
                    Task {
                        do {
                            try FileManager.default.createDirectory(at: createdURL, withIntermediateDirectories: true)
                        } catch {}
                        await t.refreshCallback?()
                    }
                }
                target.undoManager?.setActionName("New Folder")
                
                // 2. Execute UNDO
                Task {
                    do {
                        var trashedURL: NSURL? = nil
                        try FileManager.default.trashItem(at: createdURL, resultingItemURL: &trashedURL)
                    } catch {
                        Logger.shared.error("Failed to undo folder creation for \\(name): \\(error.localizedDescription)", showAlert: false)
                    }
                    await target.refreshCallback?()
                }
            }
            undoManager?.setActionName("New Folder")
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
            undoManager?.registerUndo(withTarget: self) { target in
                // 1. Register REDO: Deleting again
                target.undoManager?.registerUndo(withTarget: target) { t in
                    Task {
                        for item in trashed {
                            do {
                                let fm = FileManager.default
                                var newTrashedURL: NSURL? = nil
                                // Trashing item.original assumes the undo successfully put it back
                                if fm.fileExists(atPath: item.original.path) {
                                    try fm.trashItem(at: item.original, resultingItemURL: &newTrashedURL)
                                }
                            } catch {
                                Logger.shared.error("Failed to redo delete for \\(item.original.lastPathComponent): \\(error.localizedDescription)", showAlert: false)
                            }
                        }
                        await t.refreshCallback?()
                    }
                }
                target.undoManager?.setActionName("Delete \\(trashed.count) Items")
                
                // 2. Execute UNDO: Put back
                Task {
                    // To undo a delete, we move the trashed items back to their original locations
                    for item in trashed {
                        do {
                            let fm = FileManager.default
                            try fm.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try fm.moveItem(at: item.trashed, to: item.original)
                        } catch {
                            Logger.shared.error("Failed to undo delete for \\(item.original.lastPathComponent): \\(error.localizedDescription)", showAlert: false)
                        }
                    }
                    await target.refreshCallback?()
                }
            }
            undoManager?.setActionName("Delete \(trashed.count) Items")
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
}
