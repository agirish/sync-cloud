import SwiftUI
import UniformTypeIdentifiers

@MainActor
class DocumentSyncManager: ObservableObject {
    @Published var differences: [FileDifference] = []
    @Published var isScanning = false
    @Published var hasScanned = false
    
    @Published var sourceTree: [FileNode] = []
    @Published var destinationTree: [FileNode] = []
    @Published var isLoadingSourceTree = false
    @Published var isLoadingDestinationTree = false
    
    @Published var sourceItemCount = 0
    @Published var destinationItemCount = 0
    
    @Published var clipboardNodes: [FileNode] = []
    @Published var clipboardIsCut: Bool = false
    
    // Navigation State (Relative paths from provider roots)
    @Published var sourceRelativePath: String = ""
    @Published var destRelativePath: String = ""
    
    private var history: [(source: String, dest: String)] = [("", "")]
    private var historyIndex: Int = 0
    
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    
    func loadSourceTree(path: String) async {
        isLoadingSourceTree = true
        let rootURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let focusURL = sourceRelativePath.isEmpty ? rootURL : rootURL.appendingPathComponent(sourceRelativePath)
        let tree = await Self.buildTree(url: focusURL)
        sourceTree = tree
        sourceItemCount = countItems(in: tree)
        isLoadingSourceTree = false
    }
    
    func loadDestinationTree(path: String) async {
        isLoadingDestinationTree = true
        let rootURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let focusURL = destRelativePath.isEmpty ? rootURL : rootURL.appendingPathComponent(destRelativePath)
        let tree = await Self.buildTree(url: focusURL)
        destinationTree = tree
        destinationItemCount = countItems(in: tree)
        isLoadingDestinationTree = false
    }
    
    nonisolated private static func buildTree(url: URL) async -> [FileNode] {
        await Task.detached(priority: .userInitiated) {
            func buildNode(at fullURL: URL) -> FileNode? {
                var isDirectory: ObjCBool = false
                let fm = FileManager.default
                guard fm.fileExists(atPath: fullURL.path, isDirectory: &isDirectory) else { return nil }
                
                let name = fullURL.lastPathComponent
                
                if isDirectory.boolValue {
                    let contents = (try? fm.contentsOfDirectory(atPath: fullURL.path)) ?? []
                    var children: [FileNode] = []
                    for item in contents {
                        if item.hasPrefix(".") { continue }
                        let childURL = fullURL.appendingPathComponent(item)
                        if let childNode = buildNode(at: childURL) {
                            children.append(childNode)
                        }
                    }
                    children.sort { (a, b) in
                        if a.isDirectory == b.isDirectory {
                            return a.name.localizedStandardCompare(b.name) == .orderedAscending
                        }
                        return a.isDirectory
                    }
                    return FileNode(id: fullURL.path, name: name, isDirectory: true, children: children)
                } else {
                    return FileNode(id: fullURL.path, name: name, isDirectory: false, children: nil)
                }
            }
            
            let fm = FileManager.default
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            var rootChildren: [FileNode] = []
            for item in contents {
                if item.hasPrefix(".") { continue }
                let childURL = url.appendingPathComponent(item)
                if let childNode = buildNode(at: childURL) {
                    rootChildren.append(childNode)
                }
            }
            rootChildren.sort { (a, b) in
                if a.isDirectory == b.isDirectory {
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                return a.isDirectory
            }
            return rootChildren
        }.value
    }
    
    // MARK: - Navigation Methods
    
    func focusOn(relativePath: String, isSource: Bool, otherProviderPath: String) {
        let newSource = isSource ? relativePath : findMatchingPath(relativePath, in: otherProviderPath)
        let newDest = !isSource ? relativePath : findMatchingPath(relativePath, in: otherProviderPath)
        
        // Trim history if we're not at the end
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        
        history.append((newSource, newDest))
        historyIndex = history.count - 1
        updateStateFromHistory()
    }
    
    func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        updateStateFromHistory()
    }
    
    func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        updateStateFromHistory()
    }
    
    func resetNavigation() {
        focusOn(relativePath: "", isSource: true, otherProviderPath: "")
    }
    
    private func updateStateFromHistory() {
        let state = history[historyIndex]
        sourceRelativePath = state.source
        destRelativePath = state.dest
        canGoBack = historyIndex > 0
        canGoForward = historyIndex < history.count - 1
    }
    
    private func findMatchingPath(_ relativePath: String, in rootPath: String) -> String {
        if relativePath.isEmpty { return "" }
        let fullPath = (rootPath as NSString).expandingTildeInPath + "/" + relativePath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
            return relativePath
        }
        // If exact match not found, don't reset to root if we were already elsewhere
        // This helps persistence during rapid file operations
        return relativePath 
    }
    
    private func countItems(in tree: [FileNode]) -> Int {
        var count = 0
        for node in tree {
            count += 1
            if let children = node.children {
                count += countItems(in: children)
            }
        }
        return count
    }
    
    func refreshTreesAndScan(source: CloudProvider, destination: CloudProvider) async {
        let sourceRoot = (source.path as NSString).expandingTildeInPath
        let destRoot = (destination.path as NSString).expandingTildeInPath
        
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadSourceTree(path: sourceRoot) }
            group.addTask { await self.loadDestinationTree(path: destRoot) }
        }
        
        let currentSourceFull = (sourceRoot as NSString).appendingPathComponent(sourceRelativePath)
        let currentDestFull = (destRoot as NSString).appendingPathComponent(destRelativePath)
        
        await scanDirectories(
            source: source, sourcePath: currentSourceFull,
            destination: destination, destinationPath: currentDestFull
        )
    }
    
    func scanDirectories(source: CloudProvider, sourcePath: String, destination: CloudProvider, destinationPath: String) async {
        isScanning = true
        differences = []
        
        let newDifferences = await Task.detached(priority: .userInitiated) { () -> [FileDifference] in
            do {
                let sourceURL = URL(fileURLWithPath: (sourcePath as NSString).expandingTildeInPath)
                let destinationURL = URL(fileURLWithPath: (destinationPath as NSString).expandingTildeInPath)
                
                // Ensure directories exist
                try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                
                let sourceFilesInfo = try Self.getFilesInDirectory(sourceURL)
                let destinationFilesInfo = try Self.getFilesInDirectory(destinationURL)
                
                // Find differences
                var diffs: [FileDifference] = []
                
                // Check for files in source but not in destination (or compare if exists)
                for (relativePath, sourceFile) in sourceFilesInfo {
                    if let destFile = destinationFilesInfo[relativePath] {
                        // exists in both, compare dates
                        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceFile.path)
                        let destAttributes = try FileManager.default.attributesOfItem(atPath: destFile.path)
                        
                        if let sourceDate = sourceAttributes[.modificationDate] as? Date,
                           let destDate = destAttributes[.modificationDate] as? Date {
                            if abs(sourceDate.timeIntervalSince(destDate)) > 1 { // 1 second tolerance
                                if sourceDate > destDate {
                                    diffs.append(FileDifference(
                                        relativePath: relativePath,
                                        sourceItemPath: sourceFile.path,
                                        destinationItemPath: destFile.path,
                                        type: .differentDates,
                                        action: .copyToDestination,
                                        description: "\(source.displayName) file is newer"
                                    ))
                                } else {
                                    diffs.append(FileDifference(
                                        relativePath: relativePath,
                                        sourceItemPath: sourceFile.path,
                                        destinationItemPath: destFile.path,
                                        type: .differentDates,
                                        action: .copyToSource,
                                        description: "\(destination.displayName) file is newer"
                                    ))
                                }
                            }
                        }
                    } else {
                        // missing in destination
                        let destExpectedPath = destinationURL.appendingPathComponent(relativePath).path
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            sourceItemPath: sourceFile.path,
                            destinationItemPath: destExpectedPath,
                            type: .missingInDestination,
                            action: .copyToDestination,
                            description: "Missing in \(destination.displayName)"
                        ))
                    }
                }
                
                // Check for files in destination but not in source
                for (relativePath, destFile) in destinationFilesInfo {
                    if sourceFilesInfo[relativePath] == nil {
                        let sourceExpectedPath = sourceURL.appendingPathComponent(relativePath).path
                        diffs.append(FileDifference(
                            relativePath: relativePath,
                            sourceItemPath: sourceExpectedPath,
                            destinationItemPath: destFile.path,
                            type: .missingInSource,
                            action: .copyToSource,
                            description: "Missing in \(source.displayName)"
                        ))
                    }
                }
                
                return diffs.sorted { $0.relativePath < $1.relativePath }
                
            } catch {
                print("Error scanning directories: \(error)")
                return []
            }
        }.value
        
        differences = newDifferences
        hasScanned = true
        isScanning = false
    }
    
    func syncFile(_ difference: FileDifference) async {
        // Find the difference in our array and mark it as syncing
        if let index = differences.firstIndex(where: { $0.id == difference.id }) {
            differences[index].isSyncing = true
        }
        
        let success = await Task.detached(priority: .userInitiated) { () -> Bool in
            do {
                let fromURL: URL
                let toURL: URL
                
                if difference.action == .copyToDestination {
                    fromURL = URL(fileURLWithPath: difference.sourceItemPath)
                    toURL = URL(fileURLWithPath: difference.destinationItemPath)
                } else {
                    fromURL = URL(fileURLWithPath: difference.destinationItemPath)
                    toURL = URL(fileURLWithPath: difference.sourceItemPath)
                }
                
                // Ensure destination directory exists
                try FileManager.default.createDirectory(at: toURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                
                // Remove existing file if replacing
                if FileManager.default.fileExists(atPath: toURL.path) {
                    try FileManager.default.removeItem(at: toURL)
                }
                
                // Copy the file
                try FileManager.default.copyItem(at: fromURL, to: toURL)
                return true
                
            } catch {
                print("Error syncing file \(difference.relativePath): \(error)")
                return false
            }
        }.value
        
        if success {
            // Remove from differences list
            differences.removeAll { $0.id == difference.id }
        } else {
            // Reset syncing state
            if let index = differences.firstIndex(where: { $0.id == difference.id }) {
                differences[index].isSyncing = false
            }
        }
    }
    

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
    
    // Returns a dictionary mapping relative paths to file URLs
    nonisolated private static func getFilesInDirectory(_ url: URL) throws -> [String: URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return [:]
        }
        
        var result: [String: URL] = [:]
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if let isRegularFile = resourceValues.isRegularFile, isRegularFile {
                    // Safely compute relative path by dropping the base URL path plus the trailing slash
                    let basePathLength = url.path.count + 1
                    let path = fileURL.path
                    if path.count > basePathLength {
                        let relativePath = String(path.dropFirst(basePathLength))
                        result[relativePath] = fileURL
                    } else {
                        // Fallback, though shouldn't be reached if fileURL is structurally a child
                        let relativePath = path.replacingOccurrences(of: url.path + "/", with: "")
                        result[relativePath] = fileURL
                    }
                }
            } catch {
                print("Error reading resource values for \(fileURL): \(error)")
            }
        }
        
        return result
    }
}

struct FileNode: Identifiable, Hashable, Codable {
    let id: String // Absolute path
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?
}

extension FileNode: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

struct FileDifference: Identifiable {
    let id = UUID()
    let relativePath: String
    let sourceItemPath: String
    let destinationItemPath: String
    let type: DifferenceType
    let action: SyncAction
    let description: String
    var isSyncing: Bool = false
    
    enum DifferenceType {
        case missingInDestination
        case missingInSource
        case differentDates
    }
    
    enum SyncAction {
        case copyToDestination
        case copyToSource
    }
}

extension Array where Element == FileNode {
    func findNode(at path: String?) -> FileNode? {
        guard let path = path else { return nil }
        for node in self {
            if node.id == path { return node }
            if let children = node.children, let found = children.findNode(at: path) {
                return found
            }
        }
        return nil
    }
    
    func findNodes(at paths: Set<String>) -> [FileNode] {
        var found: [FileNode] = []
        for node in self {
            if paths.contains(node.id) {
                found.append(node)
            }
            if let children = node.children {
                found.append(contentsOf: children.findNodes(at: paths))
            }
        }
        return found
    }
}