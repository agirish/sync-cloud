import Foundation

/// Ranks destinations for a loose file from the tree's own profile and memory, with **no model
/// call**: the free tier's answer to "where does this go?". Measured leave-one-out on a real tree
/// (thousands of filed documents, a file name plus 400 characters of page 1), name alone puts the
/// right folder first about 13% of the time; with ``FolderProfile``, ``FilingMemory`` and the rules
/// below, about 62% (82% in the top three). Several of those rules were found by measuring, and are
/// load-bearing.
public enum FilingRouter {

    /// A ranked destination, relative to the provider root.
    public struct Candidate: Sendable, Equatable {
        public let relativePath: String
        public let score: Double
        /// The readable anchor that contributed most: display-ready evidence for the card, nil when
        /// the folder was reached by name or inheritance rather than content.
        public let evidenceToken: String?
        /// How many distinctive **words** this file shares with the folder's filed documents. Not a
        /// file count, and named to avoid one: the memory records no per-token file counts, so a
        /// card can't say "N similar files already here" from it.
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
        /// How separated the winner is; ``FilingRouter/margin(top:runnerUp:)`` is the one place the
        /// rule lives. `(top − runnerUp) / top`, 1.0 for a lone candidate above zero, and 0 when
        /// the top score is zero or less. This is Organize's real confidence signal: on held-out
        /// data a margin ≥ 0.5 is right 94% of the time, and below 0.2 only 42%, which sets what to
        /// auto-file, suggest, or refine.
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

    // Weights, tuned on one split and reported on another held out from it. Deliberately few: many
    // knobs tuned on one tree would fit that tree rather than describe it.
    static let contentWeight = 1.0
    static let nameWeight = 0.55
    /// How much of a scoring folder's evidence its neighbours (siblings and its own children)
    /// inherit, as a multiple of the donor's score, not a constant (see ``rank``). Above 1 because
    /// inheritance exists for the cold folder, above all the current year's empty bucket
    /// (`Home/Utilities/AT&T/2026` before January's bill), which can only inherit and must beat a
    /// different family whose year folder has content of its own. Flat on the tune split from 0.9
    /// up.
    static let inheritWeight = 1.4
    static let yearInNameWeight = 3.0
    static let yearInBodyWeight = 2.0
    static let identifierBoost = 4.0
    /// As much as a year: a file naming its month belongs in that month's slot, not beside it.
    static let monthFitWeight = 3.0

    /// How much of a document the router reads: **page 1, 400 characters**, the sampling rule
    /// ``FilingMemory`` records and the one every weight here was tuned under. Enforced here, not
    /// trusted from the caller: `ContentSignalExtractor` returns up to five pages, and the line
    /// items on pages 2-5 pull unrelated folders close enough to drop a `.medium` margin to `.low`.
    static let contentSampleChars = 400

    /// A prepared inverted index, built once per scan, not per file, so a scan doesn't walk every
    /// folder's token list for every file.
    public struct Index: Sendable {
        let byAnchor: [String: [(folder: String, weight: Double)]]
        let byIdHash: [String: [(folder: String, weight: Double)]]
        let docs: [String: Int]
        let destinations: [String]
        let pathTokens: [String: Set<String>]
        let anchorTokens: [String: Set<String>]
        let yearKey: [String: String]
        /// Folder → the month it is a slot for (`05. May 2024` → 5), from its own name.
        let monthSlot: [String: Int]
        let roleBonus: [String: Double]
        let children: [String: [String]]
        let personTokens: Set<String>
        /// Folder → the registry person its `axes.person` resolves to. Only folders the registry
        /// can resolve appear; an axis naming someone outside it is left to the token fallback.
        let folderPerson: [String: String]
        let registry: PersonRegistry?
        let salt: String
        /// Name-token → folders, and year → folders. For speed, which matters: scoring names by
        /// walking every destination costs about 10 ms per file on a 3,000-folder tree, seconds of
        /// synchronous work per scan. Looking up by the file's own tokens touches a few hundred
        /// folders instead.
        let foldersByPathToken: [String: [String]]
        let foldersByYear: [String: [String]]
        /// Folder → its anchors, for recovering display evidence for the shown candidates.
        let anchorsByFolder: [String: [String: Double]]
        /// Folder → anchor → share of that folder's documents carrying it, where the memory records
        /// it. Read only by ``AutomationRuleProposer``: ranking a destination wants rarity, keying
        /// a rule wants recurrence.
        let docFrequencyByFolder: [String: [String: Double]]
        /// The same, for the hashed digit-bearing tokens. Separate because they are keyed and
        /// looked up by hash; one map would make every lookup know which kind it holds.
        let idDocFrequencyByFolder: [String: [String: Double]]
        /// Folder → the folders it is a stash of copies of. See ``SatelliteFolders``.
        let satelliteHomes: [String: Set<String>]

        public var isEmpty: Bool { destinations.isEmpty }
    }

    /// Prepares the index for one taxonomy. `destinations` is the caller's taxonomy; folders the
    /// profile forbids are dropped here, not at the call site, so no consumer can forget.
    public static func makeIndex(destinations: [String], profile: FolderProfile?,
                                 memory: FilingMemory?, registry: PersonRegistry? = nil,
                                 satelliteHomes: [String: Set<String>] = [:]) -> Index {
        // One rule, asked the same way everywhere; see ``FolderProfile/isInboxPath(_:)``.
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
        var monthSlot: [String: Int] = [:]
        var roleBonus: [String: Double] = [:]
        var children: [String: [String]] = [:]
        var foldersByPathToken: [String: [String]] = [:]
        var foldersByYear: [String: [String]] = [:]
        var folderPerson: [String: String] = [:]
        for f in allowed {
            let pt = FilingRouter.pathTokens(of: f)
            pathTokens[f] = pt
            if let base = f.split(separator: "/").last.map(String.init),
               let m = FilingPeriod.monthSlot(ofFolderNamed: base) {
                monthSlot[f] = m
                // A slot names its year (`05. May 2024`) even outside a year folder, so the year
                // axis reaches and judges it.
                if profile?.folders[f]?.yearKey == nil,
                   let y = base.split(whereSeparator: { !$0.isNumber }).first(where: { FilingRouter.isYearToken(String($0)) }) {
                    yearKey[f] = String(y)
                }
            }
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
        // Only pairs whose both ends survived the allow-list can fire, so a satellite whose home
        // was filtered out (an inbox, a forbidden folder) is not half-applied.
        let satellites = satelliteHomes.reduce(into: [String: Set<String>]()) { out, pair in
            guard allowedSet.contains(pair.key) else { return }
            let homes = pair.value.filter { allowedSet.contains($0) }
            if !homes.isEmpty { out[pair.key] = homes }
        }
        return Index(byAnchor: byAnchor, byIdHash: byIdHash, docs: docs, destinations: allowed,
                     pathTokens: pathTokens, anchorTokens: anchorTokens, yearKey: yearKey,
                     monthSlot: monthSlot, roleBonus: roleBonus, children: children,
                     personTokens: profile?.personTokens ?? [], folderPerson: folderPerson,
                     registry: registry, salt: memory?.salt ?? "",
                     foldersByPathToken: foldersByPathToken, foldersByYear: foldersByYear,
                     anchorsByFolder: anchorsByFolder, docFrequencyByFolder: docFrequencyByFolder,
                     idDocFrequencyByFolder: idDocFrequencyByFolder,
                     satelliteHomes: satellites)
    }

    /// Ranks destinations for one file. `contentSnippet` is page 1 only, as the profile assumes: a
    /// statement, form, letter or bill says what it is on page 1, and later pages are line items
    /// that change nothing.
    public static func rank(fileName: String, contentSnippet: String?, index: Index,
                            excluding: Set<String> = [], limit: Int = 5) -> Ranking {
        guard !index.isEmpty else { return .empty }
        let stem = (fileName as NSString).deletingPathExtension
        // Months and ordinals say when, not what (`05. May 2026`): kept out of the name evidence,
        // as a year is kept out of the category, unless the word names a person in this tree.
        let periodWords = FilingPeriod.periodTokens(inStem: stem, keeping: index.personTokens)
        let nameTokens = Set(tokenize(stem)).subtracting(periodWords)
        let fileMonth = FilingPeriod.month(inFileName: fileName)
        // The sample this scorer was measured on (``contentSampleChars``); whatever the caller
        // hands over, only this much is scored.
        let sample = contentSnippet.map { String($0.prefix(contentSampleChars)) }
        var contentTokens = nameTokens
        if let sample { contentTokens.formUnion(tokenize(sample)) }

        let yearsInName = nameTokens.filter(isYearToken)
        // **Years must be read from the document, not only the filename**: three `Lease
        // Agreement.pdf` files differ only by the term printed inside. Read from the text, not its
        // tokens: `tokenize` keeps `20NOV2026` (a visa foil's expiry) as one token that never looks
        // like a year, and `contentTokens` starts as a copy of `nameTokens`, so a token-based body
        // year would just count the filename's year twice.
        let yearsInBody = sample.map(yearsInText) ?? []

        // ---- content evidence -------------------------------------------------------------
        // Scoring keeps one number per folder. The winning anchor and the match count are recovered
        // at the end for the few folders shown, not tracked for the thousands a common word
        // touches.
        var content: [String: Double] = [:]
        for token in contentTokens {
            if isIdentifier(token) {
                let h = FilingMemory.hash(token, salt: index.salt)
                for (folder, weight) in index.byIdHash[h] ?? [] {
                    content[folder, default: 0] += weight * identifierBoost
                }
            }
            // A month word on the page is a date, not a topic: it reaches no folder's anchors.
            if FilingPeriod.isMonthWord(token), !index.personTokens.contains(token) { continue }
            for (folder, weight) in index.byAnchor[token] ?? [] {
                content[folder, default: 0] += weight
            }
        }
        for (folder, raw) in content {
            let n = max(index.docs[folder] ?? 1, 1)
            content[folder] = raw / Double(n).squareRoot()
        }

        // **Evidence has to reach folders that hold none of their own, or an empty folder is
        // unreachable.** `Home/Utilities/AT&T/2024` has no content yet while its siblings are full
        // of AT&T bills: content identifies the family, and the year axis below picks the member.
        //
        // A scoring folder shares with its siblings (through their parent) **and with its own
        // children**; both are load-bearing. `Immigration/Visa/US/H-1B Visa` holds every visa foil
        // while its per-era children hold none.
        //
        // **The share is proportional to the donor's score, not normalised.** Content scores reach
        // the hundreds, so a share normalised to [0, `inheritWeight`] would barely move a cold
        // folder.
        if !content.isEmpty {
            // Donors are read from a snapshot taken before any share lands, so evidence moves one
            // hop and can't cascade down a deep tree.
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
        // Only folders this file can reach are scored: ones sharing a name token, ones whose year
        // the file names, and ones content already put in play. Everything else scores zero or
        // loses anyway (a non-matching year is a penalty on a folder with nothing else), so walking
        // the whole tree only adds latency.
        var reachable = Set<String>()
        for t in nameTokens {
            if let fs = index.foldersByPathToken[t] { reachable.formUnion(fs) }
        }
        for y in yearsInName.union(yearsInBody) {
            if let fs = index.foldersByYear[y] { reachable.formUnion(fs) }
        }
        reachable.formUnion(content.keys)          // a wrong year must still penalise a live folder

        let people = nameTokens.intersection(index.personTokens)
        // Person identity, phrase-first, asked of the raw strings: "Daughter Father" must spend its
        // surname on Daughter, and a Set has lost the order that makes that possible. Detected once
        // per file, body included, so a scan whose page names its person routes between sibling
        // person buckets as a well-named file does.
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
            // The axis, where the registry resolves it: a match confirms, and a contradiction (the
            // document names people and this folder's person isn't among them) is the strongest
            // negative name evidence has. It is what routes `Son … Report Card.pdf` to `School/Son`
            // over a sibling with identical documents. Multi-person documents are safe: no penalty
            // for anyone the document names.
            //
            // **Computed before the early-outs below, and a reason to score the folder at all.**
            // Those guards drop folders the file name doesn't touch, which is exactly this case:
            // `Scan 2026-08-02.pdf` shares no token with `School/Son`, yet a page naming Son must
            // route there.
            var personDelta = 0.0
            if let fp = index.folderPerson[folder], !detectedPeople.isEmpty {
                personDelta = detectedPeople.contains(fp) ? 1.0 : -3.0
            }
            if let year = index.yearKey[folder] {
                if !yearsInName.isEmpty { s += yearInNameWeight * yearFit(year, yearsInName) }
                if !yearsInBody.isEmpty { s += yearInBodyWeight * yearFit(year, yearsInBody) }
                // A month slot is the year's member for that month: the right month confirms, a
                // different one rules the slot out the way a wrong year does.
                if let slot = index.monthSlot[folder], let fileMonth {
                    s += slot == fileMonth ? monthFitWeight : -yearInNameWeight
                }
            } else if s == 0, personDelta == 0 {
                continue
            }
            if s == 0, personDelta == 0 { continue }
            s += index.roleBonus[folder] ?? 0
            if !people.isEmpty, !people.isDisjoint(with: pathToks) { s += 2.0 }
            name[folder] = s + personDelta
        }

        // ---- blend --------------------------------------------------------------------------
        // Both sides are normalised to [0, 1] first. Adding raw scores would let content outvote
        // the profile exactly where the profile is the only signal, such as a folder with nothing
        // filed yet.
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

        // **A folder does not outrank the folder it is a stash of copies of.** Applied here, not by
        // the callers (`rank` has two, and one could forget), and to the scores rather than the
        // final order, so the margin below reflects what the ranking claims.
        //
        // A demotion, not a removal: the satellite stays on the card as an alternate, since the
        // relation says which folder is home, not that a document may never be copied into a
        // petition packet.
        //
        // Fires only when both ends are in play for the same file. Leave-one-out can't score it:
        // the corpus files those documents in the satellite, so a replay counts every demotion as a
        // regression. It exists for a document arriving for the first time, which the corpus never
        // holds.
        if !index.satelliteHomes.isEmpty {
            // Read from a snapshot, so a chain (A copies B, B copies C) settles against the scores
            // as ranked, not against a partly demoted set.
            let scored = total
            for (satellite, homes) in index.satelliteHomes {
                guard let own = scored[satellite] else { continue }
                guard let best = homes.compactMap({ scored[$0] }).max(), best < own else { continue }
                total[satellite] = best * 0.99
            }
        }
        guard !total.isEmpty else { return .empty }

        // Top-k by selection, not sorting: a document puts thousands of folders in play and only
        // five are shown, and a full `sorted()` would be the largest cost in this function.
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
        let margin = Self.margin(top: best[0].value, runnerUp: best.count > 1 ? best[1].value : nil)
        let candidates = best.prefix(limit).map { entry -> Candidate in
            let (token, hits) = evidence(for: entry.key, tokens: contentTokens, index: index)
            return Candidate(relativePath: entry.key, score: entry.value,
                             evidenceToken: token, sharedAnchors: hits)
        }
        return Ranking(candidates: Array(candidates), margin: margin)
    }

    /// How separated the winner is: `(top − runnerUp) / top`, and 1.0 when it runs unopposed.
    ///
    /// **A top score of zero or less is not a winner but the last folder standing.** Name scores go
    /// negative (a wrong-year `yearFit`, a person contradiction), and `excluding` ("Try another"'s
    /// refusals) is applied after the blend, so in principle every positive can be removed and
    /// leave a penalised folder on top. Answering 1.0 there would make it `.high`, and `route`
    /// treats a `.high` with no evidence token as not `fromContent`, so blind-batch eligible. Zero
    /// is `.low`: offered, never filed unseen. No `rank` fixture has reached `top <= 0` (the
    /// blend's normalisation keeps pulling the survivor above zero), so this is a guard, named so
    /// it can be tested directly.
    static func margin(top: Double, runnerUp: Double?) -> Double {
        guard top > 0 else { return 0 }
        guard let runnerUp else { return 1.0 }
        return (top - runnerUp) / top
    }

    /// The heaviest anchor this file shares with `folder`, and how many it shares, computed for the
    /// shown candidates only. Ties break on the token so a card's evidence chip is the same every
    /// run: `contentTokens` is a Set, and its order isn't.
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
    // split differently (`pg&e` → `pg`, `e`) simply never matches: fewer hits, lower accuracy, no
    // error.

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

    /// Digit-bearing and long enough to discriminate: an account last-4, a case number, a claim id.
    static func isIdentifier(_ t: String) -> Bool {
        t.count >= 4 && t.contains(where: \.isNumber)
    }

    /// A folder's own name tokens, plus the punctuation-free form of each word in it.
    /// `tokenize("H-1B Visa")` is `["1b", "visa"]`, so without `h1b` a file called `H1B Visa - Nov
    /// 2026.pdf` would score its branch no better than `H-4 Visa`. Index-side only, which keeps it
    /// safe: these come from folder names, not ``FilingMemory``, so they can't disagree with the
    /// builder. That is why ``tokenize`` itself stays as it is.
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

    /// Every year the text prints, found without ``tokenize``. A separate reader because changing
    /// the tokenizer would silently stop stored anchors matching; years never feed anchor lookup.
    ///
    /// A year is a four-digit `19xx`/`20xx` run that isn't part of a longer digit run: it finds
    /// `2026` in `20NOV2026` and refuses `2024` in the control number `20241808200001`.
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

    /// Text whose glyphs arrive one per field (`0 3 J U L 2 0 2 4`), put back together. A real
    /// extraction artifact that can hide an issue date. Joins any run of four or more
    /// single-character fields, which can't damage a year that was already contiguous.
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

    /// Re-orders a ranking by how well each candidate's existing file names cover the incoming one.
    ///
    /// **Only between a folder and its own ancestor or descendant**, which is what makes it safe. A
    /// folder and its subfolder share vocabulary, so content can't separate them
    /// (`Immigration/OCI/Son` and its `Application` child scored within 1% for `Son OCI
    /// Photo.jpg`), while their file names can. Between unrelated folders the bonus is noise:
    /// across a whole shortlist it moved held-out and tune accuracy in opposite directions.
    ///
    /// **Coverage of the incoming name, not Jaccard.** `Son OCI Photo - 4up print sheet` covers all
    /// of `Son OCI Photo`, `Son OCI.pdf` two thirds; Jaccard scores both 0.67 and picks the wrong
    /// folder.
    ///
    /// `namesInFolder` is injected because this module doesn't touch the filesystem; see
    /// ``FileSyncManager/peerNameLookup()`` for the listing and `route(_:index:…)` for the one
    /// caller.
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
        // Ties break on the path, as in `rank`, so a re-order is reproducible.
        let sorted = rescored.sorted { a, b in
            a.1 == b.1 ? a.0.relativePath < b.0.relativePath : a.1 > b.1
        }
        guard sorted.count > 1, sorted[0].1 > 0 else { return ranking }
        let margin = Self.margin(top: sorted[0].1, runnerUp: sorted[1].1)
        return Ranking(candidates: sorted.map { Candidate(relativePath: $0.0.relativePath,
                                                          score: $0.1,
                                                          evidenceToken: $0.0.evidenceToken,
                                                          sharedAnchors: $0.0.sharedAnchors) },
                       margin: margin)
    }

    /// How much a fully covering peer name is worth. Swept on both splits and flat within ±0.1 once
    /// scoped to one branch, so it is set to what separates the case it exists for.
    static var peerWeight: Double { 0.30 }
}
