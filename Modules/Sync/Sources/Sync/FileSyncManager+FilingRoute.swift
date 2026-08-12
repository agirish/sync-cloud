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
    func prepareFilingRouter(destinations: Set<String>, providerRoot: String? = nil) {
        guard filingFolderProfile != nil || filingMemory != nil, !destinations.isEmpty else {
            invalidateFilingRouterIndex()
            return
        }
        // Refreshed before the early-out below, not after it: the satellite map and the taxonomy
        // move independently — a duplicates scan writes new fingerprints without adding a folder —
        // and gating it on the taxonomy having changed would leave the map stale for as long as the
        // tree's shape held still, which is most of the time.
        let before = filingSatelliteHomes
        refreshSatelliteHomes(providerRoot: providerRoot)
        if filingRouterIndex != nil, filingRouterIndexKey == destinations,
           before == filingSatelliteHomes { return }
        filingRouterIndex = FilingRouter.makeIndex(destinations: Array(destinations),
                                                   profile: filingFolderProfile,
                                                   memory: filingMemory,
                                                   registry: filingPersonRegistry,
                                                   satelliteHomes: filingSatelliteHomes)
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
        rejectedByFile: [String: Set<String>] = [:], chunk: Int = 25,
        peerNames: ((String) -> [String])? = nil
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
                                     rejectedByFile: rejectedByFile, peerNames: peerNames)
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
        rejectedByFile: [String: Set<String>] = [:],
        peerNames: ((String) -> [String])? = nil
    ) -> (suggestions: [FilingSuggestion], routed: Int, shortlists: [String: [String]]) {
        var routed = 0
        var shortlists: [String: [String]] = [:]
        let updated = suggestions.map { s -> FilingSuggestion in
            let outcome = route(s, index: index, snippets: snippets,
                                providerRoot: providerRoot, rejectedByFile: rejectedByFile,
                                peerNames: peerNames)
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
        providerRoot: String, rejectedByFile: [String: Set<String>], shortlistLimit: Int = 8,
        peerNames: ((String) -> [String])? = nil
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
        let ranked = FilingRouter.rank(fileName: s.fileName, contentSnippet: snippets[s.filePath],
                                       index: index, excluding: excluded, limit: shortlistLimit)
        // **The peer-name rerank is applied HERE, and this line is the whole of its effect.** The
        // lookup was built by every scan and threaded through three signatures to reach this
        // function, which then ranked without it — so the one case it exists for
        // (`Divit OCI Photo.jpg`, where a folder and its own subfolder sit 1% apart and only the
        // filenames already in them can separate the two) went on being decided by the content
        // score that cannot see the difference. A parameter accepted and not read is worse than one
        // that was never added: the cache is built, the closure is passed, and every test of the
        // helper passes, while nothing in the app calls it.
        //
        // The router speaks in paths relative to the provider root and the lookup lists real
        // directories, so the join is the adapter between the two — see `peerNameLookup`.
        let ranking = peerNames.map { namesIn in
            FilingRouter.rerankedByPeerNames(ranked, fileName: s.fileName) { relative in
                namesIn(providerRoot + "/" + relative)
            }
        } ?? ranked
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
        return (s.replacingCandidates([dest] + others), true, shortlist)
    }
}

// MARK: - Peer filenames

extension FileSyncManager {

    /// A per-scan cache of "what files are already in this folder", for
    /// ``FilingRouter/rerankedByPeerNames(_:fileName:namesInFolder:)``.
    ///
    /// Only the handful of folders on a file's own shortlist are ever asked about, and a folder is
    /// listed once however many files land on it — a scan of a few hundred loose files touches tens
    /// of folders, not thousands. Rebuilt each scan rather than persisted: it describes the tree as
    /// it is right now, and a stale answer here would quietly re-order a ranking.
    func peerNameLookup() -> (String) -> [String] {
        let box = PeerNameCache()
        return { absoluteFolder in box.names(in: absoluteFolder) }
    }
}

/// Reference box so the closure above can memoise across calls without capturing the actor.
final class PeerNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: [String]] = [:]

    func names(in absoluteFolder: String) -> [String] {
        lock.lock()
        if let hit = cache[absoluteFolder] { lock.unlock(); return hit }
        lock.unlock()
        // Files only: a subfolder's NAME is not a peer document, and counting it as one would let
        // `Application` cover an incoming `…Application….pdf` on the strength of the folder itself.
        // Asked through the resource keys rather than a `fileExists` per entry — one syscall for
        // the listing instead of one more for every name in it.
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: absoluteFolder),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        let names = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }.map(\.lastPathComponent)
        lock.lock(); cache[absoluteFolder] = names; lock.unlock()
        return names
    }
}

// MARK: - Reading a scan on request

extension FileSyncManager {

    /// Recovers a scanned PDF's text with OCR and re-routes that one file.
    ///
    /// **Offered, never spent.** Rendering a page and running Vision over it measured 0.5–2.1 s per
    /// file on a real tree (a lease at 1.39 s, an amenity agreement at 2.14 s, an eOCI card at
    /// 0.70 s). For the file in front of the user that is a click; for the 500-file inbox this app
    /// is built for it is ten minutes of fans, spent on files the user may not care about. So the
    /// scan records which files would benefit (``filingUnreadableScans``) and this runs on request.
    ///
    /// Re-routes through the router alone — no model call, so the answer costs nothing beyond the
    /// OCR and comes from the measured path rather than an uncalibrated one. The recovered text is
    /// exactly what that path was missing: `Divit - eOCI.pdf` extracts nothing and OCRs to
    /// "eOCI Card | Government of India | Bureau of Immigration | OVERSEAS CITIZEN OF INDIA".
    @discardableResult
    public func readScan(for suggestion: FilingSuggestion) async -> Bool {
        guard let ocr = filingOCRExtractor, let index = filingRouterIndex,
              let root = filingLastProviderRoot else { return false }
        // One render per file at a time — a second click while Vision is out would start a second.
        guard !filingOCRInFlight.contains(suggestion.filePath) else { return false }
        filingOCRInFlight.insert(suggestion.filePath)
        defer { filingOCRInFlight.remove(suggestion.filePath) }

        let generation = filingSuggestionsGeneration
        guard let text = await ocr(suggestion.filePath), !text.isEmpty else {
            // Nothing came back: stop offering, or the button invites the same wait again.
            filingUnreadableScans.remove(suggestion.filePath)
            Logger.shared.info("Filing: OCR found no text in “\(suggestion.fileName)”")
            return false
        }
        // The list this is about must still be the list on screen — same rule as the refine pass.
        guard filingSuggestionsGeneration == generation,
              let live = filingSuggestions.first(where: { $0.id == suggestion.id })
        else { return false }

        let rejected = filingRejections(under: URL(fileURLWithPath: root))
        var rejectedByFile: [String: Set<String>] = [:]
        let paths = Self.rejectedPaths(forFileNamed: live.fileName, in: rejected)
            .union(filingSessionRejections[live.id] ?? [])
        if !paths.isEmpty { rejectedByFile[live.id] = paths }

        // Routed as a homeless file whatever the card currently shows: the point of the click is
        // that the home on it was decided without the document's text.
        let blank = FilingSuggestion(filePath: live.filePath, fileName: live.fileName, size: live.size,
                                     modificationDate: live.modificationDate, candidates: [],
                                     providerRoot: live.providerRoot)
        let outcome = Self.route(blank, index: index, snippets: [live.filePath: text],
                                 providerRoot: root, rejectedByFile: rejectedByFile)
        filingUnreadableScans.remove(suggestion.filePath)
        // The scan recorded nothing for this file — it had no text to record. Now it has, and a
        // rule offered after filing it should key on what the OCR found rather than on a filename
        // that says `Divit - eOCI.pdf`.
        filingPageSamples[suggestion.filePath] = String(text.prefix(FilingRouter.contentSampleChars))
        guard outcome.routed, let best = outcome.suggestion.best else {
            Logger.shared.info("Filing: read “\(live.fileName)” (\(text.count) chars) — no home matched it")
            return false
        }
        replaceFilingSuggestion(live.id, candidates: [best])
        Logger.shared.info("Filing: read “\(live.fileName)” (\(text.count) chars) — "
                           + "\((best.path as NSString).lastPathComponent)")
        return true
    }
}
