import Foundation

extension DocumentSyncManager {
    
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
            self.currentError = "Error copying items: \(firstError.localizedDescription)"
        }
    }
    

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
            self.currentError = "Error copying items: \(firstError.localizedDescription)"
        }
    }
    
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
            self.currentError = "Error moving items: \(firstError.localizedDescription)"
        }
    }
    
    // MARK: - File Operations

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
            self.currentError = "Error renaming item: \(err.localizedDescription)"
        }
    }
    
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
            self.currentError = "Error creating folder: \(err.localizedDescription)"
        }
    }

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
            self.currentError = "Error deleting items: \(firstError.localizedDescription)"
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
