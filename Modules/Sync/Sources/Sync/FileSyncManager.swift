import Events
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Core business logic manager governing the synchronization engine.
/// Manages in-memory tree structures (`FileNode`) for cloud providers and handles differential scanning.
/// Tracks active file operations for app-wide termination guards and ensures serialized execution of background tasks.
@MainActor
public class FileSyncManager: ObservableObject {
    /// The file manager used for all disk operations.
    /// Can be injected to support testing via `MockFileManager`.
    public let fileManager: FileManaging
    
    /// A closure that resolves naming collisions during file operations.
    /// In production, this typically shows an NSAlert. In tests, it can be mocked to return specific resolutions.
    public var collisionResolver: @MainActor (String, Bool) -> CollisionResolution = { fileName, isMove in
        return promptForCollision(fileName: fileName, isMove: isMove)
    }
    
    /// Initializes a new FileSyncManager with a specific file manager.
    /// - Parameter fileManager: The file manager to use. Defaults to `FileManager.default`.
    public init(fileManager: FileManaging = FileManager.default) {
        self.fileManager = fileManager
    }
    
    /// Array of differences calculated between the source and destination directories after a scan.
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
            sourceTree = Self.sort(nodes: sourceTree, by: sortOption)
            destinationTree = Self.sort(nodes: destinationTree, by: sortOption)
            refreshSubject.send()
        }
    }
    
    /// Global toggle to show/hide hidden files (e.g. .DS_Store, .git)
    @Published public var showHiddenFiles: Bool = false {
        didSet {
            guard showHiddenFiles != oldValue else { return }
            // CRITICAL: Cache must be invalidated because hidden files change the tree structure itself
            prefetchedTrees.removeAll()
            refreshSubject.send()
        }
    }
    
    /// Internal representation of the loaded file structure for the source provider.
    @Published public var sourceTree: [FileNode] = []
    /// Internal representation of the loaded file structure for the destination provider.
    @Published public var destinationTree: [FileNode] = []
    @Published public var isLoadingSourceTree = false
    @Published public var isLoadingDestinationTree = false
    
    /// Total number of recursive items found in the source directory.
    @Published public var sourceItemCount = 0
    /// Total number of recursive items found in the destination directory.
    @Published public var destinationItemCount = 0
    
    /// Cached structures generated asynchronously upon app load to eliminate blocking when switching providers.
    @Published public var prefetchedTrees: [String: [FileNode]] = [:]
    
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
    
    /// Tracks the number of currently active file operations (Sync, Move, Delete, etc.).
    /// Used by the app-level guard to prevent accidental termination during critical tasks.
    @Published public var activeFileOperationsCount = 0
    
    /// Global Combine subject to trigger a UI refresh of trees from anywhere without closure retain cycles.
    public let refreshSubject = PassthroughSubject<Void, Never>()
    
    /// Global serial queue for file operations to prevent data corruption from concurrent Undo/Redo or file syncing.
    private var fileOperationTask: Task<Void, Swift.Error> = Task {}

    struct ScanRequest: Sendable {
        let source: CloudProvider
        let sourcePath: String
        let destination: CloudProvider
        let destinationPath: String
        let generation: Int
    }
    
    // Internal task tracking for re-entrancy protection
    internal var activeLoadSourceTask: Task<Void, Never>?
    internal var activeLoadDestTask: Task<Void, Never>?
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
    
    /// Navigates through the navigational history across both panes.
    public var history: [(source: String, dest: String)] = [("", "")]
    /// Current index in the navigation history stack.
    public var historyIndex: Int = 0
    
    /// Indicates if the user can navigate back in history.
    @Published public var canGoBack: Bool = false
    /// Indicates if the user can navigate forward in history.
    @Published public var canGoForward: Bool = false
    
    // Navigation and Scanning methods moved to extensions
    
    /// Synchronizes a specific file difference between source and destination.
    /// Marks the difference as `isSyncing` and enqueues a safe copy or move operation.
    /// - Parameters:
    ///   - difference: The model representing the discrepancy to resolve.
    ///   - isMove: If true, moves the file instead of copying.
    ///   - fileManager: The file manager to use for the sync (defaults to `self.fileManager`).
    public func syncFile(_ difference: FileDifference, isMove: Bool = false, fileManager: FileManaging? = nil) async {
        let activeFM = fileManager ?? self.fileManager
        // Find the difference in our array and mark it as syncing
        if let index = differences.firstIndex(where: { $0.id == difference.id }) {
            differences[index].isSyncing = true
        }
        
        let result = await enqueueFileOperation { () -> (error: Error?, trashed: URL?, from: URL?, to: URL?) in
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
                
                try activeFM.createDirectory(at: toURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                
                let trashed: URL?
                if isMove {
                    trashed = try Self.safeMoveItem(at: fromURL, to: toURL, fileManager: activeFM)
                } else {
                    trashed = try Self.safeCopyItem(at: fromURL, to: toURL, fileManager: activeFM)
                }
                
                return (nil, trashed, fromURL, toURL)
                
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
            Logger.shared.info("Synced file: \(difference.relativePath)")
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
    

    /// Prunes the selection sets to remove any paths that are no longer present in the trees.
    /// This prevents "ghost" selection markers when files are moved or deleted.
    public func pruneSelection() {
        var allSourcePaths = Set<String>()
        var allDestPaths = Set<String>()
        
        collectPaths(in: sourceTree, into: &allSourcePaths)
        collectPaths(in: destinationTree, into: &allDestPaths)
        
        let prunedSource = selectedSourcePaths.filter { allSourcePaths.contains($0) }
        let prunedDest = selectedDestinationPaths.filter { allDestPaths.contains($0) }
        
        if prunedSource != selectedSourcePaths {
            selectedSourcePaths = prunedSource
        }
        if prunedDest != selectedDestinationPaths {
            selectedDestinationPaths = prunedDest
        }
    }

    /// Defers selection pruning to the next MainActor turn to avoid reentrant list delegate mutations.
    func scheduleSelectionPrune() {
        guard !hasPendingSelectionPrune else { return }
        hasPendingSelectionPrune = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Defer to the next run-loop cycle to avoid NSTableView delegate reentrancy.
            try? await Task.sleep(nanoseconds: 10_000_000)
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
