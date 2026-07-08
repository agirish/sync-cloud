import Events
import Foundation

extension FileSyncManager {
    
    // MARK: - Core Scanning Operations

    /// Loads the file tree for one pane — served from the prefetch cache when the focused
    /// folder (or an ancestor's cached deep tree containing it) is available, otherwise from
    /// disk with a shallow-first progressive paint.
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
            let focusPath = focusURL.path

            // Fast path: serve the focus from the cache without touching the disk — a direct
            // hit, or a slice of the cached root tree (deep by construction, so drill-down and
            // breadcrumb navigation are instant). File operations, sort changes, and force
            // refresh clear the cache, so this never serves stale post-operation state.
            let cached = prefetchedTrees[focusPath]
                ?? Self.subtree(atPath: focusPath, in: prefetchedTrees[rootURL.path])
            if let cached {
                Logger.shared.debug("Serving \(label) tree for \(focusPath) from cache")
                prefetchedTrees[focusPath] = cached
                if isLeft {
                    self.rawLeftTree = cached
                    self.lastLoadedLeftFocusPath = focusPath
                    self.applyFilters()
                    // A slow load we just cancelled may have left the spinner flag set; it can't
                    // clear it itself (this newer load owns the flag once it starts).
                    if isLoadingLeftTree { isLoadingLeftTree = false }
                } else {
                    self.rawRightTree = cached
                    self.lastLoadedRightFocusPath = focusPath
                    self.applyFilters()
                    if isLoadingRightTree { isLoadingRightTree = false }
                }
                return
            }

            // Slow Path: Load actively
            if isLeft { isLoadingLeftTree = true }
            else { isLoadingRightTree = true }

            // buildTree detaches its own worker (and forwards cancellation into it),
            // so no extra detached hop is needed here.
            let fm = self.fileManager
            let sortOp = self.sortOption

            // Progressive first paint: publish the immediate children right away (one
            // directory listing), then swap in the deep tree when the full walk finishes —
            // but only when the pane has nothing valid to show for this focus (first load,
            // or navigation to an uncached folder). A same-focus refresh keeps the current
            // deep tree visible until the new one lands (stale-while-revalidate) instead of
            // collapsing rows to a shallow flash. The loading flag stays up until the deep
            // tree lands, which also keeps pruneSelection off the interim tree.
            let currentTree = isLeft ? rawLeftTree : rawRightTree
            let lastFocus = isLeft ? lastLoadedLeftFocusPath : lastLoadedRightFocusPath
            if currentTree.isEmpty || lastFocus != focusPath {
                let shallowTree = await Self.buildTree(url: focusURL, sortOption: sortOp, fileManager: fm, maxDepth: 1)
                guard !Task.isCancelled else { return }
                if isLeft {
                    self.rawLeftTree = shallowTree
                    self.lastLoadedLeftFocusPath = focusPath
                } else {
                    self.rawRightTree = shallowTree
                    self.lastLoadedRightFocusPath = focusPath
                }
                self.applyFilters()
            }

            let tree = await Self.buildTree(url: focusURL, sortOption: sortOp, fileManager: fm)

            guard !Task.isCancelled else { return }

            if isLeft {
                self.rawLeftTree = tree
                self.lastLoadedLeftFocusPath = focusPath
                self.applyFilters()
                isLoadingLeftTree = false
            } else {
                self.rawRightTree = tree
                self.lastLoadedRightFocusPath = focusPath
                self.applyFilters()
                isLoadingRightTree = false
            }
            // Cache the deep tree for this focus (never the shallow one — cache consumers,
            // including the in-memory diff scan, rely on cached trees being fully walked).
            self.prefetchedTrees[focusPath] = tree
            Logger.shared.debug("\(label) Tree Loaded. Count: \(isLeft ? leftItemCount : rightItemCount)")
        }

        if isLeft { activeLoadLeftTask = task }
        else { activeLoadRightTask = task }

        // `task` is unstructured, so the caller's cancellation (e.g. a cancelled refresh)
        // does not reach it on its own — forward it explicitly.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
    
    /// The children of the directory at `path` inside a cached deep tree, or nil when the path
    /// is not present (or `tree` is nil). Lets navigation serve a drill-down from an ancestor's
    /// cached tree without re-walking the disk.
    nonisolated static func subtree(atPath path: String, in tree: [FileNode]?) -> [FileNode]? {
        guard let tree else { return nil }
        for node in tree where node.isDirectory {
            if node.id == path { return node.children ?? [] }
            if path.hasPrefix(node.id + "/") { return subtree(atPath: path, in: node.children) }
        }
        return nil
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

            // The two pane loads are independent — disjoint published state, and each walks
            // the disk on its own detached worker — so run them concurrently. Serially they
            // doubled time-to-first-render, and panes on different volumes don't even
            // contend for I/O. Cancelling this task cancels both child loads.
            async let leftLoad: Void = self.loadTree(path: leftRoot, isLeft: true)
            async let rightLoad: Void = self.loadTree(path: rightRoot, isLeft: false)
            _ = await (leftLoad, rightLoad)
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

        let leftURL = URL(fileURLWithPath: (request.leftPath as NSString).expandingTildeInPath)
        let rightURL = URL(fileURLWithPath: (request.rightPath as NSString).expandingTildeInPath)

        // In-memory fast path: when both focused folders have deep trees in the prefetch
        // cache (file operations clear it, so cached ⇒ current), derive the comparison maps
        // from the trees instead of re-walking both directories on disk — the scan becomes
        // near-instant after navigation. Tree semantics apply: the tree builder follows
        // symlinked directories (the disk enumerator does not), so their contents
        // participate in the diff exactly as the panes display them.
        let newDifferences: [FileDifference]?
        if let cachedLeft = prefetchedTrees[leftURL.path], let cachedRight = prefetchedTrees[rightURL.path] {
            Logger.shared.debug("Scanning from cached trees (no disk walk)")
            newDifferences = await Task.detached(priority: .userInitiated) {
                let leftFilesInfo = FileDiffEngine.filesInfo(fromTree: cachedLeft, basePath: leftURL.path)
                let rightFilesInfo = FileDiffEngine.filesInfo(fromTree: cachedRight, basePath: rightURL.path)
                return FileDiffEngine.computeDifferences(
                    left: request.left,
                    leftURL: leftURL,
                    right: request.right,
                    rightURL: rightURL,
                    leftFilesInfo: leftFilesInfo,
                    rightFilesInfo: rightFilesInfo
                )
            }.value
        } else {
            newDifferences = await Task.detached(priority: .userInitiated) { () -> [FileDifference]? in
                do {
                    let fm = await MainActor.run { self.fileManager }

                    // The two walks are independent and FileManager is thread-safe, so run them
                    // concurrently — serially they doubled the scan's disk phase.
                    let leftWalk = Task.detached(priority: .userInitiated) {
                        try FileDiffEngine.getFilesInDirectory(leftURL, fileManager: fm)
                    }
                    let rightWalk = Task.detached(priority: .userInitiated) {
                        try FileDiffEngine.getFilesInDirectory(rightURL, fileManager: fm)
                    }
                    let leftFilesInfo = try await leftWalk.value
                    let rightFilesInfo = try await rightWalk.value

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
                    Task { @MainActor in Logger.shared.error(msg) }
                    return nil
                }
            }.value
        }

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
    
    /// Walks the directory tree off the main actor. Cancelling the calling task aborts the walk:
    /// the detached worker doesn't inherit cancellation, so it is forwarded explicitly below —
    /// that is what makes the `Task.isCancelled` checks inside `buildNode` effective.
    /// `maxDepth` caps the walk (1 = immediate children only) for the progressive first paint;
    /// capped directories come back with `children: []` — present and expandable-looking, but
    /// unexplored — and nil means unlimited.
    nonisolated static func buildTree(url: URL, sortOption: SortOption, fileManager fm: FileManaging = FileManager.default, maxDepth: Int? = nil) async -> [FileNode] {
        let buildTask = Task.detached(priority: .userInitiated) {
            struct TreeBuilder {
                let fileManager: FileManaging
                let sortOption: SortOption
                let maxDepth: Int?

                /// Keys prefetched when listing a directory so each child's resourceValues in
                /// buildNode is a cache hit rather than a separate stat.
                static let childKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .tagNamesKey, .typeIdentifierKey]

                /// Immediate children of a directory. For the real filesystem this batch-prefetches
                /// child metadata in a single call; for injected mocks it reconstructs child URLs from
                /// the enumerator names exactly as before.
                func childURLs(of dirURL: URL) -> [URL] {
                    if let realFm = fileManager as? FileManager {
                        // Fast path: one call prefetches every child's metadata so buildNode's
                        // resourceValues are cache hits. The URL-based API does not traverse a
                        // symlinked directory, so fall back to the path-based listing (which follows
                        // symlinks, as the tree always has) when it yields nothing.
                        if let prefetched = try? realFm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: Self.childKeys, options: []) {
                            if !prefetched.isEmpty {
                                return prefetched
                            }
                            // An empty result is either a genuinely empty directory or a symlinked
                            // directory the URL-based API refused to traverse. Only the symlink case
                            // needs the fallback listing; for plain empty directories the symlink
                            // check is a cache hit (isSymbolicLinkKey is in childKeys) or one lstat,
                            // cheaper than a second directory listing.
                            let isSymlink = (try? dirURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                            if !isSymlink {
                                return prefetched
                            }
                        }
                        let names = (try? realFm.contentsOfDirectory(atPath: dirURL.path)) ?? []
                        return names.map { dirURL.appendingPathComponent($0) }
                    } else {
                        var urls: [URL] = []
                        if let enumerator = fileManager.enumerator(at: dirURL, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: nil) {
                            for case let u as URL in enumerator {
                                urls.append(dirURL.appendingPathComponent(u.lastPathComponent))
                            }
                        }
                        return urls
                    }
                }

                func buildNode(at fullURL: URL, depth: Int) -> FileNode? {
                    guard !Task.isCancelled else { return nil }

                    let name = fullURL.lastPathComponent

                    var isDirectory = false
                    var modDate: Date?
                    var size: Int?
                    var tags: [String]?
                    var kind: String?

                    if fileManager is FileManager {
                        // Real filesystem: a single resourceValues fetch covers existence, type, and
                        // metadata (the same keys the diff scan reads), avoiding a separate
                        // fileExists stat per node.
                        guard let rv = try? fullURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .tagNamesKey, .typeIdentifierKey]) else { return nil }
                        modDate = rv.contentModificationDate
                        size = rv.fileSize
                        tags = rv.tagNames
                        kind = rv.typeIdentifier
                        if rv.isSymbolicLink == true {
                            // resourceValues reports on the link itself, not its target. Preserve the
                            // prior fileExists behavior for symlinks: resolve to the target so linked
                            // directories still recurse and broken links are still dropped.
                            var isDir: ObjCBool = false
                            guard fileManager.fileExists(atPath: fullURL.path, isDirectory: &isDir) else { return nil }
                            isDirectory = isDir.boolValue
                        } else {
                            isDirectory = rv.isDirectory ?? false
                        }
                    } else {
                        // Injected mock: resourceValues hits the real disk, so use the mock for
                        // existence/type (metadata stays nil, as before).
                        var isDir: ObjCBool = false
                        guard fileManager.fileExists(atPath: fullURL.path, isDirectory: &isDir) else { return nil }
                        isDirectory = isDir.boolValue
                    }

                    if isDirectory {
                        // Depth-capped (shallow) pass: report the directory but don't walk into
                        // it — empty children keep it rendering as a folder until the deep pass.
                        if let maxDepth, depth >= maxDepth {
                            return FileNode(id: fullURL.path, name: name, isDirectory: true, children: [], modificationDate: modDate, fileSize: size, tags: tags, kind: kind)
                        }
                        var children: [FileNode] = []
                        for childURL in childURLs(of: fullURL) {
                            if let childNode = buildNode(at: childURL, depth: depth + 1) {
                                children.append(childNode)
                            }
                        }
                        children = FileSyncManager.sortLevel(nodes: children, by: sortOption)
                        return FileNode(id: fullURL.path, name: name, isDirectory: true, children: children, modificationDate: modDate, fileSize: size, tags: tags, kind: kind)
                    } else {
                        return FileNode(id: fullURL.path, name: name, isDirectory: false, children: nil, modificationDate: modDate, fileSize: size, tags: tags, kind: kind)
                    }
                }
            }
            
            let builder = TreeBuilder(fileManager: fm, sortOption: sortOption, maxDepth: maxDepth)
            // Batch logging to avoid MainActor overhead in recursion
            // (Removed per-node logging)

            let rootChildURLs = builder.childURLs(of: url)
            await Logger.shared.debug("buildTree contents count: \(rootChildURLs.count)")
            var rootChildren: [FileNode] = []
            for childURL in rootChildURLs {
                if let childNode = builder.buildNode(at: childURL, depth: 1) {
                    rootChildren.append(childNode)
                }
            }
            rootChildren = FileSyncManager.sortLevel(nodes: rootChildren, by: sortOption)
            return rootChildren
        }
        return await withTaskCancellationHandler {
            await buildTask.value
        } onCancel: {
            buildTask.cancel()
        }
    }
    
    /// Recursively sorts a whole tree (children first, then each level). Use when re-sorting an
    /// already-built tree, e.g. when the sort option changes.
    nonisolated static func sort(nodes: [FileNode], by option: SortOption) -> [FileNode] {
        var sorted = nodes

        // Recursively sort children first
        for i in 0..<sorted.count {
            if let children = sorted[i].children {
                sorted[i].children = sort(nodes: children, by: option)
            }
        }

        return sortLevel(nodes: sorted, by: option)
    }

    /// Sorts one level only, leaving children untouched. `buildNode` sorts each subtree as it is
    /// built (bottom-up), so sorting the current level is enough there — the recursive `sort`
    /// would re-sort every subtree once per ancestor level.
    nonisolated static func sortLevel(nodes: [FileNode], by option: SortOption) -> [FileNode] {
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
