import Events
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Core business logic manager governing the synchronization engine
/// Manages the in-memory tree structures (FileNode) for both source and destination cloud providers.
/// Responsible for scanning directories, computing FileDifferences, and tracking relative navigation paths.


@MainActor
public class FileSyncManager: ObservableObject {
    public init() {}
    /// Array of differences calculated between the source and destination directories.
    @Published public var differences: [FileDifference] = []
    /// Indicates whether a deep structure scan is currently in progress.
    @Published public var isScanning = false
    /// Indicates whether at least one successful scan has occurred.
    @Published public var hasScanned = false
    
    /// Global sorting preference for the file trees.
    @Published public var sortOption: SortOption = .name {
        didSet {
            // Re-sort trees globally when option changes
            sourceTree = Self.sort(nodes: sourceTree, by: sortOption)
            destinationTree = Self.sort(nodes: destinationTree, by: sortOption)
        }
    }
    
    /// Global toggle to show/hide hidden files (e.g. .DS_Store, .git)
    @Published public var showHiddenFiles: Bool = false
    
    /// Internal representation of the loaded file structure for the source provider.
    @Published public var sourceTree: [FileNode] = []
    /// Internal representation of the loaded file structure for the destination provider.
    @Published public var destinationTree: [FileNode] = []
    @Published public var isLoadingSourceTree = false
    @Published public var isLoadingDestinationTree = false
    
    @Published public var sourceItemCount = 0
    @Published public var destinationItemCount = 0
    
    @Published public var clipboardNodes: [FileNode] = []
    @Published public var clipboardIsCut: Bool = false
    
    /// Global UndoManager injected from SwiftUI environment
    public var undoManager: UndoManager?
    
    // Global Error state
    @Published public var currentError: String? = nil
    
    // Navigation State (Relative paths from provider roots)
    @Published public var sourceRelativePath: String = ""
    @Published public var destRelativePath: String = ""
    
    // View State Persistence
    @Published public var selectedSourcePaths: Set<String> = []
    @Published public var selectedDestinationPaths: Set<String> = []
    @Published public var sourceExpandedPaths: Set<String> = []
    @Published public var destExpandedPaths: Set<String> = []
    
    /// Global Combine subject to trigger a UI refresh of trees from anywhere without closure retain cycles.
    public let refreshSubject = PassthroughSubject<Void, Never>()
    
    /// Global serial queue for file operations to prevent data corruption from concurrent Undo/Redo or file syncing.
    private var fileOperationTask: Task<Void, Swift.Error> = Task {}
    
    /// Enqueues a file operation to be executed sequentially after all previous file operations have completed.
    /// This is strictly required to ensure that rapid Undo/Redo operations do not race with each other asynchronously.
    @discardableResult
    public func enqueueFileOperation<T: Sendable>(
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        let previousTask = fileOperationTask
        let newTask = Task.detached(priority: .userInitiated) {
            _ = await previousTask.result
            let res = await operation()
            await MainActor.run { [weak self] in self?.refreshSubject.send() }
            return res
        }
        fileOperationTask = Task { _ = await newTask.value }
        return await newTask.value
    }
    
    /// Tracks the navigational history across both panes.
    private var history: [(source: String, dest: String)] = [("", "")]
    private var historyIndex: Int = 0
    
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false
    
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
    
    nonisolated private static func buildTree(url: URL, sortOption: SortOption, showHiddenFiles: Bool) async -> [FileNode] {
        await Task.detached(priority: .userInitiated) {
            func buildNode(at fullURL: URL) -> FileNode? {
                var isDirectory: ObjCBool = false
                let fm = FileManager.default
                guard fm.fileExists(atPath: fullURL.path, isDirectory: &isDirectory) else { return nil }
                
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
                    let contents = (try? fm.contentsOfDirectory(atPath: fullURL.path)) ?? []
                    var children: [FileNode] = []
                    for item in contents {
                        if !showHiddenFiles && item.hasPrefix(".") { continue }
                        let childURL = fullURL.appendingPathComponent(item)
                        if let childNode = buildNode(at: childURL) {
                            children.append(childNode)
                        }
                    }
                    children = sort(nodes: children, by: sortOption)
                    return FileNode(id: fullURL.path, name: name, isDirectory: true, children: children, modificationDate: modDate, fileSize: size, tags: tags, kind: kind)
                } else {
                    return FileNode(id: fullURL.path, name: name, isDirectory: false, children: nil, modificationDate: modDate, fileSize: size, tags: tags, kind: kind)
                }
            }
            
            let fm = FileManager.default
            await Logger.shared.info("buildTree scanning: \(url.path)")
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            await Logger.shared.info("buildTree contents count: \(contents.count)")
            var rootChildren: [FileNode] = []
            for item in contents {
                if !showHiddenFiles && item.hasPrefix(".") { continue }
                let childURL = url.appendingPathComponent(item)
                if let childNode = buildNode(at: childURL) {
                    rootChildren.append(childNode)
                }
            }
            rootChildren = sort(nodes: rootChildren, by: sortOption)
            return rootChildren
        }.value
    }
    
    nonisolated private static func sort(nodes: [FileNode], by option: SortOption) -> [FileNode] {
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
    
    // MARK: - Navigation Methods
    
    public func focusOn(relativePath: String, isSource: Bool, otherProviderPath: String) {
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
    
    public func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        updateStateFromHistory()
    }
    
    public func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        updateStateFromHistory()
    }
    
    public func resetNavigation() {
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
    
    public func scanDirectories(source: CloudProvider, sourcePath: String, destination: CloudProvider, destinationPath: String) async {
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
                        // exists in both, compare dates in RAM
                        if let sourceDate = sourceFile.modificationDate,
                           let destDate = destFile.modificationDate {
                            if abs(sourceDate.timeIntervalSince(destDate)) > 1 { // 1 second tolerance
                                if sourceDate > destDate {
                                    diffs.append(FileDifference(
                                        relativePath: relativePath,
                                        sourceItemPath: sourceFile.url.path,
                                        destinationItemPath: destFile.url.path,
                                        type: .differentDates,
                                        action: .copyToDestination,
                                        description: "\(source.displayName) file is newer"
                                    ))
                                } else {
                                    diffs.append(FileDifference(
                                        relativePath: relativePath,
                                        sourceItemPath: sourceFile.url.path,
                                        destinationItemPath: destFile.url.path,
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
                            sourceItemPath: sourceFile.url.path,
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
                            destinationItemPath: destFile.url.path,
                            type: .missingInSource,
                            action: .copyToSource,
                            description: "Missing in \(source.displayName)"
                        ))
                    }
                }
                
                return diffs.sorted { $0.relativePath < $1.relativePath }
                
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
    
    public func syncFile(_ difference: FileDifference) async {
        // Find the difference in our array and mark it as syncing
        if let index = differences.firstIndex(where: { $0.id == difference.id }) {
            differences[index].isSyncing = true
        }
        
        let resultError = await Task.detached(priority: .userInitiated) { () -> Error? in
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
                
                // Atomically copy the file to prevent file loss/corruption during sync
                try Self.safeCopyItem(at: fromURL, to: toURL)
                return nil
                
            } catch {
                return error
            }
        }.value
        
        if let error = resultError {
            let msg = "Error syncing file \(difference.relativePath): \(error.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
        }
        
        if resultError == nil {
            Logger.shared.info("Synced file: \(difference.relativePath)")
            // Remove from differences list
            differences.removeAll { $0.id == difference.id }
        } else {
            // Reset syncing state
            if let index = differences.firstIndex(where: { $0.id == difference.id }) {
                differences[index].isSyncing = false
            }
        }
    }
    

    // Implementations moved to FileOperations.swift
    
    
    private struct FileInfo {
        let url: URL
        let modificationDate: Date?
    }
    
    // Returns a dictionary mapping relative paths to cached FileInfo
    nonisolated private static func getFilesInDirectory(_ url: URL) throws -> [String: FileInfo] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return [:]
        }
        
        var result: [String: FileInfo] = [:]
        let basePathLength = url.path.count + 1
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))
                if let isRegularFile = resourceValues.isRegularFile, isRegularFile {
                    let relativePath: String
                    let path = fileURL.path
                    if path.count > basePathLength {
                        relativePath = String(path.dropFirst(basePathLength))
                    } else {
                        relativePath = path.replacingOccurrences(of: url.path + "/", with: "")
                    }
                    
                    result[relativePath] = FileInfo(
                        url: fileURL, 
                        modificationDate: resourceValues.contentModificationDate
                    )
                }
            } catch {
                let msg = "Error reading resource values for \(fileURL): \(error)"
                Task { @MainActor in Logger.shared.error(msg, showAlert: false) }
            }
        }
        
        return result
    }
}
