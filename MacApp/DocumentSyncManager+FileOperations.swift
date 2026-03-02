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
                    try fm.createDirectory(at: URL(fileURLWithPath: targetPath).deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: targetPath) {
                        try fm.removeItem(atPath: targetPath)
                    }
                    try fm.copyItem(atPath: node.id, toPath: targetPath)
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
                    if fm.fileExists(atPath: targetPath) {
                        try fm.removeItem(atPath: targetPath)
                    }
                    try fm.copyItem(atPath: node.id, toPath: targetPath)
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
                    if fm.fileExists(atPath: targetPath) {
                        try fm.removeItem(atPath: targetPath)
                    }
                    try fm.moveItem(atPath: node.id, toPath: targetPath)
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
                try fm.moveItem(at: url, to: newURL)
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
}
