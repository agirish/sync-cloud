import Events
import Foundation

/// Organize's second pass: the opt-in one that can cost money.
///
/// The scan (``FileSyncManager/findFilingSuggestions(folder:providerRoot:providerName:nameProvider:ignoringCache:options:fileManager:)``)
/// runs entirely at ``FilingClassifierTier/free`` and publishes a complete list. This pass re-asks
/// the preferred backend (Claude, when enabled with a stored key) about the same files.
///
/// It is not a scan, in three ways. It walks nothing: the scan's cached taxonomy is what it reasons
/// about. It never touches `filingScanLifecycle`, since flipping `isSuggestingFiles` would swap the
/// lens to its scanning view and take the list off screen. And its scope is handed in, as with
/// ``FileSyncManager/applyRecommendedFiling(_:)``: the pass is priced per file, so the count on the
/// button and the array iterated must be one value.
extension FileSyncManager {

    /// What a refine pass did, for the summary line beside the results. `classified` is what was
    /// actually sent: 0 when the spend guardrail declined, since the batch size would overstate
    /// what the user was charged for.
    public struct FilingRefineSummary: Sendable, Equatable {
        /// Why nothing was sent to Claude, when nothing was. `classified == 0` has three causes:
        /// every answer was cached, the user declined the charge, or Claude was chosen but its key
        /// couldn't be read so the pass ran on-device. The banner says which and goes away; this
        /// rides on ``FileSyncManager/filingLastRefine``, which the durable "refined" pill reads an
        /// hour later, so the cause is carried rather than guessed from the number.
        public enum Outcome: String, Sendable, Equatable, Codable {
            /// The pass reached the backend the user chose.
            case ran
            /// Claude's request failed partway, or couldn't start. Answers that arrived are kept.
            case failed
            /// The person stopped it. Answers that arrived are kept.
            case stopped
            /// The spend prompt was refused: Cancel, or "Use On-Device Instead".
            case declined
            /// Claude was switched on but its saved key could not be read, so this ran on-device.
            case downgraded
        }

        /// Suggestions in scope that needed an answer (rule-steered ones are excluded upstream).
        public let asked: Int
        /// Served from the verdict cache: already answered by this backend, at no new cost.
        public let reused: Int
        /// Sent to Claude, and so billable: 0 for every ``Outcome`` but ``Outcome/ran``. Not the
        /// number of files a classifier saw: a downgraded pass classifies on-device and this stays
        /// 0, which is why the log line reports its own count.
        public let classified: Int
        /// Suggestions whose home the pass actually moved: the honest headline, since a pass that
        /// classified forty files and changed none did exactly that. Can be non-zero when
        /// `classified` is 0: cached answers still apply, even on a declined pass.
        public let changed: Int
        /// Why the pass sent what it sent. See ``Outcome``.
        public let outcome: Outcome
        /// Suggestions in scope left out because their file is hidden from Claude
        /// (``FileSyncManager/filingSuggestionsHiddenFromClaude(_:)``). Not in `asked`.
        public let hiddenFromClaude: Int

        /// - Note: `outcome` defaults to ``Outcome/ran`` so call sites describing an ordinary pass
        ///   need not pass it. The three producers inside `refineFilingSuggestions` all do.
        public init(asked: Int, reused: Int, classified: Int, changed: Int,
                    outcome: Outcome = .ran, hiddenFromClaude: Int = 0) {
            self.asked = asked
            self.reused = reused
            self.classified = classified
            self.changed = changed
            self.outcome = outcome
            self.hiddenFromClaude = hiddenFromClaude
        }
    }

    /// Whether there is a list to refine and a backend to refine it with. Says nothing about cost:
    /// that is ``filingCloudRefineAvailable`` (is a key stored, cheap per render) and
    /// ``filingRoutesToCloud(_:)`` (will this be billed, resolved for real). The UI needs this and
    /// the first: this says whether the control can work, that whether it's worth offering, since a
    /// refine routed back to the on-device model the scan already ran would improve nothing.
    public var canRefineFilingSuggestions: Bool {
        filingUsesAI && filingClassifier != nil && !isRefiningFilingSuggestions
            && !filingSuggestions.isEmpty
            && filingLastProviderRoot != nil && !filingLastTaxonomyFolders.isEmpty
    }

    /// The suggestions in `scope` a refine pass would ask about: all but those an explicit user rule
    /// already steered and those whose file is hidden from Claude. The button's count must be this
    /// number. `FilingEngine.applyVerdicts` drops a rule-steered suggestion whatever the backend
    /// says, so including one would pay for an answer discarded on arrival, and counting it would
    /// quote for work that won't happen.
    public func filingSuggestionsEligibleForRefine(_ scope: [FilingSuggestion]) -> [FilingSuggestion] {
        guard let root = filingLastProviderRoot else { return [] }
        // Provider-scoped, as `tryAnotherFolder` checks its cached root: the taxonomy belongs to
        // one provider, and a verdict resolved against the wrong tree names a destination in the
        // wrong provider.
        //
        // De-duplicated by file path, for correctness: two dictionaries downstream are built with
        // `uniqueKeysWithValues`, which traps on a repeated key, and sending a file twice would be
        // a double charge and an over-quoted count.
        //
        // A file hidden from Claude is never eligible (Settings ▸ Ask Claude ▸ Privacy ▸ Hidden from
        // Claude): not its name, not its page, not a download to read it.
        let hidden = claudeHiddenMatcher()
        var seen: Set<String> = []
        return scope.filter {
            $0.providerRoot == root && $0.best?.remembered != true && !hidden.isHidden($0.filePath)
                && seen.insert($0.filePath).inserted
        }
    }

    /// How many suggestions in `scope` Refine leaves out because their file is hidden from Claude:
    /// the ones ``filingSuggestionsEligibleForRefine(_:)`` would otherwise have asked about.
    public func filingSuggestionsHiddenFromClaude(_ scope: [FilingSuggestion]) -> Int {
        guard let root = filingLastProviderRoot else { return 0 }
        let hidden = claudeHiddenMatcher()
        guard !hidden.isEmpty else { return 0 }
        var seen: Set<String> = []
        return scope.filter {
            $0.providerRoot == root && $0.best?.remembered != true && hidden.isHidden($0.filePath)
                && seen.insert($0.filePath).inserted
        }.count
    }

    /// The Hidden from Claude list (``AskClaudePrivacy``), read once per pass. Every `.refine`-tier
    /// request honours it: no file, folder name, excerpt or rejected folder inside a hidden folder
    /// goes to the backend. Read from `filingContentDefaults`, `.standard` in the app, so tests
    /// drive it without touching his own list.
    func claudeHiddenMatcher() -> AskClaudePrivacy.Matcher {
        AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: filingContentDefaults))
    }

    /// `relative` (under `root`) is a folder the backend may be shown.
    nonisolated static func shownToClaude(_ relative: String, under root: String,
                                          hidden: AskClaudePrivacy.Matcher) -> Bool {
        hidden.isEmpty || !hidden.isHidden((root as NSString).appendingPathComponent(relative))
    }

    /// The banner's clause for files left out as hidden from Claude, or "".
    public nonisolated static func hiddenFromClaudeNote(_ count: Int) -> String {
        switch count {
        case 0: return ""
        case 1: return " 1 file hidden from Claude was left out."
        default: return " \(count) files hidden from Claude were left out."
        }
    }

    /// Re-asks the preferred backend about `scope`, and republishes the list with whatever it
    /// improves. Returns what it did, or nil when it declined to run at all.
    ///
    /// This is the whole pass in one go: build the request, put today's spend dialog in front of it,
    /// send it. The same three halves are also exposed apart, as ``prepareFilingRefine(_:)`` and
    /// ``sendFilingRefine(_:scope:)``, for a plan that waits for a click (TE335).
    ///
    /// Mirrors the scan's phase 3 (cache split, snippets, spend pre-flight, classify, record,
    /// apply), with three differences from running against a list already on screen:
    ///
    /// - The cache split happens before the pre-flight, so the price is honest: a file this backend
    ///   already answered isn't sent, and quoting for it would misstate the figure approved.
    /// - Verdicts are recorded before the staleness check: the call is made and billed, and
    ///   dropping its answers because the list moved on would mean paying twice.
    /// - A stale result is dropped, not applied: if a rescan republished meanwhile, the cards on
    ///   screen belong to that scan, and these verdicts are about the previous list.
    @discardableResult
    public func refineFilingSuggestions(_ scope: [FilingSuggestion]) async -> FilingRefineSummary? {
        guard canRefineFilingSuggestions, let classifier = filingClassifier,
              let root = filingLastProviderRoot else { return nil }
        let eligible = filingSuggestionsEligibleForRefine(scope)
        let hiddenCount = filingSuggestionsHiddenFromClaude(scope)
        guard !eligible.isEmpty else {
            if hiddenCount > 0 {
                banner = .warning("Nothing was sent — "
                    + (hiddenCount == 1 ? "that file is" : "those files are") + " hidden from Claude.", log: .warn)
            }
            return nil
        }
        // One pass at a time: `canRefineFilingSuggestions` checks `isRefiningFilingSuggestions`,
        // the token claimed on the next line. The button is disabled while a pass runs, but a menu
        // equivalent or a second click in the same run-loop turn isn't, and two passes would race
        // each other's publish. Check and claim are adjacent with no await between, so the claim is
        // atomic on this actor.
        let invocation = UUID()
        filingRefineInFlight = invocation
        filingRefineStopRequested = false
        defer {
            // Release only what this invocation still owns: `clearFiling()` can free the slot
            // mid-round-trip, and a successor's guard must not be stripped by this one's exit. Same
            // ownership discipline as `filingTryAnotherInFlight`.
            if filingRefineInFlight == invocation { filingRefineInFlight = nil }
        }
        guard let work = await buildRefineWork(eligible: eligible, hiddenCount: hiddenCount, root: root,
                                               classifier: classifier) else { return nil }
        // Whether the pass was declined, not just whether it ran. `cloudSpendAllows` returns false
        // for both refusals (Cancel, and the over-cap dialog whose only button is "Use On-Device
        // Instead"), which downstream would look like "nothing to send", and a user who declined
        // would be told the pass ran and found no better homes.
        var declined = false
        if !work.files.isEmpty {
            declined = !cloudSpendAllows(files: work.files, taxonomyFolders: work.context.destinations,
                                         downloading: work.cloudOnly.count)
        }
        return await executeRefine(work, declined: declined, invocation: invocation)
    }

    /// What a pass has worked out before anything is sent: the batch, the cache split, the pages
    /// read, and the request they make. Built by ``buildRefineWork(eligible:hiddenCount:root:classifier:)``,
    /// priced by the plan, sent by ``executeRefine(_:declined:invocation:)``.
    struct RefineWork {
        typealias Request = (files: [FilingCandidateFile], shortlists: [String: [String]], context: FilingContext)
        let root: String
        let classifier: FilingClassifier
        let eligible: [FilingSuggestion]
        let hiddenCount: Int
        let hidden: AskClaudePrivacy.Matcher
        let existingRelative: Set<String>
        let preAwaitGeneration: Int
        let excludedByFile: [String: [String]]
        let keysByFile: [String: FilingVerdictKey]
        let cachedVerdicts: [String: FilingVerdict]
        let cloudOnly: [FilingSuggestion]
        let snippets: [String: String]
        let files: [FilingCandidateFile]
        let shortlists: [String: [String]]
        let context: FilingContext
        /// The request from a set of pages: built again once cloud-only files are downloaded.
        let request: @MainActor ([String: String]) -> Request
    }

    /// Everything up to the price: the hidden list, the snapshot the answers are read against, the
    /// rejections, the cache split, the pages, and the request. Sends and downloads nothing. nil
    /// when it was cancelled.
    func buildRefineWork(eligible: [FilingSuggestion], hiddenCount: Int, root: String,
                         classifier: @escaping FilingClassifier) async -> RefineWork? {
        // Once per pass: the matcher resolves each parent folder once and keeps it.
        let hidden = claudeHiddenMatcher()
        func shown(_ relative: String) -> Bool { Self.shownToClaude(relative, under: root, hidden: hidden) }
        // Snapshot everything the verdicts are interpreted against, where `root` was validated. A
        // scan of another provider during the round-trip swaps these; read live afterwards they
        // would mark segments new against the wrong tree, and the "creates N new folders"
        // confirmation would be about another account's folders. Hidden folders still exist, so
        // new-vs-existing reads the whole set; only what is sent leaves them out.
        let allTaxonomyFolders = filingLastTaxonomyFolders
        let existingRelative = filingLastExistingFolders.isEmpty
            ? Set(allTaxonomyFolders) : filingLastExistingFolders
        let taxonomyFolders = hidden.isEmpty ? allTaxonomyFolders : allTaxonomyFolders.filter(shown)
        let preAwaitGeneration = filingSuggestionsGeneration

        // Rejections as the scan builds them: persisted (token-keyed) plus this session's
        // path-keyed ones, relativized for the backend's exclusion list. Read before the await,
        // since the request carries this list and it must describe what was sent. The apply
        // filter re-reads them afterwards (below).
        let scopedRejections = filingRejections(under: URL(fileURLWithPath: root))
        let excludedByFile = Dictionary(uniqueKeysWithValues: eligible.map { s in
            // A rejected folder goes out as "avoid: …", so a hidden one is left off.
            (s.filePath, rejectedFolders(for: s, in: scopedRejections)
                .filter { !hidden.isHidden($0) }
                .compactMap { Self.relativePath($0, under: root) })
        })

        // Split against the cache first (see the doc above for why this precedes the pre-flight).
        let identity = resolvedFilingVerdictIdentity(for: .refine)
        let downloadsBeforeAsking = filingReadsContents && filingSnippetExtractor != nil
            && filingRoutesToCloud(.refine)
        var keysByFile: [String: FilingVerdictKey] = [:]
        var cachedVerdicts: [String: FilingVerdict] = [:]
        var misses = eligible
        // `artifacts` nil means the fingerprint is unavailable and the cache is off, read and
        // write (see the scan site in `FileSyncManager+Filing`). The stakes are highest here:
        // these are the paid answers.
        if let identity, let artifacts = filingRoutingFingerprint {
            // Warmed off the main actor before `recordFilingVerdicts` reaches the synchronous
            // accessor, as the scan does: at the entry cap the file is megabytes, and decoding it on
            // the main actor is a visible hitch.
            let cache = await loadedFilingVerdictCache()
            misses = []
            for s in eligible {
                // As on the scan tier, an unreadable mtime leaves the file unkeyed, so it is
                // re-asked rather than answered from a key built around a placeholder. These are
                // the paid answers, where a false hit is the expensive direction.
                guard let key = FilingVerdictKey(
                    filePath: s.filePath, modificationDate: s.modificationDate, size: s.size,
                    model: identity, promptVersion: CloudFilingProtocol.promptVersion,
                    excludedRelativePaths: excludedByFile[s.filePath] ?? [],
                    artifacts: artifacts, pageSent: downloadsBeforeAsking) else {
                    misses.append(s)
                    continue
                }
                keysByFile[s.filePath] = key
                // A cloud-only file's cached answer came from its name alone; this pass is about to
                // read it, so it is asked again.
                var hit: FilingVerdict?
                if !(downloadsBeforeAsking && filingNotDownloaded.contains(s.filePath)) {
                    hit = cache.verdict(for: key, providerRoot: root, existingRelative: existingRelative)
                    // An answer given with the page also answers a pass that would send the name
                    // alone; the reverse is not true.
                    if hit == nil, !key.pageSent {
                        hit = cache.verdict(for: key.withPageSent(true), providerRoot: root,
                                            existingRelative: existingRelative)
                    }
                }
                // A saved answer naming a hidden folder is a miss, not a hit: it would be dropped on
                // arrival, and the file would never reach Claude.
                if let saved = hit, !hidden.isEmpty,
                   let dest = FilingEngine.destination(from: saved, providerRoot: root,
                                                       existingRelative: existingRelative,
                                                       nameProvider: filingLastNameProvider),
                   hidden.isHidden(dest.path) {
                    hit = nil
                }
                if let hit {
                    cachedVerdicts[s.filePath] = hit
                } else {
                    misses.append(s)
                }
            }
        }

        var snippets: [String: String] = [:]
        if filingReadsContents, let extractor = filingSnippetExtractor, !misses.isEmpty {
            // Every file, not only the nameless ones. This is the pass the user asked for and the
            // only one that spends money, so it must not hand the model less than the router had:
            // a name-only verdict here is one the overlay refuses anyway (`contentBlind`), a paid
            // round-trip that changes nothing. The pre-flight below prices the extra excerpts.
            snippets = await Self.extractSnippets(for: misses.map { $0.filePath }, using: extractor)
            if Task.isCancelled { return nil }
        }
        /// The request this pass would send, from the pages in hand. Built twice when cloud-only
        /// files are downloaded after the price is agreed.
        func request(_ snippets: [String: String]) -> (files: [FilingCandidateFile],
                                                       shortlists: [String: [String]],
                                                       context: FilingContext) {
            let files = misses.map { s in
                FilingCandidateFile(filePath: s.filePath, fileName: s.fileName,
                                    ext: (s.fileName as NSString).pathExtension.lowercased(),
                                    year: Self.modificationYear(s.modificationDate),
                                    contentSnippet: snippets[s.filePath],
                                    excludedRelativePaths: excludedByFile[s.filePath] ?? [])
            }

            // Estimate the request that will actually be sent. The classifier gets
            // `context.destinations`, which drops inbox folders; pricing the unfiltered taxonomy
            // would over-estimate, and that can trip the spend cap and refuse a pass within budget.
            // The same folder menu the scan builds: the router's shortlist for these files ahead of
            // the shallow structural list. Ranked again rather than reusing the scan's, since a
            // refine runs on a few files, minutes later, against rejections the scan never saw.
            // `preferredFolders` is called with or without a router index, because its fallback is
            // the card's own candidates; without it an unsurveyed tree would send the paid model a
            // capped shallow list missing the answer the free pass already found.
            var preferred: [String] = []
            var shortlists: [String: [String]] = [:]
            if let index = filingRouterIndex {
                // Through the peer-name rerank, because the scan's menu is (`Self.route` reranks).
                // Ranked raw, a folder and its own subfolder a percent apart could be shortlisted in
                // opposite orders by the scan and a refine of the same file, handing the paid
                // classifier a different menu for one question.
                let peerNames = peerNameLookup()
                shortlists = Dictionary(uniqueKeysWithValues: misses.map { s in
                    let ranked = FilingRouter.rank(fileName: s.fileName, contentSnippet: snippets[s.filePath],
                                                   index: index,
                                                   excluding: Set(excludedByFile[s.filePath] ?? []),
                                                   limit: 8)
                    let ranking = FilingRouter.rerankedByPeerNames(ranked, fileName: s.fileName) { relative in
                        peerNames(root + "/" + relative)
                    }
                    return (s.filePath, ranking.candidates.map(\.relativePath).filter(shown))
                })
            }
            // Filtered too: a card's own candidates can name a hidden folder the scan chose.
            preferred = Self.preferredFolders(for: files, shortlists: shortlists,
                                              in: eligible, providerRoot: root).filter(shown)
            let context = filingContext(
                taxonomyFolders: FilingEngine.classifierFolders(preferred: preferred,
                                                                fallback: taxonomyFolders))
            return (files, shortlists, context)
        }
        // Cloud-only files are downloaded, after the price is agreed. The extractor never fetches,
        // so a file only in iCloud would reach the model as its name alone. The quote prices their
        // first pages as though read and says how many will download; nothing is fetched before
        // the user agrees, nor when the pass isn't going to Claude at all.
        let cloudOnly = downloadsBeforeAsking
            ? misses.filter { filingNotDownloaded.contains($0.filePath) && snippets[$0.filePath] == nil }
            : []
        var priced = snippets
        for s in cloudOnly {
            priced[s.filePath] = String(repeating: "x ", count: CloudFilingProtocol.maxSnippetChars / 2)
        }
        let (files, shortlists, context) = request(priced)
        return RefineWork(root: root, classifier: classifier, eligible: eligible, hiddenCount: hiddenCount,
                          hidden: hidden, existingRelative: existingRelative,
                          preAwaitGeneration: preAwaitGeneration, excludedByFile: excludedByFile,
                          keysByFile: keysByFile, cachedVerdicts: cachedVerdicts, cloudOnly: cloudOnly,
                          snippets: snippets, files: files, shortlists: shortlists, context: context,
                          request: { request($0) })
    }

    /// Downloads, sends, records and applies a built pass. `declined` is the spend dialog's refusal.
    /// The caller holds `invocation` in `filingRefineInFlight`.
    func executeRefine(_ work: RefineWork, declined: Bool, invocation: UUID) async -> FilingRefineSummary? {
        let root = work.root, classifier = work.classifier, eligible = work.eligible
        let hiddenCount = work.hiddenCount, hidden = work.hidden, existingRelative = work.existingRelative
        let preAwaitGeneration = work.preAwaitGeneration, keysByFile = work.keysByFile
        let cachedVerdicts = work.cachedVerdicts, cloudOnly = work.cloudOnly, request = work.request
        var snippets = work.snippets
        var (files, shortlists, context) = (work.files, work.shortlists, work.context)
        var verdicts = cachedVerdicts
        var classifiedCount = 0
        if !declined, !cloudOnly.isEmpty, let extractor = filingSnippetExtractor {
            isDownloadingFilingFiles = true
            let (landed, pending, refused) = await fetchCloudOnlyFiles(cloudOnly)
            isDownloadingFilingFiles = false
            filingNotDownloaded.subtract(landed)
            snippets.merge(await Self.extractSnippets(for: landed, using: extractor)) { _, new in new }
            if Task.isCancelled { return nil }
            // The survey reads the page too, as Download and Read would: a card the model leaves
            // alone shouldn't go on saying it was placed by name.
            if filingSuggestionsGeneration == preAwaitGeneration, filingLastProviderRoot == root,
               let index = filingRouterIndex {
                for path in landed {
                    guard let text = snippets[path],
                          let live = filingSuggestions.first(where: { $0.filePath == path }),
                          let best = routeWithPage(live, text: text, providerRoot: root, index: index).best
                    else { continue }
                    replaceFilingSuggestion(live.id, candidates: [best])
                }
            }
            Logger.shared.info("Filing: refine downloaded \(landed.count) of \(cloudOnly.count) cloud-only file(s) to read page 1"
                + (pending.isEmpty ? "" : ", \(pending.count) still downloading")
                + (refused == 0 ? "" : ", \(refused) refused"))
        }
        (files, shortlists, context) = request(snippets)
        // What a classifier saw, whichever one it was. Separate from `classifiedCount` ("sent to
        // Claude", the billable figure): a downgraded pass classifies every file on-device while
        // that stays 0, and the log should report the pass as run in full.
        var sentToBackend = 0
        var result: FilingRefineResult?
        if !files.isEmpty, !declined {
            let fresh: [String: FilingVerdict]
            if filingRoutesToCloud(.refine), let refiner = filingRefineClassifier {
                // Claude, streamed, and it says how it ended. No on-device answer stands in for a
                // failed one. The task is kept so Stop can end the request; cancelling this pass's own
                // task ends it too.
                let stopped = filingRefineStopRequested
                let run = Task { stopped ? FilingRefineResult(ending: .stopped) : await refiner(context, files) }
                filingRefineRun = run
                let reply = await withTaskCancellationHandler { await run.value } onCancel: { run.cancel() }
                filingRefineRun = nil
                result = reply
                fresh = reply.verdicts
                sentToBackend = reply.sent
                classifiedCount = reply.started ? reply.sent : 0
            } else {
                fresh = await classifier(context, files, .refine)
                sentToBackend = files.count
                // Not counted when downgraded to on-device: `classifiedCount` is what the durable
                // "refined" pill reports as "N files were sent to Claude", and it must agree with the
                // banner saying nothing was sent or billed.
                classifiedCount = filingCloudRefineIsDowngraded ? 0 : files.count
            }
            // Before the staleness check, deliberately: the answer is already paid for.
            recordFilingVerdicts(fresh, keys: keysByFile, providerRoot: root,
                                 existingRelative: existingRelative)
            verdicts.merge(fresh) { _, new in new }
        }

        // The list these verdicts are about must still be the list on screen. A rescan republishes
        // wholesale and bumps the generation; applying an old pass's verdicts to a new scan's cards
        // would silently move homes the new scan just computed.
        guard filingRefineInFlight == invocation,
              filingSuggestionsGeneration == preAwaitGeneration else {
            Logger.shared.info("Filing: refine result discarded — the suggestions were replaced while it ran")
            return nil
        }

        // Rejections re-read after the await, not the earlier snapshot. `applyVerdicts` uses them
        // to refuse a folder the user rejected, a claim about what is on screen now: a "Try
        // another" landing while this pass was out records a rejection the snapshot can't see, and
        // the folder just rejected would be suggested again. (The request's exclusion list stays
        // pre-await, because it describes what was sent.)
        let liveRejections = filingRejections(under: URL(fileURLWithPath: root))
        var rejectedByFile: [String: Set<String>] = [:]
        for s in filingSuggestions {
            let paths = rejectedFolders(for: s, in: liveRejections)
            if !paths.isEmpty { rejectedByFile[s.filePath] = paths }
        }
        // `uniqueKeysWithValues` is safe here, unlike on `scope`: this maps the manager's own
        // published list, whose ids come from a directory walk.
        let before = Dictionary(uniqueKeysWithValues: filingSuggestions.map { ($0.id, $0.best?.path) })
        // The scan's rule, as the same expression: see `FilingEngine.contentBlindFiles`.
        let contentBlind = FilingEngine.contentBlindFiles(
            handedOver: eligible.map { $0.filePath }, read: Set(snippets.keys),
            hadReader: filingReadsContents && filingSnippetExtractor != nil)
        // The profile and registry are passed here as on the scan, so the cross-person veto also
        // guards Refine, the pass most likely to name a confident wrong person, and one family
        // member's document can't be filed into another's.
        //
        // Claude was never shown a hidden folder, so an answer that resolves into one (a guess, a
        // new folder that lands there, or a verdict cached before it was hidden) isn't taken, and
        // the free suggestion stands. Judged on the folder the answer resolves to, as
        // `applyVerdicts` reads it (trimmed, root prefix stripped), not its raw spelling:
        // " Archive/2026" and "<root>/Archive/2026" both land in Archive/2026.
        let usable = hidden.isEmpty ? verdicts : verdicts.filter {
            guard let dest = FilingEngine.destination(from: $0.value, providerRoot: root,
                                                      existingRelative: existingRelative,
                                                      nameProvider: filingLastNameProvider)
            else { return true }   // unresolvable: applyVerdicts drops it anyway
            return !hidden.isHidden(dest.path)
        }
        let refined = FilingEngine.applyVerdicts(usable, to: filingSuggestions,
                                                 existingRelative: existingRelative,
                                                 providerRoot: root, nameProvider: filingLastNameProvider,
                                                 rejectedByFile: rejectedByFile,
                                                 contentBlind: contentBlind,
                                                 // The shortlists this pass ranked and showed the
                                                 // model, so an answer from them can lead, and one
                                                 // past them can't, as on the scan.
                                                 routerShortlists: shortlists,
                                                 shortlistVerdictsLead: true,
                                                 satelliteHomes: filingSatelliteHomes,
                                                 profile: filingRoutingProfile,
                                                 registry: filingPersonRegistry,
                                                 pageSamples: filingPageSamples,
                                                 identity: filingPersonIdentity,
                                                 onVeto: { [weak self] refusal in
                                                     self?.recordPersonVeto(refusal)
                                                 })
        let changed = refined.filter { before[$0.id] != $0.best?.path }.count
        publishFilingSuggestions(refined)
        // Resolved once here, so the pill's summary and the banners below can't describe the same
        // pass differently. `downgraded` outranks `declined`: the spend prompt is only reached with
        // the cloud route selected, and if that route is unreachable the pass ran on-device.
        let ran: FilingRefineSummary.Outcome
        switch result?.ending {
        case .stopped?: ran = .stopped
        case .failed?: ran = .failed
        default: ran = .ran
        }
        let outcome: FilingRefineSummary.Outcome =
            filingCloudRefineIsDowngraded ? .downgraded : (declined ? .declined : ran)
        let summary = FilingRefineSummary(asked: eligible.count, reused: cachedVerdicts.count,
                                          classified: classifiedCount, changed: changed,
                                          outcome: outcome, hiddenFromClaude: hiddenCount)
        let hiddenNote = Self.hiddenFromClaudeNote(hiddenCount)
        filingLastRefine = summary
        // `sentToBackend`, not `classifiedCount` (see the declaration). The route is named because
        // the number alone can't tell a pass nobody paid for from one nobody ran.
        Logger.shared.info("Filing: refined \(eligible.count) suggestion(s) — \(sentToBackend) sent to "
            + "\(outcome == .downgraded ? "the on-device backend (Claude's key was unreadable)" : "the backend")"
            + ", \(cachedVerdicts.count) reused from cache, \(changed) home(s) changed"
            + (hiddenCount == 0 ? "" : ", \(hiddenCount) hidden from Claude left out")
            + (outcome == .declined ? " — the cloud pass was declined" : ""))
        // The one state where the button and the router disagree: a key is stored (so the button
        // offered Claude) but couldn't be read (so the pass ran on-device). Nothing was billed, and
        // "no better homes found" would report a Claude verdict nobody got, so name the key. See
        // ``filingCloudRefineConfigured`` for why the cheap display check may be weaker than the
        // route.
        if filingCloudRefineIsDowngraded {
            Logger.shared.warning("Filing: refine ran on-device — Claude is switched on but the "
                + "saved key could not be read, so nothing was sent or billed")
            banner = .warning("Couldn’t reach Claude — your saved API key couldn’t be read. "
                              + "These are the on-device suggestions; check the key in Settings ▸ Ask Claude.", log: .loggedAtSite)
            return summary
        }
        // A declined charge is not a result. Nothing was sent or re-routed, so only cached answers
        // were applied, and "no better homes found" would report an outcome the user's own Cancel
        // prevented.
        if declined {
            // And say what the cache did anyway: a cached answer still applies and can move a
            // home, so the banner says so rather than leave the user to notice the list changed.
            // "Unchanged" only where it's provably true: with no cached verdicts, `applyVerdicts`
            // short-circuits on an empty dictionary.
            var text = "Nothing was sent — the cloud pass was declined."
            if cachedVerdicts.isEmpty {
                text += " The suggestions are unchanged."
            } else {
                text += " \(cachedVerdicts.count) answer\(cachedVerdicts.count == 1 ? " was" : "s were")"
                    + " reused from the cache"
                text += changed == 0
                    ? ", and no home changed."
                    : ", moving \(changed) home\(changed == 1 ? "" : "s")."
            }
            banner = .warning(text + hiddenNote, log: .warn)
            return summary
        }
        // Stopped or failed: say what came of it, what was kept and whether anything may have been
        // billed. Not a success banner over a pass that didn't finish.
        if let result, result.ending != .answered {
            banner = .warning(Self.refineEndingText(result, changed: changed) + hiddenNote, log: .warn)
            return summary
        }
        // Success in both directions: "no better homes found" is a complete, correct answer to
        // what was asked, not a failure to warn about.
        var capNote = ""
        if let result, result.sent < files.count {
            capNote = " \(result.sent) of \(files.count) went in this request; press Refine again for the rest."
        }
        banner = .success((changed > 0
            ? "Refined \(eligible.count) suggestion\(eligible.count == 1 ? "" : "s") — "
              + "\(changed) home\(changed == 1 ? "" : "s") changed."
            : "Refined \(eligible.count) suggestion\(eligible.count == 1 ? "" : "s") — "
              + "no better homes found.") + capNote + hiddenNote)
        return summary
    }

    /// Ends the refine request that is out, if one is. What had arrived is kept (LS).
    /// Pressed before the request began, it stops the pass before sending anything.
    public func stopFilingRefine() {
        guard isRefiningFilingSuggestions else { return }
        filingRefineStopRequested = true
        filingRefineRun?.cancel()
    }

    /// What a pass that stopped or failed says, in the banner: how many answers arrived and were
    /// kept, how many homes they moved, and whether anything may have been billed.
    static func refineEndingText(_ result: FilingRefineResult, changed: Int) -> String {
        let reason: String?
        let lead: String
        switch result.ending {
        case .answered: return ""
        case .stopped: reason = nil; lead = "Stopped."
        case .failed(let why): reason = why; lead = result.started ? "Claude didn’t finish." : "Couldn’t ask Claude."
        }
        var text = lead + (reason.map { " " + $0 } ?? "")
        guard result.started else { return text + " Nothing was sent, and the suggestions are unchanged." }
        if result.answered > 0 {
            text += " \(result.answered) of \(result.sent) answers arrived and were kept"
                + (changed == 0 ? "." : ", moving \(changed) home\(changed == 1 ? "" : "s").")
        } else {
            text += " Nothing came back, so the suggestions are unchanged."
        }
        let cost = FilingSpendFormat.cost(result.costUSD)
        if case .stopped = result.ending {
            text += result.costUSD > 0 ? " About \(cost) was billed for what ran." : ""
        } else {
            text += " A request had started, so up to about \(cost) may have been billed."
        }
        return text
    }

    /// Every folder rejected for `suggestion`: this session's path-keyed rejections plus the
    /// persisted token-keyed ones. One derivation, so the request's exclusion list and the apply
    /// filter differ only in when they ran.
    ///
    /// `scopedRejections` is passed in, not read here: `filingRejections` decodes JSON from
    /// `UserDefaults` on every access, so fetching it here would decode the whole store once per
    /// suggestion, on the main actor, twice per pass. Each caller decodes once.
    private func rejectedFolders(for suggestion: FilingSuggestion,
                                 in scopedRejections: [FilingRejection]) -> Set<String> {
        Self.rejectedPaths(forFileNamed: suggestion.fileName, in: scopedRejections)
            .union(filingSessionRejections[suggestion.filePath] ?? [])
    }
}

// MARK: - A plan that waits for a click (TE335, C1)

extension FileSyncManager {

    /// What a Refine pass would send and what it would cost, worked out and shown before anything
    /// leaves the Mac. One is open per source: ``prepareFilingRefine(_:)`` replaces the last, and
    /// ``sendFilingRefine(_:scope:)`` takes it, so a second click on Send finds nothing.
    public struct FilingRefinePlan: Sendable, Equatable, Identifiable {
        /// What Send will be billed as.
        public enum Billing: Sendable, Equatable {
            /// The pass doesn't reach Claude, or nothing needs sending: no charge.
            case notBilled
            /// Must not run (no price for the model); the reason is in the log.
            case blocked
            /// Priced as the classifier will price it.
            case quote(FilingSpendPreflight)
        }

        public let id: UUID
        /// The source this plan belongs to.
        public let providerRoot: String
        /// The suggestions Refine may ask about (the button's count): not rule-steered, not hidden.
        public let eligible: Int
        /// Suggestions left out because their file is hidden from Claude.
        public let hiddenFromClaude: Int
        /// Eligible suggestions already answered by this backend: reused free.
        public let reused: Int
        /// Files in the request.
        public let toSend: Int
        /// Cloud-only files that would download, and stay downloaded, so page 1 can be read.
        public let downloads: Int
        public let billing: Billing
        /// The list on screen when the plan was made.
        let generation: Int
        /// What the request is made of: the files, the folders each rejected, which ones download,
        /// the counts and the price. Send builds the request again and sends only if this still
        /// matches.
        let fingerprint: [String]
    }

    /// What ``sendFilingRefine(_:scope:)`` did.
    public enum FilingRefineSendResult: Sendable, Equatable {
        /// The pass ran.
        case sent(FilingRefineSummary)
        /// What would be sent or what it would cost changed since the plan: nothing was sent, and
        /// this plan, now the open one, says what Send would do.
        case requoted(FilingRefinePlan)
        /// The plan was replaced, already sent, or the list it was about is gone.
        case stale
        /// A pass is already running, or Refine can't run now.
        case unavailable
        /// Over the limit, or no price for the model: nothing was sent.
        case blocked
        /// Every eligible file went hidden since the plan.
        case nothingToSend
    }

    /// Works out the request and its price without sending, downloading or asking anything, and
    /// keeps the result as this source's open plan. nil when Refine can't run or has nothing to ask.
    public func prepareFilingRefine(_ scope: [FilingSuggestion]) async -> FilingRefinePlan? {
        guard canRefineFilingSuggestions, let classifier = filingClassifier,
              let root = filingLastProviderRoot else { return nil }
        let eligible = filingSuggestionsEligibleForRefine(scope)
        guard !eligible.isEmpty else { return nil }
        guard let work = await buildRefineWork(eligible: eligible, hiddenCount: filingSuggestionsHiddenFromClaude(scope),
                                               root: root, classifier: classifier) else { return nil }
        // The list moved on while the pages were read: this plan is about the old one.
        guard filingSuggestionsGeneration == work.preAwaitGeneration, filingLastProviderRoot == root else { return nil }
        let plan = refinePlan(from: work)
        filingOpenRefinePlans[root] = plan
        return plan
    }

    /// Drops an open plan (the card's Cancel).
    public func discardFilingRefinePlan(_ plan: FilingRefinePlan) {
        if filingOpenRefinePlans[plan.providerRoot]?.id == plan.id { filingOpenRefinePlans[plan.providerRoot] = nil }
    }

    /// Sends an open plan. **Builds the whole request again first**, from the list on screen now
    /// (`scope`), the Hidden from Claude list as it is now and the saved answers as they are now, and
    /// sends only if that is what the plan quoted. If a rescan, a Try Another, a newly hidden folder
    /// or a change of price made it something else, nothing is sent and the new plan is returned to
    /// be read again. No dialog: the plan was the quote.
    public func sendFilingRefine(_ plan: FilingRefinePlan, scope: [FilingSuggestion]) async -> FilingRefineSendResult {
        // Taking the plan is the claim against a double click: the second send finds none.
        guard filingOpenRefinePlans[plan.providerRoot]?.id == plan.id else { return .stale }
        filingOpenRefinePlans[plan.providerRoot] = nil
        guard canRefineFilingSuggestions, let classifier = filingClassifier,
              let root = filingLastProviderRoot, root == plan.providerRoot else { return .unavailable }
        let eligible = filingSuggestionsEligibleForRefine(scope)
        guard !eligible.isEmpty else { return .nothingToSend }
        guard let work = await buildRefineWork(eligible: eligible, hiddenCount: filingSuggestionsHiddenFromClaude(scope),
                                               root: root, classifier: classifier) else { return .stale }
        let fresh = refinePlan(from: work)
        guard fresh.generation == plan.generation, fresh.fingerprint == plan.fingerprint else {
            // A different list (a rescan) means a different plan, not an amended one.
            guard filingSuggestionsGeneration == work.preAwaitGeneration else { return .stale }
            filingOpenRefinePlans[root] = fresh
            return .requoted(fresh)
        }
        switch fresh.billing {
        case .blocked: return .blocked
        case .quote(let quote) where quote.wouldExceedCap: return .blocked
        default: break
        }
        // The list can move during the rebuild's awaits; sending then would pay for answers that
        // are dropped on arrival. Checked next to the claim, with no await between.
        guard filingSuggestionsGeneration == work.preAwaitGeneration, canRefineFilingSuggestions else { return .stale }
        let invocation = UUID()
        filingRefineInFlight = invocation
        filingRefineStopRequested = false
        defer { if filingRefineInFlight == invocation { filingRefineInFlight = nil } }
        guard let summary = await executeRefine(work, declined: false, invocation: invocation) else { return .stale }
        return .sent(summary)
    }

    private func refinePlan(from work: RefineWork) -> FilingRefinePlan {
        let billing: FilingRefinePlan.Billing
        if work.files.isEmpty {
            billing = .notBilled
        } else {
            switch filingSpendGate(files: work.files, taxonomyFolders: work.context.destinations,
                                   downloading: work.cloudOnly.count) {
            case .notBilled: billing = .notBilled
            case .blocked: billing = .blocked
            case .billable(let preflight): billing = .quote(preflight)
            }
        }
        let cloudOnly = Set(work.cloudOnly.map(\.filePath))
        var fingerprint = work.files.map { file in
            file.filePath + "|" + file.excludedRelativePaths.sorted().joined(separator: ",")
                + (cloudOnly.contains(file.filePath) ? "|download" : "")
                + (file.contentSnippet == nil ? "" : "|text")
        }.sorted()
        fingerprint.append("eligible \(work.eligible.count) reused \(work.cachedVerdicts.count) hidden \(work.hiddenCount)")
        switch billing {
        case .quote(let q): fingerprint.append("quote \(q.model) \(q.fileCount) \(q.estCostUSD) \(q.downloadCount) \(q.wouldExceedCap)")
        case .blocked: fingerprint.append("blocked")
        case .notBilled: fingerprint.append("notBilled")
        }
        return FilingRefinePlan(id: UUID(), providerRoot: work.root, eligible: work.eligible.count,
                                hiddenFromClaude: work.hiddenCount, reused: work.cachedVerdicts.count,
                                toSend: work.files.count, downloads: work.cloudOnly.count, billing: billing,
                                generation: work.preAwaitGeneration, fingerprint: fingerprint)
    }
}

// MARK: - §5.6: the mapping refine

extension FileSyncManager {

    /// What a mapping refine came back with, three outcomes the sheet must not conflate:
    /// proposals, the user declining the quote, and a pass that couldn't run.
    public enum MappingRefineOutcome: Sendable, Equatable {
        case proposals([MappingRefineProposal])
        /// The spend prompt was refused: nothing was sent, and "check your key" would be the wrong
        /// sentence.
        case declined
        /// No transport, an unpriced model, or a hard failure: the sheet says the pass couldn't
        /// run.
        case unavailable
        /// The family, a member or a mapped folder is hidden from Claude: nothing was sent.
        case hiddenFromClaude
    }

    /// Whether `request` names a folder hidden from Claude: the family, a folder its rows were
    /// drawn from (a member — a sibling family's too, with the group on), or a mapped folder
    /// inside one. `root` is the folder the request's paths are relative to.
    func mappingRefineTouchesHiddenFolder(_ request: MappingRefineRequest, under root: String) -> Bool {
        let hidden = claudeHiddenMatcher()
        guard !hidden.isEmpty else { return false }
        if hidden.isHidden((root as NSString).appendingPathComponent(request.family)) { return true }
        for folder in request.drawnFrom {
            let path = (root as NSString).appendingPathComponent(folder)
            if hidden.isHidden(path) { return true }
            for row in request.rows where hidden.isHidden((path as NSString).appendingPathComponent(row.source)) {
                return true
            }
        }
        return false
    }

    /// The mapping refine's entry point: the spend pre-flight every paid call gets (quoted for the
    /// model the transport will resolve, against the same caps and store), then the injected
    /// transport. On the mapping, never on the apply; the caller edits rows with what comes back.
    ///
    /// `root` is the folder the request's family is relative to. Given, a request that names a
    /// folder hidden from Claude is refused before anything is priced or sent.
    public func refineMapping(_ request: MappingRefineRequest, under root: String? = nil) async -> MappingRefineOutcome {
        guard let mappingRefiner else { return .unavailable }
        if let root, mappingRefineTouchesHiddenFolder(request, under: root) {
            Logger.shared.info("Mapping refine skipped — part of “\(request.family)” is hidden from Claude")
            return .hiddenFromClaude
        }
        // Unlike the filing refine there is no on-device fallback for naming: the pass reaches
        // Claude or doesn't run. So the route gate is hard, and it keeps a stored key from being
        // billed while the cloud toggle is off: the transport reads the Keychain directly and must
        // never be reached around the router.
        guard filingRoutesToCloud(.refine) else {
            Logger.shared.info("Mapping refine skipped — the refine tier does not route to "
                + "Claude (cloud off, or no usable key), and naming has no on-device model")
            return .unavailable
        }
        let model = filingRefineModelID
        // An unpriced model is not a free one, as in the filing refine's gate: no quote, no cap
        // arithmetic, no call.
        guard let estCost = MappingRefineProtocol.estimatedCostUSD(model: model,
                                                                   request: request) else {
            Logger.shared.warning("Mapping refine skipped — no price is known for model "
                + "“\(model)”, so the cost could not be quoted. Pick one of the offered "
                + "models in Settings ▸ Organize.")
            return .unavailable
        }
        let tokens = MappingRefineProtocol.estimateTokens(request: request)
        let preflight = FilingSpendPreflight(
            fileCount: request.rows.count, model: model,
            estInputTokens: tokens.input, estOutputTokens: tokens.output,
            estCostUSD: estCost,
            monthlySpentUSD: AskClaudeSpend.spent(in: filingContentDefaults),
            monthlyCapUSD: AskClaudeSpend.limit(in: filingContentDefaults),
            totalSpentUSD: 0, totalCapUSD: 0,
            unit: "folder name")
        guard filingCloudSpendConfirmer(preflight) else {
            // Two cases end in `false`, and the sheet words them differently on purpose: over the
            // cap the dialog offered no proceed button, so the budget said no (`.unavailable`,
            // whose sentence names the caps), and "Declined at the estimate" would blame the
            // person for a refusal they never made.
            if preflight.wouldExceedCap {
                Logger.shared.info("Mapping refine blocked at the budget cap "
                    + "(\(FilingSpendFormat.cost(estCost)) for \(request.rows.count) name(s)) "
                    + "— nothing was sent")
                return .unavailable
            }
            Logger.shared.info("Mapping refine declined at the estimate "
                + "(\(FilingSpendFormat.cost(estCost)) for \(request.rows.count) name(s)) "
                + "— nothing was sent")
            return .declined
        }
        guard let proposals = await mappingRefiner(request) else { return .unavailable }
        return .proposals(proposals)
    }
}
