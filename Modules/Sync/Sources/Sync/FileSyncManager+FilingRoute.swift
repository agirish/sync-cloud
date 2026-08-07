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

    /// Overlays router homes onto suggestions that have none.
    ///
    /// **Only upgrades, never demotes.** A router home leads a card when it is at least as confident
    /// as what is already there, matching the rule the classifier overlay follows — otherwise a
    /// low-margin guess would displace a strong filename match and, because the promoted candidate
    /// is content-derived, drop the file out of the blind "File recommended" batch.
    ///
    /// Content-derived homes are marked `fromContent`, which keeps them out of that batch on
    /// purpose: reading words out of a document is a weaker, less checkable signal than a filename,
    /// and this pass moves files nobody has looked at.
    nonisolated static func applyRoutes(
        _ suggestions: [FilingSuggestion], index: FilingRouter.Index,
        snippets: [String: String], providerRoot: String,
        rejectedByFile: [String: Set<String>] = [:]
    ) -> (suggestions: [FilingSuggestion], routed: Int) {
        var routed = 0
        let updated = suggestions.map { s -> FilingSuggestion in
            if s.best?.remembered == true { return s }        // an explicit user rule outranks this
            let excluded = rejectedByFile[s.filePath] ?? []
            let ranking = FilingRouter.rank(fileName: s.fileName, contentSnippet: snippets[s.filePath],
                                            index: index, excluding: excluded)
            guard let best = ranking.best else { return s }
            let confidence = ranking.confidence
            guard confidence >= (s.best?.confidence ?? .low) else { return s }
            let path = providerRoot + "/" + best.relativePath
            if excluded.contains(path) { return s }
            let fromContent = best.evidenceToken != nil
            let reason = fromContent
                ? "Matches \(best.neighborMatches) document\(best.neighborMatches == 1 ? "" : "s") already filed here"
                : "Fits how this folder is used"
            let dest = FilingDestination(
                path: path, confidence: confidence, reasons: [reason],
                // The router only ever names folders that came from the taxonomy, so nothing here
                // is ever a folder to create — an empty `newSegments` is a fact, not a default.
                newSegments: [], fromContent: fromContent, remembered: false, fromAI: false,
                evidenceToken: best.evidenceToken, neighborMatches: best.neighborMatches)
            routed += 1
            let others = s.candidates.filter { $0.path != dest.path }
            return FilingSuggestion(filePath: s.filePath, fileName: s.fileName, size: s.size,
                                    modificationDate: s.modificationDate, candidates: [dest] + others,
                                    providerRoot: s.providerRoot)
        }
        return (updated, routed)
    }
}
