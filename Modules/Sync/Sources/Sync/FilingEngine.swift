import Foundation

// MARK: - Result model

/// How sure Filing is about a suggested home.
///
/// `Codable` so a verdict survives in ``FilingVerdictCache`` across launches. The raw values are
/// therefore persisted — append new cases rather than renaming existing ones, exactly as
/// `LiquidGlassHue` does for the same reason.
public enum FilingConfidence: String, Codable, Sendable, Equatable, Comparable {
    case low, medium, high

    /// The ordering `Comparable` is built on — **exhaustive, with no `default:` and no final
    /// `else`**, so appending a case is a build error here rather than a silent `0`.
    ///
    /// This was `self == .high ? 2 : (self == .medium ? 1 : 0)`. A ternary chain has no arm for a
    /// case it does not name: a fourth confidence would have ranked 0, identical to `.low`, and
    /// every comparison built on it — the batch gate that decides which cards "File all confident"
    /// acts on, the sort that puts surer answers first — would have read the new case as the least
    /// sure one. The header two lines up already says to APPEND new cases, which is precisely the
    /// change this shape could not survive.
    var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (a: FilingConfidence, b: FilingConfidence) -> Bool { a.rank < b.rank }
}

/// A candidate destination folder for a loose file.
public struct FilingDestination: Identifiable, Sendable, Equatable, Hashable {
    /// Absolute path of the destination folder.
    public let id: String
    public var path: String { id }
    public let confidence: FilingConfidence
    /// Human-readable "why this home" reasons.
    public let reasons: [String]
    /// Trailing path segments that don't exist yet and would be created on apply (e.g. ["Tesla",
    /// "Insurance"]). Empty when the whole path already exists.
    public let newSegments: [String]
    /// True when the deciding signal came from the file's *contents* (F2), not its name. Such
    /// matches are excluded from the blind "File recommended" batch — reading a word out of a
    /// document is a less checkable signal than a filename, and that batch moves files nobody has
    /// looked at.
    ///
    /// The blind-batch exclusion is what this flag is FOR, and it holds for every content-derived
    /// home. The confidence *cap* is narrower: it binds the heuristic content path
    /// (``Evidence/content``) and not the router's measured margin (``Evidence/measuredContent``),
    /// which is priced rather than claimed — so `.high` together with `fromContent` is a state the
    /// router builds on every home it names, and only the heuristic path cannot reach.
    public let fromContent: Bool
    /// True when this destination came from a remembered rule the user taught (F3). Ranked ahead of
    /// heuristic matches of equal confidence — an explicit correction outranks a guess.
    public let remembered: Bool
    /// True when an intelligent backend (on-device LLM / cloud) chose this destination by reasoning
    /// about the folder taxonomy and the file's contents, rather than keyword overlap.
    public let fromAI: Bool
    /// For a content-derived match (F2), the specific evidence word *read from the file* that
    /// decided this home (display-ready, e.g. "Invoice") — nil for a filename match. Lets the card
    /// surface content evidence distinctly (a highlight chip) so the stronger signal is legible,
    /// not indistinguishable from a plain name match.
    public let evidenceToken: String?
    /// How many files already in the destination share the matched signal — neighbor corroboration
    /// for a content match ("N similar files already in the target"). 0 when unknown or none.
    public let neighborMatches: Int
    /// What the file would be **called** once it lands here, when this folder names its files by a
    /// convention and the file's own name gives up its date — `04. Apr 2025.pdf` for a
    /// `DetailedBillApr2025.pdf` heading into a `NN. Mon YYYY` folder. nil ⇒ it keeps its name.
    ///
    /// It hangs off the DESTINATION rather than off the suggestion because the answer *is* a
    /// property of the destination: the slot a file takes is the folder's to decide, and "Try
    /// another" moves the file to a folder that numbers its files differently, or not at all. A
    /// name stored one level up would keep saying `04. Apr 2025.pdf` after the user sent the file
    /// somewhere that has never numbered anything.
    public let proposedName: String?

    public var isNew: Bool { !newSegments.isEmpty }

    public init(path: String, confidence: FilingConfidence, reasons: [String], newSegments: [String], fromContent: Bool = false, remembered: Bool = false, fromAI: Bool = false, evidenceToken: String? = nil, neighborMatches: Int = 0, proposedName: String? = nil) {
        self.id = path
        self.confidence = confidence
        self.reasons = reasons
        self.newSegments = newSegments
        self.fromContent = fromContent
        self.remembered = remembered
        self.fromAI = fromAI
        self.evidenceToken = evidenceToken
        self.neighborMatches = neighborMatches
        self.proposedName = proposedName
    }

    /// Where a destination's deciding evidence came from — the input to
    /// ``init(path:base:evidence:reasons:newSegments:remembered:evidenceToken:neighborMatches:proposedName:)``,
    /// the one construction path that applies the content-derived confidence cap.
    public enum Evidence: Sendable, Equatable {
        /// The filename, metadata, or an existing folder's own name. The claim stands as made.
        case name
        /// Read out of the file's *contents* by keyword overlap (a taxonomy hit, a remembered or
        /// automation rule, a universal rule). Capped at `.medium`: reading a common word out of a
        /// document is a weaker signal than a filename — and `fromContent` keeps the match out of
        /// the blind "File recommended" batch besides.
        case content
        /// Read out of the file's contents, but priced by the router's *calibrated margin* — the
        /// one content-derived signal whose confidence is measured rather than claimed (right
        /// 92.9% of the time when it reports high), so the cap does not apply. Still
        /// `fromContent`, so still never in the blind batch.
        case measuredContent
    }

    /// The one place the content-derived confidence cap lives. Every heuristic construction site
    /// (taxonomy match, remembered rule, automation, universal rule, router home) builds its
    /// confidence through here rather than spelling `min(base, .medium)` — or, worse, a
    /// `.medium`/`.high` overwrite that only agrees with the cap while base happens to be `.high` —
    /// for itself.
    ///
    /// The deliberate exception is the `fromAI` site,
    /// `FilingEngine.destination(from:providerRoot:existingRelative:fileName:)` — a code span, not
    /// a doc link, because that method is internal and this initializer is public, so the link
    /// could not resolve for anyone reading the public documentation. A backend's verdict keeps
    /// the confidence it claimed there, and the `fromAI` flag (not a demotion) is what keeps it
    /// out of the blind batch.
    public init(path: String, base: FilingConfidence, evidence: Evidence, reasons: [String],
                newSegments: [String], remembered: Bool = false, evidenceToken: String? = nil,
                neighborMatches: Int = 0, proposedName: String? = nil) {
        self.init(path: path,
                  confidence: evidence == .content ? min(base, .medium) : base,
                  reasons: reasons, newSegments: newSegments,
                  fromContent: evidence != .name, remembered: remembered, fromAI: false,
                  evidenceToken: evidenceToken, neighborMatches: neighborMatches,
                  proposedName: proposedName)
    }

    /// This folder named twice — one candidate carrying both claims. The higher-confidence
    /// candidate is the WINNER (a tie keeps `self`, the earlier-constructed candidate) and its
    /// claim stands: confidence, new segments, evidence token, neighbor count, proposed name.
    /// Reasons union, so both stories about the folder survive.
    ///
    /// Provenance merges two ways, on purpose:
    /// - `remembered` and `fromAI` merge by OR — "the user taught this" and "a model chose this"
    ///   are facts about either claimant that stay true of the merged candidate.
    /// - `fromContent` follows the WINNER, deliberately not OR. The flag documents the *deciding*
    ///   signal (see its declaration), and the confidence kept is the winner's: OR-ing it would
    ///   pair the winner's `.high` with a flag the LOSER earned — the very state the capped
    ///   construction path refuses to build for a heuristic content match — and would let a weak
    ///   content candidate that happens to name the same folder knock a legitimate filename home
    ///   out of the blind batch. Pinned by
    ///   `FilingProvenancePinTests/sameFolderNamedByARuleAndByContentKeepsTheWinnersProvenance`.
    func merging(_ other: FilingDestination) -> FilingDestination {
        let winner = other.confidence > confidence ? other : self
        return FilingDestination(path: path, confidence: winner.confidence,
                                 reasons: Array(Set(reasons + other.reasons)).sorted(),
                                 newSegments: winner.newSegments,
                                 fromContent: winner.fromContent,
                                 remembered: remembered || other.remembered,
                                 fromAI: fromAI || other.fromAI,
                                 evidenceToken: winner.evidenceToken,
                                 neighborMatches: winner.neighborMatches,
                                 proposedName: winner.proposedName)
    }

    /// A copy of this destination with its final folder renamed — for a NEW folder the user edits
    /// before accepting it.
    ///
    /// Only meaningful when ``isNew``: renaming a folder that already exists would not rename
    /// anything, it would name a DIFFERENT folder and quietly propose creating it. So a destination
    /// that creates nothing returns itself, and the caller cannot turn "file into this" into
    /// "create that" by accident.
    public func renamingNewFolder(to name: String) -> FilingDestination {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newSegments.isEmpty, !trimmed.isEmpty, !trimmed.contains("/"),
              trimmed != "." , trimmed != ".." else { return self }
        let parent = (path as NSString).deletingLastPathComponent
        return FilingDestination(path: parent + "/" + trimmed, confidence: confidence,
                                 reasons: reasons, newSegments: newSegments.dropLast() + [trimmed],
                                 fromContent: fromContent, remembered: remembered, fromAI: fromAI,
                                 evidenceToken: evidenceToken, neighborMatches: neighborMatches,
                                 proposedName: proposedName)
    }

    /// A copy of this destination at a different confidence — for capping a claim the evidence
    /// behind it cannot support (see ``FilingEngine/applyVerdicts(_:to:existingRelative:providerRoot:rejectedByFile:contentBlind:routerShortlists:)``).
    public func withConfidence(_ c: FilingConfidence) -> FilingDestination {
        FilingDestination(path: path, confidence: c, reasons: reasons, newSegments: newSegments,
                          fromContent: fromContent, remembered: remembered, fromAI: fromAI,
                          evidenceToken: evidenceToken, neighborMatches: neighborMatches,
                          proposedName: proposedName)
    }

    /// A copy of this destination carrying `name` as the rename it would apply.
    public func naming(_ name: String?) -> FilingDestination {
        FilingDestination(path: path, confidence: confidence, reasons: reasons,
                          newSegments: newSegments, fromContent: fromContent,
                          remembered: remembered, fromAI: fromAI, evidenceToken: evidenceToken,
                          neighborMatches: neighborMatches, proposedName: name)
    }
}

/// A loose file and its ranked suggested homes.
public struct FilingSuggestion: Identifiable, Sendable, Equatable {
    /// Absolute path of the loose file — its identity.
    public let id: String
    public var filePath: String { id }
    public let fileName: String
    public let size: Int
    public let modificationDate: Date?
    /// Ranked destinations, best first. Empty when nothing confident fits ("no confident home").
    public let candidates: [FilingDestination]
    /// Absolute path of the provider root this file lives under, when known — lets the UI render the
    /// destination breadcrumb provider-relative (e.g. "iCloud › Documents › …") instead of leaking
    /// the `/Users/<you>` home prefix. nil ⇒ the UI tilde-abbreviates instead.
    public let providerRoot: String?
    /// Provider-relative folders that already hold **this same document**, by content — the PDF text
    /// fingerprint where there is one and the byte hash otherwise.
    ///
    /// Empty is the ordinary case and the default, so a caller that knows nothing about duplicates
    /// builds exactly the suggestion it always did.
    public let alreadyFiledAt: [String]

    public var best: FilingDestination? { candidates.first }
    /// Whether this document is already somewhere in the tree.
    public var isAlreadyFiled: Bool { !alreadyFiledAt.isEmpty }
    /// The rename the card offers alongside the move, or nil when the best home does not name its
    /// files by a convention this pass can read.
    public var proposedName: String? { best?.proposedName }
    public var hasConfidentHome: Bool { (best?.confidence ?? .low) >= .medium }
    /// Eligible for the blind "File recommended" batch: a confident home derived from the filename
    /// (not content, not the LLM). Content-derived and AI homes still show a per-file "File here"
    /// but aren't auto-filed — a weaker/less-verifiable signal shouldn't move files unseen (the
    /// on-device model can be confidently wrong).
    ///
    /// **A document the tree already holds is never in the blind batch.** The batch files without
    /// the user looking, and the one thing they cannot review afterwards is a second copy they did
    /// not know was a copy: it lands under a name of its own, in a folder that legitimately fits,
    /// and nothing about it says it is a duplicate. Filing it is not undone by moving it back.
    public var isBatchEligible: Bool {
        hasConfidentHome && best?.fromContent == false && best?.fromAI == false && !isAlreadyFiled
    }

    public init(filePath: String, fileName: String, size: Int, modificationDate: Date?,
                candidates: [FilingDestination], providerRoot: String? = nil,
                alreadyFiledAt: [String] = []) {
        self.id = filePath
        self.fileName = fileName
        self.size = size
        self.modificationDate = modificationDate
        self.candidates = candidates
        self.providerRoot = providerRoot
        self.alreadyFiledAt = alreadyFiledAt
    }

    /// A copy of this suggestion carrying the folders that already hold the same document.
    public func alreadyFiled(at folders: [String]) -> FilingSuggestion {
        FilingSuggestion(filePath: filePath, fileName: fileName, size: size,
                         modificationDate: modificationDate, candidates: candidates,
                         providerRoot: providerRoot, alreadyFiledAt: folders)
    }

    /// The same document with a **new list of homes** — and everything else about it intact.
    ///
    /// The one way to re-answer a suggestion. Four places do it — a verdict promotion, a route, a
    /// re-ask, a rename re-naming — and every one was rebuilding the value member by member, so
    /// none of them carried `alreadyFiledAt`.
    ///
    /// **Two of the four could actually lose it**, which is worth stating precisely rather than
    /// counting call sites as defects: the marker is produced by `markingAlreadyFiled` at the very
    /// end of the scan, and `route`/`namingSuggestions` both run before that (and `readScan` hands
    /// `route` a deliberately blank suggestion), so neither ever held a marker to drop. The two
    /// that did are `applyVerdicts` reached from a refine and `replaceFilingSuggestion` behind
    /// "Try another": refine a marked list or press that button, and `isAlreadyFiled` flipped back
    /// to false. The card lost the one warning that stops a second copy being filed — and losing
    /// it is not undone by moving the file back, because the copy lands under a name of its own in
    /// a folder that fits. Unifying all four is still right; only the count of defects is two.
    ///
    /// A rebuild that wants to drop the marker has to say so; the default is to keep what was
    /// learned about the document, since none of these callers learned anything to the contrary.
    public func replacingCandidates(_ candidates: [FilingDestination]) -> FilingSuggestion {
        FilingSuggestion(filePath: filePath, fileName: fileName, size: size,
                         modificationDate: modificationDate, candidates: candidates,
                         providerRoot: providerRoot, alreadyFiledAt: alreadyFiledAt)
    }
}

public struct FilingOptions: Sendable {
    public var maxCandidates: Int
    public var minFileSize: Int
    public var ignoredNames: Set<String>
    /// Whether the provider's volume distinguishes `Inbox` from `inbox`, used when deciding that a
    /// candidate folder is the file's own parent (`PathBoundary.namesSameDirectory`). Defaults to
    /// FALSE — the macOS default, and the safe direction: over-matching only withholds a
    /// suggestion to move a file where it already is, while under-matching offers one whose apply
    /// path would rename the file in place. (`generateUniqueURL`'s like-named parameter defaults
    /// the other way because there the conservative answer is the opposite one.)
    public var caseSensitiveVolume: Bool

    public init(maxCandidates: Int = 3, minFileSize: Int = 0,
                ignoredNames: Set<String> = FilingOptions.defaultIgnoredNames,
                caseSensitiveVolume: Bool = false) {
        self.maxCandidates = maxCandidates
        self.minFileSize = minFileSize
        self.ignoredNames = ignoredNames
        self.caseSensitiveVolume = caseSensitiveVolume
    }

    public static let defaultIgnoredNames: Set<String> = [
        ".DS_Store", ".localized", "Thumbs.db", "desktop.ini"
    ]
}

// MARK: - Engine

/// Suggests where loose files belong within a single provider, using only on-device signals:
/// filenames, extensions, file dates, and the user's *own* existing folders (learned taxonomy)
/// plus a small set of universal rules. Pure and deterministic — no content reading, no network.
public enum FilingEngine {

    /// - Parameters:
    ///   - looseFiles: The files to find homes for (the direct files of the picked folder).
    ///   - taxonomy: The provider's folder tree, used to learn where things go and to know which
    ///     folders already exist (so new sub-paths are proposed relative to them, never invented
    ///     from nothing).
    ///   - providerRoot: Absolute path of the provider root — the only place a brand-new top-level
    ///     folder (e.g. "Photos") may be proposed.
    ///   - options: Tuning.
    /// - Returns: One suggestion per loose file, in input order.
    /// - Parameter contentTokens: Optional per-file tokens extracted from the file's *contents*
    ///   (entities/keywords from PDF text, OCR, etc.), merged with the filename tokens so a file
    ///   whose name says nothing can still find a home. Empty for the filename-only (F1) pass.
    /// - Parameter rules: Remembered filing rules (F3) — token-set → folder mappings the user
    ///   taught by correcting past suggestions. A rule that matches ranks ahead of the heuristics.
    ///   Legacy: pre-migration stores only; migrated installs pass `automations` instead.
    /// - Parameter automations: The user's automation rules. An enabled, runnable automation that
    ///   matches a file steers its suggestion exactly like a remembered rule: user-taught, so it
    ///   ranks ahead of the heuristics (capped to medium when the match needed the file's content).
    /// - Parameter providerName: Resolves `{provider}` in an automation's destination template.
    /// - Parameter automationSnippets: Per-file lowercased text excerpts, extracted up front for the
    ///   files where a content-reading automation could match — the SAME text the Automations
    ///   preview evaluates, so a rule gives one answer on both surfaces.
    /// - Parameter now: Injectable clock for the automations' date conditions and `{year}` tokens.
    /// - Parameter rejectedByFile: Per-file absolute folder paths the user has rejected — dropped
    ///   from that file's candidates so a "no, not there" is never re-suggested.
    public static func suggest(
        looseFiles: [FileNode],
        taxonomy: [FileNode],
        providerRoot: String,
        contentTokens: [String: Set<String>] = [:],
        rules: [FilingRule] = [],
        automations: [AutomationRule] = [],
        /// The household, so a `personIs` rule and a `{person}` destination can resolve. nil ⇒
        /// person rules never match, which is the behaviour before people existed.
        registry: PersonRegistry? = nil,
        identity: PersonIdentityIndex? = nil,
        providerName: String? = nil,
        automationSnippets: [String: String] = [:],
        now: Date = Date(),
        rejectedByFile: [String: Set<String>] = [:],
        options: FilingOptions = .init()
    ) -> [FilingSuggestion] {
        var profiles: [FolderProfile] = []
        var existingPaths: Set<String> = [providerRoot]
        for node in taxonomy {
            collectProfiles(node, ancestorTokens: [], into: &profiles, paths: &existingPaths, options: options)
        }
        // Which rules are allowed to act does not depend on the file, so it is decided once for
        // the scan rather than once per loose file — the shared eligibility bar, one array.
        let actingAutomations = AutomationRuleSet.eligible(automations)

        return looseFiles.compactMap { file -> FilingSuggestion? in
            guard !file.isDirectory else { return nil }
            guard !options.ignoredNames.contains(file.name) else { return nil }
            guard (file.fileSize ?? 0) >= options.minFileSize else { return nil }

            let nameToks = fileTokens(file.name)
            let content = contentTokens[file.id] ?? []
            let tokens = nameToks.union(content)
            let ext = (file.name as NSString).pathExtension.lowercased()
            // The year segment of rule destinations (Receipts/<year>, Taxes/<year>, …): a single
            // plausible year in the FILENAME names the document's own year and wins over the
            // modification date, which is merely when the bytes last changed — a 2023 tax form
            // downloaded in 2024 belongs in Taxes/2023, not Taxes/2024. Zero or multiple filename
            // years (a "2021-2022" range says nothing definite) fall back to mtime.
            let year = filenameYear(in: nameToks) ?? yearString(file.modificationDate)

            var candidates: [FilingDestination] = []
            candidates += rememberedCandidates(rules: rules, tokens: tokens, nameTokens: nameToks,
                                               contentTokens: content, existingPaths: existingPaths)
            candidates += automationCandidates(automations: actingAutomations, file: file,
                                               contentTokens: content,
                                               snippet: automationSnippets[file.id],
                                               providerRoot: providerRoot, providerName: providerName,
                                               existingPaths: existingPaths, now: now,
                                               registry: registry, identity: identity)
            candidates += taxonomyCandidates(tokens: tokens, nameTokens: nameToks, contentTokens: content, profiles: profiles)
            candidates += ruleCandidates(tokens: tokens, nameTokens: nameToks, contentTokens: content,
                                         nameLower: file.name.lowercased(), ext: ext, year: year,
                                         profiles: profiles, existingPaths: existingPaths, providerRoot: providerRoot)

            // A file already sitting in a suggested folder shouldn't be told to move to where it is.
            // Case-folded on a case-insensitive volume: a rule destination spelled in a different
            // case names the same folder there, and offering it would put the file on a path whose
            // apply step renames it in place.
            let selfParent = (file.id as NSString).deletingLastPathComponent
            candidates.removeAll {
                PathBoundary.namesSameDirectory($0.path, selfParent, caseSensitive: options.caseSensitiveVolume)
            }

            // Drop rejected folders from the full pool BEFORE ranking+capping, so a valid deeper
            // candidate isn't lost: removing after the cap could strip the top pick and leave the
            // file with fewer (or no) homes even though a good one existed just past the cap.
            var pool = candidates
            if let rejected = rejectedByFile[file.id], !rejected.isEmpty {
                pool.removeAll { rejected.contains($0.path) }
            }
            let ranked = rank(pool, limit: options.maxCandidates)
            return FilingSuggestion(filePath: file.id, fileName: file.name,
                                    size: file.fileSize ?? 0, modificationDate: file.modificationDate,
                                    candidates: ranked, providerRoot: providerRoot)
        }
    }

    // MARK: Folder profiles (learned taxonomy)

    struct FolderProfile {
        let path: String
        let name: String
        let depth: Int
        /// Tokens from the folder name and its ancestors (strong signal).
        let nameTokens: Set<String>
        /// Tokens from the names of files directly inside (weaker signal).
        let contentTokens: Set<String>
        /// For each content token, how many files directly inside carry it — the count behind
        /// "N similar files already in the target".
        let contentTokenFileCounts: [String: Int]
    }

    private static func collectProfiles(
        _ node: FileNode, ancestorTokens: Set<String>,
        into profiles: inout [FolderProfile], paths: inout Set<String>, options: FilingOptions
    ) {
        guard node.isDirectory, !options.ignoredNames.contains(node.name) else { return }
        paths.insert(node.id)

        let combinedNameTokens = ancestorTokens.union(nameTokens(node.name))
        var contentTokens = Set<String>()
        var contentTokenFileCounts: [String: Int] = [:]
        for child in node.children ?? [] where !child.isDirectory {
            let toks = fileTokens(child.name)
            contentTokens.formUnion(toks)
            for t in toks { contentTokenFileCounts[t, default: 0] += 1 }
        }
        profiles.append(FolderProfile(
            path: node.id, name: node.name, depth: node.id.split(separator: "/").count,
            nameTokens: combinedNameTokens, contentTokens: contentTokens,
            contentTokenFileCounts: contentTokenFileCounts))

        for child in node.children ?? [] where child.isDirectory {
            collectProfiles(child, ancestorTokens: combinedNameTokens, into: &profiles, paths: &paths, options: options)
        }
    }

    /// Existing folders whose profile overlaps the file's tokens, as ranked destinations.
    private static func taxonomyCandidates(tokens: Set<String>, nameTokens: Set<String>,
                                           contentTokens: Set<String>, profiles: [FolderProfile]) -> [FilingDestination] {
        guard !tokens.isEmpty else { return [] }
        var out: [FilingDestination] = []
        for p in profiles {
            let nameHits = tokens.intersection(p.nameTokens)
            let contentHits = tokens.intersection(p.contentTokens).subtracting(nameHits)
            // A bare year names WHICH same-year folder, not WHAT category — matching a year-named
            // folder on the year alone must never stand up a high-confidence, batch-eligible home,
            // or the blind "File recommended" batch would move e.g. "2024-tax-return.pdf" into
            // whichever `…/2024` folder sorts first. Only non-year hits carry category strength;
            // the year still rides along in the displayed reason below.
            let categoryNameHits = nameHits.filter { !isYear($0) }
            let categoryContentHits = contentHits.filter { !isYear($0) }
            let score = categoryNameHits.count * 3 + categoryContentHits.count
            guard score >= 3 else { continue }   // a real folder-name hit, or ≥3 content hits
            let hitSet = nameHits.union(contentHits)
            let hits = hitSet.sorted().prefix(3).joined(separator: ", ")
            // Content-derived when the deciding (non-year) tokens are NOT in the filename — a year
            // shared between the filename and the folder must not make a content match look
            // name-derived (and thus batch-eligible). Compare the category hits to the real
            // filename tokens, so a token in BOTH name and content counts as from the name.
            let categoryHits = categoryNameHits.union(categoryContentHits)
            let fromContent = categoryHits.isDisjoint(with: nameTokens) && !categoryHits.isDisjoint(with: contentTokens)
            let base: FilingConfidence = !categoryNameHits.isEmpty ? .high : .medium
            if fromContent {
                // Surface the single strongest evidence word (prefer a sibling-content hit, which
                // carries a neighbor count) plus how many files already in the target share it —
                // legible corroboration a plain name match can't offer.
                let evidenceRaw = contentHits.sorted().first ?? nameHits.sorted().first ?? hitSet.sorted().first ?? ""
                let neighbors = p.contentTokenFileCounts[evidenceRaw] ?? 0
                let reason = neighbors > 0
                    ? "Matched “\(evidenceRaw)” read from the file — \(neighbors) similar file\(neighbors == 1 ? "" : "s") already in the target"
                    : "Matched “\(evidenceRaw)” read from the file, in a folder you already keep"
                out.append(FilingDestination(path: p.path, base: base, evidence: .content,
                                             reasons: [reason], newSegments: [],
                                             evidenceToken: evidenceRaw.capitalized, neighborMatches: neighbors))
            } else {
                let reason = "Matches “\(hits)” in a folder you already keep"
                out.append(FilingDestination(path: p.path, base: base, evidence: .name,
                                             reasons: [reason], newSegments: []))
            }
        }
        return out
    }

    // MARK: Remembered rules (F3)

    /// Destinations from remembered rules whose trigger tokens are all present in the file. A rule
    /// match is high confidence (the user taught it) — unless the match rests only on content
    /// tokens, which is capped to medium like any other content-derived signal.
    private static func rememberedCandidates(
        rules: [FilingRule], tokens: Set<String>, nameTokens: Set<String>,
        contentTokens: Set<String>, existingPaths: Set<String>
    ) -> [FilingDestination] {
        guard !rules.isEmpty, !tokens.isEmpty else { return [] }
        var out: [FilingDestination] = []
        for rule in rules {
            let trigger = Set(rule.tokens)
            guard !trigger.isEmpty, trigger.isSubset(of: tokens) else { continue }
            // From content when none of the trigger tokens appear in the filename.
            let fromContent = trigger.isDisjoint(with: nameTokens) && !trigger.isDisjoint(with: contentTokens)
            let shown = rule.tokens.sorted().prefix(3).joined(separator: ", ")
            let reason = fromContent
                ? "Remembered — you file “\(shown)” documents here (read from the file)"
                : "Remembered — you file “\(shown)” here"
            out.append(FilingDestination(
                path: rule.destinationPath,
                base: .high, evidence: fromContent ? .content : .name,   // user-taught ⇒ high, capped like any content signal
                reasons: [reason],
                newSegments: missingSegments(of: rule.destinationPath, existingPaths: existingPaths),
                remembered: true))
        }
        return out
    }

    // MARK: Automation rules (steering)

    /// Destinations from the user's automations, as suggestion candidates. An enabled, runnable
    /// automation whose conditions hold for the file steers the suggestion the way a remembered
    /// rule always did: the user wrote it, so it's high confidence — capped to medium when the
    /// match needed the file's *content* (same cap every content-derived signal gets, which also
    /// keeps it out of the blind batch apply). A rule whose destination resolves outside this
    /// provider is inert here, exactly like the old provider-scoped remembered rules.
    ///
    /// Takes the already-narrowed ``AutomationRuleSet`` rather than the raw rules: eligibility is
    /// a property of the rules, not of the file, so the scan decides it once instead of once per
    /// loose file.
    private static func automationCandidates(
        automations: AutomationRuleSet, file: FileNode, contentTokens: Set<String>, snippet: String?,
        providerRoot: String, providerName: String?, existingPaths: Set<String>, now: Date,
        registry: PersonRegistry?, identity: PersonIdentityIndex?
    ) -> [FilingDestination] {
        guard !automations.isEmpty else { return [] }
        let facts = automationFacts(for: file, contentTokens: contentTokens, snippet: snippet,
                                    registry: registry, identity: identity)
        // The same facts with the content stripped — a rule that only matches WITH content is a
        // content-derived signal (medium confidence, "read from the file" note, no blind batch).
        var nameOnlyFacts = facts
        nameOnlyFacts.contentTokens = []
        nameOnlyFacts.snippet = nil

        var out: [FilingDestination] = []
        for rule in automations.rules {
            guard AutomationEvaluator.matches(rule, facts, now: now) else { continue }
            guard case .resolved(let resolved) = AutomationEvaluator.resolveDestination(
                rule.destinationTemplate, for: facts, providerName: providerName, now: now) else { continue }
            guard let destination = AutomationEvaluator.absoluteDestination(resolved, providerRoot: providerRoot) else { continue }
            let fromContent = ruleMatchIsContentDerived(rule, facts: facts, nameOnlyFacts: nameOnlyFacts, now: now)
            let label = rule.name.trimmingCharacters(in: .whitespaces)
            let shown = label.isEmpty ? rule.summary : label
            let reason = fromContent
                ? "Your rule “\(shown)” files this here (read from the file)"
                : "Your rule “\(shown)” files this here"
            out.append(FilingDestination(
                path: destination,
                base: .high, evidence: fromContent ? .content : .name,   // user-written ⇒ high, capped like any content signal
                reasons: [reason],
                newSegments: missingSegments(of: destination, existingPaths: existingPaths),
                remembered: true))
        }
        return out
    }

    /// The evaluator facts for a loose file in an Organize scan. Shared with the manager's
    /// content-gating pass so both build identical inputs. `snippet` (when a content-reading rule
    /// warranted extracting it) also supplies the content tokens, tokenized exactly as the
    /// Automations preview tokenizes its excerpt — one rule, one answer on both surfaces.
    static func automationFacts(for file: FileNode, contentTokens: Set<String> = [],
                                snippet: String? = nil,
                                registry: PersonRegistry? = nil,
                                identity: PersonIdentityIndex? = nil) -> AutomationFileFacts {
        let parentPath = (file.id as NSString).deletingLastPathComponent
        return AutomationFileFacts(
            path: file.id, name: file.name,
            parentFolderName: (parentPath as NSString).lastPathComponent,
            parentPath: parentPath,
            sizeBytes: file.fileSize ?? 0,
            modificationDate: file.modificationDate,
            isDirectory: file.isDirectory,
            // Lowercased HERE, the one choke point on the scan path: the facts contract says
            // "already lowercased" but the Organize scan hands over the extractor's raw text
            // (the dry-run lowercases its own) — and `contentContains` matches case-sensitively
            // against a lowercased needle, so raw "Invoice" never matched "invoice" in the scan
            // while the Automations preview said it would. nameTokens lowercases internally, so
            // the derived contentTokens are unchanged either way.
            snippet: snippet?.lowercased(),
            contentTokens: snippet.map { nameTokens($0) } ?? contentTokens)
            .attributing(registry, identity: identity)
    }

    /// Whether a matched rule's evidence is content-derived — which caps it to medium and keeps it
    /// out of the blind batch. For the learned single-`mentionsAll` shape this is the EXACT test
    /// the legacy remembered rules used (content-derived only when NO trigger word is in the
    /// filename), so a migrated rule keeps its batch behavior; a general multi-condition rule is
    /// content-derived whenever it would not match on the name/metadata alone (conservative).
    private static func ruleMatchIsContentDerived(
        _ rule: AutomationRule, facts: AutomationFileFacts, nameOnlyFacts: AutomationFileFacts, now: Date
    ) -> Bool {
        if rule.conditions.count == 1, case .mentionsAll(let tokens) = rule.conditions[0] {
            let trigger = Set(tokens.map { $0.lowercased() }.filter { !$0.isEmpty })
            return trigger.isDisjoint(with: facts.nameTokens) && !trigger.isDisjoint(with: facts.contentTokens)
        }
        return !AutomationEvaluator.matches(rule, nameOnlyFacts, now: now)
    }

    /// The trailing segments of an absolute path that don't yet exist (would be recreated on apply);
    /// empty when the whole path already exists. Lets a remembered folder that was since deleted be
    /// re-proposed with NEW tags rather than silently failing.
    static func missingSegments(of path: String, existingPaths: Set<String>) -> [String] {
        if existingPaths.contains(path) { return [] }
        var current = ""
        var segments: [(prefix: String, seg: String)] = []
        for seg in path.split(separator: "/") {
            current += "/" + seg
            segments.append((current, String(seg)))
        }
        // The missing tail is everything after the LONGEST prefix that exists. Latching at the
        // first non-existing prefix instead would mark every segment from the filesystem root:
        // `existingPaths` holds the provider root and its walked folders, never the root's own
        // ancestors ("/Users", …), so for a real multi-segment provider root the first prefix
        // always misses and a deleted remembered folder would flag the whole path as NEW.
        let lastExisting = segments.lastIndex { existingPaths.contains($0.prefix) }
        let missingStart = lastExisting.map { $0 + 1 } ?? 0
        return segments[missingStart...].map { $0.seg }
    }

    // MARK: Universal rules

    private static func ruleCandidates(
        tokens: Set<String>, nameTokens: Set<String>, contentTokens: Set<String>, nameLower: String,
        ext: String, year: String?, profiles: [FolderProfile], existingPaths: Set<String>, providerRoot: String
    ) -> [FilingDestination] {
        var out: [FilingDestination] = []
        // A signal is "from content" when none of its tokens appear in the filename. Content-derived
        // matches are capped to medium (a common word in a document is weaker than a filename) and
        // get a "(read from the file)" note, which also keeps them out of the blind batch apply.
        func rule(_ anchor: String, _ segs: [String], _ base: FilingConfidence, _ reason: String, signal: Set<String>) {
            let fc = signal.isDisjoint(with: nameTokens) && !signal.isDisjoint(with: contentTokens)
            out.append(under(anchor, segs, existingPaths, base: base,
                             evidence: fc ? .content : .name,
                             reason + (fc ? " (read from the file)" : "")))
        }

        // Photos → <Photos folder>/<year>, or a proposed Photos/<year> at the root (extension-based).
        if photoExtensions.contains(ext), let year {
            if let photos = existingFolder(named: ["photos", "pictures", "images", "camera roll"], in: profiles) {
                rule(photos, [year], .high, "Photo — filed by capture year", signal: [])
            } else {
                rule(providerRoot, ["Photos", year], .medium, "Photo — suggested Photos/\(year)", signal: [])
            }
        }

        // Vehicle documents → <Vehicles>/<Brand>[/Insurance]  (only if you keep a vehicles folder).
        if let brand = vehicleBrands.first(where: { tokens.contains($0) }),
           let vehicles = existingFolder(named: ["vehicles", "cars", "auto", "automobile"], in: profiles) {
            var segs = [brand.capitalized]
            var reason = "Vehicle document — \(brand.capitalized)"
            var signal: Set<String> = [brand]
            if !tokens.isDisjoint(with: insuranceTokens) {
                segs.append("Insurance"); reason = "\(brand.capitalized) insurance document"
                signal.formUnion(tokens.intersection(insuranceTokens))
            }
            rule(vehicles, segs, .medium, reason, signal: signal)
        }

        // Receipts / invoices / orders → <Receipts>/<year> or <Finance|Documents>/Receipts/<year>.
        let receiptSig = tokens.intersection(receiptTokens)
        if !receiptSig.isEmpty, let year {
            if let receipts = existingFolder(named: ["receipts", "invoices", "purchases", "orders"], in: profiles) {
                rule(receipts, [year], .high, "Receipt or invoice — filed by year", signal: receiptSig)
            } else if let finance = existingFolder(named: ["finance", "documents", "financial"], in: profiles) {
                rule(finance, ["Receipts", year], .medium, "Receipt or invoice — suggested Receipts/\(year)", signal: receiptSig)
            }
        }

        // Tax documents → <Taxes>/<year> or <Finance|Documents>/Taxes/<year>. Form numbers like
        // 1099/1040 are bare digits (stripped from filename tokens), so also sniff the raw name —
        // when they're in the NAME the match is a name signal (not content).
        let taxSig = tokens.intersection(taxTokens)
        let taxFromName = nameLower.contains("1099") || nameLower.contains("1040")
        if !taxSig.isEmpty || taxFromName, let year {
            let taxSignal: Set<String> = taxFromName ? [] : taxSig
            if let taxes = existingFolder(named: ["taxes", "tax"], in: profiles) {
                rule(taxes, [year], .high, "Tax document — filed by year", signal: taxSignal)
            } else if let finance = existingFolder(named: ["finance", "documents", "financial"], in: profiles) {
                rule(finance, ["Taxes", year], .medium, "Tax document — suggested Taxes/\(year)", signal: taxSignal)
            }
        }

        // Statements → <Statements|Bank|Finance>/<year>.
        let stmtSig = tokens.intersection(statementTokens)
        if !stmtSig.isEmpty, let year,
           let base = existingFolder(named: ["statements", "bank", "banking", "finance"], in: profiles) {
            rule(base, [year], .medium, "Statement — filed by year", signal: stmtSig)
        }

        return out
    }

    /// Builds a destination under an EXISTING anchor folder, appending segments and marking which
    /// are new (don't yet exist).
    private static func under(_ anchor: String, _ segments: [String], _ existingPaths: Set<String>,
                             base: FilingConfidence, evidence: FilingDestination.Evidence,
                             _ reason: String) -> FilingDestination {
        var path = anchor
        var newSegments: [String] = []
        var creating = false
        for seg in segments {
            path += "/" + seg
            if creating || !existingPaths.contains(path) {
                creating = true
                newSegments.append(seg)
            }
        }
        return FilingDestination(path: path, base: base, evidence: evidence, reasons: [reason],
                                 newSegments: newSegments)
    }

    private static func existingFolder(named candidates: [String], in profiles: [FolderProfile]) -> String? {
        profiles
            .filter { candidates.contains($0.name.lowercased()) }
            .min(by: { $0.depth < $1.depth })?
            .path
    }

    // MARK: Ranking

    private static func rank(_ candidates: [FilingDestination], limit: Int) -> [FilingDestination] {
        var byPath: [String: FilingDestination] = [:]
        for c in candidates {
            // The merge discipline lives on FilingDestination.merging — one owner, documented there.
            byPath[c.path] = byPath[c.path]?.merging(c) ?? c
        }
        return byPath.values.sorted { a, b in
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            if a.remembered != b.remembered { return a.remembered }      // a correction you taught outranks a guess
            if a.isNew != b.isNew { return !a.isNew }                    // prefer existing folders
            if a.newSegments.count != b.newSegments.count { return a.newSegments.count < b.newSegments.count }
            // Among equally-good matches, prefer the shallower, more general folder — so a generic
            // doc lands in top-level /Insurance, not a nested namesake like /Health/Insurance.
            let da = a.path.split(separator: "/").count, db = b.path.split(separator: "/").count
            if da != db { return da < db }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }.prefix(limit).map { $0 }
    }

    // MARK: Tokenization

    /// Tokens from a filename (extension stripped). Camera-sequence stems (IMG_2023, DSC_1995,
    /// PXL 0421, GOPR0042) drop their year-shaped digits: the number is a shot counter, not a
    /// year, and letting it through filed IMG_2023.jpg (shot in 2026) into Photos/2023 — at high
    /// confidence and batch-eligible. Applied to the RAW stem before tokenization, because the
    /// tokens alone can't tell IMG_2023 from a genuine "2023" ("img" is a stopword, so both
    /// reduce to the bare year token). This is the one shared entry point for filename tokens,
    /// so the heuristic year, the automations' `{year}` template (which derives its filename
    /// year from these tokens), and `mentionsAll` matching all agree.
    public static func fileTokens(_ fileName: String) -> Set<String> {
        let stem = (fileName as NSString).deletingPathExtension
        let tokens = nameTokens(stem)
        guard isCameraSequenceStem(stem) else { return tokens }
        return tokens.filter { !isYear($0) }
    }

    /// Whether a raw filename stem is a camera/phone sequence name — a known device prefix plus
    /// a 3–6 digit shot counter and nothing else. "Wedding 2023" is NOT one: its year is real.
    ///
    /// GoPro prefixes are pinned to the exact shapes the cameras write — GOPR + 4-digit file
    /// number (GOPR0001.MP4), or GP/GH/GX/GS + 2-digit chapter + 4-digit file number
    /// (GP010001, GH010001, GX010001, GS010001), no separator. The old `gopr\w*` alternative
    /// backtracked through arbitrary words, so a hand-named "gopro_hawaii_2023.mp4" counted as
    /// a camera sequence and its REAL 2023 lost both year filing and "mentions 2023" matching.
    static func isCameraSequenceStem(_ stem: String) -> Bool {
        stem.range(of: #"^(?:(?:img|dsc|dscn|dscf|dcim|pxl|mvimg)[_ -]?\d{3,6}|gopr\d{4}|(?:gp|gh|gx|gs)\d{6})$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The union of every category vocabulary — the keywords a content extractor should surface
    /// from a document (insurers, vendors, banks, tax terms, vehicle brands) so the rules fire.
    public static let categoryKeywords: Set<String> =
        insuranceTokens.union(receiptTokens).union(taxTokens).union(statementTokens).union(vehicleBrands)

    /// Tokens from an arbitrary name: split on non-alphanumerics and camelCase, lowercase, drop
    /// stopwords and non-year pure numbers.
    public static func nameTokens(_ s: String) -> Set<String> {
        var spaced = ""
        var prev: Character? = nil
        for ch in s {
            if ch.isLetter || ch.isNumber {
                if let p = prev, p.isLowercase, ch.isUppercase { spaced.append(" ") }  // camelCase
                spaced.append(ch)
            } else {
                spaced.append(" ")
            }
            prev = ch
        }
        var out = Set<String>()
        for raw in spaced.split(separator: " ") {
            let t = raw.lowercased()
            if t.count < 2 { continue }
            if stopwords.contains(t) { continue }
            if t.allSatisfy(\.isNumber) {
                if isYear(t) { out.insert(t) }   // keep years, drop other bare numbers
                continue
            }
            out.insert(t)
        }
        return out
    }

    private static func isYear(_ t: String) -> Bool {
        guard t.count == 4, let n = Int(t) else { return false }
        return n >= 1900 && n <= 2099
    }

    /// The single PLAUSIBLE year named by the filename's tokens, or nil. Plausible narrows
    /// ``isYear``'s 1900–2099 token span to 1990...(current year + 1) — old scans and next
    /// year's pre-dated statements are real; "2098" in a filename is not a filing year.
    /// Requires exactly one such token: several ("FY2021-2022 report") name no single year.
    /// `now` is injectable for deterministic tests.
    static func filenameYear(in nameTokens: Set<String>, now: Date = Date()) -> String? {
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: now)
        let plausible = nameTokens.filter { token in
            guard isYear(token), let n = Int(token) else { return false }
            return n >= 1990 && n <= currentYear + 1
        }
        return plausible.count == 1 ? plausible.first : nil
    }

    private static func yearString(_ date: Date?) -> String? {
        guard let date else { return nil }
        return Calendar(identifier: .gregorian).dateComponents([.year], from: date).year.map(String.init)
    }

    // MARK: Remembered-rule construction (F3)

    /// Whether a rule can be learned from this filename at all — true when the name yields at least
    /// one salient (non-year) token. A file whose name says nothing (e.g. "scan0012.pdf") can't seed
    /// a rule, so the UI shouldn't offer to remember it.
    public static func canRemember(fileName: String) -> Bool {
        fileTokens(fileName).contains { !isYear($0) }
    }

    /// The filename's salient (non-year) tokens, sorted — the signature used to remember a rejection
    /// so it generalizes to files with the same distinctive words.
    public static func salientTokens(ofFileNamed fileName: String) -> [String] {
        fileTokens(fileName).filter { !isYear($0) }.sorted()
    }

    /// Builds a remembered rule from a correction: the file the user just filed and where they put
    /// it. The trigger prefers the *distinctive anchor* — tokens the filename shares with the
    /// destination's own folder names (e.g. "tesla" in a `…/Tesla/Insurance` path) — so the rule
    /// generalizes ("the next Tesla document") without keying on incidental words. Falls back to the
    /// file's salient tokens when there's no shared anchor. Returns nil when nothing usable remains.
    public static func rule(forFileNamed fileName: String, contentTokens: Set<String> = [],
                            filedInto destinationPath: String) -> FilingRule? {
        let salientName = fileTokens(fileName).filter { !isYear($0) }
        // Only the leaf folders carry meaning; the provider-root prefix would add noise.
        let destTokens = destinationPath.split(separator: "/").suffix(3)
            .reduce(into: Set<String>()) { $0.formUnion(nameTokens(String($1))) }

        var trigger = salientName.intersection(destTokens)
        if trigger.isEmpty { trigger = contentTokens.filter { !isYear($0) }.intersection(destTokens) }
        if trigger.isEmpty { trigger = salientName }
        guard !trigger.isEmpty else { return nil }
        return FilingRule(tokens: trigger.sorted(), destinationPath: destinationPath)
    }

    // MARK: Vocabularies

    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "copy", "final", "draft", "new", "old", "doc",
        "document", "file", "scan", "img", "image", "photo", "untitled", "version", "vers",
        "our", "misc", "temp", "test"
    ]
    static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "raw", "dng", "cr2", "nef",
        "mov", "mp4", "m4v", "avi"
    ]
    static let vehicleBrands: Set<String> = [
        "tesla", "toyota", "honda", "ford", "bmw", "audi", "mercedes", "lexus", "subaru",
        "nissan", "chevrolet", "chevy", "volkswagen", "volvo", "porsche", "jeep", "kia",
        "hyundai", "mazda", "rivian"
    ]
    static let insuranceTokens: Set<String> = ["insurance", "policy", "coverage", "geico", "allstate", "progressive"]
    static let receiptTokens: Set<String> = ["receipt", "invoice", "order", "purchase", "amazon", "billing", "bill"]
    // 1099/1040 are useful as *content* tokens (the filename path also sniffs them raw, since the
    // tokenizer strips bare numbers from filenames).
    // "return" was dropped — too ambiguous in document body text (product returns, etc.).
    static let taxTokens: Set<String> = ["tax", "taxes", "1099", "1040", "irs"]
    static let statementTokens: Set<String> = ["statement", "bank", "chase", "amex", "visa", "mastercard", "wells", "fargo"]

    // MARK: Intelligent classification (overlay)

    /// Folder paths relative to the provider root — the taxonomy handed to a classifier. Built
    /// structurally from node names (not by string-stripping the root) so it's immune to symlink
    /// prefix differences like /var vs /private/var. Shallowest first, capped so a huge tree can't
    /// blow the model's context (deep leaves drop first).
    public static func relativeFolderPaths(of taxonomy: [FileNode], limit: Int = 250) -> [String] {
        var out: [String] = []
        func walk(_ node: FileNode, prefix: String) {
            guard node.isDirectory else { return }
            let rel = prefix.isEmpty ? node.name : prefix + "/" + node.name
            out.append(rel)
            for child in node.children ?? [] { walk(child, prefix: rel) }
        }
        for node in taxonomy { walk(node, prefix: "") }
        return out.sorted { a, b in
            let da = a.split(separator: "/").count, db = b.split(separator: "/").count
            if da != db { return da < db }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.prefix(limit).map { $0 }
    }

    /// The folder menu a classifier is allowed to answer with — the folders the router already
    /// thinks are plausible, then the shallow structural list to fill what's left.
    ///
    /// **The cap is a token budget, not a preference for shallow folders**, and spending it by depth
    /// is how a confident wrong answer gets produced. `relativeFolderPaths` orders shallowest-first
    /// and drops deep leaves; on a real 5,012-folder tree the cut lands at depth 3, so a visa foil
    /// belonging in `Immigration/Visa/US/H-1B Visa/2024-2026` (1,344th by that order) was never in
    /// the prompt at all — nor was any folder under `Visa/US`. The model picked the best of what it
    /// could see, `Immigration/Form I-94/Abhishek` at 205th, and wrote a confident sentence about a
    /// name match that does not exist. It was not wrong about the folders it was shown; it was
    /// shown the wrong folders.
    ///
    /// `reservedForFallback` keeps room for the shallow skeleton so the model still sees the shape
    /// of the tree — a menu of nothing but deep leaves reads as a flat list of unrelated paths, and
    /// the "propose a new subfolder under an existing parent" rule needs parents in view. Any budget
    /// the fallback doesn't use goes back to `preferred`.
    public static func classifierFolders(preferred: [String], fallback: [String],
                                         limit: Int = 250, reservedForFallback: Int = 100) -> [String] {
        guard limit > 0 else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        func take(_ paths: [String], upTo cap: Int) {
            for p in paths where out.count < cap {
                if seen.insert(p).inserted { out.append(p) }
            }
        }
        take(preferred, upTo: max(0, limit - reservedForFallback))
        take(fallback, upTo: limit)
        take(preferred, upTo: limit)      // fallback was short — give the slack back
        return out
    }

    /// Overlays classifier verdicts onto heuristic suggestions: for any file the classifier gave a
    /// usable home, that destination leads (heuristic candidates stay as alternates). Files without
    /// a verdict keep their heuristic suggestion untouched — so a backend that declines never makes
    /// things worse than the keyword engine alone.
    public static func applyVerdicts(_ verdicts: [String: FilingVerdict], to suggestions: [FilingSuggestion],
                                     taxonomy: [FileNode], providerRoot: String,
                                     rejectedByFile: [String: Set<String>] = [:],
                                     contentBlind: Set<String> = [],
                                     routerShortlists: [String: [String]] = [:],
                                     satelliteHomes: [String: Set<String>] = [:],
                                     profile: Sync.FolderProfile? = nil,
                                     registry: PersonRegistry? = nil,
                                     pageSamples: [String: String] = [:],
                                     identity: PersonIdentityIndex? = nil,
                                     onVeto: ((PersonVetoRefusal) -> Void)? = nil) -> [FilingSuggestion] {
        // The early-out belongs HERE as well as in the overload, because the taxonomy walk below
        // happens on the way in. Deriving the folder set first and letting the other one return
        // early is a full recursive walk of the provider — tens of thousands of nodes on a real
        // account — to build a set nothing then reads. Not a rare path either: a machine without
        // Apple Intelligence gets `[:]` from the classifier on every single scan.
        guard !verdicts.isEmpty else { return suggestions }
        // Relative folder set for new-vs-existing marking — symlink-proof (see relativeFolderPaths).
        return applyVerdicts(verdicts, to: suggestions,
                             existingRelative: Set(relativeFolderPaths(of: taxonomy, limit: .max)),
                             providerRoot: providerRoot, rejectedByFile: rejectedByFile,
                             contentBlind: contentBlind, routerShortlists: routerShortlists,
                             satelliteHomes: satelliteHomes,
                             profile: profile, registry: registry, pageSamples: pageSamples,
                             identity: identity, onVeto: onVeto)
    }

    /// The same overlay against an already-derived folder set, for callers that have one and no
    /// tree — the refine pass, which reasons against the taxonomy the scan cached rather than
    /// re-walking a provider that can be tens of thousands of nodes.
    ///
    /// `existingRelative` is what marks a destination's trailing segments new-vs-existing, so it
    /// must be the **uncapped** set: passing the capped list the classifier was given would label
    /// a real folder beyond the cap as one to create, and the apply path would then be asked to
    /// create a folder that already exists.
    ///
    /// `contentBlind` names the files the classifier was asked about **without the file's text**. A
    /// verdict for one of those must not demote a home the router derived from that very text: the
    /// model answered from strictly less information, and the confidence it reports is its own
    /// opinion of a guess. A visa foil went out as a bare filename and came back `High` for
    /// `Immigration/Form I-94/Abhishek`, which outranked the `Medium` the router had earned by
    /// reading `CHENNAI (MADRAS) … Visa Type/Class R H1B` off page 1.
    public static func applyVerdicts(_ verdicts: [String: FilingVerdict], to suggestions: [FilingSuggestion],
                                     existingRelative: Set<String>, providerRoot: String,
                                     rejectedByFile: [String: Set<String>] = [:],
                                     contentBlind: Set<String> = [],
                                     routerShortlists: [String: [String]] = [:],
                                     satelliteHomes: [String: Set<String>] = [:],
                                     profile: Sync.FolderProfile? = nil,
                                     registry: PersonRegistry? = nil,
                                     pageSamples: [String: String] = [:],
                                     identity: PersonIdentityIndex? = nil,
                                     onVeto: ((PersonVetoRefusal) -> Void)? = nil) -> [FilingSuggestion] {
        guard !verdicts.isEmpty else { return suggestions }
        return suggestions.map { s in
            if s.best?.remembered == true { return s }   // an explicit user rule outranks the model
            guard let v = verdicts[s.filePath],
                  let rawDest = destination(from: v, providerRoot: providerRoot,
                                            existingRelative: existingRelative, fileName: s.fileName)
            else { return s }
            if rejectedByFile[s.filePath]?.contains(rawDest.path) == true { return s }   // model re-picked a rejected folder
            // Strictly less information cannot override more. Not a confidence comparison — a
            // blind verdict at any confidence loses to a home that was read out of the document.
            if contentBlind.contains(s.filePath), s.best?.fromContent == true { return s }
            // **A backend that has not seen the document may not invent a folder for it.** Naming
            // an existing folder from a filename is a guess the user can check at a glance; naming
            // one that does not exist yet asks them to accept a new shape for their tree on the
            // same evidence. `DetailedBillApr2025.pdf` came back as a High-confidence
            // `Finance/US/Accounts/DetailedBillApr2025.pdf` — two folders to create, from seven
            // characters of filename, for a file whose siblings sit in an existing folder.
            if contentBlind.contains(s.filePath), !rawDest.newSegments.isEmpty { return s }
            // **The model re-ranks the router's shortlist; it does not get to answer past it.**
            //
            // It is handed that shortlist and told to copy a path from the list, so an existing
            // folder that is not on it is not a re-ranking — it is a different answer, arrived at
            // by a backend whose confidence is not a comparable quantity. Measured the hard way:
            // the same visa foil, the same code, three scans in one afternoon returned
            // `Visa/US/H-1B Visa/2024-2026` (right), then
            // `Authorization/H-1B/2019-2022/Petition/Supporting Documents`, then
            // `Authorization/H-1B/2024-2026/Petition` — all three `.high`. The router's own margin,
            // by contrast, is calibrated: it is right 92.9% of the time when it reports high.
            //
            // So the arbitration is no longer confidence against confidence. A verdict inside the
            // shortlist reorders a set the router already vouched for, and leads on the rule below.
            // One outside it stays as an alternate, and the router's home — the measured signal —
            // keeps the card. Gated on there BEING a shortlist: with no artifacts loaded the router
            // never ran, there is nothing to re-rank against, and the model is the only answer
            // there is. A proposed NEW folder is exempt for the same reason — it cannot be on a
            // list of folders that exist — and is governed by the two rules above instead.
            if let shortlist = routerShortlists[s.filePath], !shortlist.isEmpty,
               rawDest.newSegments.isEmpty, s.best != nil,
               !shortlist.contains(Self.relative(rawDest.path, under: providerRoot)) {
                return s
            }
            // **The model may re-rank the shortlist, but not past a folder's own copy stash.**
            //
            // The router already demotes a satellite below its home (see ``SatelliteFolders``), so
            // the shortlist handed over has the home first — and a verdict naming the satellite is
            // inside the shortlist, which is exactly the case the rule above lets through. Measured
            // on the reported case: asked where `Payslip_2026-06-15.pdf` belonged, the backend
            // answered `…/Petition/Supporting Documents/pay_statements` at High confidence, four
            // copies of January and February payslips whose originals are the ten files in
            // `Work/HPE/Compensation/Salary Statements/2026`.
            //
            // Stated once here rather than by pre-filtering the shortlist, because the shortlist is
            // also what the model is *shown*, and a satellite is a perfectly good answer when its
            // home is not on the table — a document really can belong in a petition packet.
            //
            // Asked of the suggestion's OWN candidates rather than of `routerShortlists`, and that
            // is load-bearing rather than tidy: the refine pass ranks its own shortlists and does
            // not pass them here at all, so a rule keyed on them would be silently off on the one
            // pass that reaches the cloud model — the pass that produced the wrong answer this was
            // written for. The candidates are on both paths by construction.
            if let homes = satelliteHomes[Self.relative(rawDest.path, under: providerRoot)] {
                let onTheCard = Set(s.candidates.map { Self.relative($0.path, under: providerRoot) })
                if !homes.isDisjoint(with: onTheCard) { return s }
            }
            // **A backend that has not read the document cannot report high confidence.** It saw a
            // filename; that is a `.low` claim however sure the model says it is, and the badge on
            // the card is what the user reads before accepting a home. Four of one real inbox's
            // PDFs extract zero characters — they are scans with no text layer — and every one came
            // back `.high`.
            let dest = contentBlind.contains(s.filePath) && rawDest.confidence != .low
                ? rawDest.withConfidence(.low)
                : rawDest
            // **A document that names a person does not go in a different person's folder.**
            //
            // Opus, asked where `Aditi OCI.pdf` belonged, answered
            // `Immigration/OCI/Divit/Application` — the wrong child, in the wrong person's folder,
            // while `Immigration/OCI/Aditi` exists, holds `Aditi - eOCI.pdf`, and is what the
            // router ranked first. Of every error this arc produced, filing one family member's
            // document into another's is the one worth a hard rule: it is the least likely to be
            // noticed and the most annoying to undo.
            //
            // Asked of the profile's PERSON AXIS, not of the words in the path. Measured over the
            // 756 corpus documents whose filename names a known person, the gold folder's
            // `axes.person` is a different person for **3** of them (0.40%) — all one baby-shower
            // folder under `Family/Aditi/Events`. Testing the path text instead would fire on 15,
            // because `Health/Medical/Travel/Girish - 2021` reads as Girish's folder while the
            // profile correctly records it as a trip with no person axis at all.
            //
            // Resolved through the ``PersonRegistry`` when there is one, and the difference is
            // what the registry exists for. The token comparison below it reads `Mom -
            // passport.pdf` against a folder whose axis says `muktha` as a CONTRADICTION — the
            // veto fired against the correct folder, because the flattened token set knew both
            // words but not that they are one person. The registry also matches names as phrases,
            // so `Aditi Abhishek - OCI.pdf` names Aditi alone rather than Aditi-and-her-father.
            //
            // The filename outranks the page: a filename is the user's own label, a page-1
            // mention is testimony (a sponsor's affidavit prints the sponsor, not the applicant).
            // Only a file whose name names nobody consults the page it was read from — that is
            // what protects `Scan 2026-08-02.pdf`, which the filename-only rule never could.
            if let refusal = personVeto(fileName: s.fileName, destination: rawDest.path,
                                        providerRoot: providerRoot, profile: profile,
                                        registry: registry, identity: identity,
                                        pageSample: pageSamples[s.filePath]) {
                // Reported, not just refused. The veto's whole job is to make a wrong suggestion
                // not happen, so it working perfectly is indistinguishable from it not existing —
                // this is the only way the user ever learns it did something. A closure rather
                // than a returned tally: `applyVerdicts` is a pure map over suggestions and stays
                // one, and every existing caller keeps working without passing anything.
                //
                // `refusal` is nil-but-refused for the unresolvable-axis case, which is why the
                // rule returns an optional REFUSAL and a separate `refuses` answer — see the rule.
                if let reported = refusal.reported { onVeto?(reported) }
                return s
            }
            // A verdict only LEADS when it's at least as confident as the current best home.
            // Otherwise a low-confidence model guess would demote a strong filename/rule match —
            // and, because the promoted candidate is `fromAI`, drop the file out of the blind
            // "File recommended" batch. When the model is less sure than the heuristic, keep the
            // heuristic home untouched (its alternates already include what the model might pick).
            guard dest.confidence >= (s.best?.confidence ?? .low) else { return s }
            let others = s.candidates.filter { $0.path != dest.path }
            return s.replacingCandidates([dest] + others)
        }
    }

    /// **Every home on every card, through the cross-person rule — whatever proposed it.**
    ///
    /// The rule was reachable only from a backend verdict: `applyVerdicts` consulted it before
    /// promoting one, and "Try another" before accepting one. Both of those are the *model's*
    /// answers, and when the rule fires there it declines the model and restores the home the
    /// heuristics or the router had already put on the card — **which nothing had ever tested.**
    /// The router's own protection is a −3.0 score penalty, a preference, not a refusal.
    ///
    /// So on a machine with no Apple Intelligence — where the classifier returns `[:]`, every
    /// `applyVerdicts` short-circuits on the empty dictionary, and every card therefore shows a
    /// router or keyword home — the rule was reachable on no card at all. That is the default
    /// install, not a corner.
    ///
    /// **Measured on the household's own tree before it was written**, because a refusal that runs
    /// on every card can lose correct homes as easily as wrong ones. Taking the 821 distinctly-named
    /// corpus documents whose filename names exactly one person, staging each as a loose file and
    /// running the keyword engine against the real 3,013-folder taxonomy:
    ///
    /// | | cards |
    /// |---|---|
    /// | with a home at all | 821 |
    /// | whose LEADING home this refuses | 156 |
    /// | …where that home was the folder the user themselves had filed it in | **0** |
    /// | left with no surviving home | **0** |
    ///
    /// The refusals are the error the rule was written for, at scale: `Muktha Girish - 2015.pdf`
    /// and six more of Muktha's CVs led with `Family/Girish`, and eighteen of Abhishek's HDFC
    /// statements led there too — his father's folder, on the strength of the surname.
    ///
    /// One cost is worth stating rather than rounding to zero: three corpus documents *do* sit in a
    /// folder whose person axis contradicts their filename — `Shweta's Baby Shower.docx` and two
    /// siblings, under `Family/Aditi/Events/Baby Shower`, which is Aditi's folder and correctly so.
    /// Nothing suggested that folder for them in the measurement above, so no card actually lost it;
    /// a tree with more folders like it would pay 0.4% of person-named cards for the 19% it protects.
    ///
    /// **A home the user taught is exempt**, matching `applyVerdicts`' own first line. `remembered`
    /// marks both a learned rule and an automation the user wrote, and either is an instruction
    /// rather than a guess — an automation whose destination resolves `{person}` through this very
    /// registry would otherwise be refused by it.
    ///
    /// Reported once per card, for the highest-ranked refusal: the card had one home the user would
    /// have seen, and a file whose every candidate is someone else's folder is one event, not four.
    public static func refusingCrossPersonHomes(
        _ suggestions: [FilingSuggestion], providerRoot: String,
        profile: Sync.FolderProfile?, registry: PersonRegistry?,
        identity: PersonIdentityIndex? = nil, pageSamples: [String: String] = [:],
        onVeto: ((PersonVetoRefusal) -> Void)? = nil
    ) -> [FilingSuggestion] {
        // No profile ⇒ no folder has a person axis ⇒ the rule cannot fire. Stated here as well as
        // inside `personVeto` so a scan on a tree that was never surveyed does no per-candidate work.
        guard profile != nil else { return suggestions }
        return suggestions.map { s in
            guard !s.candidates.isEmpty else { return s }
            var kept: [FilingDestination] = []
            var firstRefusal: PersonVeto?
            for c in s.candidates {
                if c.remembered { kept.append(c); continue }
                if let veto = personVeto(fileName: s.fileName, destination: c.path,
                                         providerRoot: providerRoot, profile: profile,
                                         registry: registry, identity: identity,
                                         pageSample: pageSamples[s.filePath]) {
                    if firstRefusal == nil { firstRefusal = veto }
                    continue
                }
                kept.append(c)
            }
            guard kept.count != s.candidates.count else { return s }
            if let reported = firstRefusal?.reported { onVeto?(reported) }
            return s.replacingCandidates(kept)
        }
    }

    /// The outcome of the cross-person rule: a refusal, carrying the report when there is one.
    ///
    /// Two shapes, because the protection has two: a registry-resolved contradiction knows both
    /// people by name and is worth telling the user about, while an axis value the registry cannot
    /// resolve falls back to token comparison and has no names to report. Both refuse.
    struct PersonVeto {
        let reported: PersonVetoRefusal?
    }

    /// **A document that names a person does not go in a different person's folder.**
    ///
    /// Opus, asked where `Aditi OCI.pdf` belonged, answered `Immigration/OCI/Divit/Application` —
    /// the wrong child, in the wrong person's folder, while `Immigration/OCI/Aditi` exists, holds
    /// `Aditi - eOCI.pdf`, and is what the router ranked first. Of every error this arc produced,
    /// filing one family member's document into another's is the one worth a hard rule: it is the
    /// least likely to be noticed and the most annoying to undo.
    ///
    /// Asked of the profile's PERSON AXIS, not of the words in the path. Measured over the 756
    /// corpus documents whose filename names a known person, the gold folder's `axes.person` is a
    /// different person for **3** of them (0.40%) — all one baby-shower folder under
    /// `Family/Aditi/Events`. Testing the path text instead would fire on 15, because
    /// `Health/Medical/Travel/Girish - 2021` reads as Girish's folder while the profile correctly
    /// records it as a trip with no person axis at all.
    ///
    /// Resolved through the ``PersonRegistry`` when there is one, and the difference is what the
    /// registry exists for. The token comparison below it reads `Mom - passport.pdf` against a
    /// folder whose axis says `muktha` as a CONTRADICTION — the veto fired against the correct
    /// folder, because the flattened token set knew both words but not that they are one person.
    /// The registry also matches names as phrases, so `Aditi Abhishek - OCI.pdf` names Aditi alone
    /// rather than Aditi-and-her-father.
    ///
    /// The filename outranks the page: a filename is the user's own label, a page-1 mention is
    /// testimony (a sponsor's affidavit prints the sponsor, not the applicant). Only a file whose
    /// name names nobody consults the page it was read from — that is what protects
    /// `Scan 2026-08-02.pdf`, which the filename-only rule never could.
    ///
    /// **A named member rather than a block inside `applyVerdicts`**, because it was one and the
    /// other paid path did not have it: "Try another" resolves its `.refine` verdict straight
    /// through `destination(from:)`, so a re-ask could file exactly the document this rule exists
    /// to protect into exactly the folder it exists to refuse. A rule that lives in one caller is
    /// a rule the next caller does not get.
    static func personVeto(fileName: String, destination: String, providerRoot: String,
                           profile: Sync.FolderProfile?, registry: PersonRegistry?,
                           identity: PersonIdentityIndex?, pageSample: String?) -> PersonVeto? {
        guard let profile,
              let destPersonRaw = Self.owningPerson(
                  of: Self.relative(destination, under: providerRoot), in: profile)
        else { return nil }
        if let registry, let destPerson = registry.person(forAxisValue: destPersonRaw) {
            // The precedence rule lives in `attribute` — shared with the `personIs` rule
            // condition, so the two cannot answer "whose document is this" differently.
            let named = registry.attribute(fileName: fileName, pageSample: pageSample,
                                           identity: identity)
            guard !named.isEmpty, !named.contains(destPerson) else { return nil }
            return PersonVeto(reported: PersonVetoRefusal(
                namedPerson: named.sorted().joined(separator: ", "),
                proposedPerson: destPerson, fileName: fileName,
                destination: Self.relative(destination, under: providerRoot)))
        }
        // An axis person the registry cannot resolve keeps the original protection.
        let filePeople = nameTokens(fileName).intersection(profile.personTokens)
        guard !filePeople.isEmpty, !filePeople.contains(destPersonRaw) else { return nil }
        return PersonVeto(reported: nil)
    }

    /// The person axis owning `relative` — its own, or the nearest ancestor's.
    ///
    /// **The walk is what makes the rule reach a folder that does not exist yet, which was every
    /// destination it most needed to refuse.** The lookup here was an exact one into
    /// `profile.folders`, and a profile describes the folders that DO exist — so a
    /// `proposesNewFolder: true` destination missed it and returned `nil`, skipping the veto
    /// entirely. `Immigration/OCI/Divit/Application` missed even while its parent sat in the
    /// profile carrying `axes.person = Divit`, which is exactly the answer the rule's own doc
    /// cites Opus giving for `Aditi OCI.pdf`.
    ///
    /// **Nearest ancestor, not outermost**, so a new folder under Aditi's own folder stays hers
    /// even though Divit's sits beside it under a shared parent. The most specific claim available
    /// is the one that describes the destination.
    ///
    /// **Measured against the real corpus before it was written, because widening a refusal risks
    /// refusing correct answers.** Over the household's own 11,829-document corpus, taking the 679
    /// whose filename names exactly one known person and asking whether the rule would fire against
    /// their GOLD folder — the placement the user themselves made, so any fire is a false one:
    ///
    ///     exact lookup     4 fires   0.59%
    ///     ancestor walk    4 fires   0.59%     zero new false vetoes
    ///
    /// The walk never reached past a folder's own axis to contradict a correct placement, because a
    /// document sitting in a person-less subfolder of a person's folder is that person's document.
    /// What it adds is protection for the 463 person-owned folders' unborn children, where there
    /// was none.
    static func owningPerson(of relative: String, in profile: Sync.FolderProfile) -> String? {
        var parts = relative.split(separator: "/").map(String.init)
        while !parts.isEmpty {
            if let person = profile.folders[parts.joined(separator: "/")]?.axes["person"]?.lowercased() {
                return person
            }
            parts.removeLast()
        }
        return nil
    }

    /// Whether a path segment is a file name rather than a folder name — 1–5 ASCII alphanumerics
    /// after a final dot. See ``destination(from:providerRoot:existingRelative:fileName:)``.
    static func looksLikeAFileName(_ segment: String) -> Bool {
        guard let dot = segment.lastIndex(of: "."), dot != segment.startIndex else { return false }
        let ext = segment[segment.index(after: dot)...]
        return (1...5).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// `path` expressed relative to `providerRoot`, or the path unchanged when it is not under it.
    /// Boundary-safe on "/" so a sibling sharing a string prefix isn't mistaken for a child.
    static func relative(_ path: String, under providerRoot: String) -> String {
        let root = providerRoot.hasSuffix("/") ? String(providerRoot.dropLast()) : providerRoot
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    /// Turns a verdict into an absolute destination, sanitizing the model's path (strip whitespace
    /// and slashes, drop any provider-root prefix it echoed back, reject empties, absolute escapes,
    /// and `..`/`.` traversal) and marking which trailing folders are new. nil ⇒ nothing usable.
    static func destination(from verdict: FilingVerdict, providerRoot: String,
                            existingRelative: Set<String>,
                            fileName: String = "") -> FilingDestination? {
        var rel = verdict.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip an echoed provider-root prefix only on a PATH-COMPONENT boundary, so a sibling that
        // merely shares a string prefix (root "/Users/x/Docs", verdict "/Users/x/DocsArchive/Foo")
        // isn't rewritten into a subfolder ("/Users/x/Docs/Archive/Foo") — a misfile.
        if rel == providerRoot {
            rel = ""
        } else if rel.hasPrefix(providerRoot + "/") {
            rel = String(rel.dropFirst(providerRoot.count))
        }
        rel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var segments = rel.split(separator: "/").map(String.init)
        guard !segments.isEmpty, !segments.contains(".."), !segments.contains(".") else { return nil }

        // **A folder is never the file itself, extension and all.** Models answer "where does this
        // go?" with the full path *including the file* often enough to matter, and the result is a
        // proposal to create a folder called `DetailedBillApr2025.pdf` and put
        // `DetailedBillApr2025.pdf` inside it — which the card renders as an ordinary destination.
        // Drop that segment and keep the parent, which is what the answer meant.
        //
        // Matched against the WHOLE file name, never its stem. `tesla.pdf` → `Vehicles/Tesla` is a
        // perfectly good new folder named for the vendor, and a stem test would quietly delete it;
        // that case is a shipped test, and it is what caught this the first time it was written too
        // broadly. A trailing segment carrying the file's own extension is the narrow case that is
        // never a folder.
        if !fileName.isEmpty, let last = segments.last,
           last.compare(fileName, options: .caseInsensitive) == .orderedSame {
            segments.removeLast()
        }
        // **And not any other file's name either.** The rule above matched only the incoming file,
        // which is the case that was in front of me; the general one is that a path segment
        // carrying a file extension is a file. Asked where `Divit - eOCI.pdf` goes, the model
        // answered `Immigration/OCI/Divit/eOCI.pdf` — the name of the PEER document already filed
        // there — and the apply path duly created a folder called `eOCI.pdf` and moved the file
        // into it. Trimming it lands on `Immigration/OCI/Divit`, which is where it belongs and
        // what the model was reaching for.
        //
        // Only ever applied to a segment that would be CREATED: a folder that already exists is
        // the user's, whatever it is called. And "carries an extension" is deliberately narrow —
        // a dot is not enough, or `U.S. Passport` and `Dr. Smith` would lose their last word. The
        // test is 1–5 ASCII alphanumerics after the final dot, which `pdf` and `jpeg` pass and no
        // real folder name in the surveyed tree does.
        if let last = segments.last, looksLikeAFileName(last),
           !existingRelative.contains(segments.joined(separator: "/")) {
            segments.removeLast()
        }
        guard !segments.isEmpty else { return nil }

        // Walk the relative path; any segment whose cumulative path isn't already a folder is new.
        var newSegments: [String] = []
        var cumulative = ""
        var creating = false
        for seg in segments {
            cumulative = cumulative.isEmpty ? seg : cumulative + "/" + seg
            if creating || !existingRelative.contains(cumulative) {
                creating = true
                newSegments.append(seg)
            }
        }
        // **An undeclared new folder is an invention, not a proposal.** Both schemas let a backend
        // answer with a folder that does not exist — that is how a genuinely new destination gets
        // offered — and it now has to SAY so. When it did not, a path that turns out not to exist is
        // a segment the model composed rather than chose, so the existing prefix is the answer and
        // the rest is dropped. `Immigration/OCI/Divit/eOCI.pdf` becomes `Immigration/OCI/Divit`.
        if !verdict.proposesNewFolder, !newSegments.isEmpty {
            segments.removeLast(newSegments.count)
            newSegments = []
            guard !segments.isEmpty else { return nil }
        }
        let abs = providerRoot + "/" + segments.joined(separator: "/")
        return FilingDestination(path: abs, confidence: verdict.confidence, reasons: [verdict.reason],
                                 newSegments: newSegments, fromContent: false, remembered: false, fromAI: true)
    }
}
