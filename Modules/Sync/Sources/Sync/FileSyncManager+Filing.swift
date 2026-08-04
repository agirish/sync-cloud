import Events
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

    /// The phase a running Filing scan is in. Suggestions are published once, at the very end of the
    /// scan, so the results stay empty while phases 2–3 (on-device content + intelligent homes) keep
    /// refining. Surfacing the phase — and, for the slow later passes, "suggestions still improving" —
    /// through `filingScanStatus` keeps the scanning view from reading as finished before it is. This
    /// is additive: it only shapes the status string, it doesn't change what the scan does.
    public enum FilingScanPhase: Sendable, Equatable {
        /// Phase 1 — reading the loose files in the picked folder.
        case scanningFolder(String)
        /// Phase 1 — walking the provider to learn its folder taxonomy.
        case learningFolders
        /// Phase 2 — reading document contents on-device for files with no confident home.
        case readingContent(Int)
        /// Phase 3 — the intelligent classifier reasoning about the best homes.
        case findingHomes
        /// A single-file "Try another" re-ask (not part of the initial scan's phase sequence).
        case lookingForDifferent

        /// The user-facing status line shown in the scanning view.
        public var status: String {
            switch self {
            case .scanningFolder(let name):
                return "Phase 1 · scanning \(name)…"
            case .learningFolders:
                return "Phase 1 · learning your folders…"
            case .readingContent(let n):
                return "Phase 2 · reading \(n) document\(n == 1 ? "" : "s") — suggestions still improving"
            case .findingHomes:
                return "Phase 3 · finding the best homes — suggestions still improving"
            case .lookingForDifferent:
                return "Looking for a different folder…"
            }
        }
    }

    // MARK: Scan

    /// Starts a cancellable Filing scan, replacing any in-flight one. `providerName` resolves the
    /// `{provider}` token in automation destinations that steer the suggestions.
    ///
    /// `nameProvider` is the ruleset the same pass checks names against (see
    /// ``detectRiskyNames(in:root:provider:)``). Optional so callers that only want suggestions —
    /// the CLI, tests — opt out rather than being forced to name a provider they don't have.
    /// `ignoringCache` is the "Rescan (ignore cache)" path: it skips READING cached verdicts, so
    /// every file is put back to the backend, while still WRITING the fresh answers so the next
    /// ordinary scan benefits. That asymmetry is the point — the user asked for a fresh opinion,
    /// not for the cache to be turned off.
    public func startFindFilingSuggestions(folder: URL, providerRoot: URL, providerName: String? = nil,
                                           nameProvider: CloudProvider.ProviderType? = nil,
                                           ignoringCache: Bool = false,
                                           options: FilingOptions = .init()) {
        filingScanTask = restartedScanTask(replacing: filingScanTask) { [weak self] in
            await self?.findFilingSuggestions(folder: folder, providerRoot: providerRoot,
                                              providerName: providerName, nameProvider: nameProvider,
                                              ignoringCache: ignoringCache, options: options)
        }
    }

    /// Cancels a running Filing scan; suggestions are left as they were.
    public func cancelFindFilingSuggestions() { filingScanTask?.cancel() }

    /// Reads the loose files in `folder`, learns the provider's folder taxonomy, and produces
    /// suggested homes.
    public func findFilingSuggestions(
        folder: URL, providerRoot: URL, providerName: String? = nil,
        nameProvider: CloudProvider.ProviderType? = nil, ignoringCache: Bool = false,
        options: FilingOptions = .init(), fileManager fm: FileManaging? = nil
    ) async {
        guard !isSuggestingFiles else { return }
        let fileManager = fm ?? self.fileManager
        // Ask the provider's own volume how it folds case, so the engine's "already in this
        // folder" test agrees with what `performFiling` will actually do on that disk. Callers
        // that pin the option themselves (tests) keep their answer.
        var options = options
        if !options.caseSensitiveVolume {
            options.caseSensitiveVolume = Self.volumeSupportsCaseSensitiveNames(for: providerRoot)
        }
        let epoch = beginScan(\.filingScanLifecycle,
                              status: FilingScanPhase.scanningFolder(folder.lastPathComponent).status)
        // Start warming the AI backend now, so its cold-start overlaps the walk + content phases.
        if filingUsesAI, filingClassifier != nil { filingClassifierPrewarm?() }
        defer {
            endScan(\.filingScanLifecycle)
        }

        // Loose files = the direct files sitting in the picked folder (not its subfolders).
        let looseTree = await Self.buildTree(url: folder, sortOption: .name, fileManager: fileManager, maxDepth: 1)
        let looseFiles = looseTree.filter { !$0.isDirectory }
        if Task.isCancelled { return }

        updateScan(\.filingScanLifecycle, epoch: epoch, status: FilingScanPhase.learningFolders.status)
        let taxonomy = await Self.buildTree(url: providerRoot, sortOption: .name, fileManager: fileManager, maxDepth: nil)
        if Task.isCancelled { return }

        // Names, on the pass that is already here. This walk covers the whole provider — the same
        // ground the standalone Rename scan used to cover — so folding the check in loses no
        // coverage, only the trip. Published before the suggestions so the finding is on screen
        // as soon as it is known rather than waiting on classification.
        if let nameProvider {
            await detectRiskyNames(in: taxonomy, root: providerRoot, provider: nameProvider)
            if Task.isCancelled { return }
        }

        // The user's rules steer the suggestions. Automations are the one rule system; the legacy
        // remembered-rule store (F3) is consulted only until the one-time migration into
        // Automations has run, so an un-migrated install (tests, CLI) behaves exactly as before.
        ensureAutomationRulesLoaded()
        let automations = automationRules
        let rules = filingRuleDefaults.bool(forKey: Self.filingRulesMigratedKey)
            ? [] : filingRules(under: providerRoot)
        let scanClock = Date()

        // Rules that read the file's text get it here, with the same gating the Automations
        // preview uses: only files where a content condition could still FLIP an enabled rule's
        // outcome are read. This keeps the two surfaces in agreement — a rule that matches a file
        // in the lens preview matches it here — at zero cost when no rule reads content.
        var automationSnippets: [String: String] = [:]
        if filingReadsContents, let extractor = filingSnippetExtractor,
           automations.contains(where: { $0.enabled && $0.isRunnable && $0.requiresContent }) {
            let contentRules = automations.filter { $0.enabled && $0.isRunnable && $0.requiresContent }
            let candidates = looseFiles.filter { file in
                let facts = FilingEngine.automationFacts(for: file)
                return contentRules.contains {
                    !AutomationEvaluator.matches($0, facts, now: scanClock)
                        && AutomationEvaluator.couldMatchPendingContent($0, facts, now: scanClock)
                }
            }
            if !candidates.isEmpty {
                updateScan(\.filingScanLifecycle, epoch: epoch,
                           status: FilingScanPhase.readingContent(candidates.count).status)
                automationSnippets = await Self.extractSnippets(for: candidates.map { $0.id }, using: extractor)
                if Task.isCancelled { return }
            }
        }
        // Rejected folders per file — a "Try another" earlier said "not there"; never re-suggest it.
        let scopedRejections = filingRejections(under: providerRoot)
        var rejectedByFile: [String: Set<String>] = [:]
        for f in looseFiles {
            // Token-keyed persisted rejections plus this session's path-keyed ones — the latter are
            // the only record for token-less filenames, which can't persist a rejection.
            let paths = Self.rejectedPaths(forFileNamed: f.name, in: scopedRejections)
                .union(filingSessionRejections[f.id] ?? [])
            if !paths.isEmpty { rejectedByFile[f.id] = paths }
        }
        // Cache the taxonomy for single-file re-asks (Try another).
        let taxonomyFolders = FilingEngine.relativeFolderPaths(of: taxonomy)
        filingLastProviderRoot = providerRoot.path
        filingLastTaxonomyFolders = taxonomyFolders
        // Uncapped set for new-vs-existing marking on a re-ask (matches the main path's limit: .max).
        filingLastExistingFolders = Set(FilingEngine.relativeFolderPaths(of: taxonomy, limit: .max))

        // Phase 1 — filename + metadata + your taxonomy + your rules (not published yet).
        var suggestions = FilingEngine.suggest(looseFiles: looseFiles, taxonomy: taxonomy,
                                               providerRoot: providerRoot.path, rules: rules,
                                               automations: automations, providerName: providerName,
                                               automationSnippets: automationSnippets, now: scanClock,
                                               rejectedByFile: rejectedByFile, options: options)
        if Task.isCancelled { return }

        // Phase 2 — for the files with no confident home, read their contents on-device and
        // re-suggest with those tokens merged in.
        if filingReadsContents, let extractor = filingContentExtractor {
            let unsure = suggestions.filter { !$0.hasConfidentHome }
            if !unsure.isEmpty {
                updateScan(\.filingScanLifecycle, epoch: epoch,
                           status: FilingScanPhase.readingContent(unsure.count).status)
                let content = await Self.extractContent(for: unsure.map { $0.filePath }, using: extractor)
                if Task.isCancelled { return }
                if !content.isEmpty {
                    suggestions = FilingEngine.suggest(looseFiles: looseFiles, taxonomy: taxonomy,
                                                       providerRoot: providerRoot.path, contentTokens: content,
                                                       rules: rules, automations: automations,
                                                       providerName: providerName,
                                                       automationSnippets: automationSnippets, now: scanClock,
                                                       rejectedByFile: rejectedByFile, options: options)
                }
            }
        }

        if Task.isCancelled { return }

        // What the classification phase reused, published with the results below rather than as it
        // happens — same discipline as `filingScanFolder`: a cancelled scan must not relabel the
        // previous results with its own numbers.
        var cacheReuse: FilingCacheReuse?

        // Phase 3 — intelligent classification. Reasons about the folder taxonomy + document text
        // to pick a home, overriding the keyword guess for the files it's confident about. An
        // explicit remembered rule (F3) still wins, and a backend that declines/errors never makes
        // things worse than the keyword engine alone.
        if filingUsesAI, let classifier = filingClassifier {
            let remembered = Set(suggestions.filter { $0.best?.remembered == true }.map { $0.filePath })
            // Same ignoredNames/minFileSize filters the suggestion engine applied: an
            // unfiltered list sent ".DS_Store" & co. into the PAID request (name in the
            // prompt, a slot against the classification cap) and any verdict for them was
            // discarded anyway — no suggestion exists for filtered names. Junk-heavy folders
            // pushed real files past the cap, losing their classification outright.
            let toClassify = looseFiles.filter {
                !remembered.contains($0.id)
                    && !options.ignoredNames.contains($0.name)
                    && ($0.fileSize ?? 0) >= options.minFileSize
            }
            if !toClassify.isEmpty {
                updateScan(\.filingScanLifecycle, epoch: epoch,
                           status: FilingScanPhase.findingHomes.status)

                // Split against the verdict cache BEFORE anything else in this phase. The ordering
                // is the whole value of the cache, not an optimization detail: a hit must not have
                // its contents read (that is OCR/PDF work), must not occupy a slot against the
                // classifier's per-scan file cap, and above all must not be PRICED — the spend
                // preflight below quotes a figure the user approves, and quoting for files that
                // are not going to be sent would make that figure a lie.
                let existingRelative = filingLastExistingFolders
                let excludedByFile = Dictionary(uniqueKeysWithValues: toClassify.map { f in
                    (f.id, (rejectedByFile[f.id] ?? []).compactMap { Self.relativePath($0, under: providerRoot.path) })
                })
                // nil ⇒ the cache is off for this scan, read and write both. `ignoringCache` is
                // deliberately NOT part of this: it suppresses the read below while leaving the
                // write intact.
                let identity: String? = filingReusesVerdicts
                    ? (filingBackendIdentity?() ?? configuredFilingBackendIdentity) : nil
                var keysByFile: [String: FilingVerdictKey] = [:]
                var cachedVerdicts: [String: FilingVerdict] = [:]
                var misses = toClassify
                if let identity {
                    let cache = ignoringCache ? nil : loadedFilingVerdictCache()
                    misses = []
                    for f in toClassify {
                        let key = FilingVerdictKey(
                            filePath: f.id, modificationDate: f.modificationDate, size: f.fileSize ?? 0,
                            model: identity, promptVersion: CloudFilingProtocol.promptVersion,
                            excludedRelativePaths: excludedByFile[f.id] ?? [])
                        keysByFile[f.id] = key
                        if let hit = cache?.verdict(for: key, providerRoot: providerRoot.path,
                                                    existingRelative: existingRelative) {
                            cachedVerdicts[f.id] = hit
                        } else {
                            misses.append(f)
                        }
                    }
                }

                var snippets: [String: String] = [:]
                if filingReadsContents, let extractor = filingSnippetExtractor, !misses.isEmpty {
                    // Only read contents for files whose NAME says nothing — a meaningful name plus
                    // the folder tree is enough for the model, and this skips OCR/PDF work (and the
                    // token cost) for the common named-file case.
                    let namelessPaths = misses.filter { !FilingEngine.canRemember(fileName: $0.name) }.map { $0.id }
                    snippets = await Self.extractSnippets(for: namelessPaths, using: extractor)
                    if Task.isCancelled { return }
                }
                let files = misses.map { f -> FilingCandidateFile in
                    FilingCandidateFile(filePath: f.id, fileName: f.name,
                                        ext: (f.name as NSString).pathExtension.lowercased(),
                                        year: Self.modificationYear(f.modificationDate),
                                        contentSnippet: snippets[f.id],
                                        excludedRelativePaths: excludedByFile[f.id] ?? [])
                }

                // Cloud spend guardrail (X6): the true cost of a cloud (Claude) call is only known
                // AFTER it runs, so when cloud is the active backend, estimate it up front and let the
                // user — or the monthly budget cap — decline before it commits. Only gates the cloud
                // path; the on-device backend is free and never asked. A decline (user cancelled, or
                // this month's spend would exceed the cap) skips the classifier entirely, leaving the
                // scan's on-device suggestions untouched — a graceful, non-empty fallback that still
                // publishes below. No-op when cloud is off (the common case), and with the default
                // confirmer that returns true.
                var verdicts = cachedVerdicts
                if !files.isEmpty, cloudSpendAllows(files: files, taxonomyFolders: taxonomyFolders) {
                    let fresh = await classifier(taxonomyFolders, files)
                    if Task.isCancelled { return }
                    // Fresh wins on the (impossible today) overlap: a file is in exactly one of
                    // the two sets by construction, but stating the precedence keeps that a
                    // property of this line rather than of the partition above.
                    verdicts.merge(fresh) { _, new in new }
                    // `keysByFile` is empty exactly when the cache is off, so this is a no-op then
                    // — no second check of `identity` needed to say the same thing twice.
                    recordFilingVerdicts(fresh, keys: keysByFile, providerRoot: providerRoot.path,
                                         existingRelative: existingRelative)
                }
                if !cachedVerdicts.isEmpty {
                    cacheReuse = FilingCacheReuse(reused: cachedVerdicts.count, classified: files.count)
                    Logger.shared.info("Filing: reused \(cachedVerdicts.count) of \(toClassify.count) classification(s) "
                        + "from cache, \(files.count) sent to the backend")
                }
                suggestions = FilingEngine.applyVerdicts(verdicts, to: suggestions, taxonomy: taxonomy,
                                                         providerRoot: providerRoot.path, rejectedByFile: rejectedByFile)
            }
        }

        if Task.isCancelled { return }
        self.publishFilingSuggestions(suggestions)   // single publish
        // Published with the results, not at scan start: the folder labels what's on screen, and a
        // cancelled rescan of a different folder must not relabel the previous results.
        filingScanFolder = folder.path
        filingLastCacheReuse = cacheReuse
        hasSuggestedFiling = true
        let homed = suggestions.filter { $0.hasConfidentHome }.count
        let steered = suggestions.filter { $0.best?.remembered == true }.count
        Logger.shared.info("Filing: scanned \(folder.lastPathComponent) — \(suggestions.count) loose file(s), "
            + "\(homed) with a suggested home\(steered > 0 ? ", \(steered) steered by your rules" : "")")
    }

    /// True when Filing may use its intelligent backend (on-device LLM / cloud). Default on; the app
    /// only injects a classifier when one is actually available, so this gates a present backend.
    public static let usesAIDefaultsKey = "tidyFilingUseAI"
    var filingUsesAI: Bool {
        (filingContentDefaults.object(forKey: Self.usesAIDefaultsKey) as? Bool) ?? true
    }

    /// Opt-in: prefer the cloud (Claude) classifier over the on-device model when a key is present.
    /// Off by default — sends folder names + file names (and contents, if reading is on) to Anthropic.
    // `nonisolated`: these are immutable defaults-key strings, main-actor-isolated only by
    // living on `FileSyncManager`. Background callers (the cloud/on-device classifiers, the
    // app's startup read) crossed an actor boundary to read a constant.
    public nonisolated static let usesCloudDefaultsKey = "tidyFilingUseCloud"
    /// Whether Filing may use the opt-in cloud (Claude) backend. Off by default; mirrors `filingUsesAI`
    /// (both must be on, plus a stored key, for a cloud call to run). Read through the injectable
    /// defaults store so tests can flip it without touching `.standard`.
    var filingUsesCloud: Bool {
        (filingContentDefaults.object(forKey: Self.usesCloudDefaultsKey) as? Bool) ?? false
    }
    /// Which Claude model the cloud classifier uses (a model-ID string). Trades cost against quality;
    /// defaults to Haiku, the cheapest model (see `CloudFilingProtocol.defaultModel` and the
    /// matching Settings picker default).
    // `nonisolated`: these are immutable defaults-key strings, main-actor-isolated only by
    // living on `FileSyncManager`. Background callers (the cloud/on-device classifiers, the
    // app's startup read) crossed an actor boundary to read a constant.
    public nonisolated static let cloudModelDefaultsKey = "tidyFilingCloudModel"

    /// Monthly budget cap for cloud (Claude) Filing spend, in USD. 0 (the default) = no cap /
    /// unlimited — the user is never surprise-blocked. When > 0 and this calendar month's spend
    /// would exceed it, cloud calls pause and Filing falls back to its on-device suggestions.
    // `nonisolated`: these are immutable defaults-key strings, main-actor-isolated only by
    // living on `FileSyncManager`. Background callers (the cloud/on-device classifiers, the
    // app's startup read) crossed an actor boundary to read a constant.
    public nonisolated static let monthlyBudgetCapKey = "tidyFilingMonthlyBudgetUSD"

    /// Total (lifetime) budget cap for cloud (Claude) Filing spend, in USD. Unlike the monthly cap,
    /// this ships ON by default (`defaultTotalBudgetCapUSD`) as a safety backstop — a runaway or
    /// forgotten cloud setup can't quietly rack up unbounded lifetime spend. 0 = off/unlimited.
    public nonisolated static let totalBudgetCapKey = "tidyFilingTotalBudgetUSD"

    /// Default total (lifetime) cap applied when the user has never set one. Kept in sync with the
    /// Settings picker's default; read through `totalBudgetCap(in:)` so an absent key means "$5 cap",
    /// not `UserDefaults.double`'s 0 (which would read as "off"). `nonisolated` (like `totalBudgetCapKey`)
    /// so the belt-and-suspenders cap check in `CloudFilingClassifier` can read it off the main actor.
    public nonisolated static let defaultTotalBudgetCapUSD = 5.0

    /// The effective total (lifetime) cap for a defaults store. An ABSENT key means the user hasn't
    /// chosen — apply the shipped `$5` default; a present value (including an explicit `0` = "Off")
    /// is honored as-is. This is why the total cap can't just use `defaults.double(forKey:)`.
    public nonisolated static func totalBudgetCap(in defaults: UserDefaults) -> Double {
        defaults.object(forKey: totalBudgetCapKey) == nil ? defaultTotalBudgetCapUSD
                                                          : defaults.double(forKey: totalBudgetCapKey)
    }

    /// Decides whether the cloud (Claude) classifier may run for this batch. Returns true immediately
    /// when cloud is off (the on-device path is free — never gated). When cloud is on, it builds a
    /// pre-flight cost estimate (`FilingSpendPreflight`) from this month's and lifetime spend, the
    /// monthly + total caps, and the batch's estimated tokens, consults `filingCloudSpendConfirmer`,
    /// and returns its answer — logging when a
    /// call is skipped so a paused/declined scan is auditable. Returning false here leaves the scan's
    /// on-device suggestions in place (graceful fallback).
    private func cloudSpendAllows(files: [FilingCandidateFile], taxonomyFolders: [String]) -> Bool {
        guard filingUsesCloud else { return true }
        // Resolve the same way the classifier does, so the cost the user confirms is priced for the
        // model the call will actually name.
        let model = CloudFilingProtocol.currentModel(
            for: filingContentDefaults.string(forKey: Self.cloudModelDefaultsKey) ?? CloudFilingProtocol.defaultModel)
        let estTokens = CloudFilingProtocol.estimateTokens(taxonomyFolders: taxonomyFolders, files: files)
        let estCost = CloudFilingProtocol.estimatedCostUSD(
            model: model, taxonomyFolders: taxonomyFolders, files: files) ?? 0
        // Spend and caps must come from the SAME store, or the preflight compares this month's
        // spend in one place against a cap set in another. Production resolves both to `.standard`;
        // reading the spend from the hard-coded default while the caps honoured the injectable one
        // meant only a test could tell them apart — which is precisely why it went unnoticed.
        let monthlySpent = FilingSpendBudget.monthlySpend(
            entries: FilingSpendStore.entries(defaults: filingContentDefaults), now: Date())
        let totalSpent = FilingSpendStore.totals(defaults: filingContentDefaults).costUSD
        let monthlyCap = filingContentDefaults.double(forKey: Self.monthlyBudgetCapKey)
        let totalCap = Self.totalBudgetCap(in: filingContentDefaults)
        let preflight = FilingSpendPreflight(
            fileCount: files.count, model: model,
            estInputTokens: estTokens.input, estOutputTokens: estTokens.output,
            estCostUSD: estCost, monthlySpentUSD: monthlySpent, monthlyCapUSD: monthlyCap,
            totalSpentUSD: totalSpent, totalCapUSD: totalCap)
        if filingCloudSpendConfirmer(preflight) { return true }
        let monthNote = monthlyCap > 0 ? " / month cap \(FilingSpendFormat.cost(monthlyCap))" : ""
        let totalNote = totalCap > 0 ? " / total cap \(FilingSpendFormat.cost(totalCap))" : ""
        Logger.shared.info("Filing: cloud classify skipped for \(files.count) file(s) — spend guardrail declined (est \(FilingSpendFormat.cost(estCost)), this month \(FilingSpendFormat.cost(monthlySpent))\(monthNote), lifetime \(FilingSpendFormat.cost(totalSpent))\(totalNote))")
        return false
    }

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

    // MARK: Verdict cache

    /// What the last Filing scan's classification phase got for free. `classified` is what was
    /// actually sent to the backend, so `reused + classified` is the number of files that needed
    /// an answer — not the number of loose files, which also includes those a rule already steered.
    public struct FilingCacheReuse: Sendable, Equatable {
        public let reused: Int
        public let classified: Int
        public init(reused: Int, classified: Int) {
            self.reused = reused
            self.classified = classified
        }
    }

    /// Whether Filing may reuse a cached classifier verdict for an unchanged file. Default ON —
    /// the key already carries everything the answer depended on, so reuse is not a tradeoff
    /// between speed and correctness, and leaving it off would mean re-paying for answers that
    /// cannot have changed. The switch exists for the user who wants every scan asked afresh.
    public static let reuseVerdictsDefaultsKey = "tidyFilingReuseVerdicts"
    var filingReusesVerdicts: Bool {
        (filingContentDefaults.object(forKey: Self.reuseVerdictsDefaultsKey) as? Bool) ?? true
    }

    /// The identity recorded for a verdict the on-device model produced.
    public static let onDeviceBackendIdentity = "on-device"

    /// The backend identity derivable from settings alone — what ``filingBackendIdentity`` falls
    /// back to when the app has not supplied one (the CLI and tests, neither of which has a
    /// Keychain downgrade to account for). Resolved through `currentModel` so a stored id from
    /// before a model refresh keys the same as the model that will actually run.
    var configuredFilingBackendIdentity: String {
        guard filingUsesCloud else { return Self.onDeviceBackendIdentity }
        let model = CloudFilingProtocol.currentModel(
            for: filingContentDefaults.string(forKey: Self.cloudModelDefaultsKey) ?? CloudFilingProtocol.defaultModel)
        return "cloud:" + model
    }

    /// The cache, read from disk at most once per launch and then held in memory. An unset
    /// ``filingVerdictCacheURL`` yields a permanently empty cache — every lookup misses.
    func loadedFilingVerdictCache() -> FilingVerdictCache {
        if let cached = filingVerdictCache { return cached }
        let loaded = filingVerdictCacheURL.map { FilingVerdictStore.load(from: $0) } ?? FilingVerdictCache()
        filingVerdictCache = loaded
        return loaded
    }

    /// Records this scan's fresh verdicts and writes the cache back. Only files present in `keys`
    /// are recorded, which is what keeps a cache-disabled scan from writing.
    func recordFilingVerdicts(_ verdicts: [String: FilingVerdict], keys: [String: FilingVerdictKey],
                              providerRoot: String, existingRelative: Set<String>, now: Date = Date()) {
        guard !verdicts.isEmpty, !keys.isEmpty, let url = filingVerdictCacheURL else { return }
        var cache = loadedFilingVerdictCache()
        var recorded = 0
        for (path, verdict) in verdicts {
            guard let key = keys[path] else { continue }
            cache.record(verdict, for: key, providerRoot: providerRoot,
                         existingRelative: existingRelative, now: now)
            recorded += 1
        }
        guard recorded > 0 else { return }
        cache.trim()
        filingVerdictCache = cache
        FilingVerdictStore.save(cache, to: url)
    }

    /// Forgets cached verdicts — all of them, or just those under `providerRoot`. The next scan
    /// re-asks the backend, which for the cloud backend means paying again; the UI that offers
    /// this should say so.
    public func clearFilingVerdictCache(under providerRoot: String? = nil) {
        guard let url = filingVerdictCacheURL else { return }
        var cache = loadedFilingVerdictCache()
        let before = cache.count
        if let providerRoot {
            cache.removeAll(under: providerRoot)
        } else {
            cache = FilingVerdictCache()
        }
        filingVerdictCache = cache
        FilingVerdictStore.save(cache, to: url)
        Logger.shared.info("Filing: cleared \(before - cache.count) cached classification(s)")
    }

    /// How many verdicts are cached — for the Settings readout.
    public var filingVerdictCacheCount: Int { loadedFilingVerdictCache().count }

    /// True when Filing may read file contents (on-device) to improve suggestions. Default on.
    public static let readContentsDefaultsKey = "tidyFilingReadContents"
    var filingReadsContents: Bool {
        (filingContentDefaults.object(forKey: Self.readContentsDefaultsKey) as? Bool) ?? true
    }

    // MARK: Remembering rules (learned by example)

    /// Where the legacy remembered filing rules (F3) persist (JSON, in `filingRuleDefaults`). The
    /// store is read for the one-time migration into Automations — and consulted by scans only
    /// until that migration has run — but no new rules are ever written to it.
    public static let rulesDefaultsKey = "tidyFilingRules"

    /// Set once ``migrateFilingRulesToAutomations(providerRoots:)`` has converted the legacy F3
    /// store; scans then steer from automations alone.
    public static let filingRulesMigratedKey = "tidyFilingRulesMigratedToAutomations"

    /// The legacy remembered rules (F3). Kept readable for the migration and the pre-migration
    /// scan path; the old data stays in defaults untouched afterwards as a backup.
    public var filingRules: [FilingRule] {
        get {
            FileSyncManager.decodePersistedStore([FilingRule].self, from: filingRuleDefaults,
                                                 key: Self.rulesDefaultsKey,
                                                 describing: "remembered filing rules") ?? []
        }
        set {
            FileSyncManager.writePersistedStore(newValue, to: filingRuleDefaults,
                                                key: Self.rulesDefaultsKey,
                                                describing: "remembered filing rules")
        }
    }

    /// Legacy rules whose destination lives inside `providerRoot` — the only ones safe to apply to
    /// a scan of that provider (a rule's destination is an absolute path in one provider's tree).
    func filingRules(under providerRoot: URL) -> [FilingRule] {
        let root = providerRoot.path
        // Disabled rules (G1) stay persisted/editable in the manager but are inert for scans.
        return filingRules.filter { $0.enabled && PathBoundary.contains($0.destinationPath, under: root) }
    }

    /// Learns an automation from a correction: "file <fileName> here" becomes a *mentions*-rule —
    /// "files that mention these words go here" — using the same distinctive-anchor token derivation
    /// remembered rules (F3) always used. The destination is stored as the **absolute** path that
    /// was filed into, exactly as F3 stored it, so a learned rule stays scoped to the provider
    /// containing that folder and can never batch-file into another provider (a rule can be made
    /// portable by editing its destination to a provider-relative template). Re-teaching the same
    /// trigger replaces the old destination rather than duplicating. Returns the saved rule so the
    /// caller can open it for review; nil when the filename yields nothing distinctive to key on.
    @discardableResult
    public func rememberAutomationRule(fileName: String, contentTokens: Set<String> = [],
                                       destinationPath: String) -> AutomationRule? {
        guard let derived = FilingEngine.rule(forFileNamed: fileName, contentTokens: contentTokens,
                                              filedInto: destinationPath) else { return nil }
        ensureAutomationRulesLoaded()
        let condition = AutomationCondition.mentionsAll(derived.tokens)
        // Newest destination for a trigger wins — replace any rule keyed on exactly these words,
        // through the logging remover so the audit trail shows the old rule going away.
        for stale in automationRules.filter({ $0.conditions == [condition] }) {
            removeAutomationRule(id: stale.id)
        }
        let rule = AutomationRule(name: derived.tokens.map(\.capitalized).joined(separator: " "),
                                  matchMode: .all, conditions: [condition], destinationTemplate: destinationPath)
        upsertAutomationRule(rule)
        return rule
    }

    /// One-time migration: every legacy remembered rule (F3) becomes an automation with a single
    /// `mentionsAll` condition — the same tokens, the same **absolute** destination, the same
    /// enabled state — so the rules the user taught keep steering Organize (scoped to the same
    /// provider they always were) and become visible/editable in the Automations lens. Idempotent
    /// via ``filingRulesMigratedKey``; the legacy store is left in place (unconsulted) as a backup.
    public func migrateFilingRulesToAutomations() {
        guard !filingRuleDefaults.bool(forKey: Self.filingRulesMigratedKey) else { return }
        // Read through the three-way result, not the `?? []` getter. This is the one caller whose
        // decision is IRREVERSIBLE: marking the migration done is a one-way flag, and line ~113
        // never consults the legacy store again. An unreadable store read as "no rules" would
        // therefore orphan every remembered rule the user ever taught, permanently, on the strength
        // of a decode that failed once — and the backup this leaves behind is only bytes in
        // defaults, with nothing that can put them back. So: stand down and try again next launch.
        let legacyRead = FileSyncManager.readPersistedStore([FilingRule].self, from: filingRuleDefaults,
                                                            key: Self.rulesDefaultsKey,
                                                            describing: "remembered filing rules")
        guard case .decoded(let legacy) = legacyRead else {
            if case .unreadable = legacyRead {
                Logger.shared.error(
                    "Not migrating remembered filing rules: the saved rules could not be read. "
                    + "Leaving them in place and will retry on the next launch.")
            } else {
                filingRuleDefaults.set(true, forKey: Self.filingRulesMigratedKey)
            }
            return
        }
        guard !legacy.isEmpty else {
            filingRuleDefaults.set(true, forKey: Self.filingRulesMigratedKey)
            return
        }
        ensureAutomationRulesLoaded()
        var migrated = 0
        for rule in legacy {
            let condition = AutomationCondition.mentionsAll(rule.tokens)
            guard !automationRules.contains(where: { $0.conditions == [condition] && $0.destinationTemplate == rule.destinationPath })
            else { continue }
            upsertAutomationRule(AutomationRule(name: rule.tokens.map(\.capitalized).joined(separator: " "),
                                                enabled: rule.enabled, matchMode: .all,
                                                conditions: [condition], destinationTemplate: rule.destinationPath))
            migrated += 1
        }
        filingRuleDefaults.set(true, forKey: Self.filingRulesMigratedKey)
        Logger.shared.info("Migrated \(migrated) remembered filing rule(s) into Automations — manage them under Tidy ▸ Automations")
    }

    // MARK: Rejections + "Try another" (negative feedback)

    /// Where remembered rejections are persisted (JSON, in `filingRuleDefaults`).
    public static let rejectionsDefaultsKey = "tidyFilingRejections"

    /// Folders the user has rejected for files, so suggestions never re-offer them.
    public var filingRejections: [FilingRejection] {
        get {
            FileSyncManager.decodePersistedStore([FilingRejection].self, from: filingRuleDefaults,
                                                 key: Self.rejectionsDefaultsKey,
                                                 describing: "remembered filing rejections") ?? []
        }
        set {
            FileSyncManager.writePersistedStore(newValue, to: filingRuleDefaults,
                                                key: Self.rejectionsDefaultsKey,
                                                describing: "remembered filing rejections")
        }
    }

    /// Rejections whose folder lives inside `providerRoot`.
    func filingRejections(under providerRoot: URL) -> [FilingRejection] {
        let root = providerRoot.path
        return filingRejections.filter { PathBoundary.contains($0.path, under: root) }
    }

    /// The absolute folder paths rejected for a file — a rejection matches when its trigger tokens
    /// are all present in the filename's salient tokens (mirrors how F3 rules match).
    nonisolated static func rejectedPaths(forFileNamed name: String, in rejections: [FilingRejection]) -> Set<String> {
        let fileTokens = Set(FilingEngine.salientTokens(ofFileNamed: name))
        guard !fileTokens.isEmpty else { return [] }
        var out: Set<String> = []
        for r in rejections where !r.tokens.isEmpty && Set(r.tokens).isSubset(of: fileTokens) {
            out.insert(r.path)
        }
        return out
    }

    /// Records that the user rejected `destinationPath` for a file like `fileName`.
    @discardableResult
    public func rememberFilingRejection(fileName: String, destinationPath: String) -> Bool {
        let tokens = FilingEngine.salientTokens(ofFileNamed: fileName)
        guard !tokens.isEmpty else { return false }
        let rejection = FilingRejection(tokens: tokens, path: destinationPath)
        var all = filingRejections
        guard !all.contains(rejection) else { return true }
        all.append(rejection)
        filingRejections = all
        return true
    }

    public func clearFilingRejections() { filingRejections = [] }

    /// Absolute folder path → relative to `root`, or nil if not STRICTLY under it. Thin wrapper
    /// over ``PathBoundary/relativize(_:under:)`` that keeps this call's historical exact-match
    /// behavior: `path == root` returns nil here (the callers build classifier exclusion lists,
    /// where the provider root itself has never been an entry), not `""`.
    nonisolated static func relativePath(_ path: String, under root: String) -> String? {
        guard let rel = PathBoundary.relativize(path, under: root), !rel.isEmpty else { return nil }
        return rel
    }

    /// "Try another": the user rejected the current suggested folder. Records the rejection, then
    /// shows the next non-rejected candidate the file already has — or, when those are exhausted,
    /// re-asks the backend for a genuinely different folder (excluding everything rejected).
    public func tryAnotherFolder(for suggestion: FilingSuggestion) async {
        guard let rejected = suggestion.best else { return }
        // One re-ask per card at a time: the button fires an unstructured Task per click, and a
        // second click while the classifier is out would start a second round-trip whose
        // late-returning result overwrote the first's. Re-entrant calls for the same suggestion
        // are ignored — the first click's answer is the one the card shows.
        guard filingTryAnotherInFlight[suggestion.id] == nil else { return }
        let invocation = UUID()
        filingTryAnotherInFlight[suggestion.id] = invocation
        defer {
            // Release only what this invocation still owns. The id is the file's absolute path —
            // stable across scans and provider switches — so after `clearFiling()` released this
            // entry mid-round-trip, a recreated card's NEW re-ask can hold the same key under its
            // own token. An unconditional remove here would strip that round-trip's guard while
            // it is still out, re-opening the exact two-round-trips race this set exists to
            // prevent.
            if filingTryAnotherInFlight[suggestion.id] == invocation {
                filingTryAnotherInFlight.removeValue(forKey: suggestion.id)
            }
        }
        // The persisted (token-keyed) rejection is best-effort — token-less filenames can't store
        // one. The session set, keyed by file path, is what guarantees the click always takes
        // effect: the rejected folder never comes back for this file, whatever its name.
        rememberFilingRejection(fileName: suggestion.fileName, destinationPath: rejected.path)
        filingSessionRejections[suggestion.filePath, default: []].insert(rejected.path)

        // Every folder rejected for this file (this session's + persisted).
        let fileTokens = Set(FilingEngine.salientTokens(ofFileNamed: suggestion.fileName))
        let allRejected = Set(filingRejections
            .filter { !$0.tokens.isEmpty && Set($0.tokens).isSubset(of: fileTokens) }
            .map { $0.path })
            .union(filingSessionRejections[suggestion.filePath] ?? [])

        // Cycle to the next candidate the file already carries.
        let remaining = suggestion.candidates.filter { !allRejected.contains($0.path) }
        if !remaining.isEmpty {
            replaceFilingSuggestion(suggestion.id, candidates: remaining)
            return
        }

        // Out of local ideas — re-ask the backend for one different folder, if one is available.
        // The cached root/taxonomy must belong to this suggestion's provider: a scan of another
        // provider (even a cancelled one) overwrites the cache, and resolving against it would
        // build — and then move the file into — a destination in the wrong provider's tree.
        guard filingUsesAI, let classifier = filingClassifier,
              let root = filingLastProviderRoot, root == suggestion.providerRoot,
              !filingLastTaxonomyFolders.isEmpty else {
            replaceFilingSuggestion(suggestion.id, candidates: [])   // card falls back to "Choose a folder…"
            return
        }
        // Snapshot the cached folder sets at the same point `root` was validated: a Filing scan
        // of another provider (or `clearFiling()`) during the classifier round-trip swaps or
        // empties them, and reading the live properties after the await would label the verdict
        // against the WRONG provider's folders — an emptied set marks EVERY segment new, so the
        // "Creates N new folders." confirmation lies. Everything after the await uses only
        // these locals, which are consistent with the validated `root` by construction.
        let taxonomyFolders = filingLastTaxonomyFolders
        let existingFoldersSnapshot = filingLastExistingFolders
        // "Try another" is a re-ask, not a scan, so it may only BORROW the status line while the
        // Filing lens is idle. Writing it unconditionally overwrote a running rescan's own phase
        // text, and the `defer` then blanked the line while that scan was still going — leaving the
        // scanning view with no status until its next update. Epoch-scoped like every other status
        // write (see `updateScan`): if a scan starts while the classifier is out, it owns the line
        // and this re-ask neither sets nor clears it. The epoch is the right currency for the
        // STATUS LINE specifically — a cancelled scan clears the line in its `defer` and bumps the
        // epoch there, which is exactly when this re-ask must stop clearing it. It is the wrong
        // currency for the RESULT write; that one uses the generation, below.
        let preAwaitEpoch = filingScanLifecycle.epoch
        // The pre-await marker for "the list my verdict is about is still the list on screen".
        // See ``filingSuggestionsGeneration``: it counts wholesale republishes only, so a scan
        // that was CANCELLED — which never reaches the publish, and deliberately leaves the old
        // cards standing — does not invalidate this verdict, though it did bump the epoch twice.
        let preAwaitGeneration = filingSuggestionsGeneration
        let ownsStatusLine = !filingScanLifecycle.isRunning
        if ownsStatusLine {
            filingScanStatus = FilingScanPhase.lookingForDifferent.status
        }
        defer {
            if ownsStatusLine, filingScanLifecycle.epoch == preAwaitEpoch {
                filingScanStatus = nil
            }
        }
        let excluded = allRejected.compactMap { Self.relativePath($0, under: root) }
        let file = FilingCandidateFile(filePath: suggestion.filePath, fileName: suggestion.fileName,
                                       ext: (suggestion.fileName as NSString).pathExtension.lowercased(),
                                       year: Self.modificationYear(suggestion.modificationDate),
                                       contentSnippet: nil, excludedRelativePaths: excluded)
        let verdicts = await classifier(taxonomyFolders, [file])
        // The verdict was computed against THIS invocation's pre-await snapshots — its taxonomy,
        // its rejections, its session. If the filing state moved on while the classifier was out,
        // the card now on screen (same id: the stable file path) belongs to the NEW state, and
        // writing the old verdict into it is a stale overwrite. Two ways the state moves on, two
        // checks: `clearFiling()` (provider switch) releases this invocation's entry, so the
        // token no longer matches; a Filing rescan never touches the in-flight dictionary but
        // does republish the list, which bumps the generation. Either way, drop the result — the
        // defer above still releases only what this invocation owns.
        guard filingTryAnotherInFlight[suggestion.id] == invocation,
              filingSuggestionsGeneration == preAwaitGeneration else { return }
        // Mark new-vs-existing against the FULL folder set (uncapped), so a real folder beyond the
        // classifier's cap isn't mislabeled as one to create. Fall back to the (capped) list sent
        // to the classifier if the full set wasn't captured. Both from the pre-await snapshots —
        // see above.
        let existingFolders = existingFoldersSnapshot.isEmpty ? Set(taxonomyFolders) : existingFoldersSnapshot
        if let verdict = verdicts[suggestion.filePath],
           let dest = FilingEngine.destination(from: verdict, providerRoot: root,
                                               existingRelative: existingFolders),
           !allRejected.contains(dest.path) {
            replaceFilingSuggestion(suggestion.id, candidates: [dest])
        } else {
            replaceFilingSuggestion(suggestion.id, candidates: [])
        }
    }

    /// The one way to WHOLESALE replace the published suggestion list. Bumps
    /// ``filingSuggestionsGeneration`` with the assignment so the two can never drift — see that
    /// property for why per-item edits are excluded.
    func publishFilingSuggestions(_ suggestions: [FilingSuggestion]) {
        filingSuggestions = suggestions
        filingSuggestionsGeneration &+= 1
    }

    /// Replaces a suggestion's candidates in place (keeps the card, updates its shown home).
    private func replaceFilingSuggestion(_ id: String, candidates: [FilingDestination]) {
        guard let i = filingSuggestions.firstIndex(where: { $0.id == id }) else { return }
        let s = filingSuggestions[i]
        filingSuggestions[i] = FilingSuggestion(filePath: s.filePath, fileName: s.fileName, size: s.size,
                                                modificationDate: s.modificationDate, candidates: candidates,
                                                providerRoot: s.providerRoot)
    }

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
        publishFilingSuggestions([])
        filingScanFolder = nil
        filingLastCacheReuse = nil
        hasSuggestedFiling = false
        filingLastProviderRoot = nil
        filingLastTaxonomyFolders = []
        filingLastExistingFolders = []
        filingSessionRejections = [:]
        // The re-ask guard too. `tryAnotherFolder` releases its own entry in a `defer`, but only
        // if it returns: `FilingClassifier` has no timeout, so a round-trip that never comes back
        // leaves the entry latched forever and every later "Try another" for that card is a
        // silent no-op. Clearing here is the ONLY recovery hatch: a Filing rescan assigns
        // `filingSuggestions` directly and never touches this dictionary, so a latched card
        // survives any number of rescans — only a provider switch (the one caller of this
        // function) frees it. Clearing wholesale is safe because every release and result write
        // in `tryAnotherFolder` is ownership-checked against its invocation token: a still-out
        // round-trip whose entry is cleared here can neither strip a successor's guard in its
        // defer nor land its stale verdict in a recreated card.
        filingTryAnotherInFlight = [:]
    }

    // MARK: Apply

    private enum FilingOutcome { case moved(MoveItemState); case noMoveNeeded; case failed }

    /// The outcome of a single `applyFilingSuggestion`. The `moved` / `notNeeded` distinction lets a
    /// caller act only on a real move (e.g. offering a learned rule, or the remember-override prompt)
    /// without re-deriving "did it move?" from a path comparison — the manager is the single source of
    /// truth. `notNeeded` is still a success: the file is where the caller asked, just already there.
    public enum FilingApplyResult: Sendable, Equatable {
        /// The file was moved into the destination (and the list row dropped).
        case moved
        /// The chosen folder is where the file already lives — nothing to do (success, no move).
        case notNeeded
        /// The move was refused (Verify All in flight) or failed; the file stayed put.
        case failed
    }

    /// Moves the suggestion's file into the chosen destination, creating any new folders in the
    /// path, and drops it from the list. Reversible with Undo (⌘Z). Never overwrites — a name
    /// collision keeps both by uniquifying.
    /// - Returns: `.moved` on a real move, `.notNeeded` when the file already lives there, `.failed`
    ///   when refused or the move errored.
    @discardableResult
    public func applyFilingSuggestion(_ suggestion: FilingSuggestion, to destination: FilingDestination,
                                      remember: Bool = false) async -> FilingApplyResult {
        // Verify All's exclusion guard, mirrored in the write direction (same rationale as
        // syncFile's): filing moves a file Verify All may be hashing.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before filing")
            return .failed
        }
        switch await performFiling(suggestion, to: destination) {
        case .moved(let move):
            // Remember only on an actual move — a rule keyed on where the file already lived is
            // noise. The log reports what actually happened: derivation can decline (a token-less
            // name), and claiming "remembered" then would be a lie in the audit trail.
            var remembered = false
            if remember {
                remembered = rememberAutomationRule(fileName: suggestion.fileName,
                                                    destinationPath: destination.path) != nil
            }
            registerMoveUndo(items: [move], actionName: "File \(suggestion.fileName)", fileManager: fileManager)
            let folderName = (destination.path as NSString).lastPathComponent
            banner = .success("Filed “\(suggestion.fileName)” → \(folderName). Press ⌘Z to undo", undoable: true)
            Logger.shared.info("Filing: filed “\(suggestion.fileName)” → \(folderName)\(remembered ? " (remembered as a rule)" : "")")
            return .moved
        case .noMoveNeeded:
            return .notNeeded   // the chosen folder is where the file already lives — nothing to do
        case .failed:
            return .failed
        }
    }

    /// Files every batch-eligible suggestion (a confident home derived from the filename) into its
    /// best destination, as one undoable batch.
    /// Every suggestion eligible for the blind batch, unfiltered — the honest "all of them" scope.
    /// The Organize lens deliberately does NOT pass this: its button scopes to whatever the search
    /// left on screen (see `applyRecommendedFiling`).
    public var batchEligibleFilingSuggestions: [FilingSuggestion] {
        filingSuggestions.filter { $0.isBatchEligible }
    }

    /// Files the batch-eligible suggestions among `scope` into their suggested homes.
    ///
    /// `scope` is REQUIRED for the same reason as `applyRecommendedDuplicates`: a search can now
    /// narrow this list, so a method that recomputed its own targets from the unfiltered
    /// `filingSuggestions` would move files the button never counted and the user could not see.
    /// The count on the button and the array iterated here are one value, passed in. Eligibility
    /// is still re-checked here, so a caller can't talk this into filing an unsure suggestion.
    public func applyRecommendedFiling(_ scope: [FilingSuggestion]) async {
        // Verify All's exclusion guard, mirrored in the write direction (same rationale as
        // syncFile's): filing moves files Verify All may be hashing.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before filing")
            return
        }
        let batch = scope.filter { $0.isBatchEligible }
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
        Logger.shared.info("Filing: filed \(n) file(s)\(failures > 0 ? ", \(failures) couldn't be filed" : "")")
        banner = failures > 0
            ? .warning("Filed \(n) file\(n == 1 ? "" : "s"); \(failures) couldn't be filed. Press ⌘Z to undo", undoable: true)
            : .success("Filed \(n) file\(n == 1 ? "" : "s"). Press ⌘Z to undo", undoable: true)
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
        // Case-folded per the volume: an exact comparison let a case-variant destination through
        // to the move below, where `fileExists` collapsed the case, found the file itself, and the
        // unique-name step renamed it in place while the banner reported a successful filing.
        if PathBoundary.namesSameDirectory(
            destFolder.path,
            src.deletingLastPathComponent().path,
            caseSensitive: FileSyncManager.volumeSupportsCaseSensitiveNames(for: src)
        ) {
            filingSuggestions.removeAll { $0.id == suggestion.id }
            return .noMoveNeeded
        }

        let logger = Logger.shared   // captured on the main actor; its methods are nonisolated
        let anchor = Self.filingAnchor(for: destination, under: suggestion.providerRoot)
        let outcome: FilingMoveOutcome = await enqueueFileOperation {
            do {
                guard fm.fileExists(atPath: src.path) else { return .failed(reason: nil) }
                // One stat, before any I/O — the guard `transferItems` has always had and filing
                // never did. `createDirectory(withIntermediateDirectories:)` below builds the WHOLE
                // path, so a destination tree that has gone away since the scan (a provider
                // unmounted, an external volume ejected) is silently RECREATED as an ordinary local
                // folder. This is a MOVE: the file would leave a live tree to sit in a dead one the
                // provider never syncs, under a success banner.
                //
                // Stat'ing the ANCHOR rather than the leaf is what makes the check precise: only
                // the folders `newSegments` names are ours to create, so everything above them must
                // already be there. See `filingAnchor(for:under:)` for how the anchor is derived and
                // why it is clamped. For a destination the user browsed to (`newSegments` empty) the
                // anchor IS the folder, which is exactly right: if it vanished between the pick and
                // the apply, refusing beats re-creating it.
                guard fm.fileExists(atPath: anchor.path) else {
                    throw FileOperationError.destinationRootUnavailable
                }
                try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                var dst = destFolder.appendingPathComponent(suggestion.fileName)
                if fm.fileExists(atPath: dst.path) {
                    dst = FileSyncManager.generateUniqueURL(for: dst, fileManager: fm)
                }
                let overwritten = try FileSyncManager.safeMoveItem(at: src, to: dst, fileManager: fm)
                return .moved(to: dst, overwritten: overwritten)
            } catch {
                // Record the cause — the generic alert below can't carry it.
                logger.warning("Filing: moving “\(suggestion.fileName)” into \(destFolder.lastPathComponent) failed: \(error.localizedDescription)")
                // A vanished destination tree is a condition the user can act on ("plug the volume
                // back in / rescan"), unlike a generic I/O failure — so it gets to say so instead
                // of being flattened into "couldn't file this item".
                let reason = (error as? FileOperationError) == .destinationRootUnavailable
                    ? error.localizedDescription
                    : nil
                return .failed(reason: reason)
            }
        }

        switch outcome {
        case .failed(let reason):
            present(.syncFailed(item: suggestion.fileName, path: suggestion.filePath,
                                reason: reason ?? "Couldn't file this item; it was left in place."))
            return .failed
        case .moved(let dst, let overwritten):
            filingSuggestions.removeAll { $0.id == suggestion.id }
            return .moved((from: src, to: dst, overwritten: overwritten))
        }
    }

    /// What the enqueued move actually did. An enum rather than a tuple because the tuple it
    /// replaced carried the same fact twice — `movedTo == nil` and `failed == true` always agreed,
    /// and nothing stopped a future edit from returning a destination alongside `failed: true`.
    private enum FilingMoveOutcome: Sendable {
        case moved(to: URL, overwritten: URL?)
        /// `reason` is user-facing when the failure is one the user can act on; nil falls back to
        /// the generic "couldn't file this item".
        case failed(reason: String?)
    }

    /// The folder a filing destination's new segments hang off — the part that must ALREADY exist,
    /// because everything below it is what `createDirectory` is being asked to create.
    ///
    /// Walking up one level per entry in `newSegments` is the whole rule, but it trusts a
    /// scan-time list, so it is clamped to the provider root. Without the clamp an over-long
    /// `newSegments` walks past the root and saturates at "/", which always exists — turning a
    /// data-safety guard into a tautology exactly when its input is wrong. `FilingEngine` builds
    /// `newSegments` as a suffix of the destination's own segments, so today it cannot over-count;
    /// the clamp is what keeps that a property of THIS function rather than of a caller far away.
    ///
    /// The clamp only applies when the destination is genuinely under the root, so a picker choice
    /// on another volume is still checked at its own anchor. An EMPTY `providerRoot` is treated as
    /// no root at all — `URL(fileURLWithPath: "")` resolves against the process working directory,
    /// so clamping to it would aim the guard at a completely unrelated folder.
    nonisolated static func filingAnchor(for destination: FilingDestination,
                                         under providerRoot: String?) -> URL {
        let destFolder = URL(fileURLWithPath: destination.path)
        let walked = destination.newSegments.reduce(destFolder) { url, _ in url.deletingLastPathComponent() }
        guard let providerRoot, !providerRoot.isEmpty,
              PathBoundary.contains(destFolder.path, under: providerRoot) else { return walked }
        return PathBoundary.contains(walked.path, under: providerRoot)
            ? walked
            : URL(fileURLWithPath: providerRoot)
    }
}
