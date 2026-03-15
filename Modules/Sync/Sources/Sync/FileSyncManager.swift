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
    /// IDs of differences that were verified as same content via checksum; these are hidden from the list until next scan.
    internal var verifiedSameDifferenceIds: Set<UUID> = []
    /// ID of the difference currently being verified (for UI spinner).
    @Published public var verifyingDifferenceId: UUID?
    /// When non-nil, a "Verify All" run is in progress: (completed count, total count).
    @Published public var verifyAllProgress: (completed: Int, total: Int)?
    /// After Verify All completes, the list of differences that verified identical; UI shows dialog to copy left→right. Cleared when user copies or cancels.
    @Published public var verifiedIdenticalForCopy: [FileDifference]?
    /// Filtered list of differences between the left and right panes (respects `showHiddenFiles`, `ignoredPaths`, and `verifiedSameDifferenceIds`).
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

    /// When true, differences that are only "right newer, same size" are hidden when the right pane is Google Drive (avoids noise from Drive overwriting file dates). Set by the app from persisted settings.
    @Published public var ignoreGoogleDriveNewerDateOnly: Bool = false {
        didSet {
            guard ignoreGoogleDriveNewerDateOnly != oldValue else { return }
            applyFilters()
        }
    }
    /// Provider type of the right pane from the last scan; used with ignoreGoogleDriveNewerDateOnly to filter differences.
    internal var lastRightProviderType: CloudProvider.ProviderType?
    
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

    /// When non-nil, a bulk sync is in progress: (completed count, total count). Used for progress indicator.
    @Published public var bulkSyncProgress: (completed: Int, total: Int)? = nil
    /// Cached "Apply to all" resolution for the current bulk run; cleared when bulk sync ends.
    internal var bulkApplyToAllResolution: CollisionResolution?

    /// Current subfolder path relative to the left pane root (empty = root).
    @Published public var leftRelativePath: String = ""
    /// Current subfolder path relative to the right pane root (empty = root).
    @Published public var rightRelativePath: String = ""

    /// Paths currently selected in the left pane (at most one pane has selection at a time).
    @Published public var selectedLeftPaths: Set<String> = [] {
        didSet {
            // Enforce mutual exclusivity: defer so we don't publish from within a view update.
            if !selectedLeftPaths.isEmpty && !selectedRightPaths.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.selectedRightPaths = []
                }
            }
        }
    }
    @Published public var selectedRightPaths: Set<String> = [] {
        didSet {
            // Enforce mutual exclusivity: defer so we don't publish from within a view update.
            if !selectedRightPaths.isEmpty && !selectedLeftPaths.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.selectedLeftPaths = []
                }
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
        filteredDifferences = filteredDifferences.filter { !verifiedSameDifferenceIds.contains($0.id) }
        if ignoreGoogleDriveNewerDateOnly, lastRightProviderType == .googleDrive {
            filteredDifferences = filteredDifferences.filter { diff in
                // Hide "right is newer, same size" only (Drive date noise)
                if diff.type == .differentDates, diff.sizesMatch, diff.action == .copyToLeft {
                    return false
                }
                return true
            }
        }
        self.differences = filteredDifferences
    }

    /// Verifies whether the two sides of a "newer / different dates" difference have the same content via checksum.
    /// Only applicable when both sides are regular files with matching size; directories and files over 100 MB are skipped.
    /// If content matches, the difference is hidden from the list until the next scan.
    /// - Parameter difference: A difference with type `differentDates` (and ideally `sizesMatch`).
    /// - Returns: `true` if content is identical and the difference was hidden; `false` if content differs or verification failed.
    public func verifyWithChecksum(_ difference: FileDifference) async -> Bool {
        guard difference.type == .differentDates else { return false }
        verifyingDifferenceId = difference.id
        defer { verifyingDifferenceId = nil }
        let same = await FileContentVerifier.filesHaveSameContent(
            leftPath: difference.leftItemPath,
            rightPath: difference.rightItemPath,
            fileManager: fileManager
        )
        guard same == true else {
            if same == false {
                currentError = "Content differs — files are not identical."
            } else {
                currentError = "Could not verify (file may be a folder, missing, or over 100 MB)."
            }
            return false
        }
        verifiedSameDifferenceIds.insert(difference.id)
        applyFilters()
        bannerMessage = "Verified identical — hidden from list"
        return true
    }

    /// Differences that qualify for checksum verification (different dates but same size; files only).
    private var verifiableDifferences: [FileDifference] {
        differences.filter { $0.type == .differentDates && $0.sizesMatch }
    }

    /// Runs checksum verification on all differences that meet the Verify criteria (newer/older but same size).
    /// Runs up to 4 verifications in parallel. Cancellable via activeProgress. When done, if any verified identical, sets `verifiedIdenticalForCopy` so the UI can offer to copy left→right.
    public func verifyAllWithChecksum() async {
        let toVerify = verifiableDifferences
        guard !toVerify.isEmpty else { return }

        let progress = Progress(totalUnitCount: Int64(toVerify.count))
        progress.localizedDescription = "Verifying \(toVerify.count) files"
        progress.isCancellable = true
        activeProgress = progress
        verifyAllProgress = (0, toVerify.count)
        verifyingDifferenceId = nil

        defer {
            verifyAllProgress = nil
            activeProgress = nil
        }

        let activeFM = fileManager
        let queue = VerifyWorkQueue(items: toVerify)
        let collector = VerifyResultsCollector()
        let counter = BulkSyncCompletedCounter(total: toVerify.count)
        let weakRef = WeakSyncManagerRef(self)
        let progressRef = BulkSyncProgressRef(progress)
        let totalCount = toVerify.count
        let concurrency = min(4, max(1, toVerify.count))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    while !progressRef.progress.isCancelled, let diff = await queue.next() {
                        let same = await FileContentVerifier.filesHaveSameContent(
                            leftPath: diff.leftItemPath,
                            rightPath: diff.rightItemPath,
                            fileManager: activeFM
                        )
                        if same == true {
                            await collector.addIdentical(diff)
                        } else if same == false {
                            await collector.addDiffered()
                        } else {
                            await collector.addSkipped()
                        }
                        let completed = await counter.increment()
                        progressRef.progress.completedUnitCount = Int64(completed)
                        await MainActor.run {
                            weakRef.value?.verifyAllProgress = (completed, totalCount)
                        }
                    }
                }
            }
        }

        let (verifiedIdentical, differed, skipped) = await collector.get()
        if !verifiedIdentical.isEmpty {
            verifiedIdenticalForCopy = verifiedIdentical
        }
        var parts: [String] = []
        if !verifiedIdentical.isEmpty { parts.append("\(verifiedIdentical.count) identical") }
        if differed > 0 { parts.append("\(differed) differed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if progress.isCancelled {
            bannerMessage = "Verify All cancelled"
        } else {
            bannerMessage = parts.isEmpty ? nil : "Verify All: " + parts.joined(separator: "; ")
        }
    }

    /// Dismisses the "copy verified" dialog without copying; hides the verified identical items from the list.
    public func dismissVerifiedCopyDialogWithoutCopy() {
        guard let list = verifiedIdenticalForCopy else { return }
        for diff in list {
            verifiedSameDifferenceIds.insert(diff.id)
        }
        verifiedIdenticalForCopy = nil
        applyFilters()
    }

    /// Bulk copy the given differences from left to right (overwrites if exists). No per-file confirmation; 2–4 concurrent copies.
    private func bulkCopyDifferencesLeftToRight(_ toCopy: [FileDifference]) async {
        let total = toCopy.count
        guard total > 0 else { return }

        let progress = Progress(totalUnitCount: Int64(total))
        progress.localizedDescription = "Copying \(total) files to match dates"
        progress.isCancellable = true
        activeProgress = progress

        for i in differences.indices where toCopy.contains(where: { $0.id == differences[i].id }) {
            differences[i].isSyncing = true
        }
        bulkSyncProgress = (0, total)

        // Yield so the progress overlay can render before we block on the copy work.
        await MainActor.run { }

        defer {
            bulkSyncProgress = nil
            activeProgress = nil
            for i in differences.indices where toCopy.contains(where: { $0.id == differences[i].id }) {
                differences[i].isSyncing = false
            }
        }

        let activeFM = fileManager
        let workList: [(FileDifference, URL, URL, Bool)] = toCopy.map { diff in
            (diff, URL(fileURLWithPath: diff.leftItemPath), URL(fileURLWithPath: diff.rightItemPath), false)
        }

        let progressRef = BulkSyncProgressRef(progress)
        let weakRef = WeakSyncManagerRef(self)
        let totalCount = total
        let counter = BulkSyncCompletedCounter(total: totalCount)

        let result = await enqueueFileOperation { () -> (successes: [(FileDifference, (URL?, URL, URL))], failures: [(FileDifference, Error)]) in
            let queue = BulkSyncWorkQueue(items: workList)
            let collector = BulkSyncResultsCollector()
            let concurrency = min(4, max(2, workList.count))

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<concurrency {
                    group.addTask {
                        while !progressRef.progress.isCancelled {
                            guard let (diff, fromURL, toURL, isMove) = await queue.next() else { break }
                            do {
                                let syncResult = try FileSyncManager.performFileSyncIO(from: fromURL, to: toURL, isMove: isMove, fileManager: activeFM)
                                await collector.addSuccess(diff, (syncResult.trashed, syncResult.from, syncResult.to))
                            } catch {
                                await collector.addFailure(diff, error)
                            }
                            let completed = await counter.increment()
                            progressRef.progress.completedUnitCount = Int64(completed)
                            await MainActor.run {
                                weakRef.value?.bulkSyncProgress = (completed, totalCount)
                            }
                        }
                    }
                }
            }

            return await collector.get()
        }

        for (diff, (trashed, from, to)) in result.successes {
            let actionName = "Sync \(diff.relativePath.components(separatedBy: "/").last ?? "")"
            let initialResolver = AsyncValueResolver<[CopyItemState]>()
            Task { await initialResolver.resolve([(source: from, destination: to, overwritten: trashed)]) }
            registerCopyUndo(stateResolver: initialResolver, actionName: actionName, fileManager: activeFM)
            differences.removeAll { $0.id == diff.id }
        }
        for (diff, error) in result.failures {
            let msg = "Error copying file \(diff.relativePath): \(error.localizedDescription)"
            currentError = msg
            Logger.shared.error(msg, showAlert: false)
            if let index = differences.firstIndex(where: { $0.id == diff.id }) {
                differences[index].isSyncing = false
            }
        }
        if !result.failures.isEmpty {
            bannerMessage = "\(result.successes.count) copied; \(result.failures.count) failed"
        } else if !result.successes.isEmpty {
            bannerMessage = "\(result.successes.count) files copied — dates matched"
        }
    }

    /// Copies the verified-identical list left→right (no confirmation, overwrites). Call after user confirms in the dialog.
    public func bulkCopyVerifiedIdenticalLeftToRight() async {
        guard let list = verifiedIdenticalForCopy, !list.isEmpty else { return }
        verifiedIdenticalForCopy = nil
        await bulkCopyDifferencesLeftToRight(list)
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
    ///   - isBulkSync: When true, uses "Apply to all" flow and cached resolution when set.
    ///   - fileManager: Optional override for tests (defaults to `self.fileManager`).
    public func syncFile(_ difference: FileDifference, isMove: Bool = false, isBulkSync: Bool = false, fileManager: FileManaging? = nil) async {
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
            let resolution: CollisionResolution
            if isBulkSync, let cached = bulkApplyToAllResolution {
                resolution = cached
            } else if isBulkSync {
                let (res, applyToAll) = NativeAlerts.promptForCollisionWithApplyToAll(fileName: fileName, isMove: isMove)
                if applyToAll { bulkApplyToAllResolution = res }
                resolution = res
            } else {
                resolution = collisionResolver(fileName, isMove)
            }
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
                try Self.ensureParentDirectoryExists(for: resolvedToURL, fileManager: activeFM)
                
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

    /// Resolves all differences in one direction by copying or moving each matching item (same behavior as per-file sync; collisions show "Apply to all" when applicable).
    /// Runs up to 4 file operations in parallel. Cancellation completes the current file then stops before starting new ones.
    /// - Parameters:
    ///   - direction: Which direction to sync (e.g. `.copyToRight` → copy all that are "missing on right" or "left newer").
    ///   - isMove: If true, moves each file; otherwise copies.
    ///   - subset: When non-nil, only differences in this array are considered (e.g. the currently filtered list). When nil, uses the full `differences` array.
    public func syncAll(direction: FileDifference.SyncAction, isMove: Bool = false, subset: [FileDifference]? = nil) async {
        let source = subset ?? differences
        let toSync = source.filter { $0.action == direction }
        let total = toSync.count
        guard total > 0 else { return }
        bulkApplyToAllResolution = nil

        let progress = Progress(totalUnitCount: Int64(total))
        progress.localizedDescription = "Syncing \(total) files"
        progress.isCancellable = true
        activeProgress = progress

        for i in differences.indices where toSync.contains(where: { $0.id == differences[i].id }) {
            differences[i].isSyncing = true
        }

        defer {
            bulkSyncProgress = nil
            bulkApplyToAllResolution = nil
            activeProgress = nil
            for i in differences.indices where toSync.contains(where: { $0.id == differences[i].id }) {
                differences[i].isSyncing = false
            }
        }

        let activeFM = fileManager
        var preparedList: [(FileDifference, URL, URL, Bool)] = []
        for difference in toSync {
            if progress.isCancelled { break }
            let fromURL: URL
            var toURL: URL
            if difference.action == .copyToRight {
                fromURL = URL(fileURLWithPath: difference.leftItemPath)
                toURL = URL(fileURLWithPath: difference.rightItemPath)
            } else {
                fromURL = URL(fileURLWithPath: difference.rightItemPath)
                toURL = URL(fileURLWithPath: difference.leftItemPath)
            }
            if activeFM.fileExists(atPath: toURL.path) {
                let fileName = toURL.lastPathComponent
                let resolution: CollisionResolution
                if let cached = bulkApplyToAllResolution {
                    resolution = cached
                } else {
                    let (res, applyToAll) = NativeAlerts.promptForCollisionWithApplyToAll(fileName: fileName, isMove: isMove)
                    if applyToAll { bulkApplyToAllResolution = res }
                    resolution = res
                }
                switch resolution {
                case .skip:
                    continue
                case .keepBoth:
                    toURL = Self.generateUniqueURL(for: toURL, fileManager: activeFM)
                case .replace:
                    break
                }
            }
            preparedList.append((difference, fromURL, toURL, isMove))
        }

        bulkSyncProgress = (0, total)
        let progressRef = BulkSyncProgressRef(progress)
        let weakRef = WeakSyncManagerRef(self)
        let totalCount = total
        let counter = BulkSyncCompletedCounter(total: totalCount)
        let workList = preparedList

        let result = await enqueueFileOperation { () -> (successes: [(FileDifference, (URL?, URL, URL))], failures: [(FileDifference, Error)]) in
            let queue = BulkSyncWorkQueue(items: workList)
            let collector = BulkSyncResultsCollector()

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        while !progressRef.progress.isCancelled {
                            guard let (diff, fromURL, toURL, isMove) = await queue.next() else { break }
                            do {
                                let syncResult = try FileSyncManager.performFileSyncIO(from: fromURL, to: toURL, isMove: isMove, fileManager: activeFM)
                                await collector.addSuccess(diff, (syncResult.trashed, syncResult.from, syncResult.to))
                            } catch {
                                await collector.addFailure(diff, error)
                            }
                            let completed = await counter.increment()
                            progressRef.progress.completedUnitCount = Int64(completed)
                            await MainActor.run {
                                weakRef.value?.bulkSyncProgress = (completed, totalCount)
                            }
                        }
                    }
                }
            }

            return await collector.get()
        }

        for (diff, (trashed, from, to)) in result.successes {
            let actionName = "Sync \(diff.relativePath.components(separatedBy: "/").last ?? "")"
            if isMove {
                let initialResolver = AsyncValueResolver<[MoveItemState]>()
                Task { await initialResolver.resolve([(from: from, to: to, overwritten: trashed)]) }
                registerMoveUndo(stateResolver: initialResolver, actionName: actionName, fileManager: activeFM)
            } else {
                let initialResolver = AsyncValueResolver<[CopyItemState]>()
                Task { await initialResolver.resolve([(source: from, destination: to, overwritten: trashed)]) }
                registerCopyUndo(stateResolver: initialResolver, actionName: actionName, fileManager: activeFM)
            }
            differences.removeAll { $0.id == diff.id }
        }
        for (diff, error) in result.failures {
            let msg = "Error syncing file \(diff.relativePath): \(error.localizedDescription)"
            currentError = msg
            Logger.shared.error(msg, showAlert: false)
            if let index = differences.firstIndex(where: { $0.id == diff.id }) {
                differences[index].isSyncing = false
            }
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

// MARK: - Bulk sync helpers (Sendable-safe refs and actors for parallel workers)

private final class BulkSyncProgressRef: @unchecked Sendable {
    let progress: Progress
    init(_ progress: Progress) { self.progress = progress }
}

private final class WeakSyncManagerRef: @unchecked Sendable {
    weak var value: FileSyncManager?
    init(_ value: FileSyncManager?) { self.value = value }
}

private actor BulkSyncWorkQueue {
    private let items: [(FileDifference, URL, URL, Bool)]
    private var index: Int = 0
    init(items: [(FileDifference, URL, URL, Bool)]) { self.items = items }
    func next() -> (FileDifference, URL, URL, Bool)? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}

private actor BulkSyncResultsCollector {
    private var successes: [(FileDifference, (URL?, URL, URL))] = []
    private var failures: [(FileDifference, Error)] = []
    func addSuccess(_ diff: FileDifference, _ result: (URL?, URL, URL)) {
        successes.append((diff, result))
    }
    func addFailure(_ diff: FileDifference, _ error: Error) {
        failures.append((diff, error))
    }
    func get() -> (successes: [(FileDifference, (URL?, URL, URL))], failures: [(FileDifference, Error)]) {
        (successes, failures)
    }
}

private actor BulkSyncCompletedCounter {
    private var completed: Int = 0
    private let total: Int
    init(total: Int) { self.total = total }
    func increment() -> Int {
        completed += 1
        return completed
    }
}

// MARK: - Verify-all parallel workers

private actor VerifyWorkQueue {
    private let items: [FileDifference]
    private var index: Int = 0
    init(items: [FileDifference]) { self.items = items }
    func next() -> FileDifference? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}

private actor VerifyResultsCollector {
    private var verifiedIdentical: [FileDifference] = []
    private var differed: Int = 0
    private var skipped: Int = 0
    func addIdentical(_ diff: FileDifference) {
        verifiedIdentical.append(diff)
    }
    func addDiffered() { differed += 1 }
    func addSkipped() { skipped += 1 }
    func get() -> (verifiedIdentical: [FileDifference], differed: Int, skipped: Int) {
        (verifiedIdentical, differed, skipped)
    }
}
