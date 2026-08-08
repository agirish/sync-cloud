import Events
import Foundation

// Phase 2.5 of the filing scan: the tree's own profile and memory, applied with no model call.
//
// It sits between the keyword engine and the classifier because that is exactly what it is worth —
// better than filename overlap, free, and able to answer for files the on-device model would be
// asked about. Measured over 9,558 filed documents, it takes top-1 routing from 28.9% (profile
// alone) to 58.2%. Every part of it is gated on the tree having been surveyed; with no artifacts
// loaded, `filingRouterIndex` is nil and this whole phase is a no-op.
extension FileSyncManager {

    /// Builds the router index for a taxonomy, reusing the last one when the taxonomy has not moved.
    func prepareFilingRouter(destinations: Set<String>) {
        guard filingFolderProfile != nil || filingMemory != nil, !destinations.isEmpty else {
            invalidateFilingRouterIndex()
            return
        }
        if filingRouterIndex != nil, filingRouterIndexKey == destinations { return }
        filingRouterIndex = FilingRouter.makeIndex(destinations: Array(destinations),
                                                   profile: filingFolderProfile,
                                                   memory: filingMemory)
        filingRouterIndexKey = destinations
        filingRouterIndexBuilds += 1
    }

    /// The context handed to a classifier — the taxonomy plus whatever has been learned about it.
    func filingContext(taxonomyFolders: [String]) -> FilingContext {
        FilingContext(taxonomyFolders: taxonomyFolders,
                      profile: filingFolderProfile, memory: filingMemory)
    }

    /// The folders worth spending the classifier's budget on, most-deserving first — the router's
    /// shortlist for each file being classified, plus the homes the earlier phases already proposed
    /// for files the router did not rank (a file with a confident home is skipped by phase 2.5, and
    /// its heuristic candidates are the best evidence there is about it).
    ///
    /// **Round-robin, not concatenated.** A hundred loose files times eight candidates is eight
    /// hundred paths for a budget of a few hundred, and taking them in file order would spend the
    /// whole thing on the first twenty files — leaving the rest with a menu that says nothing about
    /// them, which is the failure this list exists to prevent. Taking every file's first choice,
    /// then every file's second, degrades evenly instead.
    nonisolated static func preferredFolders(for files: [FilingCandidateFile],
                                             shortlists: [String: [String]],
                                             in suggestions: [FilingSuggestion],
                                             providerRoot: String) -> [String] {
        var lists: [[String]] = []
        var candidatesByFile: [String: [String]] = [:]
        for s in suggestions {
            let paths = s.candidates.compactMap { relativePath($0.path, under: providerRoot) }
            if !paths.isEmpty { candidatesByFile[s.filePath] = paths }
        }
        for f in files {
            // The router's ranking when there is one; otherwise what the file already suggests.
            let list = shortlists[f.filePath] ?? candidatesByFile[f.filePath] ?? []
            if !list.isEmpty { lists.append(list) }
        }
        var out: [String] = []
        var seen = Set<String>()
        var round = 0
        while lists.contains(where: { round < $0.count }) {
            for list in lists where round < list.count {
                if seen.insert(list[round]).inserted { out.append(list[round]) }
            }
            round += 1
        }
        return out
    }

    /// Overlays router homes onto suggestions, giving the main actor a turn every `chunk` files.
    ///
    /// Ranking one file costs a few milliseconds against a real 2,979-folder tree, so a few hundred
    /// homeless files is seconds of arithmetic — and run as one synchronous pass that is a frozen
    /// window with no progress moving. Yielding between chunks keeps the scan painting, and unlike
    /// handing the work to a detached task it leaves cancellation working: what is checked here is
    /// the enclosing scan's own cancellation, which `Task.detached` would not inherit.
    /// `shortlists` carries each ranked file's top destinations back out, keyed by file path. They
    /// are what phase 3 builds the classifier's folder menu from, and they are free here: the
    /// ranking that picks the winner has already ordered the whole field, so asking it for the top
    /// few costs a wider insertion into a six-element buffer. Ranking those same files again in
    /// phase 3 would not be free — it is milliseconds per file against a few thousand folders, and
    /// a real root inbox holds hundreds of files.
    func applyRoutesYielding(
        _ suggestions: [FilingSuggestion], index: FilingRouter.Index,
        snippets: [String: String], providerRoot: String,
        rejectedByFile: [String: Set<String>] = [:], chunk: Int = 25
    ) async -> (suggestions: [FilingSuggestion], routed: Int, shortlists: [String: [String]]) {
        var out: [FilingSuggestion] = []
        out.reserveCapacity(suggestions.count)
        var routed = 0
        var shortlists: [String: [String]] = [:]
        for (i, s) in suggestions.enumerated() {
            if i > 0, i.isMultiple(of: chunk) {
                await Task.yield()
                // A cancelled scan discards these suggestions anyway; returning the input unchanged
                // keeps this function total rather than leaving a half-routed list behind.
                if Task.isCancelled { return (suggestions, 0, [:]) }
            }
            let outcome = Self.route(s, index: index, snippets: snippets,
                                     providerRoot: providerRoot,
                                     rejectedByFile: rejectedByFile)
            out.append(outcome.suggestion)
            if outcome.routed { routed += 1 }
            if !outcome.shortlist.isEmpty { shortlists[s.filePath] = outcome.shortlist }
        }
        return (out, routed, shortlists)
    }

    /// The same overlay in one pass, for callers with a handful of files and no actor to protect.
    nonisolated static func applyRoutes(
        _ suggestions: [FilingSuggestion], index: FilingRouter.Index,
        snippets: [String: String], providerRoot: String,
        rejectedByFile: [String: Set<String>] = [:]
    ) -> (suggestions: [FilingSuggestion], routed: Int, shortlists: [String: [String]]) {
        var routed = 0
        var shortlists: [String: [String]] = [:]
        let updated = suggestions.map { s -> FilingSuggestion in
            let outcome = route(s, index: index, snippets: snippets,
                                providerRoot: providerRoot, rejectedByFile: rejectedByFile)
            if outcome.routed { routed += 1 }
            if !outcome.shortlist.isEmpty { shortlists[s.filePath] = outcome.shortlist }
            return outcome.suggestion
        }
        return (updated, routed, shortlists)
    }

    /// One file, and the only place the rules live — so the chunked driver and the batch helper
    /// cannot drift apart.
    ///
    /// **Only upgrades, never demotes.** A router home leads a card when it is at least as confident
    /// as what is already there, matching the rule the classifier overlay follows. Content-derived
    /// homes are marked `fromContent`, which keeps them out of the blind "File recommended" batch on
    /// purpose: reading words out of a document is a weaker, less checkable signal than a filename,
    /// and that batch moves files nobody has looked at.
    nonisolated static func route(
        _ s: FilingSuggestion, index: FilingRouter.Index, snippets: [String: String],
        providerRoot: String, rejectedByFile: [String: Set<String>], shortlistLimit: Int = 8
    ) -> (suggestion: FilingSuggestion, routed: Bool, shortlist: [String]) {
        if s.best?.remembered == true { return (s, false, []) }   // an explicit user rule outranks this
        // Rejections are recorded as ABSOLUTE paths; the router answers in relative ones. Passing
        // the absolute set straight through made the exclusion a silent no-op — one domain,
        // converted once, at the boundary.
        let excluded = Set((rejectedByFile[s.filePath] ?? []).compactMap {
            relativePath($0, under: providerRoot)
        })
        // **Every file is RANKED; only the homeless ones are OVERLAID.** These were one decision
        // and should never have been: the ranking is also what tells phase 3 which folders to put
        // in front of the model, and skipping it for a file that already had a home meant the model
        // was asked about that file against a menu describing every file except it. That is how a
        // T-Mobile bill the router ranks first out of 4,967 folders came back as a new
        // `Finance/US/Accounts` — the router had simply never been asked.
        let ranking = FilingRouter.rank(fileName: s.fileName, contentSnippet: snippets[s.filePath],
                                        index: index, excluding: excluded, limit: shortlistLimit)
        let shortlist = ranking.candidates.map(\.relativePath)
        guard let best = ranking.best else { return (s, false, shortlist) }
        let confidence = ranking.confidence
        // **A home that has to CREATE a folder is a weaker claim than one that names a folder the
        // documents are already in.** The keyword engine hands out `.high` for rules as generic as
        // "receipt or invoice — filed by year", which reads the word `bill` out of a filename and
        // proposes a new `Purchases/2025`. A T-Mobile bill got exactly that while five siblings
        // named `DetailedBill{Jan,Feb,Mar,May,Jun}2025.pdf` sat in an existing
        // `Home/Utilities/T-Mobile/2025` that the router ranks first out of 4,967 folders. Confidence
        // is not comparable across those two claims, so it is not what decides between them.
        //
        // The router only ever names folders from the taxonomy, so this trade is always
        // existing-for-new, never the reverse.
        let wouldCreateAFolder = s.best?.newSegments.isEmpty == false
        if s.hasConfidentHome, !wouldCreateAFolder { return (s, false, shortlist) }
        if wouldCreateAFolder {
            // Still needs real evidence — an unsure ranking must not evict a home either.
            guard confidence >= .medium else { return (s, false, shortlist) }
        } else {
            // The original rule, unchanged for the homeless case: only upgrades, never demotes.
            guard confidence >= (s.best?.confidence ?? .low) else { return (s, false, shortlist) }
        }
        let fromContent = best.evidenceToken != nil
        // **No file count.** `FilingDestination.neighborMatches` means "how many files in the
        // target contain this word", and the card prints it as "N similar files already here".
        // The memory records which words a folder's documents use, not how many use each one, so
        // that number cannot be produced honestly — it stays 0 and the sentence stays true.
        let reason = fromContent
            ? "Matched “\(best.evidenceToken ?? "")” read from the file — a word this folder's documents use"
            : "Fits how this folder is used"
        let dest = FilingDestination(
            path: providerRoot + "/" + best.relativePath, confidence: confidence, reasons: [reason],
            // The router only ever names folders that came from the taxonomy, so nothing here is
            // ever a folder to create — an empty `newSegments` is a fact, not a default.
            newSegments: [], fromContent: fromContent, remembered: false, fromAI: false,
            evidenceToken: best.evidenceToken?.capitalized, neighborMatches: 0)
        let others = s.candidates.filter { $0.path != dest.path }
        return (FilingSuggestion(filePath: s.filePath, fileName: s.fileName, size: s.size,
                                 modificationDate: s.modificationDate, candidates: [dest] + others,
                                 providerRoot: s.providerRoot), true, shortlist)
    }
}
