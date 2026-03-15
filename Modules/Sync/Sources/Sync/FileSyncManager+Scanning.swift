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
        let fm = self.fileManager
        
        await withTaskGroup(of: (String, [FileNode]?).self) { group in
            for provider in providers {
                let path = (provider.path as NSString).expandingTildeInPath
                group.addTask {
                    let rootURL = URL(fileURLWithPath: path)
                    let tree = await Self.buildTree(url: rootURL, sortOption: sortOp, fileManager: fm)
                    return (path, tree)
                }
            }
            
            for await (path, tree) in group {
                if let tree = tree {
                    await MainActor.run {
                        self.prefetchedTrees[path] = tree
                        Logger.shared.debug("Prefetched tree for \(path)")
                    }
                }
            }
        }
    }
    
    /// Loads the file tree for one pane from disk (or from prefetch cache when at root).
    /// - Parameters:
    ///   - path: Absolute path of the pane root (e.g. expanded tilde).
    ///   - isLeft: `true` for the left pane, `false` for the right pane.
    public func loadTree(path: String, isLeft: Bool) async {
        if isLeft { activeLoadLeftTask?.cancel() }
        else { activeLoadRightTask?.cancel() }

        let task = Task {
            let label = isLeft ? "Left" : "Right"
            Logger.shared.debug("Loading \(label) Tree for path: \(path)")
            
            let relPath = isLeft ? leftRelativePath : rightRelativePath
            let rootURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let focusURL = relPath.isEmpty ? rootURL : rootURL.appendingPathComponent(relPath)
            
            // Fast Path: Check prefetch cache if we are at the root
            if relPath.isEmpty, let cachedTree = prefetchedTrees[path] {
                Logger.shared.debug("Consuming prefetched tree for \(path)")
                if isLeft {
                    self.rawLeftTree = cachedTree
                    self.applyFilters()
                } else {
                    self.rawRightTree = cachedTree
                    self.applyFilters()
                }
                return
            }
            
            // Slow Path: Load actively
            if isLeft { isLoadingLeftTree = true }
            else { isLoadingRightTree = true }
            
            // Build the tree in a detached task to ensure no Main Actor blocking
            let fm = self.fileManager
            let sortOp = self.sortOption
            let tree = await Task.detached(priority: .userInitiated) {
                return await Self.buildTree(url: focusURL, sortOption: sortOp, fileManager: fm)
            }.value
            
            guard !Task.isCancelled else { return }

            if isLeft {
                self.rawLeftTree = tree
                self.applyFilters()
                isLoadingLeftTree = false
            } else {
                self.rawRightTree = tree
                self.applyFilters()
                isLoadingRightTree = false
            }
            // Update cache since we did the work
            if relPath.isEmpty { self.prefetchedTrees[path] = tree }
            Logger.shared.debug("\(label) Tree Loaded. Count: \(isLeft ? leftItemCount : rightItemCount)")
        }

        if isLeft { activeLoadLeftTask = task }
        else { activeLoadRightTask = task }

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
    
    /// Loads both pane trees then runs a diff scan between the current left/right paths. Cancels any in-flight refresh.
    /// - Parameters:
    ///   - left: Cloud provider for the left pane (root path and display name).
    ///   - right: Cloud provider for the right pane.
    public func refreshTreesAndScan(left: CloudProvider, right: CloudProvider) async {
        activeRefreshTask?.cancel()
        
        let task = Task {
            let leftRoot = (left.path as NSString).expandingTildeInPath
            let rightRoot = (right.path as NSString).expandingTildeInPath
            
            await self.loadTree(path: leftRoot, isLeft: true)
            guard !Task.isCancelled else { return }
            
            await self.loadTree(path: rightRoot, isLeft: false)
            guard !Task.isCancelled else { return }
            
            let currentLeftFull = (leftRoot as NSString).appendingPathComponent(leftRelativePath)
            let currentRightFull = (rightRoot as NSString).appendingPathComponent(rightRelativePath)
            
            await scanDirectories(
                left: left, leftPath: currentLeftFull,
                right: right, rightPath: currentRightFull
            )
            guard !Task.isCancelled else { return }
            self.scheduleSelectionPrune()
        }
        
        activeRefreshTask = task
        await task.value
    }
    
    /// Runs a diff scan between the two given directory paths on a background thread. Queues a single scan if one is already running.
    /// - Parameters:
    ///   - left: Cloud provider for the left pane.
    ///   - leftPath: Absolute path of the left pane’s current folder (may be a subfolder).
    ///   - right: Cloud provider for the right pane.
    ///   - rightPath: Absolute path of the right pane’s current folder.
    public func scanDirectories(left: CloudProvider, leftPath: String, right: CloudProvider, rightPath: String) async {
        scanRequestGeneration += 1
        let request = ScanRequest(
            left: left,
            leftPath: leftPath,
            right: right,
            rightPath: rightPath,
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
        Logger.shared.info("Internal scan comparing \(request.left.displayName) and \(request.right.displayName)")

        let newDifferences = await Task.detached(priority: .userInitiated) { () -> [FileDifference]? in
            do {
                let leftURL = URL(fileURLWithPath: (request.leftPath as NSString).expandingTildeInPath)
                let rightURL = URL(fileURLWithPath: (request.rightPath as NSString).expandingTildeInPath)
                
                let fm = await MainActor.run { self.fileManager }
                
                // Allow cancellation check inside the detached block if needed
                let leftFilesInfo = try FileDiffEngine.getFilesInDirectory(leftURL, fileManager: fm)
                let rightFilesInfo = try FileDiffEngine.getFilesInDirectory(rightURL, fileManager: fm)
                
                return FileDiffEngine.computeDifferences(
                    left: request.left,
                    leftURL: leftURL,
                    right: request.right,
                    rightURL: rightURL,
                    leftFilesInfo: leftFilesInfo,
                    rightFilesInfo: rightFilesInfo
                )
                
            } catch {
                let msg = "Error scanning directories: \(error)"
                Task { @MainActor in Logger.shared.error(msg, showAlert: false) }
                return nil
            }
        }.value

        let isLatestRequest = request.generation == scanRequestGeneration
        if !Task.isCancelled, isLatestRequest, let results = newDifferences {
            self.rawDifferences = results
            self.lastRightProviderType = request.right.type
            self.verifiedSameDifferenceIds.removeAll()
            self.applyFilters()
            hasScanned = true
            
            Logger.shared.debug("Scan completed: found \(results.count) differences.")
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
    
    nonisolated static func buildTree(url: URL, sortOption: SortOption, fileManager fm: FileManaging = FileManager.default) async -> [FileNode] {
        await Task.detached(priority: .userInitiated) {
            struct TreeBuilder {
                let fileManager: FileManaging
                let sortOption: SortOption
                
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
            
            let builder = TreeBuilder(fileManager: fm, sortOption: sortOption)
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
            await Logger.shared.debug("buildTree contents count: \(contents.count)")
            var rootChildren: [FileNode] = []
            for item in contents {
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
        
        // Recursively sort children first
        for i in 0..<sorted.count {
            if let children = sorted[i].children {
                sorted[i].children = sort(nodes: children, by: option)
            }
        }
        
        // Sort the current level
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
