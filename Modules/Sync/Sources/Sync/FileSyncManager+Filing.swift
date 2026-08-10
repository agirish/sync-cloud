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

    /// Re-runs the Filing scan on lens open, when `folder` is exactly what the last completed
    /// scan covered. Consent and idempotence work as in
    /// ``autoRescanDuplicatesIfEligible(root:options:)`` — a remembered target, then
    /// `hasSuggestedFiling` / `isSuggestingFiles` / the per-target latch against the callers'
    /// overlapping triggers.
    ///
    /// **There is no money question here, and none inside the scan either.** There was, in two
    /// places: a pre-flight that walked the folder and probed the verdict cache to predict
    /// whether the scan would reach the paid backend, and a second, exact stop at the
    /// classification phase. Both existed because a scan *could* spend, so an auto-started one
    /// had to be talked out of it. A scan can no longer spend at all —
    /// ``FilingClassifierTier/free`` is the only tier it classifies at, and the cloud backend is
    /// reachable only from the refine pass, which is a click. Predicting a route the scan cannot
    /// take is not a weaker version of that guarantee, it is a different and worse one: the
    /// prediction has to agree with the router, and where it didn't (cloud on, no readable key)
    /// it raised a payment dialog for a scan that was always going to be free.
    ///
    /// Returns whether a scan was started, for tests.
    @discardableResult
    public func autoRescanFilingIfEligible(folder: URL, providerRoot: URL, providerName: String? = nil,
                                           nameProvider: CloudProvider.ProviderType? = nil,
                                           options: FilingOptions = .init()) -> Bool {
        guard lensScanTargetIsRemembered(folder.path, forKey: Self.lastFilingScanFolderKey),
              Self.isReachableDirectory(folder.path, fileManager: fileManager),
              !isSuggestingFiles, !hasSuggestedFiling,
              filingAutoRescanAttempted != folder.path else { return false }
        filingAutoRescanAttempted = folder.path
        Logger.shared.info("Filing: auto-rescanning \(folder.lastPathComponent) (scanned before)")
        startFindFilingSuggestions(folder: folder, providerRoot: providerRoot,
                                   providerName: providerName, nameProvider: nameProvider,
                                   options: options)
        return true
    }

    /// Whether the app's own router says a ``FilingClassifierTier/free`` classification would
    /// reach a paid backend — which would mean the app is not honouring the tier.
    ///
    /// The free pass's guarantee is structural: it passes `.free`, and the app routes `.free` to
    /// the on-device model. This asks the app to state that, rather than assuming it. The one
    /// line in the app's wiring that maps tier → backend is the whole of the guarantee, and
    /// nothing in this module compiles against it; if it ever stops being true, the honest
    /// outcome is a scan with no classification phase and a loud log line, not a silent bill.
    ///
    /// With no app resolver (the CLI, tests) the answer is no by construction —
    /// ``configuredFilingBackendIdentity(for:)`` returns the on-device identity for `.free`
    /// unconditionally.
    var freePassWouldReachAPaidBackend: Bool { filingRoutesToCloud(.free) }

    /// Whether a classification at `tier` will reach the paid backend.
    ///
    /// **The single answer to the money question, asked by everything that needs it** — the
    /// free-pass misroute check above, the spend guardrail, and the Refine button's label. Three
    /// call sites that must agree, so they read one function rather than three predicates that
    /// happen to line up today.
    ///
    /// That is the whole lesson of the auto-rescan bug this feature replaced: the guard read the
    /// resolved ROUTE while `cloudSpendAllows` returned early on the cloud SETTING, and in the
    /// ordinary state where the two disagree — cloud switched on, no readable Keychain key, so the
    /// app's router reports the on-device downgrade — a free pass raised a payment dialog. Keying
    /// every consumer on the route is safe *because the app's classifier uses the same router with
    /// the same inputs*: if this says on-device, the call that follows cannot be billed.
    ///
    /// **An `if let` on the closure, never `filingBackendIdentity?(tier) ?? …`** — optional
    /// chaining flattens, and a closure that RETURNED nil would be indistinguishable from one
    /// never set. nil means "the app cannot vouch for which backend will run", and for a money
    /// gate the safe reading of "don't know" is to fall back on what settings configure — i.e. to
    /// ask — rather than to assume free and spend silently.
    func filingRoutesToCloud(_ tier: FilingClassifierTier) -> Bool {
        if let resolveBackend = filingBackendIdentity, let identity = resolveBackend(tier) {
            return identity.hasPrefix("cloud:")
        }
        return configuredFilingBackendIdentity(for: tier).hasPrefix("cloud:")
    }

    /// Whether to offer the cloud Refine button at all — the UI's question, before it decides
    /// between "Refine N with Opus" and the "set up Claude" invitation.
    ///
    /// Not the toggle: with cloud switched on and nothing stored, a toggle-based answer promises a
    /// model the router will not use, and the pass comes back "no better homes found" having asked
    /// nothing. The invitation is the honest control there — it opens Settings ▸ Organize, which is
    /// where the missing key goes.
    ///
    /// **Not the real route either, and that is the point of ``filingCloudRefineConfigured``.**
    /// This is read on every render of the Organize toolbar; resolving the route means decrypting
    /// the Keychain item, which can raise the password prompt — while the user types. The cheap
    /// seam answers "is a key stored", the route stays for the money decisions, and the narrow
    /// gap between them (stored but unreadable) is reported by the refine banner rather than
    /// silently believed.
    public var filingCloudRefineAvailable: Bool {
        guard filingUsesCloud else { return false }
        if let configured = filingCloudRefineConfigured { return configured() }
        return filingRoutesToCloud(.refine)
    }

    /// True when the user has asked for Claude but the router will not reach it — a key that is
    /// stored yet unreadable. The one state where ``filingCloudRefineAvailable`` and the real
    /// route disagree, named here so the refine pass can say so instead of quietly running
    /// on-device under a button that promised Opus.
    var filingCloudRefineIsDowngraded: Bool {
        filingUsesCloud && !filingRoutesToCloud(.refine)
    }

    /// Reads the loose files in `folder`, learns the provider's folder taxonomy, and produces
    /// suggested homes.
    ///
    /// **This is the free pass, all of it.** Phases 1–3 run at ``FilingClassifierTier/free``, so
    /// the whole scan — started by a click or automatically on lens open — costs nothing and can
    /// raise no spend prompt. The paid backend is reached only by ``refineFilingSuggestions(_:)``,
    /// which acts on the results this publishes. That is why there is no `autoFreeOnly` here and
    /// no cost pre-flight anywhere in the body: "free" is not a mode this scan can be asked to run
    /// in, it is the only mode it has.
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

        // The rename backlog, on the same walk and for the same reason. `RenamePlanner` is pure and
        // reads the folder profile rather than the disk, so this costs one traversal of a tree that
        // is already in memory — no second walk, and no tab to remember to visit.
        await detectRenamePlans(in: taxonomy, root: providerRoot)
        if Task.isCancelled { return }

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
                let facts = FilingEngine.automationFacts(for: file, registry: filingPersonRegistry,
                                                         identity: filingPersonIdentity)
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
        // The router reasons over the UNCAPPED folder set: the classifier's cap exists to bound
        // token cost, and this pass sends nothing anywhere, so capping it would hide real
        // destinations for no benefit.
        prepareFilingRouter(destinations: filingLastExistingFolders, providerRoot: providerRoot.path)

        // Phase 1 — filename + metadata + your taxonomy + your rules (not published yet).
        var suggestions = FilingEngine.suggest(looseFiles: looseFiles, taxonomy: taxonomy,
                                               providerRoot: providerRoot.path, rules: rules,
                                               automations: automations,
                                               registry: filingPersonRegistry,
                                               identity: filingPersonIdentity,
                                               providerName: providerName,
                                               automationSnippets: automationSnippets, now: scanClock,
                                               rejectedByFile: rejectedByFile, options: options)
        if Task.isCancelled { return }

        // Phase 2 — for the files with no confident home, read their contents on-device and
        // re-suggest with those tokens merged in.
        //
        // **A page is read once and shared.** Tokens are a pure function of the extracted text, so
        // when the router is also going to want that text, the text is what gets read and the
        // tokens are derived from it. Reading the file twice — once for tokens, once for the
        // router — doubled the most expensive work in the scan, and PDF extraction is that work.
        var routerSnippets: [String: String] = [:]
        if filingReadsContents, let extractor = filingContentExtractor {
            // **Every file a backend will be asked about, not only the homeless ones.**
            //
            // The old set was `!hasConfidentHome`, which made sense when a page was read only to
            // improve a suggestion that had nothing. It stopped making sense once that page also
            // feeds the router and the classifier's folder menu: a file the keyword engine placed
            // confidently was then classified from its filename alone, against a menu that
            // described everything except it. A T-Mobile bill named `DetailedBillApr2025.pdf` came
            // back as a NEW `Finance/US/Accounts` — while the router, given the page, ranks
            // `Home/Utilities/T-Mobile/2025` first out of 4,967 folders. Eleven of that scan's
            // thirteen files were in the confident-home set and none of them were ever read.
            //
            // The extra reads are bounded by what is actually being classified, and a file that
            // was going to be read anyway is read once — see `extractSnippets` reuse below.
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
                updateScan(\.filingScanLifecycle, epoch: epoch,
                           status: FilingScanPhase.readingContent(readSet.count).status)
                let content: [String: Set<String>]
                if filingRouterIndex != nil, let snippetExtractor = filingSnippetExtractor,
                   let tokenize = filingTokensFromText {
                    routerSnippets = await Self.extractSnippets(for: readSet.map { $0.filePath },
                                                               using: snippetExtractor)
                    if Task.isCancelled { return }
                    // A PDF that was read and gave up nothing is a scan with no text layer. Noted
                    // now, while it is known which files were actually read; the expensive part —
                    // rendering and OCR — is offered, not spent. See `filingUnreadableScans`.
                    filingUnreadableScans = Set(readSet.map { $0.filePath }.filter {
                        routerSnippets[$0] == nil && ($0 as NSString).pathExtension.lowercased() == "pdf"
                    })
                    // **Tokenize only what the keyword pass will use.** `filingTokensFromText` is
                    // NaturalLanguage named-entity recognition over up to 20,000 characters — the
                    // most expensive thing in the scan after extraction — and its only consumer is
                    // the re-suggest below, which acts on files with no confident home. Deriving it
                    // for the whole widened read set spent minutes of CPU producing tokens for
                    // files nothing would read, and would have quietly changed the suggestions for
                    // files that already had a home. The snippets stay wide; this stays narrow.
                    let unsurePaths = Set(unsure.map { $0.filePath })
                    content = routerSnippets
                        .filter { unsurePaths.contains($0.key) }
                        .compactMapValues { text in
                            let t = tokenize(text)
                            return t.isEmpty ? nil : t
                        }
                } else {
                    // No router: the keyword pass only ever wanted tokens for the homeless files,
                    // and reading the rest would buy nothing.
                    content = await Self.extractContent(for: unsure.map { $0.filePath }, using: extractor)
                }
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

        // Phase 2.5 — the tree's own profile and memory, with no model call. Reads page 1 for the
        // files still without a home and ranks destinations by what each folder already contains.
        // Skipped entirely when no profile has been loaded, which is the ordinary state.
        //
        // The snippets are kept: phase 3 would otherwise read the same pages again, and a PDF page
        // is the expensive part of this whole scan.
        var routerShortlists: [String: [String]] = [:]
        if let routerIndex = filingRouterIndex {
            // Gated on there being anything to rank at all, not on anything being homeless: the
            // ranking now also produces the shortlists phase 3's folder menu is built from, and a
            // scan where every file already has a home is exactly the one where the model was being
            // handed a menu with nothing to do with it.
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
                if count > 0 {
                    Logger.shared.info("Filing: the folder profile placed \(count) of \(unsure.count) "
                                       + "file(s) with no confident home, without a model call")
                }
            }
        }

        if Task.isCancelled { return }

        // What the classification phase reused, published with the results below rather than as it
        // happens — same discipline as `filingScanFolder`: a cancelled scan must not relabel the
        // previous results with its own numbers.
        var cacheReuse: FilingCacheReuse?

        // Phase 3 — intelligent classification, at the FREE tier. Reasons about the folder taxonomy
        // + document text to pick a home, overriding the keyword guess for the files it's confident
        // about. An explicit remembered rule (F3) still wins, and a backend that declines/errors
        // never makes things worse than the keyword engine alone.
        //
        // `freePassWouldReachAPaidBackend` is the app's own answer to "what will you route `.free`
        // to?", and a cloud answer means the tier is not being honoured. Skipping classification
        // entirely is the conservative reading: the user gets the phase-1/2 suggestions, which is
        // exactly what they get when no backend is available at all, rather than a bill for a scan
        // that promised to be free.
        if filingUsesAI, let classifier = filingClassifier, !freePassWouldReachAPaidBackend {
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
                // its contents read (that is OCR/PDF work) and must not occupy a slot against the
                // classifier's per-pass file cap. On the refine pass the same ordering also keeps
                // the spend estimate honest — see ``refineFilingSuggestions(_:)``.
                let existingRelative = filingLastExistingFolders
                let excludedByFile = Dictionary(uniqueKeysWithValues: toClassify.map { f in
                    (f.id, (rejectedByFile[f.id] ?? []).compactMap { Self.relativePath($0, under: providerRoot.path) })
                })
                // nil ⇒ the cache is off for this scan, read and write both. `ignoringCache` is
                // deliberately NOT part of this: it suppresses the read below while leaving the
                // write intact.
                let identity = resolvedFilingVerdictIdentity(for: .free)
                var keysByFile: [String: FilingVerdictKey] = [:]
                var cachedVerdicts: [String: FilingVerdict] = [:]
                var misses = toClassify
                if let identity {
                    // Warmed even on the ignore-cache path, where the READ result is thrown away.
                    // `recordFilingVerdicts` below still has to merge into the existing cache, and
                    // it reaches the SYNCHRONOUS accessor — so skipping this put a decode of a
                    // file that reaches ~12 MB at the entry cap back on the main actor, mid-scan,
                    // which is the whole thing the async accessor exists to avoid.
                    let loaded = await loadedFilingVerdictCache()
                    let cache = ignoringCache ? nil : loaded
                    misses = []
                    for f in toClassify {
                        let key = FilingVerdictKey(
                            filePath: f.id, modificationDate: f.modificationDate, size: f.fileSize ?? 0,
                            model: identity, promptVersion: CloudFilingProtocol.promptVersion,
                            excludedRelativePaths: excludedByFile[f.id] ?? [],
                            artifacts: filingArtifactFingerprint)
                        keysByFile[f.id] = key
                        if let hit = cache?.verdict(for: key, providerRoot: providerRoot.path,
                                                    existingRelative: existingRelative) {
                            cachedVerdicts[f.id] = hit
                        } else {
                            misses.append(f)
                        }
                    }
                }

                // **Every page already read goes to the model; only the READING is rationed.**
                // `canRemember` used to gate the snippet itself, so a file with a meaningful name
                // reached the backend as a bare filename even when phase 2.5 had already extracted
                // its first page and left it in `routerSnippets`. That is what reduced a visa foil
                // to the seven words of its filename. Extraction is still limited to files whose
                // name says nothing — that is the cost worth controlling, and it is unchanged.
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

                // No spend pre-flight: this is the free tier, so there is nothing to confirm. The
                // guardrail moved to ``refineFilingSuggestions(_:)``, the only pass that can
                // reach a paid backend — which is also the only pass the user explicitly asks
                // for, so the dialog now answers a question they just posed.
                // The folder menu: what the router already thinks is plausible for these very files,
                // then the shallow structural list. See ``FilingEngine/classifierFolders``.
                let menu = FilingEngine.classifierFolders(
                    preferred: Self.preferredFolders(for: files, shortlists: routerShortlists,
                                                     in: suggestions, providerRoot: providerRoot.path),
                    fallback: taxonomyFolders)

                var verdicts = cachedVerdicts
                var classifiedCount = 0
                if !files.isEmpty {
                    let fresh = await classifier(filingContext(taxonomyFolders: menu), files, .free)
                    // Recorded BEFORE the cancellation check, unlike everything else in this scan.
                    // The verdicts are true regardless of what this scan goes on to do with them —
                    // cancelling abandons the SUGGESTIONS, and there is nothing to abandon about a
                    // question that was already answered. (On the refine pass the same line has a
                    // second, sharper reason: the answer has already been billed.) `keysByFile` is
                    // empty exactly when the cache is off, so this is a no-op then.
                    recordFilingVerdicts(fresh, keys: keysByFile, providerRoot: providerRoot.path,
                                         existingRelative: existingRelative)
                    if Task.isCancelled { return }
                    classifiedCount = files.count
                    // Fresh wins on the (impossible today) overlap: a file is in exactly one of
                    // the two sets by construction, but stating the precedence keeps that a
                    // property of this line rather than of the partition above.
                    verdicts.merge(fresh) { _, new in new }
                }
                if !cachedVerdicts.isEmpty {
                    cacheReuse = FilingCacheReuse(reused: cachedVerdicts.count, classified: classifiedCount)
                    Logger.shared.info("Filing: reused \(cachedVerdicts.count) of \(toClassify.count) classification(s) "
                        + "from cache, \(classifiedCount) sent to the backend")
                }
                // Files the backend judged without their text — a cache hit counts, since the
                // verdict it replays was produced from whatever that earlier pass could see, and
                // the key records the file, not what was read from it.
                //
                // **"We read it and got nothing", never "we did not read".** The two look identical
                // from here and are not the same claim: a scan with reading switched off, or on a
                // machine with no extractor, hands EVERY file over on its name, and penalising the
                // model for that would leave those installs with no intelligent suggestions at all
                // — while telling the user nothing true, since nobody looked. Blindness is a fact
                // about the document (a scan with no text layer), so it is only asserted when there
                // was a reader to be blind despite.
                let didRead = filingReadsContents && filingSnippetExtractor != nil
                let contentBlind = didRead
                    ? Set(toClassify.map { $0.id }).subtracting(snippets.keys)
                    : []
                suggestions = FilingEngine.applyVerdicts(verdicts, to: suggestions, taxonomy: taxonomy,
                                                         providerRoot: providerRoot.path,
                                                         rejectedByFile: rejectedByFile,
                                                         contentBlind: contentBlind,
                                                         routerShortlists: routerShortlists,
                                                         satelliteHomes: filingSatelliteHomes,
                                                         profile: filingFolderProfile,
                                                         registry: filingPersonRegistry,
                                                         pageSamples: routerSnippets,
                                                         identity: filingPersonIdentity,
                                                         onVeto: { [weak self] refusal in
                                                             self?.recordPersonVeto(refusal)
                                                         })
            }
        }

        if Task.isCancelled { return }
        // What each file would be CALLED once it lands — computed against the taxonomy this scan
        // already walked, so the queue answers "where does this go" and "what is it called there"
        // in one pass. See `namingSuggestions`.
        // DETACHED, for the reason `detectRiskyNames` and `detectRenamePlans` beside it are: this
        // indexes every file in the provider and then plans one folder per candidate, and measured
        // at real-tree scale (3,000 folders, 12,000 files, 14 files × 3 candidates) it holds the
        // main actor for **21 ms** — small, but spent at exactly the moment the results publish and
        // the list rebuilds. Nothing here touches the manager, so there is nothing to hop back for.
        let namingInput = suggestions
        let namingProfile = filingFolderProfile
        let namingRoot = providerRoot.path
        suggestions = await Task.detached(priority: .userInitiated) {
            Self.namingSuggestions(namingInput, taxonomy: taxonomy, rootPath: namingRoot,
                                   profile: namingProfile)
        }.value
        if Task.isCancelled { return }
        // Which of these the tree ALREADY holds — after the naming pass, because a card that says
        // "this is already filed in X" is about the document and not about the name it would land
        // under, and before the publish so the queue never shows a duplicate as ordinary for a
        // frame and then corrects itself.
        suggestions = await markingAlreadyFiled(suggestions, providerRoot: providerRoot.path)
        if Task.isCancelled { return }
        self.publishFilingSuggestions(suggestions)   // single publish
        // Published with the results, not at scan start: the folder labels what's on screen, and a
        // cancelled rescan of a different folder must not relabel the previous results.
        filingScanFolder = folder.path
        // The pages this scan read, kept for the rule offered after a filing move — same publish
        // discipline, and replaced rather than merged so a sample can never outlive the list of
        // files it describes. Truncated to what the scorer was measured on, not to what the
        // extractor returned (see `filingPageSamples`).
        filingPageSamples = routerSnippets.mapValues { String($0.prefix(FilingRouter.contentSampleChars)) }
        filingLastCacheReuse = cacheReuse
        // These results have not been refined — whatever the previous list's refine pass did, it
        // was about files that are no longer on screen. Cleared in the same publish so the summary
        // and the rows it describes can never be one scan apart.
        filingLastRefine = nil
        hasSuggestedFiling = true
        // Remembered only on completion: the auto-rescan consent is "the user scanned exactly
        // this before", and a cancelled or stopped scan is not that.
        rememberLensScanTarget(folder.path, forKey: Self.lastFilingScanFolderKey)
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

    /// Decides whether the cloud (Claude) classifier may run for this batch. Returns true
    /// immediately when the pass is not going to reach the paid backend (never gated — there is
    /// nothing to confirm). Otherwise it builds a pre-flight cost estimate (`FilingSpendPreflight`)
    /// from this month's and lifetime spend, the monthly + total caps, and the batch's estimated
    /// tokens, consults `filingCloudSpendConfirmer`, and returns its answer — logging when a call
    /// is skipped so a paused/declined pass is auditable. Returning false leaves the suggestions
    /// exactly as the free scan left them (graceful fallback).
    ///
    /// **Called only from ``refineFilingSuggestions(_:)``.** The scan classifies at
    /// ``FilingClassifierTier/free``, which cannot route to cloud, so it has nothing to confirm.
    ///
    /// **Gated on the real route, not on `filingUsesCloud` and not on the display seam.** The
    /// toggle is not the same question: cloud on with no readable key routes on-device, and gating
    /// on the toggle put a payment dialog in front of a pass that was never going to be billed.
    /// ``filingCloudRefineAvailable`` is not the question either — it answers "is a key stored"
    /// cheaply enough to ask per render, which is deliberately weaker than "will this be billed".
    /// Money reads ``filingRoutesToCloud(_:)``, which resolves the route for real.
    func cloudSpendAllows(files: [FilingCandidateFile], taxonomyFolders: [String]) -> Bool {
        guard filingRoutesToCloud(.refine) else { return true }
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
    // `nonisolated` for the same reason as the defaults-key constants below: it is an immutable
    // string, main-actor-isolated only by living on `FileSyncManager`, and the `@Sendable`
    // routing closures the app and the tests install — which must answer `.free` with exactly
    // this value — cannot cross an actor boundary to read a constant.
    public nonisolated static let onDeviceBackendIdentity = "on-device"

    /// The backend identity derivable from settings alone — what ``filingBackendIdentity`` falls
    /// back to when the app has not supplied one (the CLI and tests, neither of which has a
    /// Keychain downgrade to account for). Resolved through `currentModel` so a stored id from
    /// before a model refresh keys the same as the model that will actually run.
    ///
    /// `.free` is the on-device identity **unconditionally** — not "when cloud is off". That is
    /// the same guarantee the tier itself carries, stated where the cache can see it: a free-pass
    /// verdict is an on-device verdict, so it must never key under a cloud model's name, or a
    /// later refine pass would serve the free answer back as if Claude had given it.
    func configuredFilingBackendIdentity(for tier: FilingClassifierTier) -> String {
        guard tier == .refine, filingUsesCloud else { return Self.onDeviceBackendIdentity }
        let model = CloudFilingProtocol.currentModel(
            for: filingContentDefaults.string(forKey: Self.cloudModelDefaultsKey) ?? CloudFilingProtocol.defaultModel)
        return "cloud:" + model
    }

    /// The identity this pass's verdict cache keys on — nil turns the cache off for the pass,
    /// read and write both (verdict reuse switched off, or the app's resolver declining to vouch).
    ///
    /// **An `if let` on the closure, NOT `filingBackendIdentity?(tier) ?? …`.** Optional chaining
    /// FLATTENS in Swift, so that spelling gives a plain `String?` in which a closure that
    /// RETURNED nil is indistinguishable from one that was never set — and `??` then sends both
    /// to the configured identity. That silently voided the one guarantee
    /// ``filingBackendIdentity`` documents: returning nil is how the app says it cannot vouch for
    /// which backend will run, and answering `"cloud:<model>"` on its behalf is exactly the
    /// durable silent-substitution the seam exists to prevent. The fallback is for an UNSET
    /// closure (the CLI, tests) and nothing else.
    func resolvedFilingVerdictIdentity(for tier: FilingClassifierTier) -> String? {
        if !filingReusesVerdicts { return nil }
        if let resolveBackend = filingBackendIdentity { return resolveBackend(tier) }
        return configuredFilingBackendIdentity(for: tier)
    }

    /// The cache, read from disk at most once per launch and then held in memory. An unset
    /// ``filingVerdictCacheURL`` yields a permanently empty cache — every lookup misses.
    /// The scan's accessor: decodes OFF the main actor on first use, then serves the memoized copy.
    ///
    /// `findFilingSuggestions` runs on the main actor, so decoding here directly would put the file
    /// on the main thread in the middle of a scan — a hitch the user sees, and at the entry cap a
    /// large one. The synchronous accessor below still exists for the two rare, small callers.
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

    /// The in-memory copy, loading synchronously only if nothing has already warmed it.
    ///
    /// **Every caller must have warmed the memo first, and that is a real obligation rather than a
    /// preference.** This runs on the main actor, and at ``FilingVerdictCache/maxEntries`` the file
    /// is on the order of twelve megabytes — a decode nobody would call "a few milliseconds", which
    /// is what this doc used to claim on the strength of the callers being rare. Rare is not the
    /// same as cheap. Both callers now arrive warm: the scan awaits ``loadedFilingVerdictCache()``
    /// before recording (on the ignore-cache path too, where the read is discarded), and the
    /// Settings readout awaits ``filingVerdictCacheCount()`` before offering `Clear`.
    ///
    /// It stays synchronous because both of them need it from a non-async position afterwards, and
    /// once warm it touches no disk at all.
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

    /// Forgets cached verdicts — all of them, or just those under `providerRoot`. The next scan
    /// re-asks the backend, which for the cloud backend means paying again; the UI that offers
    /// this should say so.
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
        // Through the QUEUE, never the synchronous `save`. A scan's own write is queued there
        // (`recordFilingVerdicts` fires it mid-scan, and at the entry cap it is a multi-megabyte
        // encode), and a synchronous write here races it: the queued PRE-clear snapshot could land
        // last, and the next launch would reload every verdict the user just cleared — a Clear
        // that silently undoes itself is worse than none. Queued, ordering does the work: this
        // snapshot is the newest, so it lands last.
        FilingVerdictStore.saveInBackground(cache, to: url)
        Logger.shared.info("Filing: cleared \(before - cache.count) cached classification(s)")
    }

    /// How many verdicts are cached — for the Settings readout, and the call that WARMS the memo
    /// for the `Clear` button beside it.
    ///
    /// Async, and that is the point: it is the first thing the Organize settings tab asks, so a
    /// synchronous version would decode the whole file on the main actor the moment the tab
    /// appeared. Awaiting ``loadedFilingVerdictCache()`` moves that decode off the actor once per
    /// launch and leaves every later read — including ``filingVerdictCacheCountNow`` below — free.
    public func filingVerdictCacheCount() async -> Int {
        await loadedFilingVerdictCache().count
    }

    /// The same count without awaiting, for reading back the result of an action that has just
    /// written the memo (`Clear`). Never the FIRST read — see ``filingVerdictCacheNow()``.
    public var filingVerdictCacheCountNow: Int { filingVerdictCacheNow().count }

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

    /// Proposes an automation for "this file went into that folder", with everything this scan
    /// already learned about the tree behind it.
    ///
    /// The seam exists so the offer is assembled in one place: the pages the scan read
    /// (``filingPageSamples``), the prepared profile/memory index, and the rules already saved.
    /// `destinationRelativePath` is provider-relative — the domain a rule's template lives in.
    /// Nothing is saved here; the caller shows the proposal and saves only if the user says so.
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
        // `.refine`, not `.free` — this is the same thing the refine pass is, for one card: an
        // explicit click asking the preferred backend for a better answer. Routing it to the free
        // tier would re-ask the model that already produced the destination being rejected.
        //
        // **Known gap, unchanged by the tier split:** a re-ask has never consulted
        // `cloudSpendAllows`, so on the cloud backend it spends without a pre-flight. A modal per
        // card click would be worse than the gap, and the hard monthly/total caps inside
        // `CloudFilingClassifier` still bound it — but it is the one paid path with no dialog, and
        // naming the tier is what makes that visible rather than incidental.
        let verdicts = await classifier(filingContext(taxonomyFolders: taxonomyFolders), [file], .refine)
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
    /// `public` so a caller outside the module can put a list on screen at all — `filingSuggestions`
    /// is `internal(set)` precisely so that nobody can do it any other way, and the render tests in
    /// `FileExplorer` need a lens showing results. Exposing THIS rather than the property is the
    /// point: the generation bump is not optional, and a setter that skipped it would silently
    /// disarm every staleness guard that reads it.
    public func publishFilingSuggestions(_ suggestions: [FilingSuggestion]) {
        filingSuggestions = suggestions
        filingSuggestionsGeneration &+= 1
    }

    /// Replaces a suggestion's candidates in place (keeps the card, updates its shown home).
    // `internal`, not `private`: `readScan(for:)` updates one card the same way "Try another"
    // does, and it lives in the router extension. Still not `public` — the generation bump above
    // is what every staleness guard reads, so wholesale replacement stays the only outside door.
    func replaceFilingSuggestion(_ id: String, candidates: [FilingDestination]) {
        guard let i = filingSuggestions.firstIndex(where: { $0.id == id }) else { return }
        let s = filingSuggestions[i]
        // **Named here too, or "Try another" answers differently from the scan.** The scan enriches
        // every candidate with the name the file would take there; a destination minted afterwards
        // would carry none, and since the apply path is gated on that name, the same folder reached
        // by rejecting a first suggestion would file the raw name while reaching it directly filed
        // `04. Apr 2025.pdf`. One folder, one answer.
        //
        // Read from disk rather than from the scan's taxonomy: this runs long after the walk, on
        // one folder the user just chose, and a single directory listing is cheaper than being
        // wrong about a tree that has moved on.
        let named = candidates.map { dest -> FilingDestination in
            guard dest.newSegments.isEmpty else { return dest }
            return dest.naming(Self.liveIncomingName(
                for: s.fileName, destination: dest.path, providerRoot: s.providerRoot,
                profile: filingFolderProfile, fileManager: fileManager))
        }
        filingSuggestions[i] = FilingSuggestion(filePath: s.filePath, fileName: s.fileName, size: s.size,
                                                modificationDate: s.modificationDate, candidates: named,
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
        // The rename backlog is a product of THIS scan, so it goes with it. Left behind it outlived
        // its own scope chip: `filingLastProviderRoot` is cleared four lines down, and that is what
        // the backlog's chip names — so the finding stayed on screen, still claiming N folders,
        // with nothing left to say which tree they were in.
        clearRenamePlans()
        filingScanFolder = nil
        filingLastCacheReuse = nil
        filingLastRefine = nil
        hasSuggestedFiling = false
        // Re-arm the auto-rescan: switching back to this provider should behave like a fresh
        // launch, exactly as Storage's restore does after `clearStorageLens()`.
        filingAutoRescanAttempted = nil
        filingLastProviderRoot = nil
        filingLastTaxonomyFolders = []
        filingLastExistingFolders = []
        filingSessionRejections = [:]
        // The refine guard, released wholesale for the same reason and with the same safety: a
        // still-out pass checks its invocation token before releasing or publishing, so clearing
        // here can neither strip a successor's guard nor land a stale verdict.
        filingRefineInFlight = nil
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
        let profile = filingFolderProfile
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
                // **Gated on the card having offered a rename.** The scan's proposal is what the
                // user saw and agreed to; without this the file is renamed whenever the destination
                // happens to number its files, including on paths that never displayed a name at
                // all — a move the user asked for silently becoming a move-and-rename.
                //
                // Given that consent, the SLOT is re-derived against the destination as it stands
                // now rather than as the scan found it, because a folder gains files while a queue
                // is open. So the card's promise decides *whether*, and the disk decides *which*.
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
