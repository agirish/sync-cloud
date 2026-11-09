import Foundation

// MARK: - Result model

/// How sure Filing is about a suggested home. `Codable` so a verdict survives in
/// ``FilingVerdictCache`` across launches, which persists the raw values: append new cases, never
/// rename existing ones.
public enum FilingConfidence: String, Codable, Sendable, Equatable, Comparable {
    case low, medium, high

    /// The ordering `Comparable` is built on: **exhaustive, with no `default:` and no final
    /// `else`**, so appending a case is a build error here. A fallback arm would rank a new case as
    /// `.low`, and every comparison built on it (the "File all confident" batch gate, the sort that
    /// puts surer answers first) would read it as the least sure.
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
    /// "Insurance"]). Empty when the whole path exists.
    public let newSegments: [String]
    /// True when the deciding signal came from the file's contents, not its name. Such homes are
    /// kept out of the blind "File recommended" batch: a word read from a document is less
    /// checkable than a filename, and that batch moves files nobody has looked at. The confidence
    /// cap is narrower: it binds the heuristic path (``Evidence/content``), not the router's
    /// measured margin (``Evidence/measuredContent``), so `.high` with `fromContent` is normal for
    /// router homes.
    public let fromContent: Bool
    /// True when this destination came from a remembered rule the user taught. Ranked ahead of
    /// heuristic matches of equal confidence: an explicit correction outranks a guess.
    public let remembered: Bool
    /// True when an intelligent backend (on-device LLM or cloud) chose this destination by
    /// reasoning about the taxonomy and the file's contents, rather than keyword overlap.
    public let fromAI: Bool
    /// For a content match, the evidence word read from the file that decided this home
    /// (display-ready, e.g. "Invoice"); nil for a filename match. Lets the card show content
    /// evidence as a highlight chip, distinct from a plain name match.
    public let evidenceToken: String?
    /// How many files already in the destination share the matched signal: neighbour corroboration
    /// for a content match ("N similar files already in the target"). 0 when unknown or none.
    public let neighborMatches: Int
    /// What the file would be **called** once it lands here, when this folder names its files by a
    /// convention and the file's name yields its date: `04. Apr 2025.pdf` for a
    /// `DetailedBillApr2025.pdf` heading into a `NN. Mon YYYY` folder. nil means it keeps its name.
    /// On the destination, not the suggestion, because the name is the folder's to decide: after
    /// "Try another" a name stored one level up would still say `04. Apr 2025.pdf` in a folder that
    /// numbers nothing.
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

    /// Where a destination's deciding evidence came from: the input to
    /// ``init(path:base:evidence:reasons:newSegments:remembered:evidenceToken:neighborMatches:proposedName:)``,
    /// the one construction path that applies the content-derived confidence cap.
    public enum Evidence: Sendable, Equatable {
        /// The filename, metadata, or an existing folder's own name. The claim stands as made.
        case name
        /// Read from the file's contents by keyword overlap (a taxonomy hit, a remembered or
        /// automation rule, a universal rule). Capped at `.medium`: a common word in a document is
        /// weaker than a filename. `fromContent` also keeps it out of the blind batch.
        case content
        /// Read from the file's contents but priced by the router's calibrated margin, the one
        /// content-derived signal whose confidence is measured, not claimed (right about 93% of the
        /// time when it reports high), so the cap doesn't apply. Still `fromContent`, so never in
        /// the blind batch.
        case measuredContent
    }

    /// The one place the content-derived confidence cap lives. Every heuristic construction site
    /// (taxonomy match, remembered rule, automation, universal rule, router home) builds its
    /// confidence here rather than spelling `min(base, .medium)` for itself.
    ///
    /// The deliberate exception is the `fromAI` site,
    /// `FilingEngine.destination(from:providerRoot:existingRelative:fileName:)` (a code span: it is
    /// internal and this is public, so a link wouldn't resolve). A backend's verdict keeps the
    /// confidence it claimed, and the `fromAI` flag, not a demotion, keeps it out of the blind
    /// batch.
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

    /// This folder named twice: one candidate carrying both claims. The higher-confidence candidate
    /// wins (a tie keeps `self`, the earlier one) and its claim stands: confidence, new segments,
    /// evidence token, neighbour count, proposed name. Reasons union, so both stories survive.
    ///
    /// Provenance merges two ways, on purpose:
    /// - `remembered` and `fromAI` merge by OR: "the user taught this" and "a model chose this" stay
    ///   true of the merged candidate.
    /// - `fromContent` follows the winner, not OR. It names the deciding signal, and the confidence
    ///   kept is the winner's; OR would pair the winner's `.high` with the loser's flag (a state the
    ///   capped construction path refuses to build) and let a weak content match on the same folder
    ///   push a legitimate filename home out of the blind batch. Pinned by
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

    /// A copy of this destination with its final folder renamed, for a new folder the user edits
    /// before accepting it. Only meaningful when ``isNew``: renaming an existing folder would name
    /// a different folder and quietly propose creating it, so a destination that creates nothing
    /// returns itself.
    public func renamingNewFolder(to name: String) -> FilingDestination {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // **The shared predicate, not a second list.** `validateItemName` is shared by the engine
        // and the UI prompts and covers `:` (Finder maps it to `/`, so the folder made wouldn't be
        // the one shown) and NUL. A hand-maintained list here would drift from it.
        guard !newSegments.isEmpty, FileSyncManager.validateItemName(trimmed) == nil else {
            return self
        }
        let parent = (path as NSString).deletingLastPathComponent
        return FilingDestination(path: parent + "/" + trimmed, confidence: confidence,
                                 reasons: reasons, newSegments: newSegments.dropLast() + [trimmed],
                                 fromContent: fromContent, remembered: remembered, fromAI: fromAI,
                                 evidenceToken: evidenceToken, neighborMatches: neighborMatches,
                                 proposedName: proposedName)
    }

    /// A copy of this destination at a different confidence, for capping a claim its evidence can't
    /// support (see
    /// ``FilingEngine/applyVerdicts(_:to:existingRelative:providerRoot:rejectedByFile:contentBlind:routerShortlists:)``).
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
    /// Absolute path of the loose file: its identity.
    public let id: String
    public var filePath: String { id }
    public let fileName: String
    public let size: Int
    public let modificationDate: Date?
    /// Ranked destinations, best first. Empty when nothing confident fits ("no confident home").
    public let candidates: [FilingDestination]
    /// Absolute path of the provider root this file lives under, when known, so the UI can render
    /// the breadcrumb provider-relative ("iCloud › Documents › …") instead of leaking the
    /// `/Users/<you>` prefix. nil means the UI tilde-abbreviates.
    public let providerRoot: String?
    /// Provider-relative folders that already hold **this same document**, by content: the PDF text
    /// fingerprint where there is one, else the byte hash. Empty is the ordinary case and the
    /// default.
    public let alreadyFiledAt: [String]
    /// The file as the scan found it, read through the same `ItemIdentity.snapshot` the move
    /// re-reads it with. By the time a card is applied, minutes later, something else may sit at
    /// the path (a re-download, an edited copy saved over it), so `performFiling` refuses a file
    /// whose identity has drifted rather than move a stranger into a folder chosen for the
    /// original. nil means no check, for a suggestion built by hand.
    public let sourceIdentity: ItemIdentity?

    public var best: FilingDestination? { candidates.first }
    /// Whether this document is already somewhere in the tree.
    public var isAlreadyFiled: Bool { !alreadyFiledAt.isEmpty }
    /// The rename the card offers alongside the move, or nil when the best home doesn't name its
    /// files by a convention this pass can read.
    public var proposedName: String? { best?.proposedName }
    public var hasConfidentHome: Bool { (best?.confidence ?? .low) >= .medium }
    /// Eligible for the blind "File recommended" batch: a `.high` home derived from the filename
    /// (not content, not the LLM). Content and AI homes still get a per-file "File here" but aren't
    /// auto-filed: a less verifiable signal shouldn't move files unseen, and the on-device model
    /// can be confidently wrong.
    ///
    /// **A document the tree already holds is never in the blind batch.** The user couldn't review
    /// a second copy they didn't know was one: it lands under its own name in a folder that fits,
    /// and nothing marks it as a duplicate.
    ///
    /// **High only.** Medium is where a one-shared-word match sits (`Health/Medical/India` for a
    /// FedEx invoice on "india"); measured on filed documents, Medium is right 57% of the time and
    /// High 85%, and only High is safe to move unseen.
    public var isBatchEligible: Bool {
        best?.confidence == .high && best?.fromContent == false && best?.fromAI == false && !isAlreadyFiled
    }

    public init(filePath: String, fileName: String, size: Int, modificationDate: Date?,
                candidates: [FilingDestination], providerRoot: String? = nil,
                alreadyFiledAt: [String] = [], sourceIdentity: ItemIdentity? = nil) {
        self.id = filePath
        self.fileName = fileName
        self.size = size
        self.modificationDate = modificationDate
        self.candidates = candidates
        self.providerRoot = providerRoot
        self.alreadyFiledAt = alreadyFiledAt
        self.sourceIdentity = sourceIdentity
    }

    /// A copy of this suggestion carrying the folders that already hold the same document.
    public func alreadyFiled(at folders: [String]) -> FilingSuggestion {
        FilingSuggestion(filePath: filePath, fileName: fileName, size: size,
                         modificationDate: modificationDate, candidates: candidates,
                         providerRoot: providerRoot, alreadyFiledAt: folders,
                         sourceIdentity: sourceIdentity)
    }

    /// A copy of this suggestion recording what the scan found at its path.
    public func recordingSource(_ identity: ItemIdentity?) -> FilingSuggestion {
        FilingSuggestion(filePath: filePath, fileName: fileName, size: size,
                         modificationDate: modificationDate, candidates: candidates,
                         providerRoot: providerRoot, alreadyFiledAt: alreadyFiledAt,
                         sourceIdentity: identity)
    }

    /// The same document with a **new list of homes**, and everything else intact. The one way to
    /// re-answer a suggestion: a verdict promotion, a route, a re-ask and a rename all go through
    /// it. Rebuilding member by member drops `alreadyFiledAt`, which matters after
    /// `markingAlreadyFiled` has run (a refine's `applyVerdicts`, "Try another"'s
    /// `replaceFilingSuggestion`): the card would lose the one warning that stops a second copy
    /// being filed, which moving the file back can't undo. A rebuild that wants to drop the marker
    /// must say so.
    public func replacingCandidates(_ candidates: [FilingDestination]) -> FilingSuggestion {
        FilingSuggestion(filePath: filePath, fileName: fileName, size: size,
                         modificationDate: modificationDate, candidates: candidates,
                         providerRoot: providerRoot, alreadyFiledAt: alreadyFiledAt,
                         sourceIdentity: sourceIdentity)
    }
}

public struct FilingOptions: Sendable {
    public var maxCandidates: Int
    public var minFileSize: Int
    public var ignoredNames: Set<String>
    /// Whether the provider's volume distinguishes `Inbox` from `inbox`, used to decide that a
    /// candidate is the file's own parent (`PathBoundary.namesSameDirectory`). Defaults to false,
    /// the macOS default and the safe direction: over-matching only withholds a move to where the
    /// file already is, while under-matching would offer one whose apply renames the file in place.
    /// (`generateUniqueURL`'s like-named parameter defaults the other way, for the opposite
    /// reason.)
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

/// Suggests where loose files belong within one provider, from on-device signals only: filenames,
/// extensions, file dates, the user's own folders (learned taxonomy) and a few universal rules.
/// Pure and deterministic: no content reading, no network.
public enum FilingEngine {

    /// - Parameters:
    ///   - looseFiles: The files to find homes for (the direct files of the picked folder).
    ///   - taxonomy: The provider's folder tree, used to learn where things go and which folders
    ///     exist, so new sub-paths are proposed under them, never invented from nothing.
    ///   - providerRoot: Absolute path of the provider root, the only place a brand-new top-level
    ///     folder (e.g. "Photos") may be proposed.
    ///   - options: Tuning.
    /// - Returns: One suggestion per loose file, in input order.
    /// - Parameter contentTokens: Optional per-file tokens from the file's contents (PDF text, OCR),
    ///   merged with the filename tokens so a file whose name says nothing can still find a home.
    ///   Empty for the filename-only pass.
    /// - Parameter automations: The user's automation rules, a correction's remembered rule among
    ///   them (`rememberAutomationRule`). An enabled, runnable one that matches steers the
    ///   suggestion, ranking ahead of the heuristics (capped to medium when the match needed the
    ///   file's content).
    /// - Parameter providerName: Resolves `{provider}` in an automation's destination template.
    /// - Parameter automationSnippets: Per-file lowercased excerpts for files a content-reading
    ///   automation could match: the same text the Automations preview evaluates, so a rule gives one
    ///   answer on both surfaces.
    /// - Parameter now: Injectable clock for the automations' date conditions and `{year}` tokens.
    /// - Parameter rejectedByFile: Per-file absolute folder paths the user rejected, dropped from that
    ///   file's candidates so a "no, not there" is never re-suggested.
    public static func suggest(
        looseFiles: [FileNode],
        taxonomy: [FileNode],
        providerRoot: String,
        contentTokens: [String: Set<String>] = [:],
        automations: [AutomationRule] = [],
        /// The household, so a `personIs` rule and a `{person}` destination can resolve. nil means
        /// person rules never match.
        registry: PersonRegistry? = nil,
        identity: PersonIdentityIndex? = nil,
        providerName: String? = nil,
        automationSnippets: [String: String] = [:],
        now: Date = Date(),
        rejectedByFile: [String: Set<String>] = [:],
        rejectedWords: [String: Set<String>] = [:],
        options: FilingOptions = .init()
    ) -> [FilingSuggestion] {
        suggest(looseFiles: looseFiles,
                learned: learnTaxonomy(taxonomy, providerRoot: providerRoot, options: options),
                providerRoot: providerRoot, contentTokens: contentTokens,
                automations: automations, registry: registry, identity: identity,
                providerName: providerName, automationSnippets: automationSnippets, now: now,
                rejectedByFile: rejectedByFile, rejectedWords: rejectedWords, options: options)
    }

    /// What
    /// ``suggest(looseFiles:taxonomy:providerRoot:contentTokens:automations:registry:identity:providerName:automationSnippets:now:rejectedByFile:rejectedWords:options:)``
    /// learns from the taxonomy before it looks at a file: every folder's profile, and the set of
    /// folders that exist. Learned once per scan, not per call: it tokenizes every folder and file
    /// name in the tree (thousands), a scan suggests twice, and nothing in it depends on the loose
    /// files.
    public struct LearnedTaxonomy: Sendable {
        let profiles: [FolderProfile]
        let existingPaths: Set<String>
    }

    /// Learns `taxonomy`, for
    /// ``suggest(looseFiles:learned:providerRoot:contentTokens:automations:registry:identity:providerName:automationSnippets:now:rejectedByFile:rejectedWords:options:)``.
    /// Only `options.ignoredNames` is read, so it must be the options the suggestions use.
    public static func learnTaxonomy(_ taxonomy: [FileNode], providerRoot: String,
                                     options: FilingOptions) -> LearnedTaxonomy {
        var profiles: [FolderProfile] = []
        var existingPaths: Set<String> = [providerRoot]
        for node in taxonomy {
            collectProfiles(node, ancestorTokens: [], into: &profiles, paths: &existingPaths, options: options)
        }
        return LearnedTaxonomy(profiles: profiles, existingPaths: existingPaths)
    }

    /// ``suggest(looseFiles:taxonomy:providerRoot:contentTokens:automations:registry:identity:providerName:automationSnippets:now:rejectedByFile:rejectedWords:options:)``
    /// against a taxonomy already learned; see ``LearnedTaxonomy``.
    public static func suggest(
        looseFiles: [FileNode],
        learned: LearnedTaxonomy,
        providerRoot: String,
        contentTokens: [String: Set<String>] = [:],
        automations: [AutomationRule] = [],
        registry: PersonRegistry? = nil,
        identity: PersonIdentityIndex? = nil,
        providerName: String? = nil,
        automationSnippets: [String: String] = [:],
        now: Date = Date(),
        rejectedByFile: [String: Set<String>] = [:],
        rejectedWords: [String: Set<String>] = [:],
        options: FilingOptions = .init()
    ) -> [FilingSuggestion] {
        let profiles = learned.profiles
        let existingPaths = learned.existingPaths
        // Folders that already file by year (a parent of some `…/2024`), once per scan.
        let filesByYear = Set(existingPaths.compactMap { path -> String? in
            isYear((path as NSString).lastPathComponent) ? (path as NSString).deletingLastPathComponent : nil
        })
        // Which rules may act doesn't depend on the file, so it is decided once per scan. A rule
        // taught for another survey's tree is inert here, as an absolute one is.
        let actingAutomations = AutomationRuleSet.eligible(automations).narrowed { $0.acts(in: providerRoot) }

        return looseFiles.compactMap { file -> FilingSuggestion? in
            guard !file.isDirectory else { return nil }
            guard !options.ignoredNames.contains(file.name) else { return nil }
            guard (file.fileSize ?? 0) >= options.minFileSize else { return nil }

            let nameToks = fileTokens(file.name)
            let content = contentTokens[file.id] ?? []
            let tokens = nameToks.union(content)
            let ext = (file.name as NSString).pathExtension.lowercased()
            // The year segment of rule destinations (Receipts/<year>, Taxes/<year>): a single
            // plausible year in the filename names the document's own year and beats the
            // modification date, so a 2023 tax form downloaded in 2024 goes to Taxes/2023. Zero or
            // several filename years (a "2021-2022" range) fall back to mtime.
            let year = filenameYear(in: nameToks) ?? yearString(file.modificationDate)

            var candidates: [FilingDestination] = []
            candidates += automationCandidates(automations: actingAutomations, file: file,
                                               contentTokens: content,
                                               snippet: automationSnippets[file.id],
                                               providerRoot: providerRoot, providerName: providerName,
                                               existingPaths: existingPaths, now: now,
                                               registry: registry, identity: identity)
            candidates += taxonomyCandidates(tokens: tokens, nameTokens: nameToks, contentTokens: content,
                                             profiles: profiles, rejectedWords: rejectedWords,
                                             words: wordGroups(file.name))
            candidates += ruleCandidates(tokens: tokens, nameTokens: nameToks, contentTokens: content,
                                         nameLower: file.name.lowercased(), ext: ext, year: year,
                                         profiles: profiles, existingPaths: existingPaths,
                                         filesByYear: filesByYear, providerRoot: providerRoot)

            // A file already in a suggested folder shouldn't be told to move to where it is.
            // Case-folded on a case-insensitive volume, where a differently cased destination names
            // the same folder and its apply would rename the file in place.
            let selfParent = (file.id as NSString).deletingLastPathComponent
            candidates.removeAll {
                PathBoundary.namesSameDirectory($0.path, selfParent, caseSensitive: options.caseSensitiveVolume)
            }

            // Drop rejected folders from the full pool before ranking and capping: removing after
            // the cap could strip the top pick and leave fewer homes, or none, though a good one
            // sat past the cap.
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
        /// For each content token, how many files directly inside carry it: the count behind "N
        /// similar files already in the target".
        let contentTokenFileCounts: [String: Int]
    }

    private static func collectProfiles(
        _ node: FileNode, ancestorTokens: Set<String>,
        into profiles: inout [FolderProfile], paths: inout Set<String>, options: FilingOptions
    ) {
        // A package (`Budget 2025.numbers`) is a document, so neither it nor anything inside is a
        // home. `performFiling` refuses one as a destination whatever route named it.
        guard node.isDirectory, !node.isPackage, !options.ignoredNames.contains(node.name) else { return }
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
    /// `rejectedWords` maps a folder's absolute path to words the user said are no reason for it; a
    /// match on that folder resting on those words alone is not offered.
    private static func taxonomyCandidates(tokens: Set<String>, nameTokens: Set<String>,
                                           contentTokens: Set<String>, profiles: [FolderProfile],
                                           rejectedWords: [String: Set<String>] = [:],
                                           words: [Set<String>] = []) -> [FilingDestination] {
        guard !tokens.isEmpty else { return [] }
        var out: [FilingDestination] = []
        for p in profiles {
            let nameHits = tokens.intersection(p.nameTokens)
            let contentHits = tokens.intersection(p.contentTokens).subtracting(nameHits)
            // A bare year names which same-year folder, not what category, so a year alone must
            // never make a `.high`, batch-eligible home (or the blind batch would move
            // "2024-tax-return.pdf" into whichever `…/2024` sorts first). Only non-year hits carry
            // category strength; the year still shows in the reason.
            let categoryNameHits = nameHits.filter { !isYear($0) }
            let categoryContentHits = contentHits.filter { !isYear($0) }
            let score = categoryNameHits.count * 3 + categoryContentHits.count
            guard score >= 3 else { continue }   // a real folder-name hit, or ≥3 content hits
            let hitSet = nameHits.union(contentHits)
            let hits = hitSet.sorted().prefix(3).joined(separator: ", ")
            // Content-derived when the deciding non-year tokens aren't in the filename, so a year
            // shared by filename and folder can't make a content match look name-derived (and
            // batch-eligible). A token in both name and content counts as from the name.
            let categoryHits = categoryNameHits.union(categoryContentHits)
            if let refused = rejectedWords[p.path], categoryHits.isSubset(of: refused) { continue }
            let fromContent = categoryHits.isDisjoint(with: nameTokens) && !categoryHits.isDisjoint(with: contentTokens)
            // **One shared word is a lead, not a home.** A single folder-name word with nothing
            // else in common would lead `Duplicate Files Report - Sep 2026.md` to an immigration
            // folder on "sep". High needs the folder's name and a second word shared with it or its
            // files; one word stays Medium, where the survey and Refine can displace it. Counted in
            // the file's own words: "FedEx" tokenizes to `fed` and `ex`, still one word.
            let wordsHit = words.filter { !$0.isDisjoint(with: categoryHits) }.count
                + categoryHits.subtracting(words.reduce(into: Set<String>()) { $0.formUnion($1) }).count
            let base: FilingConfidence = !categoryNameHits.isEmpty && wordsHit >= 2 ? .high : .medium
            if fromContent {
                // Show the single strongest evidence word (preferring a sibling-content hit, which
                // has a neighbour count) and how many files in the target share it.
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

    // MARK: Automation rules (steering)

    /// Destinations from the user's automations. An enabled, runnable automation whose conditions
    /// hold steers the suggestion: user-written, so high confidence,
    /// capped to medium when the match needed the file's content (which also keeps it out of the
    /// blind batch). A rule whose destination resolves outside this provider is inert here. Takes
    /// the already-narrowed ``AutomationRuleSet``, since eligibility doesn't depend on the file.
    private static func automationCandidates(
        automations: AutomationRuleSet, file: FileNode, contentTokens: Set<String>, snippet: String?,
        providerRoot: String, providerName: String?, existingPaths: Set<String>, now: Date,
        registry: PersonRegistry?, identity: PersonIdentityIndex?
    ) -> [FilingDestination] {
        guard !automations.isEmpty else { return [] }
        let facts = automationFacts(for: file, contentTokens: contentTokens, snippet: snippet,
                                    registry: registry, identity: identity)
        // The same facts without content: a rule that matches only with content is a
        // content-derived signal (medium, "read from the file", no blind batch).
        var nameOnlyFacts = facts
        nameOnlyFacts.contentTokens = []
        nameOnlyFacts.snippet = nil

        var out: [FilingDestination] = []
        for rule in automations.rules {
            guard AutomationEvaluator.matches(rule, facts, now: now) else { continue }
            guard let placed = ruleDestination(rule, facts: facts, providerRoot: providerRoot,
                                               providerName: providerName, now: now,
                                               children: { parent in childNames(of: parent, providerRoot: providerRoot, existingPaths: existingPaths) })
            else { continue }
            let destination = placed.path
            let fromContent = ruleMatchIsContentDerived(rule, facts: facts, nameOnlyFacts: nameOnlyFacts, now: now)
            let label = rule.name.trimmingCharacters(in: .whitespaces)
            let shown = label.isEmpty ? rule.summary : label
            let reason = placed.needsPage
                ? "Your rule “\(shown)” files this here; " + (facts.snippet == nil ? "read the file for its month" : "its first page names no date")
                : fromContent
                ? "Your rule “\(shown)” files this here (read from the file)"
                : "Your rule “\(shown)” files this here"
            out.append(FilingDestination(
                path: destination,
                // user-written ⇒ high, capped like any content signal; a folder short of the month
                // page 1 would name is a start, not the answer.
                base: placed.needsPage ? .medium : .high, evidence: fromContent ? .content : .name,
                reasons: [reason],
                newSegments: missingSegments(of: destination, existingPaths: existingPaths),
                remembered: true))
        }
        return out
    }

    /// Where a matched rule files this file, absolute, inside `providerRoot`; nil when it resolves
    /// nowhere there. A `{travel-month}` segment takes the spelling of a month folder already
    /// there. When page 1 wasn't read, or names no date, it files into the part before that token,
    /// flagged `needsPage`: Travel/Trips/IN-US for a cloud-only ticket, until Download and Read
    /// finds the month.
    public static func ruleDestination(_ rule: AutomationRule, facts: AutomationFileFacts, providerRoot: String,
                                       providerName: String?, now: Date,
                                       children: (String) -> [String]) -> (path: String, needsPage: Bool)? {
        var template = rule.destinationTemplate
        var needsPage = false
        var resolution = AutomationEvaluator.resolveDestination(template, for: facts, providerName: providerName, now: now)
        if case .unresolved(let token) = resolution,
           token == AutomationTravelDate.yearToken || token == AutomationTravelDate.monthToken {
            let segments = template.split(separator: "/").map(String.init)
            guard let first = segments.firstIndex(where: AutomationTravelDate.isUsed(in:)), first > 0 else { return nil }
            template = segments[..<first].joined(separator: "/")
            needsPage = true
            resolution = AutomationEvaluator.resolveDestination(template, for: facts, providerName: providerName, now: now)
        }
        guard case .resolved(var resolved) = resolution else { return nil }
        if !needsPage, !resolved.hasPrefix("/") {
            resolved = AutomationTravelDate.adoptingExistingMonth(resolved, template: template, children: children)
        }
        guard let path = AutomationEvaluator.absoluteDestination(resolved, providerRoot: providerRoot) else { return nil }
        return (path, needsPage)
    }

    /// A folder's subfolder names from the walked tree, `parent` relative to the root.
    static func childNames(of parent: String, providerRoot: String, existingPaths: Set<String>) -> [String] {
        let base = parent.isEmpty ? providerRoot : providerRoot + "/" + parent
        return existingPaths.compactMap { path in
            guard path.hasPrefix(base + "/") else { return nil }
            let rest = path.dropFirst(base.count + 1)
            return rest.contains("/") ? nil : String(rest)
        }
    }

    /// The evaluator facts for a loose file in an Organize scan, shared with the manager's
    /// content-gating pass so both build identical inputs. `snippet`, when present, also supplies
    /// the content tokens, tokenized as the Automations preview tokenizes its excerpt: one rule,
    /// one answer on both surfaces.
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
            // Lowercased here, the one choke point on the scan path: the facts contract says
            // "already lowercased", the scan hands over raw extractor text, and `contentContains`
            // compares against a lowercased needle, so "Invoice" would never match "invoice".
            // `nameTokens` lowercases internally, so the derived tokens don't change.
            snippet: snippet?.lowercased(),
            contentTokens: snippet.map { nameTokens($0) } ?? contentTokens)
            .attributing(registry, identity: identity)
    }

    /// Whether a matched rule's evidence is content-derived, which caps it to medium and keeps it
    /// out of the blind batch. For the learned single-`mentionsAll` shape this is the legacy
    /// remembered rules' exact test (content-derived only when no trigger word is in the filename),
    /// so a migrated rule keeps its batch behaviour; any other rule is content-derived whenever it
    /// wouldn't match on name and metadata alone.
    private static func ruleMatchIsContentDerived(
        _ rule: AutomationRule, facts: AutomationFileFacts, nameOnlyFacts: AutomationFileFacts, now: Date
    ) -> Bool {
        if rule.conditions.count == 1, case .mentionsAll(let tokens) = rule.conditions[0] {
            let trigger = Set(tokens.map { $0.lowercased() }.filter { !$0.isEmpty })
            return trigger.isDisjoint(with: facts.nameTokens) && !trigger.isDisjoint(with: facts.contentTokens)
        }
        return !AutomationEvaluator.matches(rule, nameOnlyFacts, now: now)
    }

    /// The trailing segments of an absolute path that don't exist yet (created on apply); empty
    /// when the whole path exists. Lets a remembered folder deleted since be re-proposed as new
    /// rather than silently failing.
    static func missingSegments(of path: String, existingPaths: Set<String>) -> [String] {
        if existingPaths.contains(path) { return [] }
        var current = ""
        var segments: [(prefix: String, seg: String)] = []
        for seg in path.split(separator: "/") {
            current += "/" + seg
            segments.append((current, String(seg)))
        }
        // The missing tail is everything after the longest prefix that exists. `existingPaths`
        // holds the provider root and its walked folders, never the root's own ancestors
        // ("/Users"), so latching at the first missing prefix would mark the whole path new.
        let lastExisting = segments.lastIndex { existingPaths.contains($0.prefix) }
        let missingStart = lastExisting.map { $0 + 1 } ?? 0
        return segments[missingStart...].map { $0.seg }
    }

    // MARK: Universal rules

    private static func ruleCandidates(
        tokens: Set<String>, nameTokens: Set<String>, contentTokens: Set<String>, nameLower: String,
        ext: String, year: String?, profiles: [FolderProfile], existingPaths: Set<String>,
        filesByYear: Set<String> = [], providerRoot: String
    ) -> [FilingDestination] {
        var out: [FilingDestination] = []
        // **"Filed by year" is a claim about the tree, so the tree has to make it.** These rules
        // name a `<year>` folder under the receipts or taxes folder; where that folder already
        // keeps years the claim stands, and where it doesn't (a `Purchases` sorted by country and
        // vendor) it is a proposal for a new shape, at Medium.
        func byYear(_ anchor: String, _ base: FilingConfidence) -> FilingConfidence {
            filesByYear.contains(anchor) ? base : min(base, .medium)
        }
        // A signal is "from content" when none of its tokens are in the filename. Such matches are
        // capped to medium and get a "(read from the file)" note, which also keeps them out of the
        // blind batch.
        func rule(_ anchor: String, _ segs: [String], _ base: FilingConfidence, _ reason: String, signal: Set<String>) {
            let fc = signal.isDisjoint(with: nameTokens) && !signal.isDisjoint(with: contentTokens)
            out.append(under(anchor, segs, existingPaths, base: base,
                             evidence: fc ? .content : .name,
                             reason + (fc ? " (read from the file)" : "")))
        }

        // Photos → <Photos folder>/<year>, or a proposed Photos/<year> at the root (extension-based).
        if photoExtensions.contains(ext), let year {
            if let photos = existingFolder(named: ["photos", "pictures", "images", "camera roll"], in: profiles) {
                rule(photos, [year], byYear(photos, .high), "Photo — filed by capture year", signal: [])
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
                rule(receipts, [year], byYear(receipts, .high), "Receipt or invoice — filed by year", signal: receiptSig)
            } else if let finance = existingFolder(named: ["finance", "documents", "financial"], in: profiles) {
                rule(finance, ["Receipts", year], .medium, "Receipt or invoice — suggested Receipts/\(year)", signal: receiptSig)
            }
        }

        // Tax documents → <Taxes>/<year> or <Finance|Documents>/Taxes/<year>. Form numbers like
        // 1099/1040 are bare digits, stripped from filename tokens, so the raw name is sniffed too;
        // found there, the match is a name signal.
        let taxSig = tokens.intersection(taxTokens)
        let taxFromName = nameLower.contains("1099") || nameLower.contains("1040")
        if !taxSig.isEmpty || taxFromName, let year {
            let taxSignal: Set<String> = taxFromName ? [] : taxSig
            if let taxes = existingFolder(named: ["taxes", "tax"], in: profiles) {
                rule(taxes, [year], byYear(taxes, .high), "Tax document — filed by year", signal: taxSignal)
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

    /// Builds a destination under an existing anchor folder, appending segments and marking which
    /// are new.
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
            // The merge rules live on `FilingDestination.merging`.
            byPath[c.path] = byPath[c.path]?.merging(c) ?? c
        }
        return byPath.values.sorted { a, b in
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            if a.remembered != b.remembered { return a.remembered }      // a correction you taught outranks a guess
            if a.isNew != b.isNew { return !a.isNew }                    // prefer existing folders
            if a.newSegments.count != b.newSegments.count { return a.newSegments.count < b.newSegments.count }
            // Among equally good matches, prefer the shallower, more general folder, so a generic
            // document lands in top-level /Insurance, not a nested namesake like /Health/Insurance.
            let da = a.path.split(separator: "/").count, db = b.path.split(separator: "/").count
            if da != db { return da < db }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }.prefix(limit).map { $0 }
    }

    // MARK: Tokenization

    /// Tokens from a filename, extension stripped. Camera-sequence stems (IMG_2023, DSC_1995, PXL
    /// 0421, GOPR0042) drop their year-shaped digits: the number is a shot counter, and keeping it
    /// would file IMG_2023.jpg shot in 2026 into Photos/2023 at high confidence. Applied to the raw
    /// stem, because the tokens can't tell IMG_2023 from a real "2023" ("img" is a stopword). The
    /// one shared entry point for filename tokens, so the heuristic year, the automations' `{year}`
    /// and `mentionsAll` matching agree.
    public static func fileTokens(_ fileName: String) -> Set<String> {
        let stem = (fileName as NSString).deletingPathExtension
        let tokens = nameTokens(stem)
        guard isCameraSequenceStem(stem) else { return tokens }
        return tokens.filter { !isYear($0) }
    }

    /// Whether a raw filename stem is a camera or phone sequence name: a known device prefix plus a
    /// 3–6 digit shot counter and nothing else. "Wedding 2023" is not one: its year is real. GoPro
    /// prefixes are pinned to the exact shapes the cameras write (GOPR + 4-digit file number, or
    /// GP/GH/GX/GS + 2-digit chapter + 4-digit number, no separator), so a hand-named
    /// "gopro_hawaii_2023.mp4" keeps its real year.
    static func isCameraSequenceStem(_ stem: String) -> Bool {
        stem.range(of: #"^(?:(?:img|dsc|dscn|dscf|dcim|pxl|mvimg)[_ -]?\d{3,6}|gopr\d{4}|(?:gp|gh|gx|gs)\d{6})$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The union of every category vocabulary: the keywords a content extractor should surface from
    /// a document (insurers, vendors, banks, tax terms, vehicle brands) so the rules fire.
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

    /// The single plausible year named by the filename's tokens, or nil. Plausible narrows
    /// ``isYear``'s 1900–2099 span to 1990 through next year: old scans and pre-dated statements
    /// are real, "2098" is not a filing year. Exactly one such token is required; several
    /// ("FY2021-2022 report") name no single year. `now` is injectable for tests.
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

    /// Whether a rule can be learned from this filename at all: true when the name yields at least
    /// one salient (non-year) token. A name that says nothing ("scan0012.pdf") can't seed a rule,
    /// so the UI shouldn't offer to remember it.
    public static func canRemember(fileName: String) -> Bool {
        fileTokens(fileName).contains { !isYear($0) }
    }

    /// The filename's salient (non-year) tokens, sorted: the signature a rejection is remembered
    /// by,
    /// so it generalizes to files with the same distinctive words.
    public static func salientTokens(ofFileNamed fileName: String) -> [String] {
        fileTokens(fileName).filter { !isYear($0) }.sorted()
    }

    /// The file name's words, each as the tokens it yields, so a camelCase word split in two
    /// (`FedEx` → `fed`, `ex`) still counts as one word.
    static func wordGroups(_ fileName: String) -> [Set<String>] {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map { nameTokens(String($0)) }.filter { $0.count > 1 }
    }

    /// The non-year words a file's name shares with a folder's path below `providerRoot`: what a
    /// keyword match on that folder rests on, and so what rejecting it teaches. Tokenized as
    /// ``taxonomyCandidates`` tokenizes, so the recorded words are the ones it compares.
    public static func sharedNameWords(fileName: String, folderPath: String,
                                       providerRoot: String) -> Set<String> {
        let relative = PathBoundary.relativize(folderPath, under: providerRoot) ?? folderPath
        let folderWords = relative.split(separator: "/")
            .reduce(into: Set<String>()) { $0.formUnion(nameTokens(String($1))) }
        return Set(salientTokens(ofFileNamed: fileName)).intersection(folderWords)
    }

    /// Builds a remembered rule from a correction: the file the user just filed and where they put
    /// it. The trigger prefers the distinctive anchor, tokens the filename shares with the
    /// destination's folder names ("tesla" in `…/Tesla/Insurance`), so the rule generalizes without
    /// keying on incidental words. Falls back to the file's salient tokens; nil when nothing usable
    /// remains.
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
    // 1099/1040 are useful as content tokens (the filename path also sniffs them raw, since the
    // tokenizer strips bare numbers). "return" is left out: too ambiguous in body text.
    static let taxTokens: Set<String> = ["tax", "taxes", "1099", "1040", "irs"]
    static let statementTokens: Set<String> = ["statement", "bank", "chase", "amex", "visa", "mastercard", "wells", "fargo"]

    // MARK: Intelligent classification (overlay)

    /// Folder paths relative to the provider root: the taxonomy handed to a classifier. Built from
    /// node names, not by stripping the root, so symlink prefixes like /var vs /private/var can't
    /// differ. Shallowest first, capped so a huge tree can't overflow the model's context.
    public static func relativeFolderPaths(of taxonomy: [FileNode], limit: Int = 250) -> [String] {
        shallowestFirst(unorderedRelativeFolderPaths(of: taxonomy)) {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.prefix(limit).map { $0 }
    }

    /// Every folder ``relativeFolderPaths(of:limit:)`` lists, unlimited, as a set and without the
    /// sort: `localizedStandardCompare` on every comparison would dominate the cost on a large
    /// tree.
    public static func relativeFolderPathSet(of taxonomy: [FileNode]) -> Set<String> {
        Set(unorderedRelativeFolderPaths(of: taxonomy))
    }

    private static func unorderedRelativeFolderPaths(of taxonomy: [FileNode]) -> [String] {
        var out: [String] = []
        func walk(_ node: FileNode, prefix: String) {
            // Not a package, nor anything inside one: never offered to a classifier, and a model
            // that names one anyway gets it treated as a file-like segment, not an existing folder.
            guard node.isDirectory, !node.isPackage else { return }
            let rel = prefix.isEmpty ? node.name : prefix + "/" + node.name
            out.append(rel)
            for child in node.children ?? [] { walk(child, prefix: rel) }
        }
        for node in taxonomy { walk(node, prefix: "") }
        return out
    }

    /// `paths` shallowest first, ties broken by `inOrder`: the order of the folder list above and
    /// of a survey's reading plan. Each path's depth is counted once, not per comparison, which
    /// would split every path again on each compare (hundreds of milliseconds on the main thread
    /// for a large plan). The order must stay byte-identical: a resumed document survey compares
    /// the plan it saved with the one it plans now.
    static func shallowestFirst(_ paths: [String],
                                then inOrder: (String, String) -> Bool) -> [String] {
        paths.map { ($0, $0.split(separator: "/").count) }
            .sorted { a, b in a.1 != b.1 ? a.1 < b.1 : inOrder(a.0, b.0) }
            .map(\.0)
    }

    /// The folder menu a classifier may answer with: the folders the router already finds
    /// plausible, then the shallow structural list to fill the rest.
    ///
    /// **The cap is a token budget, not a preference for shallow folders.** Spent by depth alone,
    /// it cuts a large tree at depth 3, so a document whose home is a deep leaf is never in the
    /// prompt, and the model confidently picks the best of the wrong folders it was shown.
    ///
    /// `reservedForFallback` keeps room for the shallow skeleton so the model still sees the tree's
    /// shape: deep leaves alone read as unrelated paths, and "propose a new subfolder under an
    /// existing parent" needs parents in view. Budget the fallback doesn't use goes back to
    /// `preferred`.
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

    /// Overlays classifier verdicts onto heuristic suggestions: where the classifier gave a usable
    /// home, it leads and the heuristic candidates stay as alternates. Files without a verdict keep
    /// their heuristic suggestion, so a declining backend never does worse than the keyword engine.
    public static func applyVerdicts(_ verdicts: [String: FilingVerdict], to suggestions: [FilingSuggestion],
                                     taxonomy: [FileNode], providerRoot: String,
                                     nameProvider: CloudProvider.ProviderType? = nil,
                                     rejectedByFile: [String: Set<String>] = [:],
                                     contentBlind: Set<String> = [],
                                     routerShortlists: [String: [String]] = [:],
                                     satelliteHomes: [String: Set<String>] = [:],
                                     profile: Sync.FolderProfile? = nil,
                                     registry: PersonRegistry? = nil,
                                     pageSamples: [String: String] = [:],
                                     identity: PersonIdentityIndex? = nil,
                                     onVeto: ((PersonVetoRefusal) -> Void)? = nil) -> [FilingSuggestion] {
        // The early-out belongs here as well as in the overload, because the taxonomy walk below
        // happens on the way in: a full recursive walk of the provider to build a set nothing
        // reads. Common: a Mac without Apple Intelligence gets `[:]` from the classifier on every
        // scan.
        guard !verdicts.isEmpty else { return suggestions }
        // Relative folder set for new-vs-existing marking, symlink-proof (see relativeFolderPaths).
        return applyVerdicts(verdicts, to: suggestions,
                             existingRelative: relativeFolderPathSet(of: taxonomy),
                             providerRoot: providerRoot, nameProvider: nameProvider,
                             rejectedByFile: rejectedByFile,
                             contentBlind: contentBlind, routerShortlists: routerShortlists,
                             satelliteHomes: satelliteHomes,
                             profile: profile, registry: registry, pageSamples: pageSamples,
                             identity: identity, onVeto: onVeto)
    }

    /// Which of the files handed to the classifier were judged **without their text**: the set
    /// every `contentBlind` rule in `applyVerdicts` asks about.
    ///
    /// **"We read it and got nothing", never "we didn't read."** A scan with reading off, or on a
    /// Mac with no extractor, hands every file over by name; penalising the model for that would
    /// leave those installs with no intelligent suggestions and tell the user nothing true.
    /// Blindness is a fact about the document (a scan with no text layer), so it is asserted only
    /// when there was a reader. A cache hit follows the same rule: the key records the file, not
    /// what was read.
    ///
    /// One expression, called from both the scan (`FileSyncManager+Filing`) and the refine pass
    /// (`FileSyncManager+FilingRefine`), so the two can't drift and the derivation is testable.
    public static func contentBlindFiles(handedOver: [String], read: Set<String>,
                                         hadReader: Bool) -> Set<String> {
        guard hadReader else { return [] }
        return Set(handedOver).subtracting(read)
    }

    /// The same overlay against an already-derived folder set, for callers with one and no tree:
    /// the refine pass reasons against the taxonomy the scan cached instead of re-walking the
    /// provider. `existingRelative` marks segments new or existing, so it must be the **uncapped**
    /// set: the capped list the classifier saw would label a real folder past the cap as one to
    /// create. `contentBlind` names files the classifier saw **without their text**; a verdict for
    /// one must not demote a home the router read out of that text, since the model answered from
    /// strictly less.
    public static func applyVerdicts(_ verdicts: [String: FilingVerdict], to suggestions: [FilingSuggestion],
                                     existingRelative: Set<String>, providerRoot: String,
                                     nameProvider: CloudProvider.ProviderType? = nil,
                                     rejectedByFile: [String: Set<String>] = [:],
                                     contentBlind: Set<String> = [],
                                     routerShortlists: [String: [String]] = [:],
                                     shortlistVerdictsLead: Bool = false,
                                     answersPastShortlistKept: Bool = false,
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
                                            existingRelative: existingRelative, fileName: s.fileName,
                                            nameProvider: nameProvider)
            else { return s }
            if rejectedByFile[s.filePath]?.contains(rawDest.path) == true { return s }   // model re-picked a rejected folder
            // Strictly less information can't override more. Not a confidence comparison: a blind
            // verdict at any confidence loses to a home read out of the document.
            if contentBlind.contains(s.filePath), s.best?.fromContent == true { return s }
            // **A backend that hasn't seen the document may not invent a folder for it.** Naming an
            // existing folder from a filename is a guess the user can check at a glance; naming a
            // new one asks them to accept a new shape for their tree on the same thin evidence.
            if contentBlind.contains(s.filePath), !rawDest.newSegments.isEmpty { return s }
            // **The model re-ranks the router's shortlist; it doesn't get to answer past it.** It
            // is told to copy a path from that list, so an existing folder not on it is a different
            // answer from a backend whose confidence isn't comparable (the same document can come
            // back `.high` for three different folders on three scans). The router's margin is
            // calibrated: right about 93% of the time when it reports high. So a verdict inside the
            // shortlist reorders a set the router vouched for, and leads by the rule below. One
            // outside is dropped, except Claude's on Refine (`answersPastShortlistKept`): a paid
            // answer, so it goes on through the rules below and then either leads over a weak home
            // or sits second on the card (`pastShortlist`). Only when there is a shortlist: with no artifacts loaded the
            // router never ran and the model is the only answer. A proposed new folder can't be on
            // a list of existing folders, so it is governed by the two rules above instead.
            var pastShortlist = false
            if let shortlist = routerShortlists[s.filePath], !shortlist.isEmpty,
               rawDest.newSegments.isEmpty, s.best != nil,
               !shortlist.contains(Self.relative(rawDest.path, under: providerRoot)) {
                guard answersPastShortlistKept else { return s }
                pastShortlist = true
            }
            // **The model may re-rank the shortlist, but not past a folder's own copy stash.** The
            // router demotes a satellite below its home (``SatelliteFolders``), so a verdict naming
            // the satellite is inside the shortlist and the rule above lets it through; a payslip
            // would land among a petition packet's copies instead of the salary folder holding the
            // originals.
            //
            // Checked here rather than by pre-filtering the shortlist, because the shortlist is
            // also what the model is shown, and a satellite is a good answer when its home isn't on
            // the table. Asked of the suggestion's own candidates, not `routerShortlists`, because
            // the candidates exist on every path, the refine pass included.
            if let homes = satelliteHomes[Self.relative(rawDest.path, under: providerRoot)] {
                let onTheCard = Set(s.candidates.map { Self.relative($0.path, under: providerRoot) })
                if !homes.isDisjoint(with: onTheCard) { return s }
            }
            // **A backend that hasn't read the document can't report high confidence.** It saw a
            // filename, a `.low` claim however sure the model says it is, and the card's badge is
            // what the user reads before accepting a home. Scans with no text layer are the usual
            // case.
            let dest = contentBlind.contains(s.filePath) && rawDest.confidence != .low
                ? rawDest.withConfidence(.low)
                : rawDest
            // **A document that names a person doesn't go in a different person's folder.** Filing
            // one family member's document into another's is the error least likely to be noticed
            // and most annoying to undo, so it gets a hard rule.
            //
            // Asked of the profile's person axis, not the words in the path: path text misreads a
            // folder like `Health/Medical/Travel/Elder - 2021`, which the profile records as a trip
            // with no person. Measured on the corpus, a filed document's own folder contradicts its
            // filename's person for well under 1% of documents.
            //
            // Resolved through the ``PersonRegistry`` when there is one. A flat token comparison
            // reads `Mom - passport.pdf` against a folder whose axis says `granny` as a
            // contradiction, since it doesn't know they are one person; the registry also matches
            // names as phrases, so `Daughter Father - OCI.pdf` names Daughter alone.
            //
            // The filename outranks the page: a filename is the user's own label, a page-1 mention
            // is testimony (a sponsor's affidavit prints the sponsor, not the applicant). Only a
            // file whose name names nobody consults its page, which is what protects `Scan
            // 2026-08-02.pdf`.
            if let refusal = personVeto(fileName: s.fileName, destination: rawDest.path,
                                        providerRoot: providerRoot, profile: profile,
                                        registry: registry, identity: identity,
                                        pageSample: pageSamples[s.filePath]) {
                // Reported, not just refused: a veto that works is otherwise indistinguishable from
                // one that doesn't exist. A closure rather than a returned tally, so
                // `applyVerdicts` stays a pure map and existing callers pass nothing.
                // `refusal.reported` is nil for the unresolvable-axis case, which still refuses;
                // see the rule.
                if let reported = refusal.reported { onVeto?(reported) }
                return s
            }
            // **Past the shortlist, a paid answer that read the page beats a weak home.** The
            // shortlist rule trusts the router because its High is calibrated; its Low is not a
            // claim worth defending. A file named `DIVIT110226IMMZNRECORD.pdf` gives the router
            // nothing, so its weak `Finance/US/Social Security/2026` (from "Age" on the page) kept
            // the card while Claude, having read the page, said `Health/Medical/Kaiser`. Anything
            // short of that (a medium or high home, a blind or low answer) keeps the card, and
            // the answer goes second, so Try Another Folder shows it next without asking again.
            if pastShortlist {
                if dest.path == s.best?.path { return s }   // agrees with the card: nothing to do
                let others = s.candidates.filter { $0.path != dest.path }
                guard !contentBlind.contains(s.filePath), dest.confidence >= .medium,
                      s.best?.confidence == .low else {
                    return s.replacingCandidates(Array(others.prefix(1)) + [dest] + others.dropFirst())
                }
                return s.replacingCandidates([dest] + others)
            }
            // A verdict leads only when it is at least as confident as the current best home.
            // Otherwise a low-confidence guess would demote a strong filename or rule match and,
            // being `fromAI`, drop the file from the blind batch. When the model is less sure, keep
            // the heuristic home (its alternates already include what the model might pick).
            //
            // **Except a paid answer the survey vouched for.** On Refine, a verdict naming one of
            // the router's shortlisted folders re-ranks homes the measured signal proposed, from
            // the backend the user chose to pay for; it shouldn't have to out-confide a keyword
            // engine's claimed High. It leads when it read the document and is at least Medium. A
            // taught home returned above.
            let vouched = shortlistVerdictsLead && !contentBlind.contains(s.filePath)
                && dest.confidence >= .medium
                && routerShortlists[s.filePath]?.contains(Self.relative(rawDest.path, under: providerRoot)) == true
            guard vouched || dest.confidence >= (s.best?.confidence ?? .low) else { return s }
            let others = s.candidates.filter { $0.path != dest.path }
            return s.replacingCandidates([dest] + others)
        }
    }

    /// **Every home on every card, through the cross-person rule, whatever proposed it.**
    /// `applyVerdicts` and "Try another" only check backend verdicts, and the router's own
    /// protection is a score penalty, a preference rather than a refusal. On a Mac without Apple
    /// Intelligence the classifier returns `[:]`, so without this sweep no card would ever pass the
    /// rule.
    ///
    /// Measured on a real tree before it was written, since a refusal on every card can lose
    /// correct homes too: among hundreds of documents whose filename names one person, it refused
    /// the leading home on about a fifth, never the folder the user had filed it in, and never left
    /// a card with no home. A tree with many folders like `Family/Daughter/Events/Baby Shower`
    /// (Daughter's folder, holding `Mother's Baby Shower.docx`) would pay a fraction of a percent
    /// of person-named cards.
    ///
    /// **A home the user taught is exempt**, as in `applyVerdicts`' first line: `remembered` marks
    /// a learned rule or an automation the user wrote, an instruction rather than a guess, and an
    /// automation resolving `{person}` through this registry would otherwise be refused by it.
    /// Reported once per card, for the highest-ranked refusal.
    ///
    /// **Known gap:** `attribution`'s last tier reads an identifier off the page through
    /// ``PersonIdentityIndex``, which is rebuilt from the tree as surveyed and takes no correction,
    /// so a document misfiled once teaches the wrong person's identifiers and this rule then
    /// refuses the right folder for later scans; here that can strip a router home. Kept so this
    /// sweep and `applyVerdicts` answer alike, and narrow (a page is consulted only when the name
    /// names nobody, identifiers only when the page names nobody). The fix belongs in the index.
    public static func refusingCrossPersonHomes(
        _ suggestions: [FilingSuggestion], providerRoot: String,
        profile: Sync.FolderProfile?, registry: PersonRegistry?,
        identity: PersonIdentityIndex? = nil, pageSamples: [String: String] = [:],
        onVeto: ((PersonVetoRefusal) -> Void)? = nil
    ) -> [FilingSuggestion] {
        // No profile means no folder has a person axis, so the rule can't fire. Checked here as
        // well as inside the veto so a scan on an unsurveyed tree does no per-candidate work.
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

    /// The outcome of the cross-person rule: a refusal, carrying the report when there is one. A
    /// registry-resolved contradiction knows both people by name and is worth telling the user; an
    /// axis value the registry can't resolve falls back to tokens and has no names to report. Both
    /// refuse.
    struct PersonVeto {
        let reported: PersonVetoRefusal?
    }

    /// **A document that names a person doesn't go in a different person's folder.** Filing one
    /// family member's document into another's is the error least likely to be noticed and most
    /// annoying to undo, so it gets a hard rule.
    ///
    /// Asked of the profile's person axis, not the words in the path, which would misread a folder
    /// like `Health/Medical/Travel/Elder - 2021` (a trip, with no person axis). Resolved through
    /// the ``PersonRegistry`` when there is one, so `Mom` and `granny` can be one person and
    /// `Daughter Father - OCI.pdf` names Daughter alone. The filename outranks the page: a filename
    /// is the user's own label, a page-1 mention is testimony (a sponsor's affidavit prints the
    /// sponsor). Only a file whose name names nobody consults its page, which protects `Scan
    /// 2026-08-02.pdf`.
    ///
    /// A named member, not a block inside `applyVerdicts`, so every paid path gets it: "Try
    /// another" resolves its `.refine` verdict straight through `destination(from:)`.
    static func personVeto(fileName: String, destination: String, providerRoot: String,
                           profile: Sync.FolderProfile?, registry: PersonRegistry?,
                           identity: PersonIdentityIndex?, pageSample: String?) -> PersonVeto? {
        guard let profile,
              let destPersonRaw = Self.owningPerson(
                  of: Self.relative(destination, under: providerRoot), in: profile)
        else { return nil }
        if let registry, let destPerson = registry.person(forAxisValue: destPersonRaw) {
            // The precedence rule lives in `attribute`, shared with the `personIs` rule condition,
            // so the two can't answer "whose document is this" differently.
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

    /// The person axis owning `relative`: its own, or the nearest ancestor's. The walk lets the
    /// rule reach a folder that doesn't exist yet: a profile describes only existing folders, so an
    /// exact lookup would skip the veto for every `proposesNewFolder` destination, such as a new
    /// `Immigration/OCI/Son/Application` for `Daughter OCI.pdf`.
    ///
    /// **Nearest ancestor, not outermost**, so a new folder under Daughter's own folder stays hers
    /// even when Son's sits beside it under a shared parent. Measured on the corpus against each
    /// document's own folder, the walk adds no false vetoes over the exact lookup: a document in a
    /// person-less subfolder of a person's folder is that person's.
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

    /// Whether a path segment is a file name rather than a folder name: 1–5 ASCII alphanumerics
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
    /// and slashes, drop an echoed provider-root prefix, reject empties, absolute escapes and
    /// `..`/`.` traversal) and marking which trailing folders are new. nil means nothing usable.
    /// `nameProvider` is the ruleset a new folder's name is held to, the destination provider's as
    /// the scan's risky-name pass uses it; nil applies `validateItemName` alone.
    static func destination(from verdict: FilingVerdict, providerRoot: String,
                            existingRelative: Set<String>,
                            fileName: String = "",
                            nameProvider: CloudProvider.ProviderType? = nil) -> FilingDestination? {
        var rel = verdict.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip an echoed provider-root prefix only on a path-component boundary, so a sibling
        // sharing a string prefix (root "/Users/x/Docs", verdict "/Users/x/DocsArchive/Foo") isn't
        // rewritten into a subfolder ("/Users/x/Docs/Archive/Foo"), a misfile.
        if rel == providerRoot {
            rel = ""
        } else if rel.hasPrefix(providerRoot + "/") {
            rel = String(rel.dropFirst(providerRoot.count))
        }
        rel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var segments = rel.split(separator: "/").map(String.init)
        guard !segments.isEmpty, !segments.contains(".."), !segments.contains(".") else { return nil }

        // **A folder is never the file itself, extension and all.** Models often answer with the
        // full path including the file, which would propose a folder called
        // `DetailedBillApr2025.pdf` holding that file. Drop the segment and keep the parent.
        // Matched against the whole file name, never its stem: `tesla.pdf` → `Vehicles/Tesla` is a
        // good new folder named for the vendor, and a shipped test pins it.
        if !fileName.isEmpty, let last = segments.last,
           last.compare(fileName, options: .caseInsensitive) == .orderedSame {
            segments.removeLast()
        }
        // **Nor any other file's name.** A segment carrying a file extension is a file: a model
        // naming a peer already filed there (`Immigration/OCI/Son/eOCI.pdf` for `Son - eOCI.pdf`)
        // would create a folder called `eOCI.pdf`. Trimmed, it lands on `Immigration/OCI/Son`. Only
        // for a segment that would be created (an existing folder is the user's, whatever its
        // name), and narrow: 1–5 ASCII alphanumerics after the final dot, so `U.S. Passport` and
        // `Dr. Smith` keep their last word.
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
        // **An undeclared new folder is an invention, not a proposal.** A backend must say
        // `proposesNewFolder` to offer a folder that doesn't exist; otherwise the missing segments
        // are ones it composed, so the existing prefix is the answer and the rest is dropped.
        if !verdict.proposesNewFolder, !newSegments.isEmpty {
            segments.removeLast(newSegments.count)
            newSegments = []
            guard !segments.isEmpty else { return nil }
        }
        // **A folder the model names into being must be a name the folder can have.** Each segment
        // this would create is held to `validateItemName` (as a user-typed "Create as" is) and to
        // the destination provider's rules: `Taxes: 2025` shows in Finder as `Taxes/ 2025`, and
        // `Acme Inc.` won't sync on Dropbox or OneDrive, leaving the document local-only under a
        // success banner. The candidate is dropped, not repaired: a sanitized name is a folder
        // nobody proposed, and the card still offers "Choose a folder…".
        for seg in newSegments {
            if FileSyncManager.validateItemName(seg) != nil { return nil }
            if let nameProvider, ProviderNameRules.violation(name: seg, provider: nameProvider) != nil {
                return nil
            }
        }
        let abs = providerRoot + "/" + segments.joined(separator: "/")
        return FilingDestination(path: abs, confidence: verdict.confidence, reasons: [verdict.reason],
                                 newSegments: newSegments, fromContent: false, remembered: false, fromAI: true)
    }
}
