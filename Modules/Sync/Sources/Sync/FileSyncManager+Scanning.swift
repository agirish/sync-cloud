import Events
import SwiftUI
import Combine
import UniformTypeIdentifiers

extension FileSyncManager {
    
    // MARK: - Core Scanning Operations
    
    /// Instructs the manager to read the filesystem and construct an in-memory tree for the specified pane.
    /// - Parameters:
    ///   - path: The absolute, expanded root URL string of the provider.
    ///   - isSource: True for the source pane; false for destination.
    public func loadTree(path: String, isSource: Bool) async {
        let label = isSource ? "Source" : "Destination"
        Logger.shared.info("Loading \(label) Tree for path: \(path)")
        
        if isSource { isLoadingSourceTree = true }
        else { isLoadingDestinationTree = true }
        
        let relPath = isSource ? sourceRelativePath : destRelativePath
        let rootURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let focusURL = relPath.isEmpty ? rootURL : rootURL.appendingPathComponent(relPath)
        let sortOp = self.sortOption
        let showHidden = self.showHiddenFiles
        
        // Build the tree in a detached task to ensure no Main Actor blocking
        let tree = await Task.detached(priority: .userInitiated) {
             return await Self.buildTree(url: focusURL, sortOption: sortOp, showHiddenFiles: showHidden)
        }.value
        
        if isSource {
            self.sourceTree = tree
            self.sourceItemCount = countItems(in: tree)
            isLoadingSourceTree = false
        } else {
            self.destinationTree = tree
            self.destinationItemCount = countItems(in: tree)
            isLoadingDestinationTree = false
        }
        Logger.shared.info("\(label) Tree Loaded. Count: \(isSource ? sourceItemCount : destinationItemCount)")
    }
    
    nonisolated func countItems(in tree: [FileNode]) -> Int {
        var count = 0
        for node in tree {
            count += 1
            if let children = node.children {
                count += countItems(in: children)
            }
        }
        return count
    }
    
    /// Sequentially reloads the directory trees for both source and destination, then triggers a differential scan.
    /// - Parameters:
    ///   - source: The `CloudProvider` representing the source pane.
    ///   - destination: The `CloudProvider` representing the destination pane.
    public func refreshTreesAndScan(source: CloudProvider, destination: CloudProvider) async {
        let sourceRoot = (source.path as NSString).expandingTildeInPath
        let destRoot = (destination.path as NSString).expandingTildeInPath
        
        // Call tree loads sequentially on the MainActor to prevent deadlocks from withTaskGroup
        await self.loadTree(path: sourceRoot, isSource: true)
        await self.loadTree(path: destRoot, isSource: false)
        
        let currentSourceFull = (sourceRoot as NSString).appendingPathComponent(sourceRelativePath)
        let currentDestFull = (destRoot as NSString).appendingPathComponent(destRelativePath)
        
        await scanDirectories(
            source: source, sourcePath: currentSourceFull,
            destination: destination, destinationPath: currentDestFull
        )
    }
    
    /// Performs a high-performance, background differential scan between the configured source and destination directories.
    /// - Parameters:
    ///   - source: The `CloudProvider` for the source pane.
    ///   - sourcePath: The currently focused absolute directory path for the source pane.
    ///   - destination: The `CloudProvider` for the destination pane.
    ///   - destinationPath: The currently focused absolute directory path for the destination pane.
    public func scanDirectories(source: CloudProvider, sourcePath: String, destination: CloudProvider, destinationPath: String) async {
        isScanning = true
        differences = []
        
        let newDifferences = await Task.detached(priority: .userInitiated) { () -> [FileDifference] in
            do {
                let sourceURL = URL(fileURLWithPath: (sourcePath as NSString).expandingTildeInPath)
                let destinationURL = URL(fileURLWithPath: (destinationPath as NSString).expandingTildeInPath)
                
                let sourceFilesInfo = try FileDiffEngine.getFilesInDirectory(sourceURL)
                let destinationFilesInfo = try FileDiffEngine.getFilesInDirectory(destinationURL)
                
                return FileDiffEngine.computeDifferences(
                    source: source,
                    sourceURL: sourceURL,
                    destination: destination,
                    destinationURL: destinationURL,
                    sourceFilesInfo: sourceFilesInfo,
                    destinationFilesInfo: destinationFilesInfo
                )
                
            } catch {
                let msg = "Error scanning directories: \(error)"
                Task { @MainActor in Logger.shared.error(msg, showAlert: false) }
                return []
            }
        }.value
        
        differences = newDifferences
        hasScanned = true
        isScanning = false
    }
    
    // MARK: - Internal Engine Operations
    
    nonisolated static func buildTree(url: URL, sortOption: SortOption, showHiddenFiles: Bool, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        await Task.detached(priority: .userInitiated) {
            struct TreeBuilder {
                let fileManager: FileManaging
                let sortOption: SortOption
                let showHiddenFiles: Bool
                
                func buildNode(at fullURL: URL) -> FileNode? {
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: fullURL.path, isDirectory: &isDirectory) else { return nil }
                    
                    let name = fullURL.lastPathComponent
                    
                    var modDate: Date?
                    var size: Int?
                    var tags: [String]?
                    var kind: String?
                    
                    if let rv = try? fullURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .tagNamesKey, .typeIdentifierKey]) {
                        modDate = rv.contentModificationDate
                        size = rv.fileSize
                        tags = rv.tagNames
                        kind = rv.typeIdentifier
                    }
                    
                    if isDirectory.boolValue {
                        let contents: [String] = {
                            if let realFm = fileManager as? FileManager {
                                return (try? realFm.contentsOfDirectory(atPath: fullURL.path)) ?? []
                            } else {
                                var names: [String] = []
                                if let enumerator = fileManager.enumerator(at: fullURL, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: nil) {
                                    for case let url as URL in enumerator {
                                        names.append(url.lastPathComponent)
                                    }
                                }
                                return names
                            }
                        }()
                        var children: [FileNode] = []
                        for item in contents {
                            if !showHiddenFiles && item.hasPrefix(".") { continue }
                            let childURL = fullURL.appendingPathComponent(item)
                            if let childNode = buildNode(at: childURL) {
                                children.append(childNode)
                            }
                        }
                        children = FileSyncManager.sort(nodes: children, by: sortOption)
                        return FileNode(id: fullURL.path, name: name, isDirectory: true, children: children, modificationDate: modDate, fileSize: size, tags: tags, kind: kind)
                    } else {
                        return FileNode(id: fullURL.path, name: name, isDirectory: false, children: nil, modificationDate: modDate, fileSize: size, tags: tags, kind: kind)
                    }
                }
            }
            
            let builder = TreeBuilder(fileManager: fm, sortOption: sortOption, showHiddenFiles: showHiddenFiles)
            await Logger.shared.info("buildTree scanning: \(url.path)")
            let contents: [String] = {
                if let realFm = fm as? FileManager {
                    return (try? realFm.contentsOfDirectory(atPath: url.path)) ?? []
                } else {
                    var names: [String] = []
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: nil) {
                        for case let u as URL in enumerator {
                            names.append(u.lastPathComponent)
                        }
                    }
                    return names
                }
            }()
            await Logger.shared.info("buildTree contents count: \(contents.count)")
            var rootChildren: [FileNode] = []
            for item in contents {
                if !showHiddenFiles && item.hasPrefix(".") { continue }
                let childURL = url.appendingPathComponent(item)
                if let childNode = builder.buildNode(at: childURL) {
                    rootChildren.append(childNode)
                }
            }
            rootChildren = FileSyncManager.sort(nodes: rootChildren, by: sortOption)
            return rootChildren
        }.value
    }
    
    nonisolated static func sort(nodes: [FileNode], by option: SortOption) -> [FileNode] {
        var sorted = nodes
        sorted.sort { a, b in
            // Typically preserve folder precedence
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            
            switch option {
            case .name:
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .kind:
                let kA = a.kind ?? ""
                let kB = b.kind ?? ""
                if kA == kB { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return kA.localizedStandardCompare(kB) == .orderedAscending
            case .dateModified:
                let dA = a.modificationDate ?? Date.distantPast
                let dB = b.modificationDate ?? Date.distantPast
                return dA > dB
            case .size:
                let sA = a.fileSize ?? 0
                let sB = b.fileSize ?? 0
                return sA > sB
            case .tags:
                let tA = a.tags?.joined() ?? ""
                let tB = b.tags?.joined() ?? ""
                if tA == tB { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return tA.localizedStandardCompare(tB) == .orderedAscending
            }
        }
        return sorted
    }
}
