import Events
import Foundation

// Phase 2.5 of the filing scan: the tree's own profile and memory, applied with no model call.
//
// It sits between the keyword engine and the classifier because that is what it is worth: better
// than filename overlap, free, and able to answer for files the on-device model would be asked
// about. Over 9,558 filed documents it takes top-1 routing from 28.9% (profile alone) to 58.2%.
// Gated on the tree having been surveyed: with no artifacts, `filingRouterIndex` is nil and this
// phase is a no-op.
extension FileSyncManager {

    /// Builds the router index for a taxonomy, reusing the last one when the taxonomy has not moved.
    func prepareFilingRouter(destinations: Set<String>, providerRoot: String? = nil) {
        // Which survey answers for this tree, decided first: everything below reads the profile
        // and memory it picks.
        if let providerRoot { resolveFilingSurvey(providerRoot: providerRoot, folders: destinations) }
        guard filingRoutingProfile != nil || filingRoutingMemory != nil, !destinations.isEmpty else {
            invalidateFilingRouterIndex()
            return
        }
        // Refreshed before the early-out: the satellite map moves independently of the taxonomy (a
        // duplicates scan writes fingerprints without adding a folder), so gating it on the
        // taxonomy would leave it stale while the tree's shape holds still.
        let before = filingSatelliteHomes
        refreshSatelliteHomes(providerRoot: providerRoot)
        // Before the early-out too: an undone filing moves the generation the index is keyed on.
        forgetUndoneFilings()
        forgetUndoneLearnedAccounts()
        if filingRouterIndex != nil, filingRouterIndexKey == destinations,
           before == filingSatelliteHomes,
           filingRouterIndexFiledGeneration == filingFiledSinceSurveyGeneration { return }
        // What was filed here since the survey last read its documents, folded in, and kept out of
        // `filingRoutingFingerprint`, which is read from the survey's files on disk, so a filing
        // doesn't throw away Refine answers already paid for.
        let filed = providerRoot.map { filedSinceSurvey(under: $0) } ?? [:]
        var memory = filingRoutingMemory
        if !filed.isEmpty {
            memory = FilingSurvey.memory(memory ?? FilingMemory(profileId: filingRoutingProfile?.profileId ?? "",
                                                                salt: "", folders: [:]),
                                         addingFiled: filed)
        }
        filingRouterIndex = FilingRouter.makeIndex(destinations: Array(destinations),
                                                   profile: filingRoutingProfile,
                                                   memory: memory,
                                                   registry: filingPersonRegistry,
                                                   satelliteHomes: filingSatelliteHomes)
        filingRouterIndexKey = destinations
        filingRouterIndexFiledGeneration = filingFiledSinceSurveyGeneration
        filingRouterIndexBuilds += 1
    }

    /// The context handed to a classifier: the taxonomy plus whatever has been learned about it.
    func filingContext(taxonomyFolders: [String]) -> FilingContext {
        FilingContext(taxonomyFolders: taxonomyFolders,
                      profile: filingRoutingProfile, memory: filingRoutingMemory)
    }

    /// The folders worth spending the classifier's budget on, most deserving first: the router's
    /// shortlist for each file being classified, plus the homes earlier phases proposed for files
    /// the router didn't rank (a file with a confident home skips phase 2.5, and its heuristic
    /// candidates are the best evidence there is).
    ///
    /// Round-robin, not concatenated: a hundred files times eight candidates far exceeds a budget
    /// of a few hundred, and file order would spend it all on the first twenty, leaving the rest a
    /// menu that says nothing about them. Every file's first choice, then every second, degrades
    /// evenly.
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
    /// Ranking costs a few milliseconds per file against a tree of thousands of folders, so a few
    /// hundred homeless files is seconds: in one synchronous pass, a frozen window. Yielding keeps
    /// the scan painting, and unlike a detached task keeps the enclosing scan's cancellation, which
    /// `Task.detached` wouldn't inherit.
    ///
    /// `shortlists` carries each ranked file's top destinations out, keyed by file path: phase 3
    /// builds the classifier's menu from them. They are nearly free here, since the ranking already
    /// ordered the field; ranking again in phase 3 would cost milliseconds per file.
    func applyRoutesYielding(
        _ suggestions: [FilingSuggestion], index: FilingRouter.Index,
        snippets: [String: String], providerRoot: String,
        rejectedByFile: [String: Set<String>] = [:], chunk: Int = 25,
        peerNames: ((String) -> [String])? = nil, preferring preferredSubtree: String? = nil
    ) async -> (suggestions: [FilingSuggestion], routed: Int, shortlists: [String: [String]]) {
        var out: [FilingSuggestion] = []
        out.reserveCapacity(suggestions.count)
        var routed = 0
        var shortlists: [String: [String]] = [:]
        for (i, s) in suggestions.enumerated() {
            if i > 0, i.isMultiple(of: chunk) {
                await Task.yield()
                // A cancelled scan discards these anyway; returning the input unchanged keeps this
                // total rather than leaving a half-routed list.
                if Task.isCancelled { return (suggestions, 0, [:]) }
            }
            let outcome = Self.route(s, index: index, snippets: snippets,
                                     providerRoot: providerRoot,
                                     rejectedByFile: rejectedByFile, peerNames: peerNames,
                                     preferring: preferredSubtree)
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

    /// One file, and the only place the rules live, so the chunked driver and the batch helper
    /// can't drift apart.
    ///
    /// Outranks what was guessed, never what was taught. A router home leads over a keyword
    /// engine's home at any confidence; over a model's answer, or with no home, only when at least
    /// as confident. A rule or Automation is never touched. Content-derived homes are marked
    /// `fromContent`, which keeps them out of the blind "File recommended" batch on purpose: words
    /// read from a document are a weaker, less checkable signal than a filename, and that batch
    /// moves files nobody has looked at.
    nonisolated static func route(
        _ s: FilingSuggestion, index: FilingRouter.Index, snippets: [String: String],
        providerRoot: String, rejectedByFile: [String: Set<String>], shortlistLimit: Int = 8,
        peerNames: ((String) -> [String])? = nil, preferring preferredSubtree: String? = nil
    ) -> (suggestion: FilingSuggestion, routed: Bool, shortlist: [String]) {
        if s.best?.remembered == true { return (s, false, []) }   // an explicit user rule outranks this
        // Rejections are recorded as absolute paths and the router answers in relative ones, so
        // convert once, here at the boundary, or the exclusion silently does nothing.
        let excluded = Set((rejectedByFile[s.filePath] ?? []).compactMap {
            relativePath($0, under: providerRoot)
        })
        // Every file is ranked; only the homeless ones are overlaid. The ranking also tells phase 3
        // which folders to show the model, so skipping it for a file with a home would ask the
        // model about that file against a menu built from every file except it.
        let ranked = FilingRouter.rank(fileName: s.fileName, contentSnippet: snippets[s.filePath],
                                       index: index, excluding: excluded, limit: shortlistLimit)
        // The peer-name rerank takes effect here and nowhere else. It is for a folder and its own
        // subfolder a percent apart (`Son OCI Photo.jpg`), which only the filenames already in them
        // can separate; without this line the lookup is built and passed and nothing uses it.
        // The router speaks in paths relative to the provider root and the lookup lists real
        // directories, so the join adapts between the two (see `peerNameLookup`).
        let reranked = peerNames.map { namesIn in
            FilingRouter.rerankedByPeerNames(ranked, fileName: s.fileName) { relative in
                namesIn(providerRoot + "/" + relative)
            }
        } ?? ranked
        // File Into, when the walk is wider: its folders lead unless the router is sure elsewhere,
        // the rule Ask Claude applies to a place named in the chat, so the two agree.
        let ranking = preferring(reranked, under: preferredSubtree)
        let shortlist = ranking.candidates.map(\.relativePath)
        guard let best = ranking.best else { return (s, false, shortlist) }
        let confidence = ranking.confidence
        // A home that has to create a folder is a weaker claim than one naming a folder documents
        // are already in. The keyword engine gives `.high` to rules as generic as "receipt or
        // invoice, filed by year", so a phone bill can be offered a new `Purchases/2025` while its
        // siblings sit in an existing `Home/Utilities/T-Mobile/2025`. Confidence isn't comparable
        // across those claims, so it doesn't decide between them. The router only names taxonomy
        // folders, so the trade is always existing-for-new.
        //
        // And a home found by matching words is weaker than the survey's: the keyword engine's
        // confidence is claimed, the router's is its calibrated margin (a courier invoice can score
        // High for `Health/Medical/India` on the one word "india"). So a home nobody taught (rules
        // and Automations returned above) gives way to the router's at whatever confidence it has.
        // On held-out filed documents (`FilingCardReplayTests`) that takes cards right first time
        // from 5% to 42%, and the badge means what it says: High right 77%, Medium 57%, Low 30%,
        // against 4% for a keyword High.
        if let current = s.best, current.path == providerRoot + "/" + best.relativePath {
            // The two agree. Keep the surer claim: the router taking over at a lower confidence
            // would drop a name-derived High out of the blind batch for nothing.
            guard confidence > current.confidence else { return (s, false, shortlist) }
        } else if let current = s.best, !current.fromAI {
            // A guess gives way to the measured signal, and the card carries its confidence.
        } else {
            // The homeless case, and a model's answer: only upgrades, never demotes.
            guard confidence >= (s.best?.confidence ?? .low) else { return (s, false, shortlist) }
        }
        let fromContent = best.evidenceToken != nil
        // No file count. `FilingDestination.neighborMatches` means "how many files in the target
        // contain this word", printed as "N similar files already here", but the memory records
        // which words a folder's documents use, not how many use each, so it stays 0 and the
        // sentence stays true.
        let reason = fromContent
            ? "Matched “\(best.evidenceToken ?? "")” read from the file — a word this folder’s documents use"
            : "Fits how this folder is used"
        let dest = FilingDestination(
            // `.measuredContent`, not `.content`: the router's confidence is a calibrated margin,
            // so the heuristic content cap doesn't apply. `fromContent` still keeps a
            // content-derived home out of the blind batch.
            path: providerRoot + "/" + best.relativePath,
            base: confidence, evidence: fromContent ? .measuredContent : .name, reasons: [reason],
            // The router only names folders from the taxonomy, so nothing here is a folder to
            // create: an empty `newSegments` is a fact, not a default.
            newSegments: [],
            evidenceToken: best.evidenceToken?.capitalized, neighborMatches: 0, fromSurvey: true)
        let others = s.candidates.filter { $0.path != dest.path }
        return (s.replacingCandidates([dest] + others), true, shortlist)
    }
}

// MARK: - Filed since the survey (GW)

/// One document filed in SyncCloud since the survey last read its folder: the folder, and the words
/// it brought. Kept until a survey newer than it has read the folder for itself.
public struct FilingFiledSinceSurvey: Codable, Sendable, Equatable {
    /// Absolute path of the folder it was filed into.
    public let folder: String
    /// Page 1's readable words and the name's; see ``FilingSurvey/filedAnchors(fileName:page1:)``.
    public let anchors: [String]
    public let filedAt: Date
    /// Where the file landed, so a filing undone (the file gone from there) stops teaching. Nil for
    /// entries saved before it was recorded; those are kept.
    public let filedPath: String?

    public init(folder: String, anchors: [String], filedAt: Date, filedPath: String? = nil) {
        self.folder = folder
        self.anchors = anchors
        self.filedAt = filedAt
        self.filedPath = filedPath
    }
}

extension FileSyncManager {

    /// Where ``filingFiledSinceSurvey`` persists, beside the rejections.
    public static let filedSinceSurveyDefaultsKey = "tidyFilingFiledSinceSurvey"
    /// The newest this many are kept. A survey takes them in long before; the cap is for a tree
    /// nobody ever re-surveys, where they would otherwise grow without end.
    static let filedSinceSurveyCap = 500

    public var filingFiledSinceSurvey: [FilingFiledSinceSurvey] {
        get {
            FileSyncManager.decodePersistedStore([FilingFiledSinceSurvey].self, from: filingRuleDefaults,
                                                 key: Self.filedSinceSurveyDefaultsKey,
                                                 describing: "documents filed since the survey") ?? []
        }
        set {
            FileSyncManager.writePersistedStore(Array(newValue.suffix(Self.filedSinceSurveyCap)),
                                                to: filingRuleDefaults,
                                                key: Self.filedSinceSurveyDefaultsKey,
                                                describing: "documents filed since the survey")
        }
    }

    /// Teaches the router what `folder` now holds, so the next scan ranks by it without waiting for
    /// the survey. Called for every filing SyncCloud makes, whatever chose the folder (To File or
    /// Ask Claude). `filedPath` is where the file landed: a filing undone stops teaching
    /// (``forgetUndoneFilings()``).
    func learnFromFiling(fileName: String, sourcePath: String, into folder: String, filedPath: String? = nil,
                         now: Date = Date()) {
        let anchors = FilingSurvey.filedAnchors(fileName: fileName, page1: filingPageSamples[sourcePath])
        guard !anchors.isEmpty else { return }
        filingFiledSinceSurvey.append(FilingFiledSinceSurvey(folder: folder, anchors: anchors.sorted(),
                                                             filedAt: now, filedPath: filedPath))
        filingFiledSinceSurveyGeneration += 1
    }

    /// Drops what a filing taught once its file is no longer where it was filed (Undo moved it
    /// back, or he moved it on), so the folder stops ranking for words it doesn't hold. One stat
    /// per entry, at most ``filedSinceSurveyCap``, before each router build.
    func forgetUndoneFilings() {
        let entries = filingFiledSinceSurvey
        let kept = entries.filter { entry in entry.filedPath.map { fileManager.fileExists(atPath: $0) } ?? true }
        guard kept.count != entries.count else { return }
        Logger.shared.info("Filing: forgot \(entries.count - kept.count) filing(s) no longer in their folder")
        filingFiledSinceSurvey = kept
        filingFiledSinceSurveyGeneration += 1
    }

    /// The filings under `providerRoot` the survey in use hasn't read yet, by folder relative to
    /// it, in the shape ``FilingSurvey/memory(_:addingFiled:)`` takes. "Not read yet" means newer
    /// than the survey's last look at documents: the primary survey's, or a source's own once its
    /// documents were read. A survey that has looked since holds the document in its corpus, and
    /// counting it again would double its words.
    func filedSinceSurvey(under providerRoot: String) -> [String: [Set<String>]] {
        let lookedAt = filingSurveyInUse?.kind == .own ? filingSurveyInUse?.ownDocumentsReadAt : filingSurveyedAt
        var out: [String: [Set<String>]] = [:]
        for entry in filingFiledSinceSurvey where lookedAt.map({ entry.filedAt > $0 }) ?? true {
            guard let relative = Self.relativePath(entry.folder, under: providerRoot) else { continue }
            out[relative, default: []].append(Set(entry.anchors))
        }
        return out
    }
}

// MARK: - Peer filenames

extension FileSyncManager {

    /// A per-scan cache of "what files are already in this folder", for
    /// ``FilingRouter/rerankedByPeerNames(_:fileName:namesInFolder:)``. Only folders on a file's
    /// own shortlist are asked about, each listed once, so a scan touches tens of folders, not
    /// thousands. Rebuilt each scan, not persisted: a stale answer would quietly reorder a ranking.
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
        // Files only: a subfolder's name isn't a peer document, and counting it would let
        // `Application` cover an incoming `…Application….pdf` on the strength of the folder itself.
        // Asked through resource keys: one syscall for the listing, not one more per name.
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
    /// Offered, never spent: rendering a page and running Vision takes 0.5–2.1 s per file. For the
    /// file in front of the user that is a click; for a 500-file inbox it is ten minutes of fans on
    /// files the user may not care about. So the scan records which files would benefit
    /// (``filingUnreadableScans``) and this runs on request.
    ///
    /// Re-routes through the router alone, with no model call, so the answer costs nothing beyond
    /// the OCR and comes from the measured path. The OCR text is what that path lacked:
    /// `Son - eOCI.pdf` extracts nothing and OCRs to "eOCI Card | Government of India | …".
    @discardableResult
    public func readScan(for suggestion: FilingSuggestion) async -> Bool {
        // The cached router and root must belong to this card's provider. A Filing scan of
        // another provider overwrites both before it walks, and one cancelled mid-run never
        // republishes, so this provider's cards can sit over the other's index. Routing against it
        // would put the file on a folder in the other account's tree, and "File here" would move it
        // across accounts. `tryAnotherFolder` has the same guard.
        guard let ocr = filingOCRExtractor else { return false }
        guard let index = filingRouterIndex, let root = filingLastProviderRoot,
              root == suggestion.providerRoot else {
            // Say so, and retire the dead offer, or the button stays up to do nothing again. The
            // cards are older than the scan the cache came from; a new scan of this folder
            // rebuilds both.
            filingUnreadableScans.remove(suggestion.filePath)
            Logger.shared.info("Filing: Read scan of “\(suggestion.fileName)” refused — the cached index is from another scan (\(filingLastProviderRoot ?? "none"))")
            banner = .refusal("Couldn’t read “\(suggestion.fileName)” — this list is from an earlier scan. Scan this folder again to read it.", log: .warn)
            return false
        }
        // One render per file at a time: a second click while Vision is out would start a second.
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
        // The list this is about must still be the list on screen, as in the refine pass.
        guard filingSuggestionsGeneration == generation,
              let live = filingSuggestions.first(where: { $0.id == suggestion.id })
        else { return false }

        let (best, refused) = routeWithPage(live, text: text, providerRoot: root, index: index)
        filingUnreadableScans.remove(suggestion.filePath)
        guard let best else {
            Logger.shared.info("Filing: read “\(live.fileName)” (\(text.count) chars) — "
                               + (refused ? "the home it found is someone else’s folder"
                                          : "no home matched it"))
            return false
        }
        replaceFilingSuggestion(live.id, candidates: [best], reoffer: true)
        Logger.shared.info("Filing: read “\(live.fileName)” (\(text.count) chars) — "
                           + "\((best.path as NSString).lastPathComponent)")
        return true
    }

    /// Routes one card again now that its first page is in hand: the half of ``readScan(for:)``
    /// that doesn't care where the text came from, shared with ``downloadAndReadFiling(_:)``, whose
    /// text comes from a file that was cloud-only when the scan ran.
    ///
    /// Records the page sample and applies the cross-person rule, as the scan would. Returns the
    /// home to show, or nil, with `refused` saying whether a home was found and refused as another
    /// person's folder. Changes no card; the caller does.
    func routeWithPage(_ live: FilingSuggestion, text: String, providerRoot root: String,
                       index: FilingRouter.Index) -> (best: FilingDestination?, refused: Bool) {
        let rejected = filingRejections(under: URL(fileURLWithPath: root))
        var rejectedByFile: [String: Set<String>] = [:]
        let paths = Self.rejectedPaths(forFileNamed: live.fileName, in: rejected)
            .union(filingSessionRejections[live.id] ?? [])
        if !paths.isEmpty { rejectedByFile[live.id] = paths }

        // Routed as a homeless file whatever the card currently shows: the point of the click is
        // that the home on it was decided without the document's text.
        let blank = FilingSuggestion(filePath: live.filePath, fileName: live.fileName, size: live.size,
                                     modificationDate: live.modificationDate, candidates: [],
                                     providerRoot: live.providerRoot,
                                     sourceIdentity: live.sourceIdentity)
        // `peerNames:` too, because the scan passes it: without it this pass and the scan could
        // answer differently about the same file in the case peer names exist for.
        let outcome = Self.route(blank, index: index, snippets: [live.filePath: text],
                                 providerRoot: root, rejectedByFile: rejectedByFile,
                                 peerNames: peerNameLookup(), preferring: filingPreferredSubtree)
        // The scan recorded nothing for this file, having no text. Now it has, so a rule offered
        // after filing it keys on what the OCR found, not a filename like `Son - eOCI.pdf`.
        filingPageSamples[live.filePath] = String(text.prefix(FilingRouter.contentSampleChars))
        // The scan's cross-person rule, on the one card this replaces. This path writes a home
        // without going through `applyVerdicts`, so without it one family member's document could
        // land on another's folder, and a scan with no text layer is exactly the file this is for.
        // After the page sample is recorded: the OCR text is what lets the rule attribute a file
        // whose name names nobody.
        // The scan's account phase too: a statement whose page arrived late is placed like the rest.
        let placed = applyingAccounts(to: outcome.suggestion, page: text)
        var refused = false
        let swept = FilingEngine.refusingCrossPersonHomes(
            [placed], providerRoot: root,
            profile: filingRoutingProfile, registry: filingPersonRegistry,
            identity: filingPersonIdentity, pageSamples: filingPageSamples,
            onVeto: { [weak self] refusal in
                refused = true
                self?.recordPersonVeto(refusal)
            })
        guard outcome.routed || placed.best?.account != nil, let best = swept.first?.best else { return (nil, refused) }
        return (best, false)
    }
}
