import Events
import SwiftUI
import Combine
import UniformTypeIdentifiers

extension FileSyncManager {
    
    // MARK: - Core Scanning Operations
    
    /// Pre-loads file trees for the given providers concurrently in the background.
    /// This populates the `prefetchedTrees` cache without blocking the UI or cancelling active tasks.
    public func prefetch(providers: [CloudProvider]) async {
        let sortOp = self.sortOption
        let showHidden = self.showHiddenFiles
        let fm = self.fileManager
        
        await withTaskGroup(of: (String, [FileNode]?).self) { group in
            for provider in providers {
                let path = (provider.path as NSString).expandingTildeInPath
                group.addTask {
                    let rootURL = URL(fileURLWithPath: path)
                    let tree = await Self.buildTree(url: rootURL, sortOption: sortOp, showHiddenFiles: showHidden, fileManager: fm)
                    return (path, tree)
                }
            }
            
            for await (path, tree) in group {
                if let tree = tree {
                    await MainActor.run {
                        self.prefetchedTrees[path] = tree
                        Logger.shared.info("Prefetched tree for \(path)")
                    }
                }
            }
        }
    }
    
    /// Instructs the manager to read the filesystem and construct an in-memory tree for the specified pane.
    /// - Parameters:
    ///   - path: The absolute, expanded root URL string of the provider.
    ///   - isSource: True for the source pane; false for destination.
    public func loadTree(path: String, isSource: Bool) async {
        if isSource { activeLoadSourceTask?.cancel() }
        else { activeLoadDestTask?.cancel() }

        let task = Task {
            let label = isSource ? "Source" : "Destination"
            Logger.shared.info("Loading \(label) Tree for path: \(path)")
            
            let relPath = isSource ? sourceRelativePath : destRelativePath
            let rootURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let focusURL = relPath.isEmpty ? rootURL : rootURL.appendingPathComponent(relPath)
            
            // Fast Path: Check prefetch cache if we are at the root
            if relPath.isEmpty, let cachedTree = prefetchedTrees[path] {
                Logger.shared.info("Consuming prefetched tree for \(path)")
                if isSource {
                    self.sourceTree = cachedTree
                    self.sourceItemCount = countItems(in: cachedTree)
                } else {
                    self.destinationTree = cachedTree
                    self.destinationItemCount = countItems(in: cachedTree)
                }
                return
            }
            
            // Slow Path: Load actively
            if isSource { isLoadingSourceTree = true }
            else { isLoadingDestinationTree = true }
            
            let sortOp = self.sortOption
            let showHidden = self.showHiddenFiles
            
            // Build the tree in a detached task to ensure no Main Actor blocking
            let fm = self.fileManager
            let tree = await Task.detached(priority: .userInitiated) {
                return await Self.buildTree(url: focusURL, sortOption: sortOp, showHiddenFiles: showHidden, fileManager: fm)
            }.value
            
            guard !Task.isCancelled else { return }

            if isSource {
                self.sourceTree = tree
                self.sourceItemCount = countItems(in: tree)
                isLoadingSourceTree = false
            } else {
                self.destinationTree = tree
                self.destinationItemCount = countItems(in: tree)
                isLoadingDestinationTree = false
            }
            // Update cache since we did the work
            if relPath.isEmpty { self.prefetchedTrees[path] = tree }
            Logger.shared.info("\(label) Tree Loaded. Count: \(isSource ? sourceItemCount : destinationItemCount)")
        }

        if isSource { activeLoadSourceTask = task }
        else { activeLoadDestTask = task }

        await task.value
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
    
    /// Sequentially reloads the directory trees and triggers a differential scan.
    /// Features re-entrancy protection by canceling any previously active refresh tasks.
    /// - Parameters:
    ///   - source: The `CloudProvider` representing the source pane.
    ///   - destination: The `CloudProvider` representing the destination pane.
    public func refreshTreesAndScan(source: CloudProvider, destination: CloudProvider) async {
        activeRefreshTask?.cancel()
        
        let task = Task {
            let sourceRoot = (source.path as NSString).expandingTildeInPath
            let destRoot = (destination.path as NSString).expandingTildeInPath
            
            await self.loadTree(path: sourceRoot, isSource: true)
            guard !Task.isCancelled else { return }
            
            await self.loadTree(path: destRoot, isSource: false)
            guard !Task.isCancelled else { return }
            
            let currentSourceFull = (sourceRoot as NSString).appendingPathComponent(sourceRelativePath)
            let currentDestFull = (destRoot as NSString).appendingPathComponent(destRelativePath)
            
            await scanDirectories(
                source: source, sourcePath: currentSourceFull,
                destination: destination, destinationPath: currentDestFull
            )
            guard !Task.isCancelled else { return }
            self.scheduleSelectionPrune()
        }
        
        activeRefreshTask = task
        await task.value
    }
    
    /// Performs a high-performance, background differential scan between the focused directories.
    /// Includes re-entrancy guards to prevent redundant concurrent scans.
    /// - Parameters:
    ///   - source: The `CloudProvider` for the source pane.
    ///   - sourcePath: The currently focused absolute directory path for the source pane.
    ///   - destination: The `CloudProvider` for the destination pane.
    ///   - destinationPath: The currently focused absolute directory path for the destination pane.
    public func scanDirectories(source: CloudProvider, sourcePath: String, destination: CloudProvider, destinationPath: String) async {
        scanRequestGeneration += 1
        let request = ScanRequest(
            source: source,
            sourcePath: sourcePath,
            destination: destination,
            destinationPath: destinationPath,
            generation: scanRequestGeneration
        )

        if isScanning {
            pendingScanRequest = request
            Logger.shared.warning("Scan already in progress, queueing latest request.")
            return
        }

        await executeScan(request)
    }

    private func executeScan(_ request: ScanRequest) async {
        isScanning = true

        let newDifferences = await Task.detached(priority: .userInitiated) { () -> [FileDifference]? in
            do {
                let sourceURL = URL(fileURLWithPath: (request.sourcePath as NSString).expandingTildeInPath)
                let destinationURL = URL(fileURLWithPath: (request.destinationPath as NSString).expandingTildeInPath)
                
                let (fm, showHidden) = await MainActor.run { (self.fileManager, self.showHiddenFiles) }
                
                // Allow cancellation check inside the detached block if needed
                let sourceFilesInfo = try FileDiffEngine.getFilesInDirectory(sourceURL, showHidden: showHidden, fileManager: fm)
                let destinationFilesInfo = try FileDiffEngine.getFilesInDirectory(destinationURL, showHidden: showHidden, fileManager: fm)
                
                return FileDiffEngine.computeDifferences(
                    source: request.source,
                    sourceURL: sourceURL,
                    destination: request.destination,
                    destinationURL: destinationURL,
                    sourceFilesInfo: sourceFilesInfo,
                    destinationFilesInfo: destinationFilesInfo
                )
                
            } catch {
                let msg = "Error scanning directories: \(error)"
                Task { @MainActor in Logger.shared.error(msg, showAlert: false) }
                return nil
            }
        }.value

        let isLatestRequest = request.generation == scanRequestGeneration
        if !Task.isCancelled, isLatestRequest, let results = newDifferences {
            differences = results
            hasScanned = true
            
            Logger.shared.info("Scan completed: found \(results.count) differences.")
        }

        isScanning = false

        if let pending = pendingScanRequest {
            pendingScanRequest = nil
            if pending.generation > request.generation {
                await executeScan(pending)
            }
        }
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
                    guard !Task.isCancelled else { return nil }
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
            // Batch logging to avoid MainActor overhead in recursion
            // (Removed per-node logging)
            
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
