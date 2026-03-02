import SwiftUI
import UniformTypeIdentifiers

/// Core business logic manager governing the synchronization engine
/// Manages the in-memory tree structures (FileNode) for both source and destination cloud providers.
/// Responsible for scanning directories, computing FileDifferences, and tracking relative navigation paths.
enum SortOption: String, CaseIterable, Equatable {
    case name = "Name"
    case kind = "Kind"
    case dateModified = "Date Modified"
    case size = "Size"
    case tags = "Tags"
}

@MainActor
class DocumentSyncManager: ObservableObject {
    /// Array of differences calculated between the source and destination directories.
    @Published var differences: [FileDifference] = []
    /// Indicates whether a deep structure scan is currently in progress.
    @Published var isScanning = false
    /// Indicates whether at least one successful scan has occurred.
    @Published var hasScanned = false
    
    /// Global sorting preference for the file trees.
    @Published var sortOption: SortOption = .name {
        didSet {
            // Re-sort trees globally when option changes
            sourceTree = Self.sort(nodes: sourceTree, by: sortOption)
            destinationTree = Self.sort(nodes: destinationTree, by: sortOption)
        }
    }
    
    /// Internal representation of the loaded file structure for the source provider.
    @Published var sourceTree: [FileNode] = []
    /// Internal representation of the loaded file structure for the destination provider.
    @Published var destinationTree: [FileNode] = []
    @Published var isLoadingSourceTree = false
    @Published var isLoadingDestinationTree = false
    
    @Published var sourceItemCount = 0
    @Published var destinationItemCount = 0
    
    @Published var clipboardNodes: [FileNode] = []
    @Published var clipboardIsCut: Bool = false
    
    // Global Error state
    @Published var currentError: String? = nil
    
    // Navigation State (Relative paths from provider roots)
    @Published var sourceRelativePath: String = ""
    @Published var destRelativePath: String = ""
    
    /// Tracks the navigational history across both panes.
    private var history: [(source: String, dest: String)] = [("", "")]
    private var historyIndex: Int = 0
    
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    
    /// Instructs the manager to read the filesystem and construct an in-memory tree for the source pane.
    /// - Parameter path: The absolute, expanded root URL string of the provider.
    func loadSourceTree(path: String) async {
        isLoadingSourceTree = true
        let rootURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let focusURL = sourceRelativePath.isEmpty ? rootURL : rootURL.appendingPathComponent(sourceRelativePath)
        let tree = await Self.buildTree(url: focusURL, sortOption: sortOption)
        sourceTree = tree
        sourceItemCount = countItems(in: tree)
        isLoadingSourceTree = false
    }
    
    func loadDestinationTree(path: String) async {
        isLoadingDestinationTree = true
        let rootURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let focusURL = destRelativePath.isEmpty ? rootURL : rootURL.appendingPathComponent(destRelativePath)
        let tree = await Self.buildTree(url: focusURL, sortOption: sortOption)
        destinationTree = tree
        destinationItemCount = countItems(in: tree)
        isLoadingDestinationTree = false
    }
    
    nonisolated private static func buildTree(url: URL, sortOption: SortOption) async -> [FileNode] {
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
                        if item.hasPrefix(".") { continue }
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
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            var rootChildren: [FileNode] = []
            for item in contents {
                if item.hasPrefix(".") { continue }
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
                let msg = "Error scanning directories: \(error)"
                Task { @MainActor in Logger.shared.error(msg, showAlert: false) }
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
    

    // Implementations moved to DocumentSyncManager+FileOperations.swift
    
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
                let msg = "Error reading resource values for \(fileURL): \(error)"
                Task { @MainActor in Logger.shared.error(msg, showAlert: false) }
            }
        }
        
        return result
    }
}

/// An in-memory representation of a file or directory mapped from a local or cloud path
struct FileNode: Identifiable, Hashable, Codable {
    let id: String // Absolute path
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?
    var modificationDate: Date?
    var fileSize: Int?
    var tags: [String]?
    var kind: String?
}

extension FileNode: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

/// Represents a computed discrepancy between the Source and Destination providers for a single file paths
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