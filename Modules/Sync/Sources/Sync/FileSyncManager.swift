import Events
import SwiftUI
import Combine
import UniformTypeIdentifiers
import Design

/// Core business logic for the two-pane file comparison and sync engine.
/// Holds in-memory trees (`FileNode`) for the left and right panes, runs differential scans,
/// and serializes file operations (copy, move, delete) with undo support and termination guards.
@MainActor
public class FileSyncManager: ObservableObject {
    /// File system abstraction used for all disk I/O (supports injection for tests).
    public let fileManager: FileManaging
    
    /// A closure that resolves naming collisions during file operations.
    /// In production, this typically shows an NSAlert. In tests, it can be mocked to return specific resolutions.
    public var collisionResolver: @MainActor (String, Bool) -> CollisionResolution = { fileName, isMove in
        return NativeAlerts.promptForCollision(fileName: fileName, isMove: isMove)
    }
    
    /// Initializes a new FileSyncManager with a specific file manager.
    /// - Parameter fileManager: The file manager to use. Defaults to `FileManager.default`.
    public init(fileManager: FileManaging = FileManager.default) {
        self.fileManager = fileManager
    }
    
    /// Cached differences from the latest scan before applying hidden/ignored filters.
    internal var rawDifferences: [FileDifference] = []
    /// Filtered list of differences between the left and right panes (respects `showHiddenFiles` and `ignoredPaths`).
    @Published public var differences: [FileDifference] = []
    /// Indicates whether a deep structure scan is currently in progress.
    @Published public var isScanning = false
    /// Indicates whether at least one successful scan has occurred.
    @Published public var hasScanned = false
    
    /// Global sorting preference for the file trees.
    @Published public var sortOption: SortOption = .name {
        didSet {
            guard sortOption != oldValue else { return }
            // Invalidate prefetch cache for roots as they need re-sorting or re-scanning
            prefetchedTrees.removeAll()
            // Re-sort current trees globally when option changes
            rawLeftTree = Self.sort(nodes: rawLeftTree, by: sortOption)
            rawRightTree = Self.sort(nodes: rawRightTree, by: sortOption)
            applyFilters()
        }
    }
    
    /// Global toggle to show/hide hidden files (e.g. .DS_Store, .git)
    @Published public var showHiddenFiles: Bool = false {
        didSet {
            guard showHiddenFiles != oldValue else { return }
            prefetchedTrees.removeAll()
            applyFilters()
        }
    }
    
    /// Paths that the user has explicitly requested to hide from the current comparison context.
    @Published public var ignoredPaths: Set<String> = [] {
        didSet {
            guard ignoredPaths != oldValue else { return }
            applyFilters()
        }
    }
    
    /// Raw file tree for the left pane (before hidden/ignored filtering).
    internal var rawLeftTree: [FileNode] = []
    /// Filtered file tree for the left pane (used by the UI).
    @Published public var leftTree: [FileNode] = []

    /// Raw file tree for the right pane (before hidden/ignored filtering).
    internal var rawRightTree: [FileNode] = []
    /// Filtered file tree for the right pane (used by the UI).
    @Published public var rightTree: [FileNode] = []
    /// True while the left pane tree is being loaded from disk.
    @Published public var isLoadingLeftTree = false
    /// True while the right pane tree is being loaded from disk.
    @Published public var isLoadingRightTree = false

    /// Total number of files and folders in the left pane tree (recursive).
    @Published public var leftItemCount = 0
    /// Total number of files and folders in the right pane tree (recursive).
    @Published public var rightItemCount = 0
    
    /// Cached structures generated asynchronously upon app load to eliminate blocking when switching providers.
    @Published public var prefetchedTrees: [String: [FileNode]] = [:]
    
    @Published public var clipboardNodes: [FileNode] = []
    @Published public var clipboardIsCut: Bool = false
    
    /// Global UndoManager injected from SwiftUI environment
    public var undoManager: UndoManager?
    
    /// Last error message from a file operation (cleared when user dismisses the alert).
    @Published public var currentError: String? = nil

    /// Current subfolder path relative to the left pane root (empty = root).
    @Published public var leftRelativePath: String = ""
    /// Current subfolder path relative to the right pane root (empty = root).
    @Published public var rightRelativePath: String = ""

    /// Paths currently selected in the left pane (at most one pane has selection at a time).
    @Published public var selectedLeftPaths: Set<String> = [] {
        didSet {
            // Enforce mutual exclusivity: a non-empty left selection clears any right selection.
            if !selectedLeftPaths.isEmpty && !selectedRightPaths.isEmpty {
                selectedRightPaths = []
            }
        }
    }
    @Published public var selectedRightPaths: Set<String> = [] {
        didSet {
            // Enforce mutual exclusivity: a non-empty right selection clears any left selection.
            if !selectedRightPaths.isEmpty && !selectedLeftPaths.isEmpty {
                selectedLeftPaths = []
            }
        }
    }
    /// Paths of expanded folders in the left pane tree view.
    @Published public var leftExpandedPaths: Set<String> = []
    /// Paths of expanded folders in the right pane tree view.
    @Published public var rightExpandedPaths: Set<String> = []
    
    /// Tracks the number of currently active file operations (Sync, Move, Delete, etc.).
    /// Used by the app-level guard to prevent accidental termination during critical tasks.
    @Published public var activeFileOperationsCount = 0
    /// Real-time progress tracker for the currently active bulk file operation.
    @Published public var activeProgress: Progress? = nil
    /// Short-lived banner message for in-app operation completion toasts.
    @Published public var bannerMessage: String? = nil
    
    /// Global Combine subject to trigger a UI refresh of trees from anywhere without closure retain cycles.
    public let refreshSubject = PassthroughSubject<Void, Never>()
    
    /// Chains file operations so they run one after another (avoids concurrent copy/move/undo conflicts).
    private var fileOperationTask: Task<Void, Swift.Error> = Task {}

    /// Captures a single scan request (left/right providers and paths) for re-entrancy and cancellation.
    struct ScanRequest: Sendable {
        let left: CloudProvider
        let leftPath: String
        let right: CloudProvider
        let rightPath: String
        let generation: Int
    }

    /// Active tree-load and refresh tasks; cancel before starting a new one for the same pane.
    internal var activeLoadLeftTask: Task<Void, Never>?
    internal var activeLoadRightTask: Task<Void, Never>?
    internal var activeRefreshTask: Task<Void, Never>?
    private var hasPendingSelectionPrune = false
    var scanRequestGeneration = 0
    var pendingScanRequest: ScanRequest?
    
    /// Enqueues a file operation to be executed sequentially.
    /// Manages `activeFileOperationsCount` and triggers UI refreshes and selection pruning upon completion.
    @discardableResult
    public func enqueueFileOperation<T: Sendable>(
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        await MainActor.run { self.activeFileOperationsCount += 1 }
        
        let previousTask = fileOperationTask
        let newTask = Task.detached(priority: .userInitiated) {
            _ = await previousTask.result
            let res = await operation()
            await MainActor.run { [weak self] in 
                // File operations mutate the filesystem; cached prefetched roots are stale after any write.
                self?.prefetchedTrees.removeAll()
                self?.activeFileOperationsCount = max(0, (self?.activeFileOperationsCount ?? 1) - 1)
                self?.scheduleSelectionPrune()
                self?.refreshSubject.send() 
            }
            return res
        }
        fileOperationTask = Task { _ = await newTask.value }
        return await newTask.value
    }
    
    public func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool {
        var rPath = node.id
        if rPath.hasPrefix(currentPath) {
            rPath = String(rPath.dropFirst(currentPath.count))
            if rPath.hasPrefix("/") { rPath.removeFirst() }
        }
        return Self.isIgnoredPath(rPath, ignored: ignoredPaths)
    }
    
    /// Reapplies `showHiddenFiles` and `ignoredPaths` to raw trees and differences, updating published state.
    public func applyFilters() {
        self.leftTree = Self.filterTree(rawLeftTree, showHidden: showHiddenFiles)
        self.rightTree = Self.filterTree(rawRightTree, showHidden: showHiddenFiles)
        self.leftItemCount = countItems(in: self.leftTree)
        self.rightItemCount = countItems(in: self.rightTree)
        
        var filteredDifferences = rawDifferences
        if !showHiddenFiles {
            filteredDifferences = filteredDifferences.filter { !Self.isHiddenPath($0.relativePath) }
        }
        if !ignoredPaths.isEmpty {
            filteredDifferences = filteredDifferences.filter { diff in 
                !Self.isIgnoredPath(diff.relativePath, ignored: ignoredPaths)
            }
        }
        self.differences = filteredDifferences
    }
    
    /// Recursively filters a tree removing nodes whose names start with a period if `showHidden` is false.
    nonisolated static func filterTree(_ nodes: [FileNode], showHidden: Bool) -> [FileNode] {
        if showHidden { return nodes }
        var filtered: [FileNode] = []
        for node in nodes {
            if node.name.hasPrefix(".") { continue }
            
            var newNode = node
            if let children = node.children {
                newNode.children = filterTree(children, showHidden: showHidden)
            }
            filtered.append(newNode)
        }
        return filtered
    }
    
    nonisolated static func isIgnoredPath(_ path: String, ignored: Set<String>) -> Bool {
        for ignoredPath in ignored {
            if path == ignoredPath || path.hasPrefix(ignoredPath + "/") {
                return true
            }
        }
        return false
    }
    
    nonisolated static func isHiddenPath(_ path: String) -> Bool {
        let components = path.components(separatedBy: "/")
        return components.contains { $0.hasPrefix(".") }
    }
    
    /// Stack of (leftRelativePath, rightRelativePath) for back/forward navigation.
    public var history: [(left: String, right: String)] = [("", "")]
    /// Index into `history` for the current navigation state.
    public var historyIndex: Int = 0
    
    /// Indicates if the user can navigate back in history.
    @Published public var canGoBack: Bool = false
    /// Indicates if the user can navigate forward in history.
    @Published public var canGoForward: Bool = false
    
    // Navigation and Scanning methods moved to extensions
    
    /// Resolves one difference by copying or moving the file between the two panes.
    /// If the destination already exists, prompts for Replace / Keep Both / Skip before overwriting.
    /// - Parameters:
    ///   - difference: The discrepancy to resolve (determines from/to paths from `action`).
    ///   - isMove: If true, moves the file; otherwise copies.
    ///   - fileManager: Optional override for tests (defaults to `self.fileManager`).
    public func syncFile(_ difference: FileDifference, isMove: Bool = false, fileManager: FileManaging? = nil) async {
        let activeFM = fileManager ?? self.fileManager
        // Find the difference in our array and mark it as syncing
        if let index = differences.firstIndex(where: { $0.id == difference.id }) {
            differences[index].isSyncing = true
        }
        
        let fromURL: URL
        var toURL: URL
        if difference.action == .copyToRight {
            fromURL = URL(fileURLWithPath: difference.leftItemPath)
            toURL = URL(fileURLWithPath: difference.rightItemPath)
        } else {
            fromURL = URL(fileURLWithPath: difference.rightItemPath)
            toURL = URL(fileURLWithPath: difference.leftItemPath)
        }
        
        // If destination exists, prompt before overwriting (same behavior as copy-from-tree).
        if activeFM.fileExists(atPath: toURL.path) {
            let fileName = toURL.lastPathComponent
            let resolution = collisionResolver(fileName, isMove)
            switch resolution {
            case .skip:
                if let index = differences.firstIndex(where: { $0.id == difference.id }) {
                    differences[index].isSyncing = false
                }
                return
            case .keepBoth:
                toURL = Self.generateUniqueURL(for: toURL, fileManager: activeFM)
            case .replace:
                break
            }
        }
        
        let resolvedToURL = toURL
        let result = await enqueueFileOperation { () -> (error: Error?, trashed: URL?, from: URL?, to: URL?) in
            do {
                try activeFM.createDirectory(at: resolvedToURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                
                let trashed: URL?
                if isMove {
                    trashed = try Self.safeMoveItem(at: fromURL, to: resolvedToURL, fileManager: activeFM)
                } else {
                    trashed = try Self.safeCopyItem(at: fromURL, to: resolvedToURL, fileManager: activeFM)
                }
                
                return (nil, trashed, fromURL, resolvedToURL)
                
            } catch {
                return (error, nil, nil, nil)
            }
        }
        
        if let error = result.error {
            let msg = "Error syncing file \(difference.relativePath): \(error.localizedDescription)"
            self.currentError = msg
            Logger.shared.error(msg, showAlert: false)
            
            if let index = differences.firstIndex(where: { $0.id == difference.id }) {
                differences[index].isSyncing = false
            }
        } else {
            Logger.shared.debug("Synced file: \(difference.relativePath)")
            if let from = result.from, let to = result.to {
                let actionName = "Sync \(difference.relativePath.components(separatedBy: "/").last ?? "")"
                if isMove {
                    let initialResolver = AsyncValueResolver<[MoveItemState]>()
                    Task { await initialResolver.resolve([(from: from, to: to, overwritten: result.trashed)]) }
                    self.registerMoveUndo(stateResolver: initialResolver, actionName: actionName, fileManager: activeFM)
                } else {
                    let initialResolver = AsyncValueResolver<[CopyItemState]>()
                    Task { await initialResolver.resolve([(source: from, destination: to, overwritten: result.trashed)]) }
                    self.registerCopyUndo(stateResolver: initialResolver, actionName: actionName, fileManager: activeFM)
                }
            }
            differences.removeAll { $0.id == difference.id }
        }
    }
    

    /// Removes selected paths that no longer exist in the trees (e.g. after move/delete) to avoid ghost selection.
    public func pruneSelection() {
        var allLeftPaths = Set<String>()
        var allRightPaths = Set<String>()
        
        collectPaths(in: leftTree, into: &allLeftPaths)
        collectPaths(in: rightTree, into: &allRightPaths)
        
        let prunedLeft = selectedLeftPaths.filter { allLeftPaths.contains($0) }
        let prunedRight = selectedRightPaths.filter { allRightPaths.contains($0) }
        
        if prunedLeft != selectedLeftPaths {
            selectedLeftPaths = prunedLeft
        }
        if prunedRight != selectedRightPaths {
            selectedRightPaths = prunedRight
        }
    }

    /// Defers selection pruning to the next run loop to avoid reentrant list delegate mutations.
    func scheduleSelectionPrune() {
        guard !hasPendingSelectionPrune else { return }
        hasPendingSelectionPrune = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingSelectionPrune = false
            self.pruneSelection()
        }
    }
    
    private func collectPaths(in tree: [FileNode], into paths: inout Set<String>) {
        for node in tree {
            paths.insert(node.id)
            if let children = node.children {
                collectPaths(in: children, into: &paths)
            }
        }
    }

    // Implementations moved to FileOperations.swift
    
    // Diff algorithms moved to FileDiffEngine.swift
}
