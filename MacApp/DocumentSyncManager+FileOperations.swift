import Foundation

extension DocumentSyncManager {
    
    func copyItems(nodes: [FileNode], fromSource: Bool, sourceRoot: String, destinationRoot: String) async {
        let fromRoot = ((fromSource ? sourceRoot : destinationRoot) as NSString).expandingTildeInPath
        let toRoot = ((!fromSource ? sourceRoot : destinationRoot) as NSString).expandingTildeInPath
        
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for node in nodes {
                let relativePath = node.id.replacingOccurrences(of: fromRoot, with: "")
                let targetPath = (toRoot as NSString).appendingPathComponent(relativePath)
                
                do {
                    let targetURL = URL(fileURLWithPath: targetPath)
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.safeCopyItem(at: URL(fileURLWithPath: node.id), to: targetURL, fileManager: fm)
                } catch {
                    print("Error copying item \(node.name): \(error)")
                }
            }
        }.value
    }
    

    func copyItems(nodes: [FileNode], toPath destinationPath: String) async {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for node in nodes {
                let targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                let targetPath = targetURL.path
                
                do {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.safeCopyItem(at: URL(fileURLWithPath: node.id), to: targetURL, fileManager: fm)
                } catch {
                    print("Error copying item \(node.name): \(error)")
                }
            }
        }.value
    }
    
    func moveItems(nodes: [FileNode], toPath destinationPath: String) async {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for node in nodes {
                let targetURL = URL(fileURLWithPath: destinationPath).appendingPathComponent(node.name)
                let targetPath = targetURL.path
                
                do {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.safeMoveItem(at: URL(fileURLWithPath: node.id), to: targetURL, fileManager: fm)
                } catch {
                    print("Error moving item \(node.name): \(error)")
                }
            }
        }.value
    }
    
    // MARK: - File Operations

    func renameItem(at path: String, to newName: String) async {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let url = URL(fileURLWithPath: path)
            let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
            
            do {
                try Self.safeMoveItem(at: url, to: newURL, fileManager: fm)
            } catch {
                print("Error renaming item \(path): \(error)")
            }
        }.value
    }
    
    func createFolder(named name: String, in path: String) async {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                print("Error creating folder \(name) at \(path): \(error)")
            }
        }.value
    }

    func deleteItems(at paths: [String]) async {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for path in paths {
                do {
                    if fm.fileExists(atPath: path) {
                        try fm.removeItem(atPath: path)
                    }
                } catch {
                    print("Error deleting item at \(path): \(error)")
                }
            }
        }.value
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
