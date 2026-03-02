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
        
        let errors = await Task.detached(priority: .userInitiated) { () -> [Error] in
            var taskErrors: [Error] = []
            let fm = FileManager.default
            for node in nodes {
                let relativePath = node.id.replacingOccurrences(of: fromRoot, with: "")
                let targetPath = (toRoot as NSString).appendingPathComponent(relativePath)
                
                do {
                    let targetURL = URL(fileURLWithPath: targetPath)
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.safeCopyItem(at: URL(fileURLWithPath: node.id), to: targetURL, fileManager: fm)
                } catch {
                    taskErrors.append(error)
                }
            }
            return taskErrors
        }.value
        
        if let firstError = errors.first {
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
        let errors = await Task.detached(priority: .userInitiated) { () -> [Error] in
            var taskErrors: [Error] = []
            let fm = FileManager.default
            for node in nodes {
                let targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                
                do {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.safeCopyItem(at: URL(fileURLWithPath: node.id), to: targetURL, fileManager: fm)
                } catch {
                    taskErrors.append(error)
                }
            }
            return taskErrors
        }.value
        
        if let firstError = errors.first {
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
        let errors = await Task.detached(priority: .userInitiated) { () -> [Error] in
            var taskErrors: [Error] = []
            let fm = FileManager.default
            for node in nodes {
                let targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                
                do {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.safeMoveItem(at: URL(fileURLWithPath: node.id), to: targetURL, fileManager: fm)
                } catch {
                    taskErrors.append(error)
                }
            }
            return taskErrors
        }.value
        
        if let firstError = errors.first {
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
        
        if let err = error {
            let msg = "Error renaming item: \(err.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else {
            Logger.shared.info("Renamed item to \(newName)")
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
        
        if let err = error {
            let msg = "Error creating folder: \(err.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        } else {
            Logger.shared.info("Created folder \(name) at \(path)")
        }
    }

    /// Permanently deletes files or directories from disk.
    /// - Parameter paths: An array of absolute string paths to remove from the filesystem.
    func deleteItems(at paths: [String]) async {
        let errors = await Task.detached(priority: .userInitiated) { () -> [Error] in
            var taskErrors: [Error] = []
            let fm = FileManager.default
            for path in paths {
                do {
                    if fm.fileExists(atPath: path) {
                        try fm.removeItem(atPath: path)
                    }
                } catch {
                    taskErrors.append(error)
                }
            }
            return taskErrors
        }.value
        
        if let firstError = errors.first {
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
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }
    }
    
    /// Safely moves a file, atomically replacing the destination if it exists.
    nonisolated static func safeMoveItem(at sourceURL: URL, to destinationURL: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: sourceURL)
        } else {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }
}
