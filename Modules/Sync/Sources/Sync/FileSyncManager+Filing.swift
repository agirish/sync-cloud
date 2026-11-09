import Events
import Foundation
import UniformTypeIdentifiers

/// Filing: suggests where loose files belong within one provider and moves them there. Loose files
/// come from a folder the user points at; destinations can be anywhere in the provider, learned
/// from the existing folder tree. Moves reuse the safe-move and Undo path of every other file
/// operation.
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

    /// The phase a running Filing scan is in. Suggestions are published once, at the end, so the
    /// results stay empty while phases 2–3 (on-device content, intelligent homes) keep refining.
    /// Showing the phase, and "suggestions still improving" for the slow later passes, through
    /// `filingScanLifecycle.status` keeps the scanning view from reading as finished too early. It
    /// shapes only the status string, not what the scan does.
    public enum FilingScanPhase: Sendable, Equatable {
        /// Phase 1: reading the loose files in the picked folder.
        case scanningFolder(String)
        /// Phase 1: walking the provider to learn its folder taxonomy.
        case learningFolders
        /// Phase 2: reading document contents on-device for files with no confident home.
        case readingContent(Int)
        /// Phase 3: the intelligent classifier reasoning about the best homes.
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

        /// How the phase is named when a scan reports where it stopped. Not ``status``: that is a
        /// progress line for mid-scan ("… suggestions still improving"), which reads as a claim
        /// about the future in a log sentence about a scan that has given up.
        var logLabel: String {
            switch self {
            case .scanningFolder(let name): return "scanning \(name)"
            case .learningFolders: return "learning the folder taxonomy"
            case .readingContent(let n): return "reading \(n) document\(n == 1 ? "" : "s")"
            case .findingHomes: return "finding the best homes"
            case .lookingForDifferent: return "looking for a different folder"
            }
        }
    }

    // MARK: Scan

    /// Starts a cancellable Filing scan, replacing any in-flight one. `providerName` resolves the
    /// `{provider}` token in automation destinations that steer the suggestions.
    ///
    /// `nameProvider` is the ruleset the same pass checks names against (see
    /// ``detectRiskyNames(in:root:provider:)``). Optional so callers that only want suggestions
    /// (the CLI, tests) needn't name a provider they don't have. `ignoringCache` is the "Rescan
    /// (ignore cache)" path: it skips reading cached verdicts, so every file goes back to the
    /// backend, but still writes the fresh answers so the next ordinary scan benefits. The user
    /// asked for a fresh opinion, not for the cache to be turned off.
    public func startFindFilingSuggestions(folder: URL, providerRoot: URL, providerName: String? = nil,
                                           nameProvider: CloudProvider.ProviderType? = nil,
                                           ignoringCache: Bool = false,
                                           reportsTreeFindings: Bool = true,
                                           options: FilingOptions = .init()) {
        filingScanTask = restartedScanTask(replacing: filingScanTask) { [weak self] in
            guard let self else {
                // A started scan can also produce nothing this way, with no trace inside the scan:
                // `restartedScanTask` waits for the previous scan to unwind first, so a manager
                // torn down in that window takes the scan with it.
                Logger.shared.info("Filing: scan of \(folder.lastPathComponent) dropped before it "
                    + "began — the sync manager went away while the previous scan was unwinding")
                return
            }
            await self.findFilingSuggestions(folder: folder, providerRoot: providerRoot,
                                             providerName: providerName, nameProvider: nameProvider,
                                             ignoringCache: ignoringCache,
                                             reportsTreeFindings: reportsTreeFindings, options: options)
        }
    }

    /// Cancels a running Filing scan; suggestions are left as they were.
    public func cancelFindFilingSuggestions() { filingScanTask?.cancel() }

    /// Re-runs the Filing scan on lens open, when `folder` is exactly what the last completed
    /// scan covered. Consent and idempotence work as in
    /// ``autoRescanDuplicatesIfEligible(root:options:)``: a remembered target, then
    /// `hasSuggestedFiling`, `isSuggestingFiles` and the per-target latch against the callers'
    /// overlapping triggers.
    ///
    /// No money question here or inside the scan: a scan classifies only at
    /// ``FilingClassifierTier/free``, and the cloud backend is reachable only from the refine pass,
    /// which is a click. Predicting the route instead would be worse, since the prediction must
    /// agree with the router, and where it doesn't (cloud on, no readable key) it would raise a
    /// payment dialog for a scan that was always free.
    ///
    /// Returns whether a scan was started, for tests.
    @discardableResult
    public func autoRescanFilingIfEligible(folder: URL, providerRoot: URL, providerName: String? = nil,
                                           nameProvider: CloudProvider.ProviderType? = nil,
                                           reportsTreeFindings: Bool = true,
                                           options: FilingOptions = .init()) -> Bool {
        guard lensScanTargetIsRemembered(folder.path, forKey: Self.lastFilingScanFolderKey),
              Self.isReachableDirectory(folder.path, fileManager: fileManager),
              !isSuggestingFiles, !hasSuggestedFiling,
              filingAutoRescanAttempted != folder.path else { return false }
        filingAutoRescanAttempted = folder.path
        Logger.shared.info("Filing: auto-rescanning \(folder.lastPathComponent) (scanned before)")
        startFindFilingSuggestions(folder: folder, providerRoot: providerRoot,
                                   providerName: providerName, nameProvider: nameProvider,
                                   reportsTreeFindings: reportsTreeFindings, options: options)
        return true
    }

    /// Whether the app's own router says a ``FilingClassifierTier/free`` classification would reach
    /// a paid backend, which would mean the app isn't honouring the tier.
    ///
    /// The free pass's guarantee is structural: it passes `.free`, and the app routes `.free` to the
    /// on-device model. This asks the app to state that rather than assuming it, since the one line
    /// of wiring that maps tier to backend is the whole guarantee and nothing in this module
    /// compiles against it. If it ever stops being true, the honest outcome is a scan with no
    /// classification phase and a loud log line, not a silent bill.
    ///
    /// With no app resolver (the CLI, tests) the answer is no by construction:
    /// ``configuredFilingBackendIdentity(for:)`` returns the on-device identity for `.free`.
    var freePassWouldReachAPaidBackend: Bool { filingRoutesToCloud(.free) }

    /// Whether a classification at `tier` will reach the paid backend.
    ///
    /// The single answer to the money question, for everything that asks it: the free-pass
    /// misroute check above, the spend guardrail and the Refine button's label. Keyed on the
    /// resolved route, not the cloud setting, because the two disagree in an ordinary state
    /// (cloud on, no readable Keychain key, so the router downgrades to on-device), and a check on
    /// the setting would raise a payment dialog for a free pass. Safe because the app's classifier
    /// uses the same router with the same inputs: if this says on-device, the call can't be billed.
    ///
    /// An `if let` on the closure, never `filingBackendIdentity?(tier) ?? …`: optional chaining
    /// flattens, so a closure that returned nil would look unset. nil means "the app can't vouch
    /// for which backend will run", and for a money gate the safe reading is to fall back on what
    /// settings configure, and so ask, rather than assume free and spend silently.
    func filingRoutesToCloud(_ tier: FilingClassifierTier) -> Bool {
        if let resolveBackend = filingBackendIdentity, let identity = resolveBackend(tier) {
            return identity.hasPrefix("cloud:")
        }
        return configuredFilingBackendIdentity(for: tier).hasPrefix("cloud:")
    }

    /// Whether to offer the cloud Refine button at all: the UI's question, before it picks between
    /// "Refine N with Opus" and the "set up Claude" invitation.
    ///
    /// Not the toggle: with cloud on and no key stored, the toggle would promise a model the router
    /// won't use, and the pass would report "no better homes found" having asked nothing. The
    /// invitation is the honest control there; it opens Settings ▸ Organize ▸ Suggestions, a jump from the key.
    ///
    /// Not the real route either (hence ``filingCloudRefineConfigured``): this is read on every
    /// render of the Organize toolbar, and resolving the route decrypts the Keychain item, which
    /// can raise the password prompt while the user types. The cheap seam answers "is a key
    /// stored", the route decides money, and the gap between them (stored but unreadable) is
    /// reported by the refine banner rather than silently believed.
    public var filingCloudRefineAvailable: Bool {
        if let configured = filingCloudRefineConfigured { return configured() }
        return filingRoutesToCloud(.refine)
    }

    /// True when the user asked for Claude but the router won't reach it: a key stored yet
    /// unreadable. The one state where ``filingCloudRefineAvailable`` and the real route disagree,
    /// so the refine pass can say so rather than quietly run on-device under a button that
    /// promised Opus.
    var filingCloudRefineIsDowngraded: Bool {
        filingUsesCloud && !filingRoutesToCloud(.refine)
    }

    /// Reads the loose files in `folder`, learns the provider's folder taxonomy, and produces
    /// suggested homes.
    ///
    /// This is the free pass, all of it. Phases 1–3 run at ``FilingClassifierTier/free``, so the
    /// whole scan, started by a click or on lens open, costs nothing and raises no spend prompt.
    /// The paid backend is reached only by ``refineFilingSuggestions(_:)``, acting on the results
    /// this publishes, so there is no cost pre-flight here: free is the only mode the scan has.
    ///
    /// Every way out of this function says so. The body is a run of `await`s and cancellation
    /// checks, and a silent `return` would leave "ran and found nothing" indistinguishable from
    /// "never ran" in the log (the conflation ``OrganizeOverviewState`` splits `clean` from
    /// `notScanned` to avoid). The reporting hangs off the `defer` that runs on every path and
    /// names the phase the scan stopped in, so a new cancellation check is covered as it is written.
    ///
    /// `reportsTreeFindings` is false when `providerRoot` isn't the source the other lenses
    /// describe, as when loose files in Home ▸ Downloads are filed into Documents in iCloud. The
    /// walk of `providerRoot` is still the taxonomy, but its risky names and rename plans are about
    /// iCloud, and published under the Home source they would answer Names and Renames for a tree
    /// that source doesn't show. So neither runs, and whatever they last said stands.
    public func findFilingSuggestions(
        folder: URL, providerRoot: URL, providerName: String? = nil,
        nameProvider: CloudProvider.ProviderType? = nil, ignoringCache: Bool = false,
        reportsTreeFindings: Bool = true,
        options: FilingOptions = .init(), fileManager fm: FileManaging? = nil
    ) async {
        // One budget per scan for the per-file read warnings (`FilingWarningBudget`): the first
        // ones each get their line, every file past them is named once the scan ends.
        let budget = FilingWarningBudget()
        await FilingWarningBudget.$current.withValue(budget) {
            await findFilingSuggestionsInScan(folder: folder, providerRoot: providerRoot, providerName: providerName,
                                              nameProvider: nameProvider, ignoringCache: ignoringCache,
                                              reportsTreeFindings: reportsTreeFindings, options: options, fileManager: fm)
        }
        for line in budget.overflowLines() { Logger.shared.warning(line) }
    }

    private func findFilingSuggestionsInScan(
        folder: URL, providerRoot: URL, providerName: String?,
        nameProvider: CloudProvider.ProviderType?, ignoringCache: Bool,
        reportsTreeFindings: Bool,
        options: FilingOptions, fileManager fm: FileManaging?
    ) async {
        guard !isSuggestingFiles else {
            // Before `beginScan`, so this exit is outside the `defer`'s reach and reports itself.
            // Not a failure: the running scan covers the same ground.
            Logger.shared.info("Filing: scan of \(folder.lastPathComponent) not started — "
                + "a Filing scan is already running")
            return
        }
        let fileManager = fm ?? self.fileManager
        // Ask the provider's own volume how it folds case, so the engine's "already in this folder"
        // test agrees with what `performFiling` will do on that disk. Callers that pin the option
        // themselves (tests) keep their answer.
        var options = options
        if !options.caseSensitiveVolume {
            options.caseSensitiveVolume = Self.volumeSupportsCaseSensitiveNames(for: providerRoot)
        }
        let epoch = beginScan(\.filingScanLifecycle,
                              status: FilingScanPhase.scanningFolder(folder.lastPathComponent).status)
        // Start warming the AI backend now, so its cold start overlaps the walk and content phases.
        if filingUsesAI, filingClassifier != nil { filingClassifierPrewarm?() }
        // The phase the scan is in, mirrored so the `defer` can name where it stopped. Kept in step
        // with the published status by `enter` below: `endScan` clears the lifecycle's own status,
        // and a user-facing progress line doesn't fit in a log sentence anyway.
        var phase = FilingScanPhase.scanningFolder(folder.lastPathComponent)
        func enter(_ next: FilingScanPhase) {
            phase = next
            updateScan(\.filingScanLifecycle, epoch: epoch, status: next.status)
        }
        // Set once, at the publish. Anything else reaching the `defer` abandoned the scan.
        var published = false
        defer {
            if !published {
                Logger.shared.info("Filing: scan of \(folder.lastPathComponent) abandoned while "
                    + "\(phase.logLabel) — \(Task.isCancelled ? "superseded by a newer scan, or cancelled" : "returned early")"
                    + "; suggestions are unchanged")
            }
            endScan(\.filingScanLifecycle)
        }

        // Loose files: the direct files sitting in the picked folder, not its subfolders.
        let looseTree = await Self.buildTree(url: folder, sortOption: .name, fileManager: fileManager, maxDepth: 1)
        let looseFiles = looseTree.filter { !$0.isDirectory }
        if Task.isCancelled { return }
        // Which of them are only in the cloud: the extractor won't open those, so their cards are
        // placed by name and say so. Published with the results below.
        let notDownloaded = await Self.cloudOnlyPaths(looseFiles.map { $0.id }, statFlags: filingStatFlags)
        if Task.isCancelled { return }

        enter(.learningFolders)
        // Budgeted first, as a probe (see `buildStorageLens`). A taxonomy missing folders the walk
        // never reached doesn't fail; it quietly suggests the wrong home, the most expensive way
        // for this pass to be wrong.
        let taxonomyProbe = NodeBudget(wholeTreeProbeBudget)
        var taxonomy = await Self.buildTree(url: providerRoot, sortOption: .name,
                                            fileManager: fileManager, maxDepth: nil, budget: taxonomyProbe)
        if Task.isCancelled { return }
        if taxonomyProbe.didStopADescent {
            let preflight = LargeWalkPreflight(pass: .filing, rootPath: providerRoot.path,
                                               probeLimit: taxonomyProbe.limit)
            guard largeWalkConfirmer(preflight) else {
                Logger.shared.info("Filing: “\(preflight.rootName)” holds more than \(preflight.probeLimit) entries — not scanned")
                return
            }
            taxonomy = await Self.buildTree(url: providerRoot, sortOption: .name,
                                            fileManager: fileManager, maxDepth: nil)
            if Task.isCancelled { return }
        }

        // Names, on the pass that is already here. This walk covers the whole provider, so folding
        // the check in loses no coverage, only a trip. Published before the suggestions so the
        // finding is on screen as soon as it is known, not after classification.
        if reportsTreeFindings, let nameProvider {
            await detectRiskyNames(in: taxonomy, root: providerRoot, provider: nameProvider)
            if Task.isCancelled { return }
        }

        // The rename backlog, on the same walk for the same reason. `RenamePlanner` is pure and reads
        // the folder profile, not the disk, so this costs one traversal of a tree already in memory.
        if reportsTreeFindings {
            await detectRenamePlans(in: taxonomy, root: providerRoot)
            if Task.isCancelled { return }
        }

        // The user's rules steer the suggestions. Automations are the one rule system.
        ensureAutomationRulesLoaded()
        let automations = automationRules
        let scanClock = Date()

        // Rules that read the file's text get it here, gated as the Automations preview gates it:
        // only files where a content condition could still flip an enabled rule's outcome are read.
        // So a rule that matches a file in the lens preview matches it here, at no cost when no rule
        // reads content.
        var automationSnippets: [String: String] = [:]
        let actingRules = AutomationRuleSet.eligible(automations).narrowed { $0.acts(in: providerRoot.path) }
        if filingReadsContents, let extractor = filingSnippetExtractor, actingRules.readsContent {
            let candidates = looseFiles.filter { file in
                let facts = FilingEngine.automationFacts(for: file, registry: filingPersonRegistry,
                                                         identity: filingPersonIdentity)
                return actingRules.contentCouldStillDecide(facts, now: scanClock)
            }
            if !candidates.isEmpty {
                enter(.readingContent(candidates.count))
                automationSnippets = await Self.extractSnippets(for: candidates.map { $0.id }, using: extractor)
                if Task.isCancelled { return }
            }
        }
        // Rejected folders per file: a "Try another" earlier said "not there"; never re-suggest it.
        let scopedRejections = filingRejections(under: providerRoot)
        var rejectedByFile: [String: Set<String>] = [:]
        for f in looseFiles {
            // Token-keyed persisted rejections plus this session's path-keyed ones, the only record
            // for token-less filenames, which can't persist a rejection.
            let paths = Self.rejectedPaths(forFileNamed: f.name, in: scopedRejections)
                .union(filingSessionRejections[f.id] ?? [])
            if !paths.isEmpty { rejectedByFile[f.id] = paths }
        }
        let rejectedWords = filingRejectedWords(under: providerRoot)
        // What the taxonomy says, worked out once and off the main actor: the classifier's capped
        // folder list, the uncapped set, and every folder's profile. Sorting and tokenizing a
        // 12,000-folder tree can hold the window for most of a second, and both of the scan's
        // `suggest` calls share the profiles.
        let providerRootPath = providerRoot.path
        let walkedTaxonomy = taxonomy
        let scanOptions = options
        let (taxonomyFolders, existingFolders, learned) = await Task.detached(priority: .userInitiated) {
            (FilingEngine.relativeFolderPaths(of: walkedTaxonomy),
             FilingEngine.relativeFolderPathSet(of: walkedTaxonomy),
             FilingEngine.learnTaxonomy(walkedTaxonomy, providerRoot: providerRootPath,
                                        options: scanOptions))
        }.value
        if Task.isCancelled { return }
        // Cache the taxonomy for single-file re-asks (Try another).
        filingLastProviderRoot = providerRoot.path
        filingLastNameProvider = nameProvider
        filingLastTaxonomyFolders = taxonomyFolders
        // Uncapped set for new-vs-existing marking on a re-ask (the main path's limit: .max).
        filingLastExistingFolders = existingFolders
        // The router reasons over the uncapped folder set: the classifier's cap bounds token cost,
        // and this pass sends nothing anywhere, so capping would hide real destinations for nothing.
        prepareFilingRouter(destinations: filingLastExistingFolders, providerRoot: providerRoot.path)

        // Phase 1: filename, metadata, your taxonomy and your rules (not published yet). Off the
        // main actor, against the taxonomy learned above; every input is a value.
        let registry = filingPersonRegistry
        let personIdentity = filingPersonIdentity
        let snippetsForRules = automationSnippets
        let rejections = rejectedByFile
        var suggestions = await Task.detached(priority: .userInitiated) {
            FilingEngine.suggest(looseFiles: looseFiles, learned: learned,
                                 providerRoot: providerRootPath,
                                 automations: automations,
                                 registry: registry,
                                 identity: personIdentity,
                                 providerName: providerName,
                                 automationSnippets: snippetsForRules, now: scanClock,
                                 rejectedByFile: rejections, rejectedWords: rejectedWords,
                                 options: scanOptions)
        }.value
        if Task.isCancelled { return }
        // What each card is about, recorded once phase 1 has built the cards, after the walk and
        // before any page is read. `performFiling` re-reads it before the move and refuses a file
        // changed since, since the path alone says only that something is there. One stat per file,
        // off the main actor, the same read the move makes, so an untouched file compares equal.
        // Kept by path in `scanIdentities`, because phase 2's re-suggest rebuilds every card.
        let identityInput = suggestions
        let identityDisk = fileManager
        suggestions = await Task.detached(priority: .userInitiated) {
            identityInput.map {
                $0.recordingSource(ItemIdentity.snapshot(at: URL(fileURLWithPath: $0.filePath),
                                                         fileManager: identityDisk))
            }
        }.value
        if Task.isCancelled { return }
        let scanIdentities = Dictionary(suggestions.map { ($0.id, $0.sourceIdentity) },
                                        uniquingKeysWith: { first, _ in first })

        // Phase 2: for the files with no confident home, read their contents on-device and
        // re-suggest with those tokens merged in.
        //
        // A page is read once and shared. Tokens are a pure function of the extracted text, so when
        // the router also wants the text, the text is read and the tokens derived from it; reading
        // twice would double the scan's most expensive work, PDF extraction.
        var routerSnippets: [String: String] = [:]
        if filingReadsContents, let extractor = filingContentExtractor {
            // Every file a backend will be asked about, not only the homeless ones: the page also
            // feeds the router and the classifier's folder menu, so a file the keyword engine
            // placed confidently would otherwise be classified from its filename alone, against a
            // menu describing everything but it (a phone bill offered a new `Finance/US/Accounts`
            // while the router, given the page, ranks its real `T-Mobile/2025` folder first). The
            // extra reads are bounded by what is being classified, and each file is read once.
            let unsure = suggestions.filter { !$0.hasConfidentHome }
            let willClassify = filingUsesAI && filingClassifier != nil && !freePassWouldReachAPaidBackend
            let readSet = willClassify
                ? suggestions.filter { s in
                    !s.hasConfidentHome || (s.best?.remembered != true
                        && !options.ignoredNames.contains(s.fileName)
                        && s.size >= options.minFileSize)
                  }
                : unsure
            if !readSet.isEmpty {
                enter(.readingContent(readSet.count))
                let content: [String: Set<String>]
                if filingRouterIndex != nil, let snippetExtractor = filingSnippetExtractor,
                   let tokenize = filingTokensFromText {
                    routerSnippets = await Self.extractSnippets(for: readSet.map { $0.filePath },
                                                               using: snippetExtractor)
                    if Task.isCancelled { return }
                    // A PDF read that gave up nothing is a scan with no text layer. Noted now, while
                    // it's known which files were read; rendering and OCR are offered, not spent
                    // (see `filingUnreadableScans`). Not a cloud-only one: it gave nothing because it
                    // wasn't opened, and Read Scan would download it to find text it may well have.
                    filingUnreadableScans = Set(readSet.map { $0.filePath }.filter {
                        routerSnippets[$0] == nil && !notDownloaded.contains($0)
                            && ($0 as NSString).pathExtension.lowercased() == "pdf"
                    })
                    // Tokenize only what the keyword pass will use. `filingTokensFromText` is
                    // NaturalLanguage named-entity recognition over up to 20,000 characters, the
                    // scan's most expensive step after extraction, and its only consumer is the
                    // re-suggest below, for files with no confident home. Tokenizing the whole wider
                    // read set would cost minutes of CPU and change suggestions for files that
                    // already had a home. The snippets stay wide; this stays narrow.
                    let unsurePaths = Set(unsure.map { $0.filePath })
                    content = routerSnippets
                        .filter { unsurePaths.contains($0.key) }
                        .compactMapValues { text in
                            let t = tokenize(text)
                            return t.isEmpty ? nil : t
                        }
                } else {
                    // No router: the keyword pass only wants tokens for the homeless files, and
                    // reading the rest would buy nothing.
                    content = await Self.extractContent(for: unsure.map { $0.filePath }, using: extractor)
                }
                if Task.isCancelled { return }
                if !content.isEmpty {
                    // Every argument phase 1 passed, plus the tokens. This re-suggest replaces the
                    // whole list, so an omitted argument is withdrawn from files already answered.
                    // Without `registry` and `identity`, `automationFacts` attributes nobody, every
                    // `personIs` condition reads false and every `{person}` destination is dropped,
                    // so hand-written rules would stop steering whenever a file's contents were read.
                    let registry = filingPersonRegistry
                    let personIdentity = filingPersonIdentity
                    suggestions = await Task.detached(priority: .userInitiated) {
                        FilingEngine.suggest(looseFiles: looseFiles, learned: learned,
                                             providerRoot: providerRootPath, contentTokens: content,
                                             automations: automations,
                                             registry: registry,
                                             identity: personIdentity,
                                             providerName: providerName,
                                             automationSnippets: snippetsForRules, now: scanClock,
                                             rejectedByFile: rejections,
                                             rejectedWords: rejectedWords, options: scanOptions)
                    }.value
                        // The identity too: `suggest` builds cards without one, and a card without
                        // one is filed with no "changed since the scan" check.
                        .map { $0.recordingSource(scanIdentities[$0.id] ?? nil) }
                }
            }
        }

        if Task.isCancelled { return }

        // One page sample, so every surface that asks who a document is about gets one answer.
        // `routerSnippets` holds up to 20,000 characters, but the published `filingPageSamples`,
        // which "Try another" and the OCR re-read hand to the cross-person rule, is truncated to
        // `contentSampleChars`. The scan's own veto calls use the same truncation, or a name printed
        // past the cut would attribute a document here and not on a re-ask. Derived once, used by
        // all three.
        let pageSamples = routerSnippets.mapValues { String($0.prefix(FilingRouter.contentSampleChars)) }

        // Phase 2.5: the tree's own profile and memory, with no model call. Reads page 1 for the
        // files still without a home and ranks destinations by what each folder already contains.
        // Skipped when no profile is loaded, the ordinary state.
        //
        // The snippets are kept: phase 3 would otherwise read the same pages again, and a PDF page
        // is the expensive part of the scan.
        var routerShortlists: [String: [String]] = [:]
        if let routerIndex = filingRouterIndex {
            // Gated on there being anything to rank, not on anything being homeless: the ranking
            // also produces the shortlists phase 3's folder menu is built from, which a scan where
            // every file has a home needs too.
            let unsure = suggestions.filter { !$0.hasConfidentHome }
            if !suggestions.isEmpty {
                // No extraction here: phase 2 already read these pages, and phase 3 reuses the same
                // strings below. One read per file, three consumers.
                let (routed, count, shortlists) = await applyRoutesYielding(
                    suggestions, index: routerIndex, snippets: routerSnippets,
                    providerRoot: providerRoot.path, rejectedByFile: rejectedByFile,
                    peerNames: peerNameLookup())
                if Task.isCancelled { return }
                suggestions = routed
                routerShortlists = shortlists
                // Of every card, not just the homeless: the router also replaces a home found by
                // matching words, so counting against the homeless alone could print "placed 8 of 7".
                if count > 0 {
                    Logger.shared.info("Filing: the folder profile placed \(count) of \(suggestions.count) "
                                       + "file(s), \(unsure.count) of which had no confident home, without a model call")
                }
            }
        }

        if Task.isCancelled { return }

        // What the classification phase reused, published with the results below rather than as it
        // happens, like `filingScanFolder`: a cancelled scan must not relabel the previous results.
        var cacheReuse: FilingCacheReuse?

        // Phase 3: intelligent classification, at the free tier. Reasons about the folder taxonomy
        // and document text to pick a home, overriding the keyword guess where it's confident. An
        // explicit remembered rule still wins, and a backend that declines or errors never makes
        // things worse than the keyword engine alone.
        //
        // `freePassWouldReachAPaidBackend` is the app's answer to "what will you route `.free` to?",
        // and a cloud answer means the tier isn't honoured. Skipping classification is the
        // conservative reading: the user gets the phase 1/2 suggestions, as with no backend at all,
        // rather than a bill for a scan that promised to be free.
        if filingUsesAI, let classifier = filingClassifier, !freePassWouldReachAPaidBackend {
            let remembered = Set(suggestions.filter { $0.best?.remembered == true }.map { $0.filePath })
            // The suggestion engine's ignoredNames and minFileSize filters: otherwise ".DS_Store" and
            // co. would go into the paid request, taking slots against the classification cap and
            // pushing real files past it, for verdicts that are discarded anyway.
            let toClassify = looseFiles.filter {
                !remembered.contains($0.id)
                    && !options.ignoredNames.contains($0.name)
                    && ($0.fileSize ?? 0) >= options.minFileSize
            }
            if !toClassify.isEmpty {
                enter(.findingHomes)

                // Split against the verdict cache before anything else in this phase. The ordering is
                // the cache's whole value: a hit must not have its contents read (OCR and PDF work)
                // and must not take a slot against the classifier's per-pass cap. On the refine pass
                // it also keeps the spend estimate honest (``refineFilingSuggestions(_:)``).
                let existingRelative = filingLastExistingFolders
                let excludedByFile = Dictionary(uniqueKeysWithValues: toClassify.map { f in
                    (f.id, (rejectedByFile[f.id] ?? []).compactMap { Self.relativePath($0, under: providerRoot.path) })
                })
                // nil means the cache is off for this scan, read and write. `ignoringCache` isn't
                // part of this: it suppresses the read below and leaves the write intact.
                let identity = resolvedFilingVerdictIdentity(for: .free)
                var keysByFile: [String: FilingVerdictKey] = [:]
                var cachedVerdicts: [String: FilingVerdict] = [:]
                var misses = toClassify
                // `artifacts` nil means the fingerprint is unavailable (an artifact exists but can't
                // be read), so the cache is off as for a nil identity: no key can honestly describe
                // the question, so nothing is looked up and, with `keysByFile` empty, nothing is
                // recorded under a digest that can never recur.
                // See `FilingProfileStore.fingerprint(id:in:)`.
                if let identity, let artifacts = filingRoutingFingerprint {
                    // Warmed even on the ignore-cache path, where the read is thrown away:
                    // `recordFilingVerdicts` still merges into the existing cache through the
                    // synchronous accessor, which would otherwise decode a file of up to ~12 MB on
                    // the main actor, mid-scan.
                    let loaded = await loadedFilingVerdictCache()
                    let cache = ignoringCache ? nil : loaded
                    misses = []
                    for f in toClassify {
                        // No key: this file's mtime or size couldn't be read, so the cache is off for
                        // it both ways; not looked up, and no `keysByFile` entry, so nothing is
                        // recorded. A miss costs a re-ask; a hit on a placeholder key, a wrong answer.
                        guard let key = FilingVerdictKey(
                            filePath: f.id, modificationDate: f.modificationDate, size: f.fileSize,
                            model: identity, promptVersion: CloudFilingProtocol.promptVersion,
                            excludedRelativePaths: excludedByFile[f.id] ?? [],
                            artifacts: artifacts) else {
                            misses.append(f)
                            continue
                        }
                        keysByFile[f.id] = key
                        if let hit = cache?.verdict(for: key, providerRoot: providerRoot.path,
                                                    existingRelative: existingRelative) {
                            cachedVerdicts[f.id] = hit
                        } else {
                            misses.append(f)
                        }
                    }
                }

                // Every page already read goes to the model; only the reading is rationed. A file
                // with a meaningful name still gets the page phase 2.5 extracted into
                // `routerSnippets`, or a visa foil would reach the backend as its filename alone.
                // New extraction is still limited to files whose name says nothing, the cost worth
                // controlling.
                var snippets: [String: String] = [:]
                if filingReadsContents, !misses.isEmpty {
                    let missPaths = Set(misses.map { $0.id })
                    snippets = routerSnippets.filter { missPaths.contains($0.key) }
                    if let extractor = filingSnippetExtractor {
                        let needed = misses.filter {
                            !FilingEngine.canRemember(fileName: $0.name) && snippets[$0.id] == nil
                        }.map { $0.id }
                        if !needed.isEmpty {
                            snippets.merge(await Self.extractSnippets(for: needed, using: extractor)) { _, new in new }
                            if Task.isCancelled { return }
                        }
                    }
                }
                let files = misses.map { f -> FilingCandidateFile in
                    FilingCandidateFile(filePath: f.id, fileName: f.name,
                                        ext: (f.name as NSString).pathExtension.lowercased(),
                                        year: Self.modificationYear(f.modificationDate),
                                        contentSnippet: snippets[f.id],
                                        excludedRelativePaths: excludedByFile[f.id] ?? [])
                }

                // No spend pre-flight: this is the free tier, with nothing to confirm. The guardrail
                // lives in ``refineFilingSuggestions(_:)``, the only pass that can reach a paid
                // backend and the one the user explicitly asks for.
                // The folder menu: what the router already thinks plausible for these files, then
                // the shallow structural list. See ``FilingEngine/classifierFolders``.
                let menu = FilingEngine.classifierFolders(
                    preferred: Self.preferredFolders(for: files, shortlists: routerShortlists,
                                                     in: suggestions, providerRoot: providerRoot.path),
                    fallback: taxonomyFolders)

                var verdicts = cachedVerdicts
                var classifiedCount = 0
                if !files.isEmpty {
                    let fresh = await classifier(filingContext(taxonomyFolders: menu), files, .free)
                    // Recorded before the cancellation check, unlike everything else in this scan:
                    // the verdicts are true whatever the scan goes on to do, and cancelling abandons
                    // the suggestions, not answers already given (on the refine pass, already
                    // billed). `keysByFile` is empty when the cache is off, so this is a no-op then.
                    recordFilingVerdicts(fresh, keys: keysByFile, providerRoot: providerRoot.path,
                                         existingRelative: existingRelative)
                    if Task.isCancelled { return }
                    classifiedCount = files.count
                    // Fresh wins on an overlap that can't happen today: a file is in one set by
                    // construction, and stating the precedence keeps that a property of this line.
                    verdicts.merge(fresh) { _, new in new }
                }
                if !cachedVerdicts.isEmpty {
                    cacheReuse = FilingCacheReuse(reused: cachedVerdicts.count, classified: classifiedCount)
                    Logger.shared.info("Filing: reused \(cachedVerdicts.count) of \(toClassify.count) classification(s) "
                        + "from cache, \(classifiedCount) sent to the backend")
                }
                // Files the backend judged without their text. The rule, including why a scan with
                // no reader yields an empty set rather than every file, is stated once, on
                // `FilingEngine.contentBlindFiles`, and called from here and the refine pass.
                let contentBlind = FilingEngine.contentBlindFiles(
                    handedOver: toClassify.map { $0.id }, read: Set(snippets.keys),
                    hadReader: filingReadsContents && filingSnippetExtractor != nil)
                suggestions = FilingEngine.applyVerdicts(verdicts, to: suggestions, taxonomy: taxonomy,
                                                         providerRoot: providerRoot.path,
                                                         nameProvider: nameProvider,
                                                         rejectedByFile: rejectedByFile,
                                                         contentBlind: contentBlind,
                                                         routerShortlists: routerShortlists,
                                                         satelliteHomes: filingSatelliteHomes,
                                                         profile: filingRoutingProfile,
                                                         registry: filingPersonRegistry,
                                                         pageSamples: pageSamples,
                                                         identity: filingPersonIdentity,
                                                         onVeto: { [weak self] refusal in
                                                             self?.recordPersonVeto(refusal)
                                                         })
            }
        }

        if Task.isCancelled { return }

        // The cross-person rule, applied to the cards rather than the model. A home can reach a card
        // without a backend verdict (the keyword engine, the router, and with no Apple Intelligence
        // those are the only two), so the veto runs on the cards. See
        // ``FilingEngine/refusingCrossPersonHomes(_:providerRoot:profile:registry:identity:pageSamples:onVeto:)``
        // for its cost.
        //
        // Last, so it sees every home this scan produced, and before the naming pass so nothing is
        // asked what a refused folder would call the file.
        suggestions = FilingEngine.refusingCrossPersonHomes(
            suggestions, providerRoot: providerRoot.path,
            profile: filingRoutingProfile, registry: filingPersonRegistry,
            identity: filingPersonIdentity, pageSamples: pageSamples,
            onVeto: { [weak self] refusal in self?.recordPersonVeto(refusal) })

        // What each file would be called once it lands, computed against the taxonomy this scan
        // walked, so the queue answers "where does this go" and "what is it called there" in one
        // pass. See `namingSuggestions`. Detached, like `detectRiskyNames` and `detectRenamePlans`:
        // it indexes every file in the provider and plans a folder per candidate, tens of
        // milliseconds on a real tree, spent just as the results publish. It touches nothing on
        // the manager, so there is nothing to hop back for.
        let namingInput = suggestions
        let namingProfile = filingRoutingProfile
        let namingRoot = providerRoot.path
        suggestions = await Task.detached(priority: .userInitiated) {
            Self.namingSuggestions(namingInput, taxonomy: taxonomy, rootPath: namingRoot,
                                   profile: namingProfile)
        }.value
        if Task.isCancelled { return }
        // Which of these the tree already holds: after the naming pass, since "already filed in X"
        // is about the document, not the name it would land under, and before the publish so the
        // queue never shows a duplicate as ordinary for a frame.
        suggestions = await markingAlreadyFiled(suggestions, providerRoot: providerRoot.path)
        if Task.isCancelled { return }
        self.publishFilingSuggestions(suggestions)   // single publish
        published = true
        // Published with the results, not at scan start: the folder labels what's on screen, and a
        // cancelled rescan of a different folder must not relabel the previous results.
        filingScanFolder = folder.path
        // The pages this scan read, kept for the rule offered after a filing move: same publish,
        // replaced rather than merged so a sample never outlives the list it describes. Truncated
        // to what the scorer was measured on, not what the extractor returned (`filingPageSamples`).
        filingPageSamples = pageSamples
        filingNotDownloaded = notDownloaded
        filingLastCacheReuse = cacheReuse
        // These results haven't been refined: the previous list's refine pass was about files no
        // longer on screen. Cleared in the same publish so the summary and its rows are never one
        // scan apart.
        filingLastRefine = nil
        filingLastRefineReport = nil
        hasSuggestedFiling = true
        // Remembered only on completion: the auto-rescan consent is "the user scanned exactly
        // this before", and a cancelled or stopped scan is not that.
        rememberLensScanTarget(folder.path, forKey: Self.lastFilingScanFolderKey)
        let homed = suggestions.filter { $0.hasConfidentHome }.count
        let steered = suggestions.filter { $0.best?.remembered == true }.count
        Logger.shared.info("Filing: scanned \(folder.lastPathComponent) — \(suggestions.count) loose file(s), "
            + "\(homed) with a suggested home\(steered > 0 ? ", \(steered) steered by your rules" : "")")
    }

    /// True when Filing may use its intelligent backend (on-device LLM or cloud). Default on; the
    /// app injects a classifier only when one is available, so this gates a present backend.
    public static let usesAIDefaultsKey = "tidyFilingUseAI"
    var filingUsesAI: Bool {
        (filingContentDefaults.object(forKey: Self.usesAIDefaultsKey) as? Bool) ?? true
    }

    /// Whether Claude can be used from Organize: a key is saved, answered by the app's cheap seam
    /// (``filingCloudRefineConfigured``). There is no switch of Organize's own (TE335, LW-A): a saved
    /// key is the opt-in, each Refine needs a click on Send, and a card's Try Another reaches Claude
    /// only for a file in a folder shared without asking. Unset (the CLI, tests) means no.
    var filingUsesCloud: Bool {
        filingCloudRefineConfigured?() ?? false
    }

    /// Decides whether the cloud (Claude) classifier may run for this batch. True at once when the
    /// pass won't reach the paid backend. Otherwise builds a cost estimate (`FilingSpendPreflight`)
    /// from this month's and lifetime spend, both caps and the batch's estimated tokens, asks
    /// `filingCloudSpendConfirmer`, and returns its answer, logging a skipped call so a paused or
    /// declined pass is auditable. False leaves the suggestions as the free scan left them.
    ///
    /// Called only from ``refineFilingSuggestions(_:)``: the scan classifies at
    /// ``FilingClassifierTier/free``, which can't route to cloud.
    ///
    /// Gated on the real route. Not on `filingUsesCloud`: cloud on with no readable key routes
    /// on-device, and would put a payment dialog in front of a pass never billed. Not on
    /// ``filingCloudRefineAvailable`` either, which only says "is a key stored", cheaply enough to
    /// ask per render. Money reads ``filingRoutesToCloud(_:)``, which resolves the route for real.
    func cloudSpendAllows(files: [FilingCandidateFile], taxonomyFolders: [String],
                          downloading: Int = 0) -> Bool {
        switch filingSpendGate(files: files, taxonomyFolders: taxonomyFolders, downloading: downloading) {
        case .notBilled:
            return true
        case .blocked:
            // Already logged with its reason by the gate.
            return false
        case .billable(let preflight):
            if filingCloudSpendConfirmer(preflight) { return true }
            let monthNote = preflight.monthlyCapUSD > 0 ? " / month cap \(FilingSpendFormat.cost(preflight.monthlyCapUSD))" : ""
            let totalNote = preflight.totalCapUSD > 0 ? " / total cap \(FilingSpendFormat.cost(preflight.totalCapUSD))" : ""
            Logger.shared.info("Filing: cloud classify skipped for \(files.count) file(s) — spend guardrail declined (est \(FilingSpendFormat.cost(preflight.estCostUSD)), this month \(FilingSpendFormat.cost(preflight.monthlySpentUSD))\(monthNote), lifetime \(FilingSpendFormat.cost(preflight.totalSpentUSD))\(totalNote))")
            return false
        }
    }

    /// The same guardrail without the dialog, for the per-card re-ask, which routes to `.refine`,
    /// the paid tier. A modal per card click would be worse than no gate, so this takes the half
    /// that isn't a conversation: an unpriced model or a cap breach refuses, with the specifics in
    /// the log, the remedy in a non-blocking banner, and the click keeping the free on-device answer.
    /// A banner, not silence: with only the log, the button would do nothing and the remedy would
    /// sit in a file the user has no reason to open.
    ///
    /// The refine pass keeps its dialog, showing a cap breach as an informational alert: it is a
    /// bulk action the user asked to price. A single card is not, and the remedy for a hit cap is
    /// the same either way: Settings ▸ Ask Claude.
    func cloudSpendWithinCapsWithoutPrompting(files: [FilingCandidateFile],
                                              taxonomyFolders: [String]) -> Bool {
        switch filingSpendGate(files: files, taxonomyFolders: taxonomyFolders) {
        case .notBilled:
            return true
        case .blocked:
            // Said on screen, not only logged: otherwise the click does nothing visible and the
            // remedy, a model with a known price, sits in the log. The gate has logged the
            // specifics; this says the sentence the user needs.
            banner = .warning("Couldn’t ask Claude for another folder — the chosen model has no "
                              + "known price, so the cost can’t be checked. Keeping the on-device "
                              + "suggestion; pick one of the offered models in the Ask Claude chat’s model menu.", log: .warn)
            return false
        case .billable(let preflight):
            guard preflight.wouldExceedCap else { return true }
            Logger.shared.info("Filing: cloud re-ask skipped — it would pass the monthly Claude limit "
                + "(est \(FilingSpendFormat.cost(preflight.estCostUSD)), this month "
                + "\(FilingSpendFormat.cost(preflight.monthlySpentUSD)) of "
                + "\(FilingSpendFormat.cost(preflight.monthlyCapUSD))). Keeping the card's suggestion; "
                + "raise the limit in Settings ▸ Ask Claude to keep using Claude.")
            // As for `.blocked` above, with a different remedy, so a different sentence.
            if filingRefineShowsBanner {
                banner = .warning("Couldn’t ask Claude for another folder — it would pass your monthly Claude "
                                  + "limit. Keeping the earlier suggestion; raise the limit in "
                                  + "Settings ▸ Ask Claude to keep using Claude.", log: .warn)
            }
            return false
        }
    }

    /// What a prospective cloud call costs, or why it must not be made. Shared by the refine pass's
    /// dialog and the re-ask's check so the two can never price a call differently.
    enum FilingSpendGate {
        /// Not routed to cloud, so nothing will be billed and nothing needs confirming.
        case notBilled
        /// Must not run, and the reason has been logged already.
        case blocked
        /// Will be billed, priced as the classifier will price it.
        case billable(FilingSpendPreflight)
    }

    func filingSpendGate(files: [FilingCandidateFile], taxonomyFolders: [String],
                                 downloading: Int = 0) -> FilingSpendGate {
        guard filingRoutesToCloud(.refine) else { return .notBilled }
        // The chat's model, priced from Ask Claude's table, so the cost confirmed is for the model the
        // call will name.
        let model = filingRefineModelID
        let estTokens = CloudFilingProtocol.estimateTokens(taxonomyFolders: taxonomyFolders, files: files)
        // An unpriced model is not a free one. `pricing(for:)` answers nil outside its
        // `claude-<family>` arms, and `currentModel(for:)` passes such an id through untouched (a
        // hand-set choice is honoured), so a typed `tidyFilingCloudModel` or an old dated id arrives
        // with no rate. Coerced to zero, the dialog would quote "$0.0000" for a call nothing here
        // can price, and `spent + estCostUSD` could never cross either cap, the default $5 lifetime
        // backstop included; nor would recorded spend catch up, since `CloudFilingClassifier`
        // records it as `estimatedCostUSD: 0, costUnpriced: true`.
        //
        // No substitute number is honest, so the pass stands down and keeps the free on-device
        // suggestions, as `CloudFilingClassifier` does when the spend record can't be read: no paid
        // call while no cap can be enforced. The log names the model, since the remedy is one
        // model-menu change away.
        guard let estCost = CloudFilingProtocol.estimatedCostUSD(
                model: model, taxonomyFolders: taxonomyFolders, files: files) else {
            Logger.shared.warning("Filing: cloud classify skipped for \(files.count) file(s) — no price "
                + "is known for model “\(model)”, so the cost could not be quoted and neither budget "
                + "cap could be enforced against it. Using the free on-device suggestions; pick one of "
                + "the offered models in the Ask Claude chat’s model menu to use Claude.")
            return .blocked
        }
        // Ask Claude's one monthly limit and this month's spend against it. The old Organize caps are
        // not read: there is no lifetime cap, so its half of the pre-flight is off.
        return .billable(FilingSpendPreflight(
            fileCount: files.count, model: model,
            estInputTokens: estTokens.input, estOutputTokens: estTokens.output,
            estCostUSD: estCost,
            monthlySpentUSD: AskClaudeSpend.spent(in: filingContentDefaults),
            monthlyCapUSD: AskClaudeSpend.limit(in: filingContentDefaults),
            totalSpentUSD: 0, totalCapUSD: 0, downloadCount: downloading))
    }

    static func modificationYear(_ date: Date?) -> String? {
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

    /// What the last Filing scan's classification phase got for free. `classified` is what was sent
    /// to the backend, so `reused + classified` is the files that needed an answer, not all loose
    /// files, which include those a rule already steered.
    public struct FilingCacheReuse: Sendable, Equatable {
        public let reused: Int
        public let classified: Int
        public init(reused: Int, classified: Int) {
            self.reused = reused
            self.classified = classified
        }
    }

    /// Whether Filing may reuse a cached classifier verdict for an unchanged file. Default on: the
    /// key carries everything the answer depended on, so reuse costs no correctness, and off would
    /// re-pay for answers that can't have changed. The switch is for a user who wants every scan
    /// asked afresh.
    public static let reuseVerdictsDefaultsKey = "tidyFilingReuseVerdicts"
    var filingReusesVerdicts: Bool {
        (filingContentDefaults.object(forKey: Self.reuseVerdictsDefaultsKey) as? Bool) ?? true
    }

    /// The identity recorded for a verdict the on-device model produced.
    // `nonisolated` like the defaults-key constants: an immutable string, main-actor-isolated only
    // by living on `FileSyncManager`, and the `@Sendable` routing closures the app and tests
    // install, which must answer `.free` with exactly this value, can't cross an actor to read it.
    public nonisolated static let onDeviceBackendIdentity = "on-device"

    /// The backend identity derivable from settings alone: what ``filingBackendIdentity`` falls back
    /// to when the app hasn't supplied one (the CLI and tests, which have no Keychain downgrade to
    /// account for). Resolved through `currentModel` so a stored id from before a model refresh keys
    /// the same as the model that will run.
    ///
    /// `.free` is the on-device identity unconditionally, not only when cloud is off: a free-pass
    /// verdict is an on-device verdict, and keyed under a cloud model's name a later refine pass
    /// would serve it back as if Claude had given it.
    func configuredFilingBackendIdentity(for tier: FilingClassifierTier) -> String {
        guard tier == .refine, filingUsesCloud else { return Self.onDeviceBackendIdentity }
        return "cloud:" + filingRefineModelID
    }

    /// The Claude model Refine, Try Another and Refine Names use: Ask Claude's, the one in the chat's
    /// menu and in Settings (TE335, JY-C). Not a model of Organize's own.
    public var filingRefineModelID: String {
        AskClaudeModels.option(for: filingContentDefaults.string(forKey: AskClaudeModels.defaultsKey)).id
    }

    /// Its short name for the Refine Names button: "Opus 5.5".
    public var filingRefineModelName: String {
        AskClaudeModels.option(for: filingContentDefaults.string(forKey: AskClaudeModels.defaultsKey)).name
    }

    /// The identity this pass's verdict cache keys on. nil turns the cache off for the pass, read
    /// and write (verdict reuse switched off, or the app's resolver declining to vouch).
    ///
    /// An `if let` on the closure, not `filingBackendIdentity?(tier) ?? …`: optional chaining
    /// flattens, so a closure that returned nil would be indistinguishable from an unset one, and
    /// `??` would answer `"cloud:<model>"` for an app that said it can't vouch for the backend,
    /// the silent substitution the seam exists to prevent. The fallback is for an unset closure
    /// (the CLI, tests) only.
    func resolvedFilingVerdictIdentity(for tier: FilingClassifierTier) -> String? {
        if !filingReusesVerdicts { return nil }
        // An `if let` on the closure, never `?? …`: a closure that answered nil means the app can't
        // vouch for the backend, and the settings' guess must not stand in for it.
        let identity: String?
        if let resolveBackend = filingBackendIdentity { identity = resolveBackend(tier) }
        else { identity = configuredFilingBackendIdentity(for: tier) }
        guard let identity else { return nil }
        // Any Claude model is one backend for saved answers (KR-C): `cloud:<model>` becomes one
        // identity, so changing the model doesn't ask every file again. The on-device model's own
        // identity is untouched.
        return identity.hasPrefix("cloud:") ? FilingVerdictKey.claudeIdentity : identity
    }

    /// The cache, read from disk at most once per launch and then held in memory. An unset
    /// ``filingVerdictCacheURL`` yields a permanently empty cache: every lookup misses. The scan's
    /// accessor: decodes off the main actor on first use, then serves the memoized copy, since
    /// `findFilingSuggestions` runs on the main actor and a decode there is a visible hitch, a large
    /// one at the entry cap.
    func loadedFilingVerdictCache() async -> FilingVerdictCache {
        if let cached = filingVerdictCache { return cached }
        guard let url = filingVerdictCacheURL else {
            let empty = FilingVerdictCache()
            filingVerdictCache = empty
            return empty
        }
        let loaded = await Task.detached(priority: .userInitiated) {
            FilingVerdictStore.load(from: url)
        }.value
        filingVerdictCache = loaded
        return loaded
    }

    /// The in-memory copy, loading synchronously only if nothing has warmed it.
    ///
    /// **Every caller must warm the memo first.** This runs on the main actor, and at
    /// ``FilingVerdictCache/maxEntries`` the file is about twelve megabytes. Both callers arrive
    /// warm: the scan awaits ``loadedFilingVerdictCache()`` before recording (on the ignore-cache
    /// path too, where the read is discarded), and the Settings readout awaits
    /// ``filingVerdictCacheCount()`` before offering `Clear`. Synchronous because both need it from
    /// a non-async position afterwards, and once warm it touches no disk.
    func filingVerdictCacheNow() -> FilingVerdictCache {
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
        var cache = filingVerdictCacheNow()
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
        FilingVerdictStore.saveInBackground(cache, to: url)
    }

    /// Forgets cached verdicts, all or just those under `providerRoot`. The next scan re-asks the
    /// backend, which for the cloud means paying again; the UI that offers this should say so.
    public func clearFilingVerdictCache(under providerRoot: String? = nil) {
        guard let url = filingVerdictCacheURL else { return }
        var cache = filingVerdictCacheNow()
        let before = cache.count
        if let providerRoot {
            cache.removeAll(under: providerRoot)
        } else {
            cache = FilingVerdictCache()
        }
        filingVerdictCache = cache
        // Through the queue, never the synchronous `save`. A scan's own write is queued there
        // (`recordFilingVerdicts`, a multi-megabyte encode at the entry cap), and a synchronous
        // write would race it: the queued pre-clear snapshot could land last, and the next launch
        // would reload every verdict just cleared. Queued, this snapshot is newest and lands last.
        FilingVerdictStore.saveInBackground(cache, to: url)
        Logger.shared.info("Filing: cleared \(before - cache.count) cached classification(s)")
    }

    /// How many verdicts are cached, for the Settings readout; the call that warms the memo for the
    /// `Clear` button beside it. Async on purpose: it is the first thing the Organize settings tab
    /// asks, and awaiting ``loadedFilingVerdictCache()`` moves the decode off the main actor once
    /// per launch, leaving every later read, ``filingVerdictCacheCountNow`` included, free.
    public func filingVerdictCacheCount() async -> Int {
        await loadedFilingVerdictCache().count
    }

    /// The same count without awaiting, for reading back an action that just wrote the memo
    /// (`Clear`). Never the first read; see ``filingVerdictCacheNow()``.
    public var filingVerdictCacheCountNow: Int { filingVerdictCacheNow().count }

    /// True when Filing may read file contents (on-device) to improve suggestions. Default on.
    public static let readContentsDefaultsKey = "tidyFilingReadContents"
    var filingReadsContents: Bool {
        (filingContentDefaults.object(forKey: Self.readContentsDefaultsKey) as? Bool) ?? true
    }

    // MARK: Remembering rules (learned by example)

    /// Learns an automation from a correction: "file <fileName> here" becomes a mentions-rule
    /// ("files that mention these words go here"), from the distinctive-anchor tokens remembered
    /// rules always used. The destination is the absolute path filed into, so a learned rule stays
    /// scoped to that provider and can never batch-file into another (editing its destination to a
    /// provider-relative template makes it portable). Re-teaching the same trigger replaces the old
    /// destination. Returns the saved rule for review; nil when the filename has nothing
    /// distinctive to key on.
    @discardableResult
    public func rememberAutomationRule(fileName: String, contentTokens: Set<String> = [],
                                       destinationPath: String) -> AutomationRule? {
        guard let derived = FilingEngine.rule(forFileNamed: fileName, contentTokens: contentTokens,
                                              filedInto: destinationPath) else { return nil }
        ensureAutomationRulesLoaded()
        let condition = AutomationCondition.mentionsAll(derived.tokens)
        // Newest destination for a trigger wins: replace any rule keyed on exactly these words,
        // through the logging remover so the audit trail shows the old rule going.
        for stale in automationRules.filter({ $0.conditions == [condition] }) {
            removeAutomationRule(id: stale.id)
        }
        let rule = AutomationRule(name: derived.tokens.map(\.capitalized).joined(separator: " "),
                                  matchMode: .all, conditions: [condition], destinationTemplate: destinationPath)
        upsertAutomationRule(rule)
        return rule
    }

    /// Proposes an automation for "this file went into that folder", with everything this scan
    /// already learned about the tree. Assembled in one place: the pages the scan read
    /// (``filingPageSamples``), the prepared profile and memory index, and the saved rules.
    /// `destinationRelativePath` is provider-relative, the domain a rule's template lives in.
    /// Nothing is saved; the caller shows the proposal and saves only if the user says so.
    public func proposeAutomationRule(fileName: String,
                                      filePath: String,
                                      destinationRelativePath: String,
                                      modificationDate: Date?,
                                      now: Date = Date()) -> AutomationRuleProposer.Proposal? {
        ensureAutomationRulesLoaded()
        let evidence = AutomationRuleProposer.Evidence(pageSample: filingPageSamples[filePath],
                                                       index: filingRouterIndex,
                                                       existingRules: automationRules)
        return AutomationRuleProposer.propose(fileName: fileName,
                                              destinationRelativePath: destinationRelativePath,
                                              evidence: evidence,
                                              modificationDate: modificationDate,
                                              now: now)
    }

    // MARK: Rejections + "Try another" (negative feedback)

    /// Where remembered rejections are persisted (JSON, in `filingRuleDefaults`).
    public nonisolated static let rejectionsDefaultsKey = "tidyFilingRejections"

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

    /// Where the word-level rejections persist, beside the whole-name ones.
    public nonisolated static let wordRejectionsDefaultsKey = "tidyFilingWordRejections"

    /// The words the user has said are no reason for a folder; see ``FilingWordRejection``.
    public var filingWordRejections: [FilingWordRejection] {
        get {
            FileSyncManager.decodePersistedStore([FilingWordRejection].self, from: filingRuleDefaults,
                                                 key: Self.wordRejectionsDefaultsKey,
                                                 describing: "remembered filing word rejections") ?? []
        }
        set {
            FileSyncManager.writePersistedStore(newValue, to: filingRuleDefaults,
                                                key: Self.wordRejectionsDefaultsKey,
                                                describing: "remembered filing word rejections")
        }
    }

    /// Word rejections for folders inside `providerRoot`, as the engine reads them: folder → words.
    func filingRejectedWords(under providerRoot: URL) -> [String: Set<String>] {
        let root = providerRoot.path
        return filingWordRejections.reduce(into: [:]) { out, r in
            if PathBoundary.contains(r.path, under: root) { out[r.path, default: []].insert(r.word) }
        }
    }

    /// Rejections whose folder lives inside `providerRoot`.
    func filingRejections(under providerRoot: URL) -> [FilingRejection] {
        let root = providerRoot.path
        return filingRejections.filter { PathBoundary.contains($0.path, under: root) }
    }

    /// The absolute folder paths rejected for a file: a rejection matches when its trigger tokens
    /// are all among the filename's salient tokens, as remembered rules match.
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
    ///
    /// With `providerRoot`, also records the words the file's name shares with that folder's path,
    /// plus `evidenceWord` (the word a content match was read on), as no reason for it: the lesson
    /// that reaches other files. Without it, only the whole-name rejection is kept.
    @discardableResult
    public func rememberFilingRejection(fileName: String, destinationPath: String,
                                        providerRoot: String? = nil,
                                        evidenceWord: String? = nil) -> Bool {
        if let providerRoot {
            var words = FilingEngine.sharedNameWords(fileName: fileName, folderPath: destinationPath,
                                                     providerRoot: providerRoot)
            if let evidenceWord { words.formUnion(FilingEngine.nameTokens(evidenceWord)) }
            let fresh = words.sorted().map { FilingWordRejection(word: $0, path: destinationPath) }
            let known = filingWordRejections
            let added = fresh.filter { !known.contains($0) }
            if !added.isEmpty { filingWordRejections = known + added }
        }
        let tokens = FilingEngine.salientTokens(ofFileNamed: fileName)
        guard !tokens.isEmpty else { return false }
        let rejection = FilingRejection(tokens: tokens, path: destinationPath)
        var all = filingRejections
        guard !all.contains(rejection) else { return true }
        all.append(rejection)
        filingRejections = all
        return true
    }

    public func clearFilingRejections() {
        filingRejections = []
        filingWordRejections = []
    }

    /// Absolute folder path → relative to `root`, or nil if not strictly under it. A wrapper over
    /// ``PathBoundary/relativize(_:under:)`` where `path == root` returns nil, not `""`: callers
    /// build classifier exclusion lists, where the provider root is never an entry.
    nonisolated static func relativePath(_ path: String, under root: String) -> String? {
        guard let rel = PathBoundary.relativize(path, under: root), !rel.isEmpty else { return nil }
        return rel
    }

    /// "Try another": the user rejected the suggested folder. Records the rejection, then shows the
    /// next non-rejected candidate the file already has, or, when those run out, re-asks the
    /// backend for a different folder (excluding everything rejected).
    ///
    /// `askingClaudeWithPage` is the click on "Ask Claude with Page 1…": for a file in a folder that
    /// asks each time it sends this one file's first page to Claude, because the person said to.
    public func tryAnotherFolder(for suggestion: FilingSuggestion, askingClaudeWithPage: Bool = false) async {
        // "Ask Claude with Page 1…" follows a Try Another this Mac answered: what it showed, or
        // nothing, was never rejected, so it asks Claude without rejecting anything more.
        let rejected = askingClaudeWithPage ? nil : suggestion.best
        guard askingClaudeWithPage || rejected != nil else { return }
        // One re-ask per card at a time: each click fires an unstructured Task, and a second
        // round-trip's late result would overwrite the first's. Re-entrant calls for the same
        // suggestion are ignored; the first click's answer is the one the card shows.
        guard filingTryAnotherInFlight[suggestion.id] == nil else { return }
        let invocation = UUID()
        filingTryAnotherInFlight[suggestion.id] = invocation
        filingTryAnotherNotes[suggestion.filePath] = nil
        defer {
            // Release only what this invocation still owns. The id is the file's absolute path,
            // stable across scans and provider switches, so after `clearFiling()` releases the
            // entry mid-round-trip, a recreated card's new re-ask can hold the same key under its
            // own token, and an unconditional remove would strip that guard while it is still out.
            if filingTryAnotherInFlight[suggestion.id] == invocation {
                filingTryAnotherInFlight.removeValue(forKey: suggestion.id)
            }
        }
        // The persisted (token-keyed) rejection is best-effort: token-less filenames can't store
        // one. The session set, keyed by file path, guarantees the click takes effect: the
        // rejected folder never comes back for this file, whatever its name.
        if let rejected {
            rememberFilingRejection(fileName: suggestion.fileName, destinationPath: rejected.path,
                                    providerRoot: suggestion.providerRoot,
                                    evidenceWord: rejected.evidenceToken)
            filingSessionRejections[suggestion.filePath, default: []].insert(rejected.path)
        }

        // Every folder rejected for this file (this session's + persisted).
        let fileTokens = Set(FilingEngine.salientTokens(ofFileNamed: suggestion.fileName))
        let allRejected = Set(filingRejections
            .filter { !$0.tokens.isEmpty && Set($0.tokens).isSubset(of: fileTokens) }
            .map { $0.path })
            .union(filingSessionRejections[suggestion.filePath] ?? [])

        // Cycle to the next candidate the file already carries.
        let remaining = suggestion.candidates.filter { !allRejected.contains($0.path) }
        if !askingClaudeWithPage, !remaining.isEmpty {
            replaceFilingSuggestion(suggestion.id, candidates: remaining)
            return
        }

        // Out of local ideas: re-ask the backend for a different folder, if one is available. The
        // cached root and taxonomy must belong to this suggestion's provider: a scan of another
        // provider (even a cancelled one) overwrites the cache, and resolving against it would
        // build, and move the file into, a destination in the wrong provider's tree.
        guard filingUsesAI, let classifier = filingClassifier,
              let root = filingLastProviderRoot, root == suggestion.providerRoot,
              !filingLastTaxonomyFolders.isEmpty else {
            replaceFilingSuggestion(suggestion.id, candidates: [])   // card falls back to "Choose a folder…"
            return
        }
        // Snapshot the cached folder sets where `root` was validated: a scan of another provider
        // (or `clearFiling()`) during the round-trip swaps or empties them, and reading them after
        // the await would label the verdict against the wrong folders (an emptied set marks every
        // segment new, so "Creates N new folders." would be false). Everything after the await
        // uses only these locals.
        //
        // Hidden from Claude is honoured as in the refine pass: a hidden file isn't asked about,
        // and a hidden folder is neither offered nor sent as one to avoid. Only when the re-ask
        // goes to Claude; on this Mac nothing leaves it.
        // Claude answers a Try Another only for a file in a folder shared without asking: asking it
        // sends a request with no click of its own, so the folder's choice is the consent, and a
        // folder that asks each time stays on this Mac (TE335, LX-A). Where the app installs no
        // Claude request (the CLI, tests) a pass that routes to Claude goes through the classifier.
        let routesToClaude = filingRoutesToCloud(.refine)
        let useClaude = routesToClaude
            && (filingRefineClassifier == nil || askingClaudeWithPage
                || AskClaudePrivacy.Matcher(AskClaudePrivacy.sharedFolders(in: filingContentDefaults)).holds(suggestion.filePath))
        let hidden = useClaude ? claudeHiddenMatcher() : AskClaudePrivacy.Matcher([])
        if hidden.isHidden(suggestion.filePath) {
            banner = .warning("“\(suggestion.fileName)” is hidden from Claude, so it wasn’t asked "
                              + "for another folder. Choose one instead.", log: .warn)
            replaceFilingSuggestion(suggestion.id, candidates: [])
            return
        }
        let allTaxonomyFolders = filingLastTaxonomyFolders
        // Folders left out with Customize… on a plan card stay out for Try Another too (TE335, LY-A),
        // when the request goes to Claude: on this Mac nothing leaves it.
        let leftOut = useClaude ? filingRefineLeftOutFolders : []
        let taxonomyFolders = allTaxonomyFolders.filter {
            Self.shownToClaude($0, under: root, hidden: hidden) && !Self.isLeftOut($0, in: leftOut)
        }
        let existingFoldersSnapshot = filingLastExistingFolders
        let nameProvider = filingLastNameProvider   // same snapshot rule, for a new folder's name
        // "Try another" is a re-ask, not a scan, so it only borrows the status line while the lens
        // is idle; otherwise it would overwrite a running rescan's phase text and its `defer`
        // would blank the line mid-scan. Epoch-scoped like every status write (see `updateScan`):
        // a scan that starts while the classifier is out owns the line. The epoch suits the status
        // line, since a cancelled scan clears the line and bumps the epoch; the result write uses
        // the generation, below.
        let preAwaitEpoch = filingScanLifecycle.epoch
        // The pre-await marker for "the list my verdict is about is still on screen". See
        // ``filingSuggestionsGeneration``: it counts wholesale republishes only, so a cancelled scan,
        // which never publishes and leaves the old cards standing, doesn't invalidate this verdict,
        // though it bumps the epoch.
        let preAwaitGeneration = filingSuggestionsGeneration
        let ownsStatusLine = !filingScanLifecycle.isRunning
        if ownsStatusLine {
            filingScanLifecycle.status = FilingScanPhase.lookingForDifferent.status
        }
        defer {
            if ownsStatusLine, filingScanLifecycle.epoch == preAwaitEpoch {
                filingScanLifecycle.status = nil
            }
        }
        // A folder Customize… left out goes nowhere, not even as "avoid: …"; the answer is still
        // checked against the rejections when it lands.
        let excluded = allRejected.filter { !hidden.isHidden($0) }
            .compactMap { Self.relativePath($0, under: root) }
            .filter { !Self.isLeftOut($0, in: leftOut) }
        // The page the scan already read, not nil. This is a `.refine` call, the paid tier, and as
        // in the refine pass a name-only verdict is one the overlay refuses anyway
        // (`contentBlind`), a paid round-trip that changes nothing. `filingPageSamples` already
        // holds page 1 of every file the scan read, bounded to the router's sample size (the person
        // veto below reads it too), so nothing is re-extracted. A file the scan never read sends
        // nil, the honest answer for it.
        let file = FilingCandidateFile(filePath: suggestion.filePath, fileName: suggestion.fileName,
                                       ext: (suggestion.fileName as NSString).pathExtension.lowercased(),
                                       year: Self.modificationYear(suggestion.modificationDate),
                                       contentSnippet: filingPageSamples[suggestion.filePath],
                                       excludedRelativePaths: excluded)
        // `.refine`, not `.free`: this is the refine pass for one card, an explicit click asking
        // the preferred backend for a better answer. The free tier would re-ask the model that
        // produced the destination being rejected.
        //
        // The spend gate without the conversation: a modal per card click would be worse than
        // none, so an unpriced model or a cap breach refuses under a banner naming the remedy (not
        // silently: a click that does nothing, with its reason only in `~/sync-cloud.log`, teaches
        // nothing), and the card keeps its free on-device suggestion. The refine pass keeps its
        // dialog: it is a bulk action the user asked to price.
        guard !useClaude || cloudSpendWithinCapsWithoutPrompting(files: [file], taxonomyFolders: taxonomyFolders) else {
            filingTryAnotherNotes[suggestion.filePath] = FilingTryAnotherNote(
                text: "Claude wasn’t asked: it would pass your monthly limit, or the model has no known price. This card keeps its suggestion. Settings ▸ Ask Claude has the limit.")
            return
        }
        // Claude when the pass routes there, through the request that says how it ended; otherwise
        // the on-device model, as before. A failed or stopped Claude request is not answered by the
        // on-device model.
        var cloudFailure: String?
        let verdicts: [String: FilingVerdict]
        if useClaude, let refiner = filingRefineClassifier {
            let reply = await refiner(filingContext(taxonomyFolders: taxonomyFolders), [file])
            verdicts = reply.verdicts
            switch reply.ending {
            case .answered: break
            case .stopped: cloudFailure = "It was stopped."
            case .failed(let why): cloudFailure = why
            }
            if reply.started {
                let outcome: FilingTryAnotherReport.Outcome = switch reply.ending {
                case .answered: .answered
                case .stopped: .stopped
                case .failed: .failed
                }
                filingTryAnotherReports?(FilingTryAnotherReport(fileName: suggestion.fileName, filePath: suggestion.filePath, outcome: outcome,
                                                                costUSD: reply.costUSD, modelName: filingRefineModelName))
            }
        } else {
            // This Mac: the free tier when Claude is the pass's route but not this file's, so nothing
            // leaves it; the refine tier as before where there is no Claude route at all.
            let onThisMac: FilingClassifierTier = routesToClaude && filingRefineClassifier != nil ? .free : .refine
            verdicts = await classifier(filingContext(taxonomyFolders: taxonomyFolders), [file], onThisMac)
        }
        // The verdict was computed against this invocation's pre-await snapshots. If the filing
        // state moved on while the classifier was out, the card now on screen (same id, the file
        // path) belongs to the new state, and writing the old verdict into it is a stale overwrite.
        // Two ways it moves on, two checks: `clearFiling()` releases this invocation's entry, so the
        // token no longer matches; a rescan republishes the list, which bumps the generation.
        // Either way, drop the result; the defer above still releases only what this one owns.
        guard filingTryAnotherInFlight[suggestion.id] == invocation,
              filingSuggestionsGeneration == preAwaitGeneration else { return }
        // Claude didn't answer: keep the card as it was and say why, rather than blank it.
        if let cloudFailure, verdicts[suggestion.filePath] == nil {
            filingTryAnotherNotes[suggestion.filePath] = FilingTryAnotherNote(
                text: "Claude didn’t answer: \(cloudFailure) This card keeps its earlier suggestion. Nothing was saved as Claude’s.")
            let text = "Claude didn’t answer for \(suggestion.fileName): \(cloudFailure) Keeping its earlier suggestion."
            if filingRefineShowsBanner { banner = .warning(text + "", log: .warn) } else { Logger.shared.warning("Filing: \(text)") }
            return
        }
        // Mark new-vs-existing against the full, uncapped folder set, hidden folders included
        // since they still exist, so a real folder beyond the classifier's cap isn't labelled one
        // to create. Falls back to the capped cached list, before the hidden filter, if the full
        // set wasn't captured. Both from the pre-await snapshots.
        let existingFolders = existingFoldersSnapshot.isEmpty ? Set(allTaxonomyFolders) : existingFoldersSnapshot
        // The cross-person rule the scan and the refine apply. This answer goes straight from
        // `destination(from:)` onto the card, past `applyVerdicts`, so without it a re-ask could
        // put one family member's document in another's folder, on the click most likely to
        // produce that: the model is asked again about a file it was already wrong about.
        //
        // Only the veto, not the rest of `applyVerdicts`: its confidence guard refuses an answer
        // weaker than the current best, which here is the one just rejected, and the other guards
        // arbitrate against a standing suggestion this path has already discarded.
        let accepted: FilingDestination? = {
            guard let verdict = verdicts[suggestion.filePath],
                  let dest = FilingEngine.destination(from: verdict, providerRoot: root,
                                                      existingRelative: existingFolders,
                                                      nameProvider: nameProvider),
                  !allRejected.contains(dest.path),
                  // Never shown a hidden folder, so an answer naming one is not taken.
                  !hidden.isHidden(dest.path)
            else { return nil }
            if let refusal = FilingEngine.personVeto(
                fileName: suggestion.fileName, destination: dest.path, providerRoot: root,
                profile: filingRoutingProfile, registry: filingPersonRegistry,
                identity: filingPersonIdentity,
                pageSample: filingPageSamples[suggestion.filePath]) {
                if let reported = refusal.reported { recordPersonVeto(reported) }
                return nil
            }
            return dest
        }()
        if let dest = accepted {
            replaceFilingSuggestion(suggestion.id, candidates: [dest])
        } else {
            replaceFilingSuggestion(suggestion.id, candidates: [])
        }
        // A folder that asks each time kept this on this Mac: say so, and offer the one page to Claude.
        if routesToClaude, filingRefineClassifier != nil, !useClaude {
            filingTryAnotherNotes[suggestion.filePath] = FilingTryAnotherNote(
                text: "This folder asks before Claude reads files, so Try Another used this Mac.", offersClaudeWithPage: true)
        }
    }

    /// Whether the card for `suggestion` may offer "Ask Claude with Page 1…": Claude is set up, the
    /// file is not hidden from it, and its folder asks each time (a shared folder's Try Another
    /// already asks Claude).
    public func canAskClaudeWithPage(_ suggestion: FilingSuggestion) -> Bool {
        guard filingRefineClassifier != nil, filingCloudRefineAvailable else { return false }
        if claudeHiddenMatcher().isHidden(suggestion.filePath) { return false }
        return !AskClaudePrivacy.Matcher(AskClaudePrivacy.sharedFolders(in: filingContentDefaults)).holds(suggestion.filePath)
    }

    /// The one way to replace the published suggestion list wholesale. Bumps
    /// ``filingSuggestionsGeneration`` with the assignment so the two can't drift (see that property
    /// for why per-item edits are excluded). `public` so a caller outside the module can put a list
    /// on screen, as `FileExplorer`'s render tests need; `filingSuggestions` is `internal(set)` so
    /// there is no other way, since a setter that skipped the bump would silently disarm every
    /// staleness guard that reads it.
    public func publishFilingSuggestions(_ suggestions: [FilingSuggestion]) {
        filingTryAnotherNotes = [:]
        filingSuggestions = suggestions
        filingSuggestionsGeneration &+= 1
    }

    /// Replaces a suggestion's candidates in place (keeps the card, updates its shown home).
    // `internal`, not `private`: `readScan(for:)`, in the router extension, updates one card this
    // way too. Not `public`: the generation bump above is what every staleness guard reads, so
    // wholesale replacement stays the only outside door.
    func replaceFilingSuggestion(_ id: String, candidates: [FilingDestination]) {
        guard let i = filingSuggestions.firstIndex(where: { $0.id == id }) else { return }
        let s = filingSuggestions[i]
        // Named here too, or "Try another" answers differently from the scan. The scan gives every
        // candidate the name the file would take there; a destination minted afterwards would carry
        // none, and since the apply path is gated on that name, the same folder would file the raw
        // name when reached by rejection and `04. Apr 2025.pdf` when reached directly.
        //
        // Read from disk, not the scan's taxonomy: this runs long after the walk, on one folder the
        // user just chose, and one listing is cheaper than being wrong about a tree that moved on.
        let named = candidates.map { dest -> FilingDestination in
            guard dest.newSegments.isEmpty else { return dest }
            return dest.naming(Self.liveIncomingName(
                for: s.fileName, destination: dest.path, providerRoot: s.providerRoot,
                profile: filingRoutingProfile, fileManager: fileManager))
        }
        filingSuggestions[i] = s.replacingCandidates(named)
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
        // The rename backlog is a product of this scan, so it goes with it; left behind, it would
        // still claim N folders with `filingLastProviderRoot`, which its chip names, cleared below.
        clearRenamePlans()
        filingScanFolder = nil
        filingLastCacheReuse = nil
        filingLastRefine = nil
        filingLastRefineReport = nil
        hasSuggestedFiling = false
        // Re-arm the auto-rescan: switching back to this provider behaves like a fresh launch, as
        // Storage's restore does after `clearStorageLens()`.
        filingAutoRescanAttempted = nil
        filingLastProviderRoot = nil
        filingLastNameProvider = nil
        filingLastTaxonomyFolders = []
        filingLastExistingFolders = []
        filingSessionRejections = [:]
        // The refine guard, released wholesale with the same safety: a still-out pass checks its
        // invocation token before releasing or publishing, so clearing here can neither strip a
        // successor's guard nor land a stale verdict.
        filingRefineInFlight = nil
        filingOpenRefinePlans = [:]
        // The re-ask guard too. `tryAnotherFolder` releases its own entry in a `defer`, but only if
        // it returns, and `FilingClassifier` is a seam with no timeout in its type, so a hung
        // round-trip would latch the card and make every later "Try another" a silent no-op. The
        // shipped classifier is bounded (`CloudFilingClassifier` times out at 90 s, then falls back
        // on-device), so this hatch is for an injected backend that hangs.
        //
        // This is the only recovery: a rescan assigns `filingSuggestions` directly and never
        // touches this dictionary, so only a provider switch (this function's one caller) frees a
        // latched card. Wholesale is safe because every release and result write in
        // `tryAnotherFolder` is checked against its invocation token: a still-out round-trip can
        // neither strip a successor's guard nor land its stale verdict in a recreated card.
        filingTryAnotherInFlight = [:]
        // The OCR latch, for the same reason: `readScan` releases it in a `defer` that runs only if
        // it returns, and `filingOCRExtractor` is an unbounded `async` closure, so a Vision render
        // that never returns latches the file and every later "Read scan" on it is a silent no-op.
        // Nothing else clears it, rescans included. Safe wholesale because `readScan` guards its
        // write on `filingSuggestionsGeneration`, so a still-out render can't land in a recreated
        // list; its `defer` may remove a path a later `readScan` re-inserted, which only
        // un-latches a file.
        filingOCRInFlight = []
        // These are keyed by absolute path and describe files under the provider being left, so
        // they say nothing true about the next one: `filingUnreadableScans` drives the "Read scan"
        // offer and `filingPageSamples` holds page-1 text for the rule offer. Kept across
        // switches, they would only grow.
        filingUnreadableScans = []
        filingPageSamples = [:]
        filingNotDownloaded = []
    }

    // MARK: Apply

    private enum FilingOutcome { case moved(MoveItemState); case noMoveNeeded; case failed }

    /// The outcome of a single `applyFilingSuggestion`. `moved` vs `notNeeded` lets a caller act
    /// only on a real move (offering a learned rule, the remember-override prompt) without
    /// re-deriving it from a path comparison. `notNeeded` is still a success: the file is already
    /// where the caller asked.
    public enum FilingApplyResult: Sendable, Equatable {
        /// The file was moved into the destination (and the list row dropped).
        case moved
        /// The chosen folder is where the file already lives: nothing to do (success, no move).
        case notNeeded
        /// The move was refused (Verify All in flight) or failed; the file stayed put.
        case failed
    }

    /// Moves the suggestion's file into the chosen destination, creating any new folders in the
    /// path, and drops it from the list. Reversible with Undo (⌘Z). Never overwrites: a name
    /// collision keeps both by uniquifying.
    /// - Returns: `.moved` on a real move, `.notNeeded` when the file already lives there, `.failed`
    ///   when refused or the move errored.
    @discardableResult
    public func applyFilingSuggestion(_ suggestion: FilingSuggestion, to destination: FilingDestination,
                                      remember: Bool = false) async -> FilingApplyResult {
        // Verify All's exclusion guard, in the write direction (as in `syncFile`): filing moves a
        // file Verify All may be hashing.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before filing", log: .info)
            return .failed
        }
        switch await performFiling(suggestion, to: destination) {
        case .moved(let move):
            // Remember only on an actual move: a rule keyed on where the file already lived is
            // noise. The log reports what happened, since derivation can decline (a token-less
            // name) and claiming "remembered" then would be false.
            var remembered = false
            if remember {
                remembered = rememberAutomationRule(fileName: suggestion.fileName,
                                                    destinationPath: destination.path) != nil
            }
            // Filing somewhere else says the suggestion was wrong, the same lesson as Try another:
            // otherwise a word that misled it (an invoice's "india" pointing at Medical) keeps
            // misleading the next file. A folder inside the suggested one is a more specific
            // answer, not a correction, and teaches nothing.
            if let suggested = suggestion.best,
               !PathBoundary.contains(destination.path, under: suggested.path) {
                rememberFilingRejection(fileName: suggestion.fileName, destinationPath: suggested.path,
                                        providerRoot: suggestion.providerRoot,
                                        evidenceWord: suggested.evidenceToken)
            }
            registerMoveUndo(items: [move], actionName: "File \(suggestion.fileName)", fileManager: fileManager)
            let folderName = (destination.path as NSString).lastPathComponent
            banner = .success("Filed “\(suggestion.fileName)” → \(folderName)", undoable: true)
            Logger.shared.info("Filing: filed “\(suggestion.fileName)” → \(folderName)\(remembered ? " (remembered as a rule)" : "")")
            return .moved
        case .noMoveNeeded:
            // The chosen folder is where the file already lives: nothing to do, and said so. The
            // card goes either way, and silence would read as a click that did nothing or a file
            // that went somewhere. The engine drops the file's own folder by path, so this is
            // reached through a link to it or a folder the user picked.
            banner = .success("“\(suggestion.fileName)” is already in that folder — nothing to move.")
            return .notNeeded
        case .failed:
            return .failed
        }
    }

    /// Every suggestion eligible for the blind batch (a confident home derived from the filename),
    /// unfiltered: the honest "all of them" scope. The Organize lens doesn't pass this; its button
    /// scopes to what the search left on screen (see `applyRecommendedFiling`).
    public var batchEligibleFilingSuggestions: [FilingSuggestion] {
        filingSuggestions.filter { $0.isBatchEligible }
    }

    /// True while a "File recommended" batch is running for this manager; see the latch at the
    /// foot of this file and the guard in ``applyRecommendedFiling(_:)``.
    ///
    /// Internal and not published: the storage is a file-private set nothing observes, so a
    /// SwiftUI view reading it would never be told it changed, and the button isn't disabled by
    /// it. It lets the re-entrancy test assert that its second call really overlapped the first;
    /// otherwise a run that never overlapped looks like one the latch refused.
    var isFilingBatchRunning: Bool { filingBatchInFlight.contains(ObjectIdentifier(self)) }

    /// Files the batch-eligible suggestions among `scope` into their suggested homes.
    ///
    /// `scope` is required, as for `applyRecommendedDuplicates`: a search can narrow the list, so
    /// recomputing targets from the unfiltered `filingSuggestions` would move files the button never
    /// counted and the user couldn't see. The button's count and the array iterated are one value.
    /// Eligibility is still re-checked, so a caller can't make this file an unsure suggestion.
    public func applyRecommendedFiling(_ scope: [FilingSuggestion]) async {
        // Verify All's exclusion guard, in the write direction (as in `syncFile`): filing moves
        // files Verify All may be hashing.
        guard !isVerifyAllRunning else {
            banner = .warning("Wait for Verify All to finish before filing", log: .info)
            return
        }
        let batch = scope.filter { $0.isBatchEligible }
        guard !batch.isEmpty else { return }
        // The in-flight latch every sibling write pass has. `isVerifyAllRunning` is another pass's
        // guard and says nothing about a second "File all", which is one gesture away: the button
        // is disabled only while a scan runs, its `NSAlert` confirmation's modal loop keeps the
        // main actor turning while the first batch waits on the file-operation queue, and both
        // calls file the same captured `scope`. The second would find every source already moved
        // and report "Couldn't file N files" for files that were filed.
        //
        // Refused silently: the user pressed the same button twice, and the first press is still
        // running and will report for both.
        //
        // File-private storage keyed by manager identity, since an extension can't add a stored
        // property; otherwise the sibling shape (`isBulkSyncRunning`, `isApplyingRenames`,
        // `mergingGroupIDs`): refuse at entry, latch, release in a `defer` on every exit. The
        // caller's `await` keeps `self` alive for the whole window, so the key can't be reused.
        guard !filingBatchInFlight.contains(ObjectIdentifier(self)) else { return }
        filingBatchInFlight.insert(ObjectIdentifier(self))
        defer { filingBatchInFlight.remove(ObjectIdentifier(self)) }
        var moves: [MoveItemState] = []
        // What the log names: each file, the folder it landed in and what chose it. Batch filing
        // writes no per-file line, so these are the only record of where each one went.
        var filed: [FilingBatchLog.Filed] = []
        var failures = 0
        // Counted, not dropped: its card leaves the list like a filed one, so a banner leaving it
        // out would count fewer files than went.
        var alreadyHome = 0
        for s in batch {
            guard let dest = s.best else { continue }
            switch await performFiling(s, to: dest) {
            case .moved(let move):
                moves.append(move)
                filed.append(FilingBatchLog.Filed(fileName: s.fileName, landedAs: move.to.lastPathComponent,
                                                  folder: move.to.deletingLastPathComponent().path,
                                                  source: FilingBatchLog.source(of: dest)))
            case .noMoveNeeded: alreadyHome += 1
            case .failed: failures += 1
            }
        }
        let home = alreadyHome == 0 ? ""
            : "\(alreadyHome) \(alreadyHome == 1 ? "was" : "were") already in \(alreadyHome == 1 ? "its folder" : "their folders")"
        guard !moves.isEmpty else {
            // Still one summary line: a batch that moved nothing is otherwise only a banner.
            if failures > 0 || alreadyHome > 0 {
                Logger.shared.info(FilingBatchLog.recommendedSummary(filed: [], failures: failures,
                                                                     alreadyHome: alreadyHome))
            }
            if failures > 0 {
                banner = .warning("Couldn’t file \(failures) file\(failures == 1 ? "" : "s")\(home.isEmpty ? "" : "; \(home)").", log: .warn)
            } else if alreadyHome > 0 {
                banner = .success("\(alreadyHome) file\(alreadyHome == 1 ? " was" : "s were") already in "
                    + "\(alreadyHome == 1 ? "its folder" : "their folders") — nothing to move.")
            }
            return
        }
        // One undo action reverts the whole batch, so ⌘Z is honest.
        registerMoveUndo(items: moves, actionName: "File \(CountedNoun.phrase(moves.count, "Item"))", fileManager: fileManager)
        let n = moves.count
        for line in FilingBatchLog.lines(operation: "Filing batch", filed: filed,
                                         summary: FilingBatchLog.recommendedSummary(filed: filed, failures: failures,
                                                                                    alreadyHome: alreadyHome)) {
            Logger.shared.info(line)
        }
        let filedText = "Filed \(n) file\(n == 1 ? "" : "s")" + (home.isEmpty ? "" : "; \(home)")
        banner = failures > 0
            ? .warning("\(filedText); \(failures) couldn’t be filed", undoable: true, log: .warn)
            : .success(filedText, undoable: true)
    }

    /// Removes a suggestion without moving anything ("Not here" / leave it).
    public func dismissFilingSuggestion(_ suggestion: FilingSuggestion) {
        filingSuggestions.removeAll { $0.id == suggestion.id }
    }

    /// The package `url` is, or sits inside, or nil, read off the disk with one `stat` per existing
    /// ancestor. Folders the filing would still create are skipped: only what exists can be one.
    nonisolated static func enclosingPackage(of url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" && !current.path.isEmpty {
            if let values = try? current.resourceValues(forKeys: [.isPackageKey]), values.isPackage == true {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// The outermost folder in `url`'s path that doesn't exist yet and whose extension is a package
    /// type's (`Notes.rtfd`, `Helper.app`, a `.numbers` where Numbers declares it), or nil. Folders
    /// that exist are ``enclosingPackage(of:)``'s to ask.
    nonisolated static func newPackageSegment(of url: URL, fileManager: FileManaging) -> String? {
        var current = url.standardizedFileURL
        var found: String?
        while current.path != "/", !current.path.isEmpty, !fileManager.fileExists(atPath: current.path) {
            let ext = current.pathExtension
            if !ext.isEmpty,
               UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
                .contains(where: { $0.conforms(to: .package) }) {
                found = current.lastPathComponent
            }
            current = current.deletingLastPathComponent()
        }
        return found
    }

    /// The move and list-drop. No undo registration: the caller registers, so a batch is one undo.
    private func performFiling(_ suggestion: FilingSuggestion, to destination: FilingDestination) async -> FilingOutcome {
        let fm = fileManager
        let src = URL(fileURLWithPath: suggestion.filePath)
        let destFolder = URL(fileURLWithPath: destination.path)

        // No-op: the chosen folder is the file's current folder, so leave it rather than rename it
        // "(2)". Case-folded per the volume, or a case-variant destination reaches the move, where
        // `fileExists` folds the case, finds the file itself, and the unique-name step renames it
        // in place under a success banner. And resolved through links: the own folder reached
        // through a folder link is the same folder.
        if PathBoundary.resolvesToSameDirectory(
            destFolder.path,
            src.deletingLastPathComponent().path,
            caseSensitive: FileSyncManager.volumeSupportsCaseSensitiveNames(for: src)
        ) {
            filingSuggestions.removeAll { $0.id == suggestion.id }
            return .noMoveNeeded
        }

        let logger = Logger.shared   // captured on the main actor; its methods are nonisolated
        let profile = filingRoutingProfile
        let anchor = Self.filingAnchor(for: destination, under: suggestion.providerRoot)
        let recordedSource = suggestion.sourceIdentity
        let outcome: FilingMoveOutcome = await enqueueFileOperation {
            do {
                // Gone since the scan (moved, renamed or deleted): said as that, not as a filing
                // that failed and left the file in place.
                guard fm.fileExists(atPath: src.path) else { return .failed(reason: Self.filingSourceGoneReason) }
                // And it must still be the file the card is about. Existence says only that the
                // path is occupied: a queue is stepped through minutes after the scan, and a browser
                // can re-download over the name or an editor save another document to it. Moving
                // that puts a stranger in a folder chosen for something else and, being a move,
                // leaves nothing where the user last saw it. Automations' apply has the same rule
                // (`sourceChangedSincePreview`). `.indeterminate` refuses too; nil means nothing was
                // recorded, so no check.
                if let recordedSource, recordedSource.drift(at: src, fileManager: fm) != .unchanged {
                    throw FileOperationError.sourceChangedSinceScan
                }
                // One stat before any I/O, as `transferItems` does. `createDirectory` below builds
                // the whole path, so a destination tree gone since the scan (a provider unmounted, a
                // volume ejected) would be silently recreated as a plain local folder, and this move
                // would take the file out of a live tree into one the provider never syncs, under a
                // success banner.
                //
                // The anchor is stat'ed, not the leaf: only the folders `newSegments` names are ours
                // to create, so everything above must already exist (see `filingAnchor(for:under:)`).
                // For a folder the user browsed to, the anchor is the folder itself, so if it
                // vanished between the pick and the apply this refuses rather than recreate it.
                guard fm.fileExists(atPath: anchor.path) else {
                    throw FileOperationError.destinationRootUnavailable
                }
                // A package is a document, not a folder to file into. The survey and router list
                // `Budget 2025.numbers` and its `Data/` like any folder, so a suggestion can name
                // one; a file moved in vanishes from Finder and can be dropped at the app's next
                // save. Asked here, where every route ends: the engine, the router, a model's
                // answer, a folder the user typed.
                if let document = Self.enclosingPackage(of: destFolder) {
                    throw FileOperationError.destinationIsADocument(name: document.lastPathComponent)
                }
                // And so is a folder the filing would create under a package's name: `Notes.rtfd`
                // made as a plain folder is one document to Finder once it exists, file and all.
                // Nothing is on disk to ask yet, so the extension is asked.
                if let document = Self.newPackageSegment(of: destFolder, fileManager: fm) {
                    throw FileOperationError.destinationIsADocument(name: document)
                }
                try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                // Renamed only if the card offered a rename. The scan's proposal is what the user
                // saw and agreed to; without this gate, any destination that numbers its files
                // would turn a requested move into a silent move-and-rename.
                //
                // Given that consent, the slot is re-derived against the destination as it stands
                // now, since a folder gains files while a queue is open: the card decides whether,
                // the disk decides which.
                let landingName = destination.proposedName == nil ? suggestion.fileName
                    : (Self.liveIncomingName(
                        for: suggestion.fileName, destination: destFolder.path,
                        providerRoot: suggestion.providerRoot, profile: profile,
                        fileManager: fm) ?? suggestion.fileName)
                var dst = destFolder.appendingPathComponent(landingName)
                if fm.fileExists(atPath: dst.path) {
                    dst = FileSyncManager.generateUniqueURL(for: dst, fileManager: fm)
                }
                let overwritten = try FileSyncManager.safeMoveItem(at: src, to: dst, fileManager: fm)
                return .moved(to: dst, overwritten: overwritten)
            } catch {
                // Record the cause: the generic alert below can't carry it.
                logger.warning("Filing: moving “\(suggestion.fileName)” into \(destFolder.lastPathComponent) failed: \(error.localizedDescription)")
                // A vanished destination tree is something the user can act on ("plug the volume
                // back in, rescan"), unlike a generic I/O failure, so it says so instead of
                // "couldn't file this item", as do a document destination and a changed file.
                switch error as? FileOperationError {
                case .destinationIsADocument?, .sourceChangedSinceScan?, .destinationRootUnavailable?:
                    return .failed(reason: error.localizedDescription)
                default:
                    return .failed(reason: nil)
                }
            }
        }

        switch outcome {
        case .failed(let reason):
            present(.filingFailed(item: suggestion.fileName, path: suggestion.filePath,
                                  reason: reason ?? "Couldn’t file this item; it was left in place."))
            return .failed
        case .moved(let dst, let overwritten):
            filingSuggestions.removeAll { $0.id == suggestion.id }
            learnFromFiling(fileName: suggestion.fileName, sourcePath: suggestion.filePath,
                            into: dst.deletingLastPathComponent().path, filedPath: dst.path)
            return .moved((from: src, to: dst, overwritten: overwritten))
        }
    }

    /// What the enqueued move did. An enum so a destination can never be returned alongside a
    /// failure.
    private enum FilingMoveOutcome: Sendable {
        case moved(to: URL, overwritten: URL?)
        /// `reason` is user-facing when the failure is one the user can act on; nil falls back to
        /// the generic "couldn't file this item". No retryable flag: the filing alert has no Retry
        /// to offer (`present` is given no retry).
        case failed(reason: String?)
    }

    /// The filing alert's reason for a file gone from where the scan found it: it wasn't "left in
    /// place", since it is no longer there.
    nonisolated static let filingSourceGoneReason = "It’s no longer where the scan found it — it may have been moved, renamed or deleted — so nothing was filed."

    /// The folder a filing destination's new segments hang off: the part that must already exist,
    /// since everything below it is what `createDirectory` is asked to create.
    ///
    /// Walking up one level per `newSegments` entry is the rule, but it trusts a scan-time list, so
    /// it is clamped to the provider root. Unclamped, an over-long `newSegments` would walk to "/",
    /// which always exists, turning a data-safety guard into a tautology exactly when its input is
    /// wrong. `FilingEngine` builds `newSegments` as a suffix of the destination's segments, so it
    /// can't over-count today; the clamp keeps that a property of this function.
    ///
    /// The clamp applies only when the destination is under the root, so a picker choice on another
    /// volume is checked at its own anchor. An empty `providerRoot` counts as no root:
    /// `URL(fileURLWithPath: "")` resolves against the working directory, an unrelated folder.
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

/// Which managers have a "File recommended" batch in flight: the latch behind
/// ``FileSyncManager/applyRecommendedFiling(_:)``, shaped like its siblings (`isBulkSyncRunning`,
/// `isApplyingRenames`, `mergingGroupIDs`, `filingRefineInFlight`) but file-private, because an
/// extension can't hold a stored property.
///
/// Keyed by `ObjectIdentifier` so two managers (tests make many) latch independently. Safe because
/// a latched manager can't be deallocated: the caller awaits `applyRecommendedFiling`, which holds
/// `self` for the whole window, and its `defer` clears the entry before returning.
///
/// `@MainActor` because `FileSyncManager` is: the read, insert and `defer` remove each happen in
/// one main-actor turn, which is what makes this a latch.
@MainActor private var filingBatchInFlight: Set<ObjectIdentifier> = []

/// The lines a filing batch writes to the log: one per destination folder naming every file filed
/// there and what chose its home, sorted, at most ``namesPerLine`` names a line, then the summary.
///
/// **None may start with `"Filing: filed "`.** That prefix is the Activity Log's fold key for one
/// card filed by hand (`LogGrouping.Kind.filed`); a batch summary that matched it folded in with the
/// cards filed just before and after, and the header counted lines, not files: "Filed 2 files" for a
/// batch of 40. Pure and public so `LogGroupingTests` folds this real output, not a typed copy.
public enum FilingBatchLog {
    /// One file a batch moved.
    public struct Filed: Sendable, Equatable {
        public let fileName: String
        /// The name it landed under: a convention rename or a kept-both clash can change it.
        public let landedAs: String
        /// The absolute path of the folder it landed in.
        public let folder: String
        /// What chose the home, in the log's words (``source(of:)``).
        public let source: String

        public init(fileName: String, landedAs: String, folder: String, source: String) {
            self.fileName = fileName
            self.landedAs = landedAs
            self.folder = folder
            self.source = source
        }
    }

    /// Names per line: a line stays one physical line a reader can scan, and a group of thousands is
    /// split rather than written as one line the Activity Log renders whole.
    public static let namesPerLine = 200

    /// What chose a recommended-batch home. Only two answers are possible: the blind batch takes
    /// filename-derived homes alone (`FilingSuggestion.isBatchEligible` excludes content and AI
    /// homes), and a filename home records only whether a rule or Automation taught it, not whether
    /// the folder survey or the keyword engine found it.
    public static func source(of destination: FilingDestination) -> String {
        destination.remembered ? "a rule you taught" : "its name"
    }

    public static func lines(operation: String, filed: [Filed], summary: String) -> [String] {
        // Sorted, folders and names both, so two runs over the same files read the same.
        let byFolder = Dictionary(grouping: filed, by: \.folder)
        var out: [String] = []
        for folder in byFolder.keys.sorted() {
            let names = (byFolder[folder] ?? []).sorted { $0.fileName < $1.fileName }.map { file in
                (file.landedAs == file.fileName ? "“\(file.fileName)”" : "“\(file.fileName)” as “\(file.landedAs)”")
                    + " (\(file.source))"
            }
            guard names.count > namesPerLine else {
                out.append("\(operation) → \(folder): \(names.count) file(s): \(names.joined(separator: ", "))")
                continue
            }
            for start in stride(from: 0, to: names.count, by: namesPerLine) {
                let end = min(start + namesPerLine, names.count)
                out.append("\(operation) → \(folder): names \(start + 1)–\(end) of \(names.count): "
                           + names[start..<end].joined(separator: ", "))
            }
        }
        out.append(summary)
        return out
    }

    /// The "File recommended" batch's closing line.
    public static func recommendedSummary(filed: [Filed], failures: Int, alreadyHome: Int) -> String {
        let folders = Set(filed.map(\.folder)).count
        return "Filing batch: \(filed.count) file(s) filed into \(folders) folder(s)"
            + (failures > 0 ? ", \(failures) couldn’t be filed" : "")
            + (alreadyHome > 0 ? ", \(alreadyHome) already in place" : "")
    }
}
