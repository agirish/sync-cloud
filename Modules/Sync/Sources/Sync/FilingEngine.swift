import Foundation

// MARK: - Result model

/// How sure Filing is about a suggested home.
public enum FilingConfidence: String, Sendable, Equatable, Comparable {
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

    public var isNew: Bool { !newSegments.isEmpty }

    public init(path: String, confidence: FilingConfidence, reasons: [String], newSegments: [String], fromContent: Bool = false, remembered: Bool = false, fromAI: Bool = false, evidenceToken: String? = nil, neighborMatches: Int = 0) {
        self.id = path
        self.confidence = confidence
        self.reasons = reasons
        self.newSegments = newSegments
        self.fromContent = fromContent
        self.remembered = remembered
        self.fromAI = fromAI
        self.evidenceToken = evidenceToken
        self.neighborMatches = neighborMatches
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

    public var best: FilingDestination? { candidates.first }
    public var hasConfidentHome: Bool { (best?.confidence ?? .low) >= .medium }
    /// Eligible for the blind "File recommended" batch: a confident home derived from the filename
    /// (not content, not the LLM). Content-derived and AI homes still show a per-file "File here"
    /// but aren't auto-filed — a weaker/less-verifiable signal shouldn't move files unseen (the
    /// on-device model can be confidently wrong).
    public var isBatchEligible: Bool {
        hasConfidentHome && best?.fromContent == false && best?.fromAI == false
    }

    public init(filePath: String, fileName: String, size: Int, modificationDate: Date?, candidates: [FilingDestination], providerRoot: String? = nil) {
        self.id = filePath
        self.fileName = fileName
        self.size = size
        self.modificationDate = modificationDate
        self.candidates = candidates
        self.providerRoot = providerRoot
    }
}

public struct FilingOptions: Sendable {
    public var maxCandidates: Int
    public var minFileSize: Int
    public var ignoredNames: Set<String>

    public init(maxCandidates: Int = 3, minFileSize: Int = 0,
                ignoredNames: Set<String> = FilingOptions.defaultIgnoredNames) {
        self.maxCandidates = maxCandidates
        self.minFileSize = minFileSize
        self.ignoredNames = ignoredNames
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
    /// - Parameter rejectedByFile: Per-file absolute folder paths the user has rejected — dropped
    ///   from that file's candidates so a "no, not there" is never re-suggested.
    public static func suggest(
        looseFiles: [FileNode],
        taxonomy: [FileNode],
        providerRoot: String,
        contentTokens: [String: Set<String>] = [:],
        rules: [FilingRule] = [],
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
            let year = yearString(file.modificationDate)

            var candidates: [FilingDestination] = []
            candidates += rememberedCandidates(rules: rules, tokens: tokens, nameTokens: nameToks,
                                               contentTokens: content, existingPaths: existingPaths)
            candidates += taxonomyCandidates(tokens: tokens, nameTokens: nameToks, contentTokens: content, profiles: profiles)
            candidates += ruleCandidates(tokens: tokens, nameTokens: nameToks, contentTokens: content,
                                         nameLower: file.name.lowercased(), ext: ext, year: year,
                                         profiles: profiles, existingPaths: existingPaths, providerRoot: providerRoot)

            // A file already sitting in a suggested folder shouldn't be told to move to where it is.
            let selfParent = (file.id as NSString).deletingLastPathComponent
            candidates.removeAll { $0.path == selfParent }

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
            let score = nameHits.count * 3 + contentHits.count
            guard score >= 3 else { continue }   // a folder-name hit, or ≥3 content hits
            let hitSet = nameHits.union(contentHits)
            let hits = hitSet.sorted().prefix(3).joined(separator: ", ")
            // Content-derived when the deciding tokens are NOT in the filename (compare to the real
            // filename tokens, so a token in BOTH name and content counts as from the name).
            let fromContent = hitSet.isDisjoint(with: nameTokens) && !hitSet.isDisjoint(with: contentTokens)
            let base: FilingConfidence = !nameHits.isEmpty ? .high : .medium
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

    /// Tokens from a filename (extension stripped).
    public static func fileTokens(_ fileName: String) -> Set<String> {
        nameTokens((fileName as NSString).deletingPathExtension)
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

    /// Overlays classifier verdicts onto heuristic suggestions: for any file the classifier gave a
    /// usable home, that destination leads (heuristic candidates stay as alternates). Files without
    /// a verdict keep their heuristic suggestion untouched — so a backend that declines never makes
    /// things worse than the keyword engine alone.
    public static func applyVerdicts(_ verdicts: [String: FilingVerdict], to suggestions: [FilingSuggestion],
                                     taxonomy: [FileNode], providerRoot: String,
                                     rejectedByFile: [String: Set<String>] = [:]) -> [FilingSuggestion] {
        guard !verdicts.isEmpty else { return suggestions }
        // Relative folder set for new-vs-existing marking — symlink-proof (see relativeFolderPaths).
        let existingRelative = Set(relativeFolderPaths(of: taxonomy, limit: .max))
        return suggestions.map { s in
            if s.best?.remembered == true { return s }   // an explicit user rule outranks the model
            guard let v = verdicts[s.filePath],
                  let dest = destination(from: v, providerRoot: providerRoot, existingRelative: existingRelative)
            else { return s }
            if rejectedByFile[s.filePath]?.contains(dest.path) == true { return s }   // model re-picked a rejected folder
            // A verdict only LEADS when it's at least as confident as the current best home.
            // Otherwise a low-confidence model guess would demote a strong filename/rule match —
            // and, because the promoted candidate is `fromAI`, drop the file out of the blind
            // "File recommended" batch. When the model is less sure than the heuristic, keep the
            // heuristic home untouched (its alternates already include what the model might pick).
            guard dest.confidence >= (s.best?.confidence ?? .low) else { return s }
            let others = s.candidates.filter { $0.path != dest.path }
            return FilingSuggestion(filePath: s.filePath, fileName: s.fileName, size: s.size,
                                    modificationDate: s.modificationDate, candidates: [dest] + others,
                                    providerRoot: s.providerRoot)
        }
    }

    /// Turns a verdict into an absolute destination, sanitizing the model's path (strip whitespace
    /// and slashes, drop any provider-root prefix it echoed back, reject empties, absolute escapes,
    /// and `..`/`.` traversal) and marking which trailing folders are new. nil ⇒ nothing usable.
    static func destination(from verdict: FilingVerdict, providerRoot: String,
                            existingRelative: Set<String>) -> FilingDestination? {
        var rel = verdict.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if rel.hasPrefix(providerRoot) { rel = String(rel.dropFirst(providerRoot.count)) }
        rel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = rel.split(separator: "/").map(String.init)
        guard !segments.isEmpty, !segments.contains(".."), !segments.contains(".") else { return nil }

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
        let abs = providerRoot + "/" + segments.joined(separator: "/")
        return FilingDestination(path: abs, confidence: verdict.confidence, reasons: [verdict.reason],
                                 newSegments: newSegments, fromContent: false, remembered: false, fromAI: true)
    }
}
