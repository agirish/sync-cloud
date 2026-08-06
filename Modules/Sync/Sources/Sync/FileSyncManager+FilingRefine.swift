import Events
import Foundation

/// Organize's **second pass** — the opt-in one that can cost money.
///
/// The scan (``FileSyncManager/findFilingSuggestions(folder:providerRoot:providerName:nameProvider:ignoringCache:options:fileManager:)``)
/// runs entirely at ``FilingClassifierTier/free`` and publishes a complete list of suggestions.
/// This pass takes that published list and re-asks the *preferred* backend — Claude, when the user
/// has enabled it and stored a key — for a better answer about the same files.
///
/// **It is not a scan, and the difference matters in three places.** It walks nothing (the
/// taxonomy the scan cached is the taxonomy it reasons about), it never touches
/// `filingScanLifecycle` (flipping `isSuggestingFiles` would swap the lens to its scanning view
/// and take the list off screen — the one thing an action called "refine what I'm looking at"
/// must not do), and its scope is handed in rather than recomputed. That last one is the same
/// rule ``FileSyncManager/applyRecommendedFiling(_:)`` follows and for a sharper reason here:
/// this pass is priced per file, so the count on the button and the array iterated below have to
/// be one value, not two derivations that agree today.
extension FileSyncManager {

    /// What a refine pass did, for the summary line beside the results.
    ///
    /// `classified` is what was actually sent — it is 0 when the spend guardrail declined, and
    /// reporting the batch size there would overstate what the user was charged for.
    public struct FilingRefineSummary: Sendable, Equatable {
        /// Suggestions in scope that needed an answer (rule-steered ones are excluded upstream).
        public let asked: Int
        /// Served from the verdict cache — already answered by this backend, at no new cost.
        public let reused: Int
        /// Actually sent to the backend.
        public let classified: Int
        /// Suggestions whose suggested home the pass actually moved. The honest headline: a pass
        /// that classified forty files and changed none did exactly that.
        public let changed: Int

        public init(asked: Int, reused: Int, classified: Int, changed: Int) {
            self.asked = asked
            self.reused = reused
            self.classified = classified
            self.changed = changed
        }
    }

    /// Whether there is a list to refine and a backend to refine it with.
    ///
    /// Deliberately says nothing about *cost* — that is ``filingCloudRefineAvailable`` (is a key
    /// stored, cheap enough to ask per render) and ``filingRoutesToCloud(_:)`` (will this be
    /// billed, resolved for real). The UI needs this one and the first of those: this decides
    /// whether the control can work at all, that decides whether it is worth offering — a refine
    /// routing back to the on-device model the scan already ran would improve nothing, so offering
    /// it as an upgrade would be a lie.
    public var canRefineFilingSuggestions: Bool {
        filingUsesAI && filingClassifier != nil && !isRefiningFilingSuggestions
            && !filingSuggestions.isEmpty
            && filingLastProviderRoot != nil && !filingLastTaxonomyFolders.isEmpty
    }

    /// The suggestions in `scope` a refine pass would actually ask about — everything except the
    /// ones an explicit user rule already steered.
    ///
    /// Exposed because the **button's count must be this number**. A rule-steered suggestion is
    /// dropped by `FilingEngine.applyVerdicts` no matter what the backend says, so including it
    /// would mean paying for an answer that is discarded on arrival, and counting it would mean
    /// quoting the user for work that is not going to happen.
    public func filingSuggestionsEligibleForRefine(_ scope: [FilingSuggestion]) -> [FilingSuggestion] {
        guard let root = filingLastProviderRoot else { return [] }
        // Provider-scoped for the same reason `tryAnotherFolder` validates its cached root: the
        // taxonomy this pass reasons against belongs to one provider, and a verdict resolved
        // against the wrong tree names a destination in the wrong provider.
        //
        // **De-duplicated by file path, and that is a correctness requirement rather than
        // tidiness.** `scope` comes from a caller, and two dictionaries downstream are built with
        // `uniqueKeysWithValues`, which TRAPS on a repeated key — a list naming the same file
        // twice crashed the process. Quietly sending a file twice would be no better: this pass is
        // priced per file, so a duplicate is a double charge and a count the button over-quotes.
        var seen: Set<String> = []
        return scope.filter {
            $0.providerRoot == root && $0.best?.remembered != true && seen.insert($0.filePath).inserted
        }
    }

    /// Re-asks the preferred backend about `scope`, and republishes the list with whatever it
    /// improves. Returns what it did, or nil when it declined to run at all.
    ///
    /// The shape mirrors the scan's phase 3 — cache split, snippets for the nameless, spend
    /// pre-flight, classify, record, apply — with three differences that come from running
    /// against a list already on screen:
    ///
    /// - **The cache split happens before the pre-flight, and that ordering is the honest price.**
    ///   A file whose verdict this backend already gave is not sent, so quoting for it would make
    ///   the figure the user approves a lie.
    /// - **The verdicts are recorded before the staleness check.** The call has happened and has
    ///   been billed; dropping its answers because the list moved on would mean paying twice for
    ///   a question that is already answered.
    /// - **A stale result is dropped, not applied.** If a rescan republished while this was out,
    ///   the cards on screen belong to that scan, and these verdicts are about the previous list.
    @discardableResult
    public func refineFilingSuggestions(_ scope: [FilingSuggestion]) async -> FilingRefineSummary? {
        guard canRefineFilingSuggestions, let classifier = filingClassifier,
              let root = filingLastProviderRoot else { return nil }
        let eligible = filingSuggestionsEligibleForRefine(scope)
        guard !eligible.isEmpty else { return nil }
        // One pass at a time — the check is `canRefineFilingSuggestions`' `isRefiningFilingSuggestions`
        // clause above, which reads the very token claimed on the next line. The button is disabled
        // while a pass runs, but a menu equivalent and a second click landing in the same run-loop
        // turn are not the button, and two passes would race each other's publish. Check and claim
        // are adjacent and there is no await between them, so the claim is atomic on this actor.
        let invocation = UUID()
        filingRefineInFlight = invocation
        defer {
            // Release only what this invocation still owns — `clearFiling()` can free the slot
            // mid-round-trip, and a successor's pass must not have its guard stripped by this
            // one's exit. Same ownership discipline as `filingTryAnotherInFlight`.
            if filingRefineInFlight == invocation { filingRefineInFlight = nil }
        }

        // Snapshot everything the verdicts will be interpreted against, at the point `root` was
        // validated. A scan of another provider during the round-trip swaps these; reading them
        // live afterwards would mark segments new against the wrong tree, and the "creates N new
        // folders" confirmation would be about folders in a different account.
        let taxonomyFolders = filingLastTaxonomyFolders
        let existingRelative = filingLastExistingFolders.isEmpty
            ? Set(taxonomyFolders) : filingLastExistingFolders
        let preAwaitGeneration = filingSuggestionsGeneration

        // Rejections, exactly as the scan builds them: persisted (token-keyed) plus this session's
        // path-keyed ones, relativized for the backend's exclusion list. Read here, pre-await,
        // because this list is what the REQUEST carries — it has to describe what was actually
        // sent. The apply filter re-reads them afterwards; see below.
        let scopedRejections = filingRejections(under: URL(fileURLWithPath: root))
        let excludedByFile = Dictionary(uniqueKeysWithValues: eligible.map { s in
            (s.filePath, rejectedFolders(for: s, in: scopedRejections)
                .compactMap { Self.relativePath($0, under: root) })
        })

        // Split against the cache first — see the doc above for why this precedes the pre-flight.
        let identity = resolvedFilingVerdictIdentity(for: .refine)
        var keysByFile: [String: FilingVerdictKey] = [:]
        var cachedVerdicts: [String: FilingVerdict] = [:]
        var misses = eligible
        if let identity {
            // Warmed off the main actor before `recordFilingVerdicts` reaches the synchronous
            // accessor, for the same reason the scan warms it: at the entry cap the file is
            // multi-megabyte, and decoding it on the main actor is a hitch the user sees.
            let cache = await loadedFilingVerdictCache()
            misses = []
            for s in eligible {
                let key = FilingVerdictKey(
                    filePath: s.filePath, modificationDate: s.modificationDate, size: s.size,
                    model: identity, promptVersion: CloudFilingProtocol.promptVersion,
                    excludedRelativePaths: excludedByFile[s.filePath] ?? [])
                keysByFile[s.filePath] = key
                if let hit = cache.verdict(for: key, providerRoot: root,
                                           existingRelative: existingRelative) {
                    cachedVerdicts[s.filePath] = hit
                } else {
                    misses.append(s)
                }
            }
        }

        var snippets: [String: String] = [:]
        if filingReadsContents, let extractor = filingSnippetExtractor, !misses.isEmpty {
            // Only files whose NAME says nothing: a meaningful name plus the folder tree is enough
            // for the model, and this skips OCR/PDF work — and its token cost — for named files.
            let namelessPaths = misses.filter { !FilingEngine.canRemember(fileName: $0.fileName) }
                .map { $0.filePath }
            snippets = await Self.extractSnippets(for: namelessPaths, using: extractor)
            if Task.isCancelled { return nil }
        }
        let files = misses.map { s in
            FilingCandidateFile(filePath: s.filePath, fileName: s.fileName,
                                ext: (s.fileName as NSString).pathExtension.lowercased(),
                                year: Self.modificationYear(s.modificationDate),
                                contentSnippet: snippets[s.filePath],
                                excludedRelativePaths: excludedByFile[s.filePath] ?? [])
        }

        var verdicts = cachedVerdicts
        var classifiedCount = 0
        if !files.isEmpty, cloudSpendAllows(files: files, taxonomyFolders: taxonomyFolders) {
            let fresh = await classifier(taxonomyFolders, files, .refine)
            // Before the staleness check, deliberately — the answer is already paid for.
            recordFilingVerdicts(fresh, keys: keysByFile, providerRoot: root,
                                 existingRelative: existingRelative)
            classifiedCount = files.count
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

        // Rejections RE-READ after the await, not the pre-await snapshot. `applyVerdicts` uses
        // these to refuse a verdict naming a folder the user rejected, and that is a claim about
        // what is on screen NOW — a "Try another" landing while this pass was out records a
        // rejection the snapshot cannot see, and applying against the stale copy re-suggests the
        // folder the user just rejected. (The request's exclusion list above is the opposite case:
        // it must stay pre-await, because it describes what was actually sent.)
        let liveRejections = filingRejections(under: URL(fileURLWithPath: root))
        var rejectedByFile: [String: Set<String>] = [:]
        for s in filingSuggestions {
            let paths = rejectedFolders(for: s, in: liveRejections)
            if !paths.isEmpty { rejectedByFile[s.filePath] = paths }
        }
        // `uniqueKeysWithValues` is safe here where it is not on `scope`: this maps the manager's
        // own published list, whose ids come from a directory walk.
        let before = Dictionary(uniqueKeysWithValues: filingSuggestions.map { ($0.id, $0.best?.path) })
        let refined = FilingEngine.applyVerdicts(verdicts, to: filingSuggestions,
                                                 existingRelative: existingRelative,
                                                 providerRoot: root, rejectedByFile: rejectedByFile)
        let changed = refined.filter { before[$0.id] != $0.best?.path }.count
        publishFilingSuggestions(refined)
        let summary = FilingRefineSummary(asked: eligible.count, reused: cachedVerdicts.count,
                                          classified: classifiedCount, changed: changed)
        filingLastRefine = summary
        Logger.shared.info("Filing: refined \(eligible.count) suggestion(s) — \(classifiedCount) sent to the backend, "
            + "\(cachedVerdicts.count) reused from cache, \(changed) home(s) changed")
        // The one state where the button and the router disagree: a key IS stored (so the button
        // offered Claude) but it could not be read (so the pass ran on-device). Nothing was
        // billed, and saying "no better homes found" would report a Claude verdict nobody got —
        // the honest answer names the key. See ``filingCloudRefineConfigured`` for why the cheap
        // display check is allowed to be weaker than the route.
        if filingCloudRefineIsDowngraded {
            Logger.shared.warning("Filing: refine ran on-device — Claude is switched on but the "
                + "saved key could not be read, so nothing was sent or billed")
            banner = .warning("Couldn't reach Claude — your saved API key couldn't be read. "
                              + "These are the on-device suggestions; check the key in Settings ▸ Organize.")
            return summary
        }
        // Success in both directions: "no better homes found" is a complete, correct answer to
        // what was asked, not a failure to warn about.
        banner = .success(changed > 0
            ? "Refined \(eligible.count) suggestion\(eligible.count == 1 ? "" : "s") — "
              + "\(changed) home\(changed == 1 ? "" : "s") changed."
            : "Refined \(eligible.count) suggestion\(eligible.count == 1 ? "" : "s") — "
              + "no better homes found.")
        return summary
    }

    /// Every folder rejected for `suggestion` — this session's path-keyed rejections plus the
    /// persisted token-keyed ones. The one derivation, so the request's exclusion list and the
    /// apply filter cannot answer differently for reasons other than *when* they ran.
    ///
    /// **`scopedRejections` is passed in, deliberately, rather than read here.** `filingRejections`
    /// decodes JSON out of `UserDefaults` on *every* access — the getters are hot enough that
    /// `readPersistedStore` documents a scan reading them per file — so a helper that fetched them
    /// itself would decode the whole store once per suggestion, on the main actor, twice per pass.
    /// Each caller decodes once and hands the result down.
    private func rejectedFolders(for suggestion: FilingSuggestion,
                                 in scopedRejections: [FilingRejection]) -> Set<String> {
        Self.rejectedPaths(forFileNamed: suggestion.fileName, in: scopedRejections)
            .union(filingSessionRejections[suggestion.filePath] ?? [])
    }
}
