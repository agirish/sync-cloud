import Foundation

// MARK: - Result model

/// How sure Filing is about a suggested home.
///
/// `Codable` so a verdict survives in ``FilingVerdictCache`` across launches. The raw values are
/// therefore persisted — append new cases rather than renaming existing ones, exactly as
/// `LiquidGlassHue` does for the same reason.
public enum FilingConfidence: String, Codable, Sendable, Equatable, Comparable {
    case low, medium, high
    var rank: Int { self == .high ? 2 : (self == .medium ? 1 : 0) }
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
    /// matches are capped to medium confidence and excluded from the blind "File recommended"
    /// batch — reading a common word out of a document is a weaker signal than a filename.
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
    /// The one way to re-answer a suggestion, because there are four places that do it (a verdict
    /// promotion, a route, a re-ask, a rename re-naming) and every one of them was rebuilding the
    /// value member by member. Each therefore silently dropped `alreadyFiledAt`, which only
    /// `markingAlreadyFiled` produces and which runs once, at the end of the scan: refine a marked
    /// list, or press "Try another", and `isAlreadyFiled` flipped back to false. The card lost the
    /// one warning that stops a second copy being filed — and losing it is not undone by moving
    /// the file back, because the copy lands under a name of its own in a folder that fits.
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
            candidates += automationCandidates(automations: automations, file: file,
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
            let confidence = fromContent ? min(base, .medium) : base
            if fromContent {
                // Surface the single strongest evidence word (prefer a sibling-content hit, which
                // carries a neighbor count) plus how many files already in the target share it —
                // legible corroboration a plain name match can't offer.
                let evidenceRaw = contentHits.sorted().first ?? nameHits.sorted().first ?? hitSet.sorted().first ?? ""
                let neighbors = p.contentTokenFileCounts[evidenceRaw] ?? 0
                let reason = neighbors > 0
                    ? "Matched “\(evidenceRaw)” read from the file — \(neighbors) similar file\(neighbors == 1 ? "" : "s") already in the target"
                    : "Matched “\(evidenceRaw)” read from the file, in a folder you already keep"
                out.append(FilingDestination(path: p.path, confidence: confidence, reasons: [reason],
                                             newSegments: [], fromContent: true,
                                             evidenceToken: evidenceRaw.capitalized, neighborMatches: neighbors))
            } else {
                let reason = "Matches “\(hits)” in a folder you already keep"
                out.append(FilingDestination(path: p.path, confidence: confidence, reasons: [reason],
                                             newSegments: [], fromContent: false))
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
                confidence: fromContent ? .medium : .high,
                reasons: [reason],
                newSegments: missingSegments(of: rule.destinationPath, existingPaths: existingPaths),
                fromContent: fromContent, remembered: true))
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
    private static func automationCandidates(
        automations: [AutomationRule], file: FileNode, contentTokens: Set<String>, snippet: String?,
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
        for rule in automations where rule.enabled && rule.isRunnable {
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
                confidence: fromContent ? .medium : .high,
                reasons: [reason],
                newSegments: missingSegments(of: destination, existingPaths: existingPaths),
                fromContent: fromContent, remembered: true))
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
            out.append(under(anchor, segs, existingPaths,
                             fc ? min(base, .medium) : base,
                             reason + (fc ? " (read from the file)" : ""), fromContent: fc))
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
                             _ confidence: FilingConfidence, _ reason: String, fromContent: Bool = false) -> FilingDestination {
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
        return FilingDestination(path: path, confidence: confidence, reasons: [reason],
                                 newSegments: newSegments, fromContent: fromContent)
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
            if let existing = byPath[c.path] {
                let winner = c.confidence > existing.confidence ? c : existing
                byPath[c.path] = FilingDestination(path: c.path, confidence: winner.confidence,
                                                   reasons: Array(Set(existing.reasons + c.reasons)).sorted(),
                                                   newSegments: winner.newSegments, fromContent: winner.fromContent,
                                                   remembered: existing.remembered || c.remembered,
                                                   fromAI: existing.fromAI || c.fromAI,
                                                   evidenceToken: winner.evidenceToken, neighborMatches: winner.neighborMatches)
            } else {
                byPath[c.path] = c
            }
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
            if let profile,
               let destPersonRaw = profile.folders[Self.relative(rawDest.path, under: providerRoot)]?
                   .axes["person"]?.lowercased() {
                if let registry, let destPerson = registry.person(forAxisValue: destPersonRaw) {
                    // The precedence rule lives in `attribute` — shared with the `personIs` rule
                    // condition, so the two cannot answer "whose document is this" differently.
                    let named = registry.attribute(fileName: s.fileName,
                                                   pageSample: pageSamples[s.filePath],
                                                   identity: identity)
                    if !named.isEmpty, !named.contains(destPerson) {
                        // Reported, not just refused. The veto's whole job is to make a wrong
                        // suggestion not happen, so it working perfectly is indistinguishable from
                        // it not existing — this is the only way the user ever learns it did
                        // something. A closure rather than a returned tally: `applyVerdicts` is a
                        // pure map over suggestions and stays one, and every existing caller keeps
                        // working without passing anything.
                        onVeto?(PersonVetoRefusal(
                            namedPerson: named.sorted().joined(separator: ", "),
                            proposedPerson: destPerson, fileName: s.fileName,
                            destination: Self.relative(rawDest.path, under: providerRoot)))
                        return s
                    }
                } else {
                    // An axis person the registry cannot resolve keeps the original protection.
                    let filePeople = nameTokens(s.fileName).intersection(profile.personTokens)
                    if !filePeople.isEmpty, !filePeople.contains(destPersonRaw) { return s }
                }
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
