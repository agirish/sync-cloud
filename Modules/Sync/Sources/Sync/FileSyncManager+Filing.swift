import Foundation

/// Filing — suggests where loose files belong within one provider and moves them there. Loose
/// files come from a folder the user points at; destinations can be anywhere in the provider
/// (learned from the existing folder tree). Moves reuse the same safe-move + Undo path as every
/// other file operation.
extension FileSyncManager {

    /// Aggregate numbers for the Filing results view.
    public struct FilingSummary: Sendable, Equatable {
        public var fileCount: Int
        public var withConfidentHome: Int
        public var needNewFolders: Int
    }

    public var filingSummary: FilingSummary {
        var confident = 0, needFolders = 0
        for s in filingSuggestions {
            if s.hasConfidentHome { confident += 1 }
            if s.best?.isNew == true { needFolders += 1 }
        }
        return FilingSummary(fileCount: filingSuggestions.count,
                             withConfidentHome: confident, needNewFolders: needFolders)
    }

    // MARK: Scan

    /// Starts a cancellable Filing scan, replacing any in-flight one.
    public func startFindFilingSuggestions(folder: URL, providerRoot: URL, options: FilingOptions = .init()) {
        let previous = filingScanTask
        previous?.cancel()
        filingScanTask = Task { [weak self] in
            _ = await previous?.value
            await self?.findFilingSuggestions(folder: folder, providerRoot: providerRoot, options: options)
        }
    }

    /// Cancels a running Filing scan; suggestions are left as they were.
    public func cancelFindFilingSuggestions() { filingScanTask?.cancel() }

    /// Reads the loose files in `folder`, learns the provider's folder taxonomy, and produces
    /// suggested homes.
    public func findFilingSuggestions(
        folder: URL, providerRoot: URL, options: FilingOptions = .init(), fileManager fm: FileManaging? = nil
    ) async {
        guard !isSuggestingFiles else { return }
        let fileManager = fm ?? self.fileManager
        isSuggestingFiles = true
        filingScanStatus = "Reading \(folder.lastPathComponent)…"
        filingScanFolder = folder.path
        defer {
            isSuggestingFiles = false
            filingScanStatus = nil
        }

        // Loose files = the direct files sitting in the picked folder (not its subfolders).
        let looseTree = await Self.buildTree(url: folder, sortOption: .name, fileManager: fileManager, maxDepth: 1)
        let looseFiles = looseTree.filter { !$0.isDirectory }
        if Task.isCancelled { return }

        filingScanStatus = "Learning your folders…"
        let taxonomy = await Self.buildTree(url: providerRoot, sortOption: .name, fileManager: fileManager, maxDepth: nil)
        if Task.isCancelled { return }

        let suggestions = FilingEngine.suggest(looseFiles: looseFiles, taxonomy: taxonomy,
                                               providerRoot: providerRoot.path, options: options)
        if Task.isCancelled { return }
        self.filingSuggestions = suggestions
        hasSuggestedFiling = true
    }

    /// Clears suggestions (e.g. when switching providers).
    public func clearFiling() {
        filingScanTask?.cancel()
        filingSuggestions = []
        filingScanFolder = nil
        hasSuggestedFiling = false
    }

    // MARK: Apply

    /// Moves the suggestion's file into the chosen destination, creating any new folders in the
    /// path, and drops it from the list. Reversible with Undo (⌘Z). Never overwrites — a name
    /// collision keeps both by uniquifying.
    @discardableResult
    public func applyFilingSuggestion(_ suggestion: FilingSuggestion, to destination: FilingDestination) async -> Bool {
        let ok = await performFiling(suggestion, to: destination)
        if ok, currentError == nil {
            let folderName = (destination.path as NSString).lastPathComponent
            banner = .success("Filed “\(suggestion.fileName)” → \(folderName). Press ⌘Z to undo")
        }
        return ok
    }

    /// Files every suggestion that has a confident home into its best destination.
    public func applyRecommendedFiling() async {
        let batch = filingSuggestions.filter { $0.hasConfidentHome }
        guard !batch.isEmpty else { return }
        var filed = 0
        for s in batch {
            guard let dest = s.best else { continue }
            if await performFiling(s, to: dest) { filed += 1 }
        }
        if filed > 0, currentError == nil {
            banner = .success("Filed \(filed) file\(filed == 1 ? "" : "s"). Press ⌘Z to undo")
        }
    }

    /// Removes a suggestion without moving anything ("Not here" / leave it).
    public func dismissFilingSuggestion(_ suggestion: FilingSuggestion) {
        filingSuggestions.removeAll { $0.id == suggestion.id }
    }

    /// The move + undo + list-drop, without a banner (so batch shows a single summary).
    @discardableResult
    private func performFiling(_ suggestion: FilingSuggestion, to destination: FilingDestination) async -> Bool {
        let fm = fileManager
        let src = URL(fileURLWithPath: suggestion.filePath)
        let destFolder = URL(fileURLWithPath: destination.path)

        let outcome: (movedTo: URL?, overwritten: URL?, failed: Bool) = await enqueueFileOperation {
            do {
                guard fm.fileExists(atPath: src.path) else { return (nil, nil, true) }
                try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                var dst = destFolder.appendingPathComponent(suggestion.fileName)
                if fm.fileExists(atPath: dst.path) {
                    dst = FileSyncManager.generateUniqueURL(for: dst, fileManager: fm)
                }
                let overwritten = try FileSyncManager.safeMoveItem(at: src, to: dst, fileManager: fm)
                return (dst, overwritten, false)
            } catch {
                return (nil, nil, true)
            }
        }

        guard let moved = outcome.movedTo, !outcome.failed else {
            present(.syncFailed(item: suggestion.fileName, path: suggestion.filePath,
                                reason: "Couldn't file this item; it was left in place."))
            return false
        }
        registerMoveUndo(items: [(from: src, to: moved, overwritten: outcome.overwritten)],
                         actionName: "File \(suggestion.fileName)", fileManager: fm)
        filingSuggestions.removeAll { $0.id == suggestion.id }
        return true
    }
}
