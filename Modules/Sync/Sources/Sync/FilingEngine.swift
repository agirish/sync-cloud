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

    public var isNew: Bool { !newSegments.isEmpty }

    public init(path: String, confidence: FilingConfidence, reasons: [String], newSegments: [String], fromContent: Bool = false, remembered: Bool = false) {
        self.id = path
        self.confidence = confidence
        self.reasons = reasons
        self.newSegments = newSegments
        self.fromContent = fromContent
        self.remembered = remembered
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

    public var best: FilingDestination? { candidates.first }
    public var hasConfidentHome: Bool { (best?.confidence ?? .low) >= .medium }
    /// Eligible for the blind "File recommended" batch: a confident home derived from the filename
    /// (not content). Content-derived homes still show a per-file "File here" but aren't auto-filed.
    public var isBatchEligible: Bool { hasConfidentHome && best?.fromContent == false }

    public init(filePath: String, fileName: String, size: Int, modificationDate: Date?, candidates: [FilingDestination]) {
        self.id = filePath
        self.fileName = fileName
        self.size = size
        self.modificationDate = modificationDate
        self.candidates = candidates
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
    public static func suggest(
        looseFiles: [FileNode],
        taxonomy: [FileNode],
        providerRoot: String,
        contentTokens: [String: Set<String>] = [:],
        rules: [FilingRule] = [],
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

            let ranked = rank(candidates, limit: options.maxCandidates)
            return FilingSuggestion(filePath: file.id, fileName: file.name,
                                    size: file.fileSize ?? 0, modificationDate: file.modificationDate,
                                    candidates: ranked)
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
    }

    private static func collectProfiles(
        _ node: FileNode, ancestorTokens: Set<String>,
        into profiles: inout [FolderProfile], paths: inout Set<String>, options: FilingOptions
    ) {
        guard node.isDirectory, !options.ignoredNames.contains(node.name) else { return }
        paths.insert(node.id)

        let combinedNameTokens = ancestorTokens.union(nameTokens(node.name))
        var contentTokens = Set<String>()
        for child in node.children ?? [] where !child.isDirectory {
            contentTokens.formUnion(fileTokens(child.name))
        }
        profiles.append(FolderProfile(
            path: node.id, name: node.name, depth: node.id.split(separator: "/").count,
            nameTokens: combinedNameTokens, contentTokens: contentTokens))

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
            let reason = fromContent
                ? "Matches “\(hits)” read from the file, in a folder you already keep"
                : "Matches “\(hits)” in a folder you already keep"
            out.append(FilingDestination(path: p.path, confidence: confidence, reasons: [reason],
                                         newSegments: [], fromContent: fromContent))
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
    private static func missingSegments(of path: String, existingPaths: Set<String>) -> [String] {
        if existingPaths.contains(path) { return [] }
        var current = ""
        var missing: [String] = []
        var creating = false
        for seg in path.split(separator: "/") {
            current += "/" + seg
            if creating || !existingPaths.contains(current) {
                creating = true
                missing.append(String(seg))
            }
        }
        return missing
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
                                                   remembered: existing.remembered || c.remembered)
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
}
