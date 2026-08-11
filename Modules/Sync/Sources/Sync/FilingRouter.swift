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
/// | ＋ ``FilingMemory`` | 58.2% | 77.4% |
/// | ＋ inheritance that is actually in scale (see ``rank``) | 59.8% | 79.6% |
/// | ＋ the document's own years, and `inheritWeight` re-swept | **61.9%** | **81.8%** |
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
        /// How many distinctive **words** this file shares with the folder's filed documents.
        ///
        /// Deliberately not called anything with "files" or "matches" in it. It was
        /// `neighborMatches`, which is the name of a `FilingDestination` field meaning *how many
        /// files in the target contain the evidence word* — so a token count reached a card that
        /// renders it as "N similar files already here". The memory does not record per-token file
        /// counts, so that claim cannot be made from it at all.
        public let sharedAnchors: Int

        public init(relativePath: String, score: Double, evidenceToken: String?, sharedAnchors: Int) {
            self.relativePath = relativePath
            self.score = score
            self.evidenceToken = evidenceToken
            self.sharedAnchors = sharedAnchors
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
    /// How much of a scoring folder's evidence its neighbours inherit — its siblings and its own
    /// children. A multiple of the donor's score, not a constant: see ``rank``.
    ///
    /// **Above 1: a cold folder is worth more than a fraction of its family.** The value was 0.45
    /// from when the share was normalised into [0, 0.45] and could not mean anything else. Once the
    /// share became proportional it was never re-swept, and 0.45 turned out to be far too timid for
    /// the case inheritance exists for: the *current year's* bucket. `Home/Utilities/AT&T/2026` has
    /// no documents in it yet — January's bill is the first — so it can only inherit, and at 0.45 it
    /// lost to `Finance/US/Credit Accounts/Apple Card/2026`, a different family whose 2026 folder
    /// had both its own content and the same exact year match. The AT&T folder's own siblings hold
    /// twelve bills a year each and their anchors are `myat, snap, myatt, att, autopay, managing,
    /// bills` — every one of them on the page.
    ///
    /// Re-swept on the 2,000-document tune split, which is flat from 0.9 upward (64.6% → 64.9%), and
    /// reported on the 7,370 held out: 60.0% → **61.9%** top-1, 80.0% → **81.8%** top-3. The class it
    /// is for moves most — a gold folder with no documents of its own goes from 1.0% to 6.9%.
    static let inheritWeight = 1.4
    static let yearInNameWeight = 3.0
    static let yearInBodyWeight = 2.0
    static let identifierBoost = 4.0

    /// How much of a document the router reads: **page 1, 400 characters** — the sampling rule the
    /// ``FilingMemory`` records for itself, and the rule under which every weight above was tuned
    /// and every accuracy figure in this file was measured.
    ///
    /// **Enforced here rather than trusted from the caller**, because the caller was not honouring
    /// it. `ContentSignalExtractor` returns up to five pages and 20,000 characters — a sane budget
    /// for a classifier prompt, and four decimal orders more than this scorer was ever measured on.
    /// A T-Mobile bill handed over at full length still ranked its real home first, but pages 2-5
    /// are line items, and the vocabulary in them pulled `Home/Insurance/2025` and three tax-
    /// deduction folders up close behind it: the margin fell from 0.37 to 0.14, which is the
    /// difference between `.medium` and `.low` — between a home that leads a card and one that
    /// cannot displace anything. The doc for `rank` always said "page 1 only". Nothing enforced it.
    static let contentSampleChars = 400

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
        /// Folder → the registry person its `axes.person` resolves to. Only folders the registry
        /// can actually resolve appear; an axis value naming someone outside the registry is left
        /// to the token fallback rather than half-resolved.
        let folderPerson: [String: String]
        let registry: PersonRegistry?
        let salt: String
        /// Name-token → folders, and year → folders.
        ///
        /// These exist for speed, and the speed is not a nicety. Scoring names by walking every
        /// destination cost **10 ms per file** against a real 2,979-folder tree; the root inbox of
        /// the tree this was built for holds 524 loose files, so a scan spent five seconds of
        /// synchronous work before showing anything. Looking folders up by the tokens a file
        /// actually has is the same arithmetic over a few hundred folders instead of three thousand.
        let foldersByPathToken: [String: [String]]
        let foldersByYear: [String: [String]]
        /// Folder → its anchors, for recovering display evidence for the shown candidates.
        let anchorsByFolder: [String: [String: Double]]
        /// Folder → anchor → share of that folder's documents carrying it, where the memory records
        /// it. Read only by ``AutomationRuleProposer``: ranking a *destination* wants rarity, while
        /// keying a *rule* wants recurrence, and they are different numbers.
        let docFrequencyByFolder: [String: [String: Double]]
        /// The same, for the hashed digit-bearing tokens. Separate because they are keyed by hash
        /// and looked up by hash — folding them into the readable map would need every lookup to
        /// know which kind of token it holds.
        let idDocFrequencyByFolder: [String: [String: Double]]
        /// Folder → the folders it is a stash of copies of. See ``SatelliteFolders``.
        let satelliteHomes: [String: Set<String>]

        public var isEmpty: Bool { destinations.isEmpty }
    }

    /// Prepares the index for one taxonomy.
    ///
    /// `destinations` is the taxonomy the caller already computed; folders the profile forbids are
    /// dropped here rather than at the call site so no consumer can forget.
    public static func makeIndex(destinations: [String], profile: FolderProfile?,
                                 memory: FilingMemory?, registry: PersonRegistry? = nil,
                                 satelliteHomes: [String: Set<String>] = [:]) -> Index {
        // One rule, asked the same way everywhere — see ``FolderProfile/isInboxPath(_:)``.
        let allowed = destinations.filter { profile?.acceptsNewFiles($0) ?? !FolderProfile.isInboxPath($0) }
        var byAnchor: [String: [(String, Double)]] = [:]
        var byIdHash: [String: [(String, Double)]] = [:]
        var docs: [String: Int] = [:]
        var anchorsByFolder: [String: [String: Double]] = [:]
        var docFrequencyByFolder: [String: [String: Double]] = [:]
        var idDocFrequencyByFolder: [String: [String: Double]] = [:]
        let allowedSet = Set(allowed)
        if let memory {
            for (folder, entry) in memory.folders where allowedSet.contains(folder) {
                docs[folder] = entry.docs
                anchorsByFolder[folder] = Dictionary(entry.anchors.map { ($0.token, $0.weight) },
                                                     uniquingKeysWith: { a, b in max(a, b) })
                let shares = entry.anchors.compactMap { t in t.docFrequency.map { (t.token, $0) } }
                if !shares.isEmpty {
                    docFrequencyByFolder[folder] = Dictionary(shares, uniquingKeysWith: { a, b in max(a, b) })
                }
                let idShares = entry.idHashes.compactMap { t in t.docFrequency.map { (t.token, $0) } }
                if !idShares.isEmpty {
                    idDocFrequencyByFolder[folder] = Dictionary(idShares, uniquingKeysWith: { a, b in max(a, b) })
                }
                for t in entry.anchors { byAnchor[t.token, default: []].append((folder, t.weight)) }
                for t in entry.idHashes { byIdHash[t.token, default: []].append((folder, t.weight)) }
            }
        }
        var pathTokens: [String: Set<String>] = [:]
        var anchorTokens: [String: Set<String>] = [:]
        var yearKey: [String: String] = [:]
        var roleBonus: [String: Double] = [:]
        var children: [String: [String]] = [:]
        var foldersByPathToken: [String: [String]] = [:]
        var foldersByYear: [String: [String]] = [:]
        var folderPerson: [String: String] = [:]
        for f in allowed {
            let pt = FilingRouter.pathTokens(of: f)
            pathTokens[f] = pt
            let entry = profile?.folders[f]
            let at = Set((entry?.anchors ?? []).flatMap { tokenize($0) })
            anchorTokens[f] = at
            for t in pt.union(at) { foldersByPathToken[t, default: []].append(f) }
            if let y = entry?.yearKey {
                yearKey[f] = y
            } else if let base = f.split(separator: "/").last.map(String.init),
                      FolderProfileEntry.looksLikeYear(base) {
                yearKey[f] = base
            }
            // A fiscal span is reachable from either half, so `2019-2020` is listed under both.
            for part in (yearKey[f] ?? "").split(separator: "-") where Int(part) != nil {
                foldersByYear[String(part), default: []].append(f)
            }
            switch entry?.role {
            case .destination, .yearBucket: roleBonus[f] = 0.5
            case .container, .passThrough: roleBonus[f] = -0.5
            default: roleBonus[f] = 0
            }
            if let slash = f.lastIndex(of: "/") {
                children[String(f[f.startIndex..<slash]), default: []].append(f)
            }
            if let registry, let axis = entry?.axes["person"],
               let id = registry.person(forAxisValue: axis) {
                folderPerson[f] = id
            }
        }
        // Only pairs whose BOTH ends survived the allow-list can ever fire, so a satellite whose
        // home was filtered out (an inbox, a forbidden folder) is not half-applied.
        let satellites = satelliteHomes.reduce(into: [String: Set<String>]()) { out, pair in
            guard allowedSet.contains(pair.key) else { return }
            let homes = pair.value.filter { allowedSet.contains($0) }
            if !homes.isEmpty { out[pair.key] = homes }
        }
        return Index(byAnchor: byAnchor, byIdHash: byIdHash, docs: docs, destinations: allowed,
                     pathTokens: pathTokens, anchorTokens: anchorTokens, yearKey: yearKey,
                     roleBonus: roleBonus, children: children,
                     personTokens: profile?.personTokens ?? [], folderPerson: folderPerson,
                     registry: registry, salt: memory?.salt ?? "",
                     foldersByPathToken: foldersByPathToken, foldersByYear: foldersByYear,
                     anchorsByFolder: anchorsByFolder, docFrequencyByFolder: docFrequencyByFolder,
                     idDocFrequencyByFolder: idDocFrequencyByFolder,
                     satelliteHomes: satellites)
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
        // The sample this scorer was measured on — see ``contentSampleChars``. Callers hand over
        // whatever their extractor produced; what gets scored is bounded here.
        let sample = contentSnippet.map { String($0.prefix(contentSampleChars)) }
        var contentTokens = nameTokens
        if let sample { contentTokens.formUnion(tokenize(sample)) }

        let yearsInName = nameTokens.filter(isYearToken)
        // **Years must be read out of the document, not only the filename.** Three files all called
        // `Lease Agreement.pdf` differ only by the term printed inside them; without this the
        // scorer picks whichever sibling year folder happens to sort first.
        //
        // Read from the TEXT, not from its tokens. `tokenize` splits on non-alphanumerics, so a
        // date printed `20NOV2026` — how every US visa foil prints its expiry — is the single token
        // `20nov2026` and never looks like a year at all. Worse, `contentTokens` starts as a copy of
        // `nameTokens`, so the "body" year was in practice the FILENAME's year counted a second
        // time: a document that named no year of its own still collected the body bonus.
        let yearsInBody = sample.map(yearsInText) ?? []

        // ---- content evidence -------------------------------------------------------------
        // Scoring keeps ONE number per folder. Which anchor won and how many matched are needed
        // only for the handful of folders actually shown, so they are recovered at the end instead
        // of being maintained for every folder a common word touches — a document routinely puts
        // thousands in play, and that bookkeeping was two extra dictionary writes on each.
        var content: [String: Double] = [:]
        for token in contentTokens {
            if isIdentifier(token) {
                let h = FilingMemory.hash(token, salt: index.salt)
                for (folder, weight) in index.byIdHash[h] ?? [] {
                    content[folder, default: 0] += weight * identifierBoost
                }
            }
            for (folder, weight) in index.byAnchor[token] ?? [] {
                content[folder, default: 0] += weight
            }
        }
        for (folder, raw) in content {
            let n = max(index.docs[folder] ?? 1, 1)
            content[folder] = raw / Double(n).squareRoot()
        }

        // **Evidence has to reach the folders that hold none of their own, or an empty folder is
        // unreachable.** `Home/Utilities/AT&T/2024` is empty for 2024, so it has no content of its
        // own and can never be proposed however obviously an AT&T bill belongs there — while its
        // siblings are full of AT&T bills. Content identifies the family; the year axis below picks
        // the member.
        //
        // A scoring folder shares with its siblings (through the parent they share) **and with its
        // own children**. Both directions are load-bearing, and the first cut had only the first:
        // `Immigration/Visa/US/H-1B Visa` holds every H-1B visa foil while its per-era children hold
        // none, so the folders the file actually belonged in inherited nothing at all.
        //
        // **The share is proportional to the donor's score, not normalised to `inheritWeight`.**
        // Dividing by the peak made every share land in [0, 0.45] and then added it to RAW content
        // scores, which on a real memory reach the hundreds — so a cold folder moved by ~0.2% of the
        // leader and inheritance was, in the one case it exists for, arithmetically inert. Measured
        // leave-one-out over 7,370 held-out documents against 2,956 folders, the two fixes together
        // take top-1 from 58.2% to 59.8% and top-3 from 77.4% to 79.6%.
        if !content.isEmpty {
            // Donors are read from a snapshot taken before any share lands, so evidence moves one
            // hop and cannot cascade down a deep tree.
            var donors: [String: Double] = [:]
            for (folder, score) in content where score > 0 {
                donors[folder] = max(donors[folder] ?? 0, score)
                if let slash = folder.lastIndex(of: "/") {
                    let parent = String(folder[folder.startIndex..<slash])
                    donors[parent] = max(donors[parent] ?? 0, score)
                }
            }
            for (donor, score) in donors {
                let share = inheritWeight * score
                for child in index.children[donor] ?? [] {
                    content[child, default: 0] += share
                }
            }
        }

        // ---- name and axis evidence -------------------------------------------------------
        //
        // Only folders this file can actually reach are scored: ones sharing a name token, ones
        // whose year the file names, and ones content already put in play. Everything else scores
        // zero (no overlap, no year) or loses anyway (a non-matching year is a penalty on a folder
        // with nothing else going for it), so walking the whole tree only bought latency.
        var reachable = Set<String>()
        for t in nameTokens {
            if let fs = index.foldersByPathToken[t] { reachable.formUnion(fs) }
        }
        for y in yearsInName.union(yearsInBody) {
            if let fs = index.foldersByYear[y] { reachable.formUnion(fs) }
        }
        reachable.formUnion(content.keys)          // a wrong year must still penalise a live folder

        let people = nameTokens.intersection(index.personTokens)
        // Person identity, phrase-first — asked of the raw strings, not the token sets, because
        // "Aditi Abhishek" must spend its surname on Aditi and a Set has already lost the order
        // that makes that possible. Detected once per file; the body is included so a scan whose
        // *page* names its person routes between sibling person buckets the same way a well-named
        // file does.
        let detectedPeople: Set<String>
        if let registry = index.registry, !index.folderPerson.isEmpty {
            detectedPeople = registry.detect(in: sample.map { stem + " " + $0 } ?? stem)
        } else {
            detectedPeople = []
        }
        var name: [String: Double] = [:]
        for folder in reachable {
            var s = 0.0
            let pathToks = index.pathTokens[folder] ?? []
            var overlap = 0
            for t in nameTokens where pathToks.contains(t) || index.anchorTokens[folder]?.contains(t) == true {
                overlap += 1
            }
            s += Double(overlap) * 2.0
            // The axis, where the registry resolves it: a match is confirmation, and a
            // *contradiction* — the document names people and this folder's person is not among
            // them — is the strongest negative signal name evidence has. Sibling person buckets
            // differ by exactly this, so it is what routes `Divit … Report Card.pdf` to
            // `School/Divit` over a sibling holding identical documents. Multi-person documents
            // are safe by construction: no penalty for anyone the document actually names.
            //
            // **Computed before the early-outs below, and counted as a reason to score the folder
            // at all.** Those guards drop any folder the file name does not touch, which is
            // precisely the case this signal exists for: `Scan 2026-08-02.pdf` shares no token
            // with `School/Divit`, so the folder was dropped before the person was ever consulted
            // and a page naming Divit routed to his sister.
            var personDelta = 0.0
            if let fp = index.folderPerson[folder], !detectedPeople.isEmpty {
                personDelta = detectedPeople.contains(fp) ? 1.0 : -3.0
            }
            if let year = index.yearKey[folder] {
                if !yearsInName.isEmpty { s += yearInNameWeight * yearFit(year, yearsInName) }
                if !yearsInBody.isEmpty { s += yearInBodyWeight * yearFit(year, yearsInBody) }
            } else if s == 0, personDelta == 0 {
                continue
            }
            if s == 0, personDelta == 0 { continue }
            s += index.roleBonus[folder] ?? 0
            if !people.isEmpty, !people.isDisjoint(with: pathToks) { s += 2.0 }
            name[folder] = s + personDelta
        }

        // ---- blend --------------------------------------------------------------------------
        // Both sides are normalised to [0, 1] first. Adding raw scores let content outvote the
        // profile exactly where the profile was the only signal left — a folder with nothing filed
        // in it scored 0.7% before this, against 26.8% for the profile alone.
        let contentPeak = content.values.max() ?? 0
        let namePeak = name.values.max() ?? 0
        var total: [String: Double] = [:]
        total.reserveCapacity(content.count + name.count)
        if contentPeak > 0 {
            for (f, v) in content { total[f, default: 0] += contentWeight * (v / contentPeak) }
        }
        if namePeak > 0 {
            for (f, v) in name { total[f, default: 0] += nameWeight * (v / namePeak) }
        }
        for f in excluding { total.removeValue(forKey: f) }

        // **A folder does not outrank the folder it is a stash of copies of.**
        //
        // Applied here rather than by the caller — `rank` has two call sites and a re-rank one of
        // them forgot would be invisible — and applied to the scores rather than to the final
        // order, so the margin below is computed on what the ranking actually claims.
        //
        // A DEMOTION, not a removal: the satellite stays on the card as an alternate, one click
        // away, because the relation is a statement about which folder is the home and not about
        // whether a document may ever be copied into a petition packet again.
        //
        // Only fires when both ends are in play for the same file, which is a narrow event: 14
        // pairs over the tree's 3,013 profiled folders, and 67 of 10,470 identified documents live
        // in a satellite at all. **Leave-one-out cannot score this**, and that is worth saying
        // plainly rather than reporting a number that looks like validation: the corpus's ground
        // truth for those 67 documents IS the satellite — they are filed there — so a replay
        // scores the demotion as 67 regressions. The population it exists for is the one the
        // corpus never holds, a document arriving for the first time.
        if !index.satelliteHomes.isEmpty {
            // Read from a snapshot, so a chain (A copies B, B copies C) settles against the scores
            // as ranked rather than against a partially demoted set.
            let scored = total
            for (satellite, homes) in index.satelliteHomes {
                guard let own = scored[satellite] else { continue }
                guard let best = homes.compactMap({ scored[$0] }).max(), best < own else { continue }
                total[satellite] = best * 0.99
            }
        }
        guard !total.isEmpty else { return .empty }

        // Top-k by selection, not by sorting. A document routinely puts a few thousand folders in
        // play and only the first five are ever shown, so a full `sorted()` was ordering ~3,000
        // string keys to read six of them — the single largest cost in this function.
        let want = max(limit, 2)                       // the runner-up is what the margin needs
        var best: [(key: String, value: Double)] = []
        best.reserveCapacity(want + 1)
        for entry in total {
            if best.count == want, entry.value < best[best.count - 1].value { continue }
            // Ties break on the path so a ranking is reproducible run to run.
            var i = best.count
            while i > 0, entry.value > best[i - 1].value
                || (entry.value == best[i - 1].value && entry.key < best[i - 1].key) { i -= 1 }
            best.insert((entry.key, entry.value), at: i)
            if best.count > want { best.removeLast() }
        }
        let top = best[0].value
        let margin = best.count > 1 && top > 0 ? (top - best[1].value) / top : 1.0
        let candidates = best.prefix(limit).map { entry -> Candidate in
            let (token, hits) = evidence(for: entry.key, tokens: contentTokens, index: index)
            return Candidate(relativePath: entry.key, score: entry.value,
                             evidenceToken: token, sharedAnchors: hits)
        }
        return Ranking(candidates: Array(candidates), margin: margin)
    }

    /// The heaviest anchor this file shares with `folder`, and how many it shares.
    ///
    /// Recomputed for the shown candidates rather than tracked for every folder during scoring.
    /// Ties break on the token so the evidence chip on a card is the same on every run —
    /// `contentTokens` is a Set, and its iteration order is not.
    static func evidence(for folder: String, tokens: Set<String>,
                         index: Index) -> (token: String?, hits: Int) {
        guard let anchors = index.anchorsByFolder[folder] else { return (nil, 0) }
        var bestToken: String?
        var bestWeight = -1.0
        var hits = 0
        for token in tokens {
            guard let w = anchors[token] else { continue }
            hits += 1
            if w > bestWeight || (w == bestWeight && token < (bestToken ?? "\u{10FFFF}")) {
                bestWeight = w
                bestToken = token
            }
        }
        return (bestToken, hits)
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

    /// A folder's own name tokens, plus the punctuation-free form of each word in it.
    ///
    /// `tokenize("H-1B Visa")` is `["1b", "visa"]` — the hyphen the folder is *named* with splits
    /// the classification off, so a file called `H1B Visa - Nov 2026.pdf` matches only `visa` and
    /// scores its own branch no better than `H-4 Visa`. Indexing `h1b` alongside `1b` costs one
    /// extra token per word and makes the two spellings the same folder.
    ///
    /// **Index-side only, and that is what keeps it safe.** These tokens come from folder names, not
    /// from a ``FilingMemory``, so widening them cannot disagree with the builder that wrote the
    /// stored anchors — the reason ``tokenize`` itself is left exactly as it is.
    static func pathTokens(of folder: String) -> Set<String> {
        var out = Set(tokenize(folder))
        for component in folder.split(separator: "/") {
            for word in component.split(whereSeparator: { $0.isWhitespace || $0 == "_" }) {
                let joined = String(word.lowercased().unicodeScalars.filter {
                    CharacterSet.alphanumerics.contains($0) && $0.isASCII
                }.map(Character.init))
                if joined.count >= 2, !stopWords.contains(joined) { out.insert(joined) }
            }
        }
        return out
    }

    /// Every year the text itself prints, found without going through ``tokenize``.
    ///
    /// Deliberately a second, narrower reader rather than a change to the tokenizer. The stored
    /// anchors in a ``FilingMemory`` were produced by the builder's tokenizer, and a token this side
    /// splits differently simply stops matching — silently, as fewer hits and lower accuracy. So
    /// years are read alongside the tokens and never feed anchor lookup.
    ///
    /// A year is a four-digit `19xx`/`20xx` run that is not part of a longer digit run: that finds
    /// `2026` inside `20NOV2026` while refusing `2024` inside the control number `20241808200001`.
    static func yearsInText(_ text: String) -> Set<String> {
        var out: Set<String> = []
        var digits = ""
        func endRun() {
            if digits.count == 4, let n = Int(digits), n > 1900, n < 2100 { out.insert(digits) }
            digits.removeAll(keepingCapacity: true)
        }
        for ch in despaced(text) {
            if ch.isASCII, ch.isNumber { digits.append(ch) } else { endRun() }
        }
        endRun()
        return out
    }

    /// Text whose glyphs arrive one-per-field — `0 3 J U L 2 0 2 4` — put back together.
    ///
    /// A real extraction artifact, and the reason this document's *issue* date was invisible while
    /// its expiry was not. Joins any run of four or more consecutive single-character fields, which
    /// cannot damage a year that was already contiguous.
    static func despaced(_ text: String) -> String {
        var out: [String] = []
        var run: [String] = []
        func flush() {
            if run.count >= 4 { out.append(run.joined()) } else { out.append(contentsOf: run) }
            run.removeAll(keepingCapacity: true)
        }
        for field in text.split(whereSeparator: \.isWhitespace) {
            if field.count == 1, let c = field.first, c.isLetter || c.isNumber {
                run.append(String(field))
            } else {
                flush()
                out.append(String(field))
            }
        }
        flush()
        return out.joined(separator: " ")
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
}

// MARK: - Peer filenames

public extension FilingRouter {

    /// Re-orders a ranking by how well each candidate's EXISTING FILE NAMES cover the incoming one.
    ///
    /// **Only between a folder and its own ancestor or descendant**, and that scoping is the whole
    /// reason this is safe. A folder and its subfolder share their vocabulary by construction, so
    /// content cannot separate them — `Immigration/OCI/Divit` scored 1.388 and
    /// `Immigration/OCI/Divit/Application` 1.374 for `Divit OCI Photo.jpg`, a 1% gap — while the
    /// file names in them say it plainly: `Application/` already holds
    /// `Divit OCI Photo - 4up print sheet.jpg` and `Divit OCI.jpg`. Between UNRELATED folders the
    /// same bonus is noise, and measurably so: applied to the whole shortlist it moved held-out
    /// top-1 by +0.2 points while the tune split moved −0.4, a disagreement in sign. Scoped to one
    /// branch both splits are flat (±0.1) and the case above is fixed.
    ///
    /// **Coverage of the incoming name, not Jaccard.** `Divit OCI Photo - 4up print sheet` covers
    /// all of `Divit OCI Photo`; `Divit OCI.pdf` in the parent covers two thirds. Jaccard scores
    /// those identically (0.67 each) and picks the wrong folder.
    ///
    /// `namesInFolder` is injected because this module does not touch the filesystem — see
    /// ``FileSyncManager/peerNameLookup()`` for the listing side, and `route(_:index:…)` for the one
    /// call that applies this. (The name written here before, `rerankByPeerNames(_:fileName:
    /// providerRoot:)`, never existed — the doc link pointed at the caller this helper was missing.)
    static func rerankedByPeerNames(_ ranking: Ranking, fileName: String,
                                    namesInFolder: (String) -> [String]) -> Ranking {
        guard let top = ranking.best?.relativePath else { return ranking }
        let incoming = Set(tokenize((fileName as NSString).deletingPathExtension))
        guard !incoming.isEmpty else { return ranking }

        func onSameBranch(_ f: String) -> Bool {
            f == top || f.hasPrefix(top + "/") || top.hasPrefix(f + "/")
        }
        func coverage(_ folder: String) -> Double {
            var best = 0.0
            for name in namesInFolder(folder) {
                let peer = Set(tokenize((name as NSString).deletingPathExtension))
                guard !peer.isEmpty else { continue }
                best = max(best, Double(incoming.intersection(peer).count) / Double(incoming.count))
            }
            return best
        }
        let rescored = ranking.candidates.map { c -> (Candidate, Double) in
            let bonus = onSameBranch(c.relativePath) ? peerWeight * coverage(c.relativePath) : 0
            return (c, c.score + bonus)
        }
        // Ties break on the path, exactly as `rank` does, so a re-order is reproducible.
        let sorted = rescored.sorted { a, b in
            a.1 == b.1 ? a.0.relativePath < b.0.relativePath : a.1 > b.1
        }
        guard sorted.count > 1, sorted[0].1 > 0 else { return ranking }
        let margin = (sorted[0].1 - sorted[1].1) / sorted[0].1
        return Ranking(candidates: sorted.map { Candidate(relativePath: $0.0.relativePath,
                                                          score: $0.1,
                                                          evidenceToken: $0.0.evidenceToken,
                                                          sharedAnchors: $0.0.sharedAnchors) },
                       margin: margin)
    }

    /// How much a fully-covering peer name is worth. Swept on both splits; flat within ±0.1 either
    /// way once scoped to one branch, so this is set to what separates the case it exists for
    /// rather than to a peak that is not there.
    static var peerWeight: Double { 0.30 }
}
