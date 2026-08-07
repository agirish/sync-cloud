import Foundation

/// Ranks destinations for a loose file from the tree's own profile and memory — **no model call.**
///
/// This is the free tier's answer to "where does this go?". Measured leave-one-out over 9,558 real
/// filed documents, choosing one of ~2,950 folders from a file name plus 400 characters of page 1:
///
/// | | top-1 | top-3 |
/// |---|---|---|
/// | name against a bare folder list | 12.6% | 19.3% |
/// | ＋ ``FolderProfile`` | 28.9% | 40.2% |
/// | ＋ ``FilingMemory`` | 58.2% | 77.5% |
///
/// Two of the rules below were found by measuring rather than by reasoning, and both are load-bearing.
public enum FilingRouter {

    /// A ranked destination, relative to the provider root.
    public struct Candidate: Sendable, Equatable {
        public let relativePath: String
        public let score: Double
        /// The readable anchor that contributed most — display-ready evidence for the card, and nil
        /// when the folder was reached by name or by inheritance rather than by content.
        public let evidenceToken: String?
        /// How many of the destination's filed documents share the matched anchors.
        public let neighborMatches: Int

        public init(relativePath: String, score: Double, evidenceToken: String?, neighborMatches: Int) {
            self.relativePath = relativePath
            self.score = score
            self.evidenceToken = evidenceToken
            self.neighborMatches = neighborMatches
        }
    }

    public struct Ranking: Sendable, Equatable {
        public let candidates: [Candidate]
        /// `(top − runnerUp) / top`, 1.0 when there is only one candidate.
        ///
        /// **This is the only honest confidence Organize has had.** Measured on the held-out split:
        /// a margin ≥ 0.5 is right 94% of the time and covers 15% of files; below 0.2 it is right
        /// 42% of the time and covers 46%. That is the signal for what to auto-file, what to
        /// suggest, and what is worth paying the refine tier for.
        public let margin: Double

        public var best: Candidate? { candidates.first }

        public var confidence: FilingConfidence {
            guard !candidates.isEmpty else { return .low }
            return margin >= 0.5 ? .high : (margin >= 0.2 ? .medium : .low)
        }

        public init(candidates: [Candidate], margin: Double) {
            self.candidates = candidates
            self.margin = margin
        }

        public static let empty = Ranking(candidates: [], margin: 0)
    }

    // Weights. Tuned on a 2,000-document split and reported on the 7,558 held out from it; they are
    // deliberately few, because a scorer with many knobs tuned on one tree would be fitting that
    // tree rather than describing it.
    static let contentWeight = 1.0
    static let nameWeight = 0.55
    /// How much of a parent's best evidence its children inherit — see ``rank`` for why this exists.
    static let inheritWeight = 0.45
    static let yearInNameWeight = 3.0
    static let yearInBodyWeight = 2.0
    static let identifierBoost = 4.0

    /// A prepared inverted index. Built once per scan, not per file: a scan of a few hundred loose
    /// files against a few thousand folders would otherwise walk every folder's token list per file.
    public struct Index: Sendable {
        let byAnchor: [String: [(folder: String, weight: Double)]]
        let byIdHash: [String: [(folder: String, weight: Double)]]
        let docs: [String: Int]
        let destinations: [String]
        let pathTokens: [String: Set<String>]
        let anchorTokens: [String: Set<String>]
        let yearKey: [String: String]
        let roleBonus: [String: Double]
        let children: [String: [String]]
        let personTokens: Set<String>
        let salt: String

        public var isEmpty: Bool { destinations.isEmpty }
    }

    /// Prepares the index for one taxonomy.
    ///
    /// `destinations` is the taxonomy the caller already computed; folders the profile forbids are
    /// dropped here rather than at the call site so no consumer can forget.
    public static func makeIndex(destinations: [String], profile: FolderProfile?,
                                 memory: FilingMemory?) -> Index {
        let allowed = destinations.filter { profile?.acceptsNewFiles($0) ?? !isInboxPath($0) }
        var byAnchor: [String: [(String, Double)]] = [:]
        var byIdHash: [String: [(String, Double)]] = [:]
        var docs: [String: Int] = [:]
        let allowedSet = Set(allowed)
        if let memory {
            for (folder, entry) in memory.folders where allowedSet.contains(folder) {
                docs[folder] = entry.docs
                for t in entry.anchors { byAnchor[t.token, default: []].append((folder, t.weight)) }
                for t in entry.idHashes { byIdHash[t.token, default: []].append((folder, t.weight)) }
            }
        }
        var pathTokens: [String: Set<String>] = [:]
        var anchorTokens: [String: Set<String>] = [:]
        var yearKey: [String: String] = [:]
        var roleBonus: [String: Double] = [:]
        var children: [String: [String]] = [:]
        for f in allowed {
            pathTokens[f] = Set(tokenize(f))
            let entry = profile?.folders[f]
            anchorTokens[f] = Set((entry?.anchors ?? []).flatMap { tokenize($0) })
            if let y = entry?.yearKey {
                yearKey[f] = y
            } else if let base = f.split(separator: "/").last.map(String.init),
                      FolderProfileEntry.looksLikeYear(base) {
                yearKey[f] = base
            }
            switch entry?.role {
            case .destination, .yearBucket: roleBonus[f] = 0.5
            case .container, .passThrough: roleBonus[f] = -0.5
            default: roleBonus[f] = 0
            }
            if let slash = f.lastIndex(of: "/") {
                children[String(f[f.startIndex..<slash]), default: []].append(f)
            }
        }
        return Index(byAnchor: byAnchor, byIdHash: byIdHash, docs: docs, destinations: allowed,
                     pathTokens: pathTokens, anchorTokens: anchorTokens, yearKey: yearKey,
                     roleBonus: roleBonus, children: children,
                     personTokens: profile?.personTokens ?? [], salt: memory?.salt ?? "")
    }

    /// Ranks destinations for one file.
    ///
    /// `contentSnippet` is page 1 only — the same rule the profile carries, because a statement,
    /// form, letter or bill says what it is on its first page and pages 2..n are line items that
    /// cost context and change nothing.
    public static func rank(fileName: String, contentSnippet: String?, index: Index,
                            excluding: Set<String> = [], limit: Int = 5) -> Ranking {
        guard !index.isEmpty else { return .empty }
        let stem = (fileName as NSString).deletingPathExtension
        let nameTokens = Set(tokenize(stem))
        var contentTokens = nameTokens
        if let contentSnippet { contentTokens.formUnion(tokenize(contentSnippet)) }

        let yearsInName = nameTokens.filter(isYearToken)
        // **Years must be read out of the document, not only the filename.** Three files all called
        // `Lease Agreement.pdf` differ only by the term printed inside them; without this the
        // scorer picks whichever sibling year folder happens to sort first.
        let yearsInBody = contentTokens.filter(isYearToken)

        // ---- content evidence -------------------------------------------------------------
        var content: [String: Double] = [:]
        var bestAnchor: [String: (token: String, weight: Double)] = [:]
        var anchorHits: [String: Int] = [:]
        for token in contentTokens {
            if isIdentifier(token) {
                let h = FilingMemory.hash(token, salt: index.salt)
                for (folder, weight) in index.byIdHash[h] ?? [] {
                    content[folder, default: 0] += weight * identifierBoost
                }
            }
            for (folder, weight) in index.byAnchor[token] ?? [] {
                content[folder, default: 0] += weight
                anchorHits[folder, default: 0] += 1
                if weight > (bestAnchor[folder]?.weight ?? -1) {
                    bestAnchor[folder] = (token, weight)
                }
            }
        }
        for (folder, raw) in content {
            let n = max(index.docs[folder] ?? 1, 1)
            content[folder] = raw / Double(n).squareRoot()
        }

        // **Evidence has to be inherited from the parent, or an empty folder is unreachable.**
        // `Home/Utilities/AT&T/2024` is empty for 2024, so it has no content of its own and can
        // never be proposed however obviously an AT&T bill belongs there — while its siblings are
        // full of AT&T bills. Content identifies the family; the year axis below picks the member.
        if !content.isEmpty {
            var parentBest: [String: Double] = [:]
            for (folder, score) in content {
                guard let slash = folder.lastIndex(of: "/") else { continue }
                let parent = String(folder[folder.startIndex..<slash])
                parentBest[parent] = max(parentBest[parent] ?? 0, score)
            }
            if let peak = parentBest.values.max(), peak > 0 {
                for (parent, score) in parentBest {
                    let share = inheritWeight * (score / peak)
                    for child in index.children[parent] ?? [] {
                        content[child, default: 0] += share
                    }
                }
            }
        }

        // ---- name and axis evidence -------------------------------------------------------
        var name: [String: Double] = [:]
        for folder in index.destinations {
            var s = 0.0
            let overlap = nameTokens.intersection(index.pathTokens[folder] ?? [])
                .union(nameTokens.intersection(index.anchorTokens[folder] ?? []))
            s += Double(overlap.count) * 2.0
            if let year = index.yearKey[folder] {
                if !yearsInName.isEmpty { s += yearInNameWeight * yearFit(year, yearsInName) }
                if !yearsInBody.isEmpty { s += yearInBodyWeight * yearFit(year, yearsInBody) }
            } else if s == 0 {
                continue
            }
            if s == 0 { continue }
            s += index.roleBonus[folder] ?? 0
            let people = nameTokens.intersection(index.personTokens)
            if !people.isEmpty, !people.isDisjoint(with: index.pathTokens[folder] ?? []) { s += 2.0 }
            name[folder] = s
        }

        // ---- blend --------------------------------------------------------------------------
        // Both sides are normalised to [0, 1] first. Adding raw scores let content outvote the
        // profile exactly where the profile was the only signal left — a folder with nothing filed
        // in it scored 0.7% before this, against 26.8% for the profile alone.
        let contentPeak = content.values.max() ?? 0
        let namePeak = name.values.max() ?? 0
        var total: [String: Double] = [:]
        if contentPeak > 0 {
            for (f, v) in content { total[f, default: 0] += contentWeight * (v / contentPeak) }
        }
        if namePeak > 0 {
            for (f, v) in name { total[f, default: 0] += nameWeight * (v / namePeak) }
        }
        for f in excluding { total.removeValue(forKey: f) }
        guard !total.isEmpty else { return .empty }

        let ranked = total.sorted { a, b in
            a.value == b.value ? a.key < b.key : a.value > b.value
        }
        let top = ranked[0].value
        let margin = ranked.count > 1 && top > 0 ? (top - ranked[1].value) / top : 1.0
        let candidates = ranked.prefix(limit).map { entry in
            Candidate(relativePath: entry.key, score: entry.value,
                      evidenceToken: bestAnchor[entry.key]?.token,
                      neighborMatches: anchorHits[entry.key] ?? 0)
        }
        return Ranking(candidates: Array(candidates), margin: margin)
    }

    // MARK: - Tokenizing
    //
    // **This has to agree exactly with the builder that wrote the memory.** A token the builder
    // stored as `pg&e` → `pg`, `e` but that this splits differently simply never matches, and the
    // failure is silent: fewer hits, lower accuracy, no error anywhere.

    static let stopWords: Set<String> = [
        "the", "an", "and", "or", "of", "to", "in", "for", "on", "at", "by", "with", "from", "is",
        "are", "was", "were", "be", "been", "this", "that", "these", "those", "it", "its", "as",
        "if", "not", "no", "yes", "you", "your", "we", "our", "us", "they", "them", "he", "she",
        "his", "her", "me", "my", "page", "date", "name", "total", "amount", "number", "com",
        "www", "http", "https", "pdf", "doc", "inc", "llc", "ltd", "co", "corp", "mr", "mrs", "ms",
        "dr", "st", "ave", "rd", "blvd", "suite", "apt", "usa", "united", "states", "california",
        "ca", "new", "please", "thank", "sincerely", "dear", "regards", "email", "phone", "fax", "tel",
    ]

    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        current.reserveCapacity(24)
        for ch in s.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch), ch.isASCII {
                current.unicodeScalars.append(ch)
            } else if !current.isEmpty {
                if current.count >= 2, !stopWords.contains(current) { out.append(current) }
                current = ""
            }
        }
        if current.count >= 2, !stopWords.contains(current) { out.append(current) }
        return out
    }

    /// Digit-bearing and long enough to discriminate — an account last-4, a case number, a claim id.
    static func isIdentifier(_ t: String) -> Bool {
        t.count >= 4 && t.contains(where: \.isNumber)
    }

    static func isYearToken(_ t: String) -> Bool {
        guard t.count == 4, t.allSatisfy(\.isNumber), let n = Int(t) else { return false }
        return n > 1900 && n < 2100
    }

    /// A folder year may be a calendar year (`2023`) or an Indian fiscal span (`2019-2020`); a span
    /// matches fully only when the document names both halves.
    static func yearFit(_ folderYear: String, _ years: Set<String>) -> Double {
        let parts = folderYear.split(separator: "-").map(String.init).filter { Int($0) != nil }
        guard !parts.isEmpty else { return 0 }
        let hits = parts.filter { years.contains($0) }.count
        if hits == parts.count { return 1.0 }
        return hits > 0 ? 0.5 : -1.0
    }

    static func isInboxPath(_ relativePath: String) -> Bool {
        for component in relativePath.split(separator: "/") {
            let c = component.lowercased()
            if c == "inbox" || c == "misc" || c == "unfiled" || c.contains("todo") { return true }
        }
        return false
    }
}
