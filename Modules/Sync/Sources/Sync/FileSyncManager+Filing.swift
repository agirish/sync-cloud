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
        // Start warming the AI backend now, so its cold-start overlaps the walk + content phases.
        if filingUsesAI, filingClassifier != nil { filingClassifierPrewarm?() }
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

        // Remembered rules (F3), scoped to this provider so a rule pointing into another provider's
        // tree can never fire here (its absolute destination would be wrong).
        let rules = filingRules(under: providerRoot)

        // Phase 1 — filename + metadata + your taxonomy + remembered rules (not published yet).
        var suggestions = FilingEngine.suggest(looseFiles: looseFiles, taxonomy: taxonomy,
                                               providerRoot: providerRoot.path, rules: rules, options: options)
        if Task.isCancelled { return }

        // Phase 2 — for the files with no confident home, read their contents on-device and
        // re-suggest with those tokens merged in.
        if filingReadsContents, let extractor = filingContentExtractor {
            let unsure = suggestions.filter { !$0.hasConfidentHome }
            if !unsure.isEmpty {
                filingScanStatus = "Reading \(unsure.count) document\(unsure.count == 1 ? "" : "s")…"
                let content = await Self.extractContent(for: unsure.map { $0.filePath }, using: extractor)
                if Task.isCancelled { return }
                if !content.isEmpty {
                    suggestions = FilingEngine.suggest(looseFiles: looseFiles, taxonomy: taxonomy,
                                                       providerRoot: providerRoot.path, contentTokens: content,
                                                       rules: rules, options: options)
                }
            }
        }

        if Task.isCancelled { return }

        // Phase 3 — intelligent classification. Reasons about the folder taxonomy + document text
        // to pick a home, overriding the keyword guess for the files it's confident about. An
        // explicit remembered rule (F3) still wins, and a backend that declines/errors never makes
        // things worse than the keyword engine alone.
        if filingUsesAI, let classifier = filingClassifier {
            let remembered = Set(suggestions.filter { $0.best?.remembered == true }.map { $0.filePath })
            let toClassify = looseFiles.filter { !remembered.contains($0.id) }
            if !toClassify.isEmpty {
                filingScanStatus = "Finding the best homes…"
                let taxonomyFolders = FilingEngine.relativeFolderPaths(of: taxonomy, providerRoot: providerRoot.path)
                var snippets: [String: String] = [:]
                if filingReadsContents, let extractor = filingSnippetExtractor {
                    // Only read contents for files whose NAME says nothing — a meaningful name plus
                    // the folder tree is enough for the model, and this skips OCR/PDF work (and the
                    // token cost) for the common named-file case.
                    let namelessPaths = toClassify.filter { !FilingEngine.canRemember(fileName: $0.name) }.map { $0.id }
                    snippets = await Self.extractSnippets(for: namelessPaths, using: extractor)
                    if Task.isCancelled { return }
                }
                let files = toClassify.map { f in
                    FilingCandidateFile(filePath: f.id, fileName: f.name,
                                        ext: (f.name as NSString).pathExtension.lowercased(),
                                        year: Self.modificationYear(f.modificationDate),
                                        contentSnippet: snippets[f.id])
                }
                let verdicts = await classifier(taxonomyFolders, files)
                if Task.isCancelled { return }
                suggestions = FilingEngine.applyVerdicts(verdicts, to: suggestions,
                                                         taxonomy: taxonomy, providerRoot: providerRoot.path)
            }
        }

        if Task.isCancelled { return }
        self.filingSuggestions = suggestions   // single publish
        hasSuggestedFiling = true
    }

    /// True when Filing may use its intelligent backend (on-device LLM / cloud). Default on; the app
    /// only injects a classifier when one is actually available, so this gates a present backend.
    public static let usesAIDefaultsKey = "tidyFilingUseAI"
    var filingUsesAI: Bool {
        (filingContentDefaults.object(forKey: Self.usesAIDefaultsKey) as? Bool) ?? true
    }

    /// Opt-in: prefer the cloud (Claude) classifier over the on-device model when a key is present.
    /// Off by default — sends folder names + file names (and contents, if reading is on) to Anthropic.
    public static let usesCloudDefaultsKey = "tidyFilingUseCloud"
    /// Which Claude model the cloud classifier uses (a model-ID string). Trades cost against quality;
    /// defaults to the best model.
    public static let cloudModelDefaultsKey = "tidyFilingCloudModel"

    private static func modificationYear(_ date: Date?) -> String? {
        guard let date else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.year], from: date).year.map(String.init)
    }

    /// Runs the injected snippet extractor over the given paths with bounded concurrency.
    nonisolated static func extractSnippets(
        for paths: [String], using extractor: @escaping @Sendable (String) async -> String?,
        maxConcurrent: Int = 4
    ) async -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        var result: [String: String] = [:]
        var next = 0
        await withTaskGroup(of: (String, String?).self) { group in
            func schedule(_ p: String) { group.addTask { (p, await extractor(p)) } }
            let initial = min(maxConcurrent, paths.count)
            while next < initial { schedule(paths[next]); next += 1 }
            for await (path, text) in group {
                if let text, !text.isEmpty { result[path] = text }
                if Task.isCancelled { group.cancelAll(); continue }
                if next < paths.count { schedule(paths[next]); next += 1 }
            }
        }
        return result
    }

    /// True when Filing may read file contents (on-device) to improve suggestions. Default on.
    public static let readContentsDefaultsKey = "tidyFilingReadContents"
    var filingReadsContents: Bool {
        (filingContentDefaults.object(forKey: Self.readContentsDefaultsKey) as? Bool) ?? true
    }

    // MARK: Remembered rules (F3)

    /// Where remembered filing rules are persisted (JSON, in `filingRuleDefaults`).
    public static let rulesDefaultsKey = "tidyFilingRules"

    /// The rules the user has taught by correcting suggestions. Persisted across scans and sessions.
    public var filingRules: [FilingRule] {
        get {
            guard let data = filingRuleDefaults.data(forKey: Self.rulesDefaultsKey),
                  let rules = try? JSONDecoder().decode([FilingRule].self, from: data) else { return [] }
            return rules
        }
        set { filingRuleDefaults.set(try? JSONEncoder().encode(newValue), forKey: Self.rulesDefaultsKey) }
    }

    /// Rules whose destination lives inside `providerRoot` — the only ones safe to apply to a scan
    /// of that provider (a rule's destination is an absolute path in one provider's tree).
    func filingRules(under providerRoot: URL) -> [FilingRule] {
        let root = providerRoot.path
        return filingRules.filter { $0.destinationPath == root || $0.destinationPath.hasPrefix(root + "/") }
    }

    /// Learns a rule from a correction: "file <fileName> here" becomes "files like this go here."
    /// No-op (returns false) when the filename yields nothing distinctive to key on.
    @discardableResult
    public func rememberFilingRule(fileName: String, contentTokens: Set<String> = [], destinationPath: String) -> Bool {
        guard let rule = FilingEngine.rule(forFileNamed: fileName, contentTokens: contentTokens,
                                           filedInto: destinationPath) else { return false }
        var rules = filingRules
        rules.removeAll { $0.tokens == rule.tokens }   // newest destination for a trigger wins
        rules.append(rule)
        filingRules = rules
        return true
    }

    /// Forgets one remembered rule.
    public func forgetFilingRule(_ rule: FilingRule) {
        filingRules.removeAll { $0.id == rule.id }
    }

    /// Forgets every remembered rule.
    public func clearFilingRules() { filingRules = [] }

    /// Runs the injected content extractor over the given paths with bounded concurrency.
    nonisolated static func extractContent(
        for paths: [String], using extractor: @escaping @Sendable (String) async -> Set<String>,
        maxConcurrent: Int = 4
    ) async -> [String: Set<String>] {
        guard !paths.isEmpty else { return [:] }
        var result: [String: Set<String>] = [:]
        var next = 0
        await withTaskGroup(of: (String, Set<String>).self) { group in
            func schedule(_ p: String) { group.addTask { (p, await extractor(p)) } }
            let initial = min(maxConcurrent, paths.count)
            while next < initial { schedule(paths[next]); next += 1 }
            for await (path, tokens) in group {
                if !tokens.isEmpty { result[path] = tokens }
                if Task.isCancelled { group.cancelAll(); continue }
                if next < paths.count { schedule(paths[next]); next += 1 }
            }
        }
        return result
    }

    /// Clears suggestions (e.g. when switching providers).
    public func clearFiling() {
        filingScanTask?.cancel()
        filingSuggestions = []
        filingScanFolder = nil
        hasSuggestedFiling = false
    }

    // MARK: Apply

    private enum FilingOutcome { case moved(MoveItemState); case noMoveNeeded; case failed }

    /// Moves the suggestion's file into the chosen destination, creating any new folders in the
    /// path, and drops it from the list. Reversible with Undo (⌘Z). Never overwrites — a name
    /// collision keeps both by uniquifying.
    @discardableResult
    public func applyFilingSuggestion(_ suggestion: FilingSuggestion, to destination: FilingDestination,
                                      remember: Bool = false) async -> Bool {
        switch await performFiling(suggestion, to: destination) {
        case .moved(let move):
            // Remember only on an actual move — a rule keyed on where the file already lived is noise.
            if remember { rememberFilingRule(fileName: suggestion.fileName, destinationPath: destination.path) }
            registerMoveUndo(items: [move], actionName: "File \(suggestion.fileName)", fileManager: fileManager)
            let folderName = (destination.path as NSString).lastPathComponent
            banner = .success("Filed “\(suggestion.fileName)” → \(folderName). Press ⌘Z to undo")
            return true
        case .noMoveNeeded:
            return true   // the chosen folder is where the file already lives — nothing to do
        case .failed:
            return false
        }
    }

    /// Files every batch-eligible suggestion (a confident home derived from the filename) into its
    /// best destination, as one undoable batch.
    public func applyRecommendedFiling() async {
        let batch = filingSuggestions.filter { $0.isBatchEligible }
        guard !batch.isEmpty else { return }
        var moves: [MoveItemState] = []
        var failures = 0
        for s in batch {
            guard let dest = s.best else { continue }
            switch await performFiling(s, to: dest) {
            case .moved(let move): moves.append(move)
            case .noMoveNeeded: break
            case .failed: failures += 1
            }
        }
        guard !moves.isEmpty else {
            if failures > 0 { banner = .warning("Couldn't file \(failures) file\(failures == 1 ? "" : "s").") }
            return
        }
        // One undo action reverts the whole batch, so ⌘Z is honest.
        registerMoveUndo(items: moves, actionName: "File \(moves.count) Items", fileManager: fileManager)
        let n = moves.count
        banner = failures > 0
            ? .warning("Filed \(n) file\(n == 1 ? "" : "s"); \(failures) couldn't be filed. Press ⌘Z to undo")
            : .success("Filed \(n) file\(n == 1 ? "" : "s"). Press ⌘Z to undo")
    }

    /// Removes a suggestion without moving anything ("Not here" / leave it).
    public func dismissFilingSuggestion(_ suggestion: FilingSuggestion) {
        filingSuggestions.removeAll { $0.id == suggestion.id }
    }

    /// The move + list-drop (no undo registration — the caller registers, so a batch is one undo).
    private func performFiling(_ suggestion: FilingSuggestion, to destination: FilingDestination) async -> FilingOutcome {
        let fm = fileManager
        let src = URL(fileURLWithPath: suggestion.filePath)
        let destFolder = URL(fileURLWithPath: destination.path)

        // No-op: the chosen folder IS the file's current folder — leave it, don't rename to "(2)".
        if destFolder.standardizedFileURL.path == src.deletingLastPathComponent().standardizedFileURL.path {
            filingSuggestions.removeAll { $0.id == suggestion.id }
            return .noMoveNeeded
        }

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
            return .failed
        }
        filingSuggestions.removeAll { $0.id == suggestion.id }
        return .moved((from: src, to: moved, overwritten: outcome.overwritten))
    }
}
