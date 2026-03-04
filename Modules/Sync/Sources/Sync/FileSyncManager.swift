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
    public var history: [(source: String, dest: String)] = [("", "")]
    public var historyIndex: Int = 0
    
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false
    
    // Navigation and Scanning methods moved to extensions
    
    public func syncFile(_ difference: FileDifference) async {
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
                
                let fm = FileManager.default
                try fm.createDirectory(at: toURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let trashed = try Self.safeCopyItem(at: fromURL, to: toURL, fileManager: fm)
                
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
                let initialResolver = AsyncValueResolver<[CopyItemState]>()
                Task { await initialResolver.resolve([(source: from, destination: to, overwritten: result.trashed)]) }
                self.registerCopyUndo(stateResolver: initialResolver, actionName: "Sync \(difference.relativePath.components(separatedBy: "/").last ?? "")")
            }
            differences.removeAll { $0.id == difference.id }
        }
    }
    

    // Implementations moved to FileOperations.swift
    
    // Diff algorithms moved to FileDiffEngine.swift
}
