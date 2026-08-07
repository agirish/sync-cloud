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

    /// Builds the router index for a taxonomy, or clears it when there is nothing to route with.
    func prepareFilingRouter(destinations: [String]) {
        guard filingFolderProfile != nil || filingMemory != nil, !destinations.isEmpty else {
            filingRouterIndex = nil
            return
        }
        filingRouterIndex = FilingRouter.makeIndex(destinations: destinations,
                                                   profile: filingFolderProfile,
                                                   memory: filingMemory)
    }

    /// The context handed to a classifier — the taxonomy plus whatever has been learned about it.
    func filingContext(taxonomyFolders: [String]) -> FilingContext {
        FilingContext(taxonomyFolders: taxonomyFolders,
                      profile: filingFolderProfile, memory: filingMemory)
    }

    /// Overlays router homes onto suggestions, giving the main actor a turn every `chunk` files.
    ///
    /// Ranking one file costs a few milliseconds against a real 2,979-folder tree, so a few hundred
    /// homeless files is seconds of arithmetic — and run as one synchronous pass that is a frozen
    /// window with no progress moving. Yielding between chunks keeps the scan painting, and unlike
    /// handing the work to a detached task it leaves cancellation working: what is checked here is
    /// the enclosing scan's own cancellation, which `Task.detached` would not inherit.
    func applyRoutesYielding(
        _ suggestions: [FilingSuggestion], index: FilingRouter.Index,
        snippets: [String: String], providerRoot: String,
        rejectedByFile: [String: Set<String>] = [:], chunk: Int = 25
    ) async -> (suggestions: [FilingSuggestion], routed: Int) {
        var out: [FilingSuggestion] = []
        out.reserveCapacity(suggestions.count)
        var routed = 0
        for (i, s) in suggestions.enumerated() {
            if i > 0, i.isMultiple(of: chunk) {
                await Task.yield()
                // A cancelled scan discards these suggestions anyway; returning the input unchanged
                // keeps this function total rather than leaving a half-routed list behind.
                if Task.isCancelled { return (suggestions, 0) }
            }
            let (one, didRoute) = Self.route(s, index: index, snippets: snippets,
                                             providerRoot: providerRoot,
                                             rejectedByFile: rejectedByFile)
            out.append(one)
            if didRoute { routed += 1 }
        }
        return (out, routed)
    }

    /// The same overlay in one pass, for callers with a handful of files and no actor to protect.
    nonisolated static func applyRoutes(
        _ suggestions: [FilingSuggestion], index: FilingRouter.Index,
        snippets: [String: String], providerRoot: String,
        rejectedByFile: [String: Set<String>] = [:]
    ) -> (suggestions: [FilingSuggestion], routed: Int) {
        var routed = 0
        let updated = suggestions.map { s -> FilingSuggestion in
            let (one, didRoute) = route(s, index: index, snippets: snippets,
                                        providerRoot: providerRoot, rejectedByFile: rejectedByFile)
            if didRoute { routed += 1 }
            return one
        }
        return (updated, routed)
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
        providerRoot: String, rejectedByFile: [String: Set<String>]
    ) -> (FilingSuggestion, Bool) {
        if s.best?.remembered == true { return (s, false) }   // an explicit user rule outranks this
        // **Only files with no home.** Ranking the rest was work with one possible outcome, and it
        // was the wrong one: an equally confident router home *replaces* a filename match, and
        // because the replacement is content-derived the file silently drops out of the blind
        // "File all N" batch. A file that already has a confident home is left alone.
        guard !s.hasConfidentHome else { return (s, false) }
        // Rejections are recorded as ABSOLUTE paths; the router answers in relative ones. Passing
        // the absolute set straight through made the exclusion a silent no-op — one domain,
        // converted once, at the boundary.
        let excluded = Set((rejectedByFile[s.filePath] ?? []).compactMap {
            relativePath($0, under: providerRoot)
        })
        let ranking = FilingRouter.rank(fileName: s.fileName, contentSnippet: snippets[s.filePath],
                                        index: index, excluding: excluded)
        guard let best = ranking.best else { return (s, false) }
        let confidence = ranking.confidence
        guard confidence >= (s.best?.confidence ?? .low) else { return (s, false) }
        let fromContent = best.evidenceToken != nil
        let reason = fromContent
            ? "Matches \(best.neighborMatches) document\(best.neighborMatches == 1 ? "" : "s") already filed here"
            : "Fits how this folder is used"
        let dest = FilingDestination(
            path: providerRoot + "/" + best.relativePath, confidence: confidence, reasons: [reason],
            // The router only ever names folders that came from the taxonomy, so nothing here is
            // ever a folder to create — an empty `newSegments` is a fact, not a default.
            newSegments: [], fromContent: fromContent, remembered: false, fromAI: false,
            evidenceToken: best.evidenceToken, neighborMatches: best.neighborMatches)
        let others = s.candidates.filter { $0.path != dest.path }
        return (FilingSuggestion(filePath: s.filePath, fileName: s.fileName, size: s.size,
                                 modificationDate: s.modificationDate, candidates: [dest] + others,
                                 providerRoot: s.providerRoot), true)
    }
}
