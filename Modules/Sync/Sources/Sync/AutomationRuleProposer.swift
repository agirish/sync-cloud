import Foundation

/// Turns a single "the user filed THIS file into THAT folder" example into a proposed
/// ``AutomationRule`` — the deterministic, learn-by-example complement to the AI filing backend.
///
/// **What a proposal keys on is the same evidence Organize's own suggestions key on.** This used to
/// pick ONE word: a token the file name shared with the destination's name, or failing that the
/// longest word in the name. That is precisely the signal ``FilingRouter`` measured at **12.6%
/// top-1** — a file name against a bare folder list — and every rule learned from it inherited that
/// accuracy. `*Statement*` → `Finance/US/Chase` is not a rule about Chase statements; it is a rule
/// about the word "statement", and the next payslip, lease and utility bill carrying that word go
/// to Chase too.
///
/// So a proposal is built from ``FilingMemory`` and ``FolderProfile`` — what the destination has
/// actually *received* — which took the same routing decision to **58.2%**:
///
/// - **Several words, not one.** A rule keys on a conjunction (``AutomationCondition/mentionsAll``),
///   so `mobile` ∧ `autopay` names T-Mobile bills rather than everything mentioning either.
/// - **Words that COME BACK, ranked by how well they discriminate — in that order.** The first cut
///   ranked candidates by the memory's weight, which is rarity, which is a direct measure of *least
///   likely to be seen again*: `Home/Utilities/T-Mobile/2025` weighs `awesome` (0.67 of its bills,
///   one marketing campaign) and `appreciation` (0.33) above `autopay` and `paying`, which are in
///   **every** bill it has ever held. So recurrence is a *filter* (``recurrenceFloor``) and rarity
///   is the *ranking* inside it — the conjunction, not the individual word, supplies specificity.
/// - **The pair is chosen, not two independent words** — see ``discriminatingPair(_:index:)``.
///
/// Measured end-to-end by replaying **1,428 real filings** from a 10,411-document tree, each rule
/// evaluated against every other document in it (leave-one-out; the shipping Swift, not a model of
/// it — they agree to 0.1 of a point):
///
/// | | recall | precision | matches nothing, ever |
/// |---|---|---|---|
/// | ranked by weight (before) | 44.9% | 53.1% | **7.8%** |
/// | recurrence floor ＋ chosen pair | **67.2%** | **54.4%** | **1.3%** |
///
/// Recall is "will it ever fire again for a file that belongs there"; precision is "of the files it
/// takes, how many belong". The old rule bought its precision by keying on words so rare that one
/// rule in thirteen could never match anything again.
/// - **Rejected when it is not discriminating at all.** A word carried as an anchor by hundreds of
///   folders cannot route anything; the memory's posting list says how many, and that is the test.
/// - **Content counts, not just the name.** The page the scan already read is a first-class source,
///   so a file called `Scan 2026-03-02.pdf` can still seed a real rule.
/// - **Inherited from the parent when the folder is cold.** A rule is learned for exactly the
///   recurring document whose home is `…/T-Mobile/{year}` — a bucket that is empty in January and
///   has no anchors of its own. Its parent's do the naming, the same way ``FilingRouter/rank``
///   inherits evidence.
/// - **Verified against its own example.** Every variant is run through ``AutomationEvaluator``
///   against the file it was learned from; one that does not match is never offered. This is not
///   ceremony: the memory's anchors were tokenized by ``FilingRouter/tokenize`` while `mentionsAll`
///   matches on ``FilingEngine/nameTokens``, and a word only the first of those produces would mint
///   a rule that is inert from birth.
///
/// With no profile loaded — the ordinary state, and every install that has never run the memory
/// builder — the name/kind heuristics below are exactly what they always were.
///
/// Pure and framework-free so it's unit-testable and lives in Sync.
public enum AutomationRuleProposer {

    /// One way to phrase the rule, as a complete set of conditions (ALL of which must hold).
    ///
    /// Variants replace the old "pick one of name / content / kind": a sophisticated rule is a
    /// *conjunction*, and the choice a person actually wants to make is how tightly to draw it —
    /// which the ordering below offers as narrower / balanced / broader rather than as three
    /// unrelated conditions.
    public struct Variant: Sendable, Equatable, Hashable, Identifiable {
        public let conditions: [AutomationCondition]
        /// Compact text for the picker chip, e.g. `“tmobile” + “autopay”`. The full sentence is
        /// ``summary``; the chip has to fit three-across in an inline prompt.
        public let chipLabel: String
        /// A destination this phrasing needs instead of the proposal's.
        ///
        /// nil for every phrasing that files where the example went — which is all of them except
        /// the `{person}` fan-out, whose whole point is that it files somewhere the example did
        /// NOT: one rule that sends each person's copy to their own folder. A variant that changes
        /// where files land has to say so, or picking it would silently keep the literal folder.
        public let destinationTemplate: String?

        public var id: [AutomationCondition] { conditions }

        /// The plain-words sentence, e.g. `mentions “tmobile” and “autopay” · kind is PDF`.
        public var summary: String { conditions.map(\.summary).joined(separator: " · ") }

        public init(conditions: [AutomationCondition], chipLabel: String,
                    destinationTemplate: String? = nil) {
            self.conditions = conditions
            self.chipLabel = chipLabel
            self.destinationTemplate = destinationTemplate
        }
    }

    /// A proposed rule plus the other ways the user can phrase it (for the inline "Save a rule?"
    /// offer). `rule` already carries `conditions == variants[0].conditions`.
    public struct Proposal: Sendable, Equatable {
        public let rule: AutomationRule
        /// Ways to phrase the rule, best first. Never empty.
        public let variants: [Variant]
        public let destinationTemplate: String

        /// The variant presented first (also the one in `rule`).
        public var defaultVariant: Variant { variants[0] }
    }

    /// What the scan already knows about this file and this tree. Every field is optional: a
    /// proposal with none of it is the filename-and-extension heuristic this always had.
    public struct Evidence: Sendable {
        /// The document's first page as the scan read it — the same text ``FilingRouter`` scores,
        /// bounded to ``FilingRouter/contentSampleChars`` here so a caller handing over a whole
        /// document cannot silently change which words a rule keys on.
        public var pageSample: String?
        /// The prepared profile + memory index for the tree being filed into.
        public var index: FilingRouter.Index?
        /// The rules already saved, so an offer that is already covered isn't made twice.
        public var existingRules: [AutomationRule]

        public init(pageSample: String? = nil, index: FilingRouter.Index? = nil,
                    existingRules: [AutomationRule] = []) {
            self.pageSample = pageSample
            self.index = index
            self.existingRules = existingRules
        }
    }

    /// English/tech stop-words and generic filing words that make useless match tokens on their own.
    ///
    /// Retained for the no-memory path only. Where a memory exists this list is not the authority —
    /// ``anchorBreadthCeiling`` is, because "generic" is a property of *this* tree ("insurance" is
    /// a generic word in a tree with 40 insurance folders and a perfectly good key in one with a
    /// single `Home/Insurance`), and a fixed list cannot know that.
    private static let stopTokens: Set<String> = [
        "the", "and", "for", "with", "from", "copy", "final", "draft", "new", "old", "doc",
        "document", "file", "scan", "img", "image", "photo", "untitled", "report", "bill",
        "invoice", "receipt", "statement", "letter", "note", "notes",
    ]

    /// How many folders may carry a word as an anchor before it is refused as a rule key.
    ///
    /// A word the memory records for 400 of 3,000 folders discriminates nothing — matching it is
    /// close to matching every document — while a word recorded for two folders all but names one.
    /// Scaled to the tree so it means the same thing in a 200-folder tree as in a 3,000-folder one,
    /// with a floor so a small tree doesn't refuse every word it has.
    static func anchorBreadthCeiling(destinations: Int) -> Int {
        max(20, destinations / 50)
    }

    /// Proposes a rule for `fileName` filed into `destinationRelativePath` (provider-root-relative,
    /// e.g. "Home/Utilities/T-Mobile"). Returns nil when the destination is empty (nothing to file
    /// into), when nothing distinctive can be keyed on, or when a saved rule already covers this
    /// example.
    public static func propose(fileName: String,
                               destinationRelativePath: String,
                               evidence: Evidence = Evidence(),
                               modificationDate: Date? = nil,
                               now: Date = Date()) -> Proposal? {
        let dest = destinationRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !dest.isEmpty else { return nil }
        // A relative destination is stored as a TEMPLATE, and the evaluator surfaces any leftover
        // `{…}` as an unresolvable token — deliberately, so a user's typo'd `{yaer}` is reported
        // rather than guessed at. But this path is not a template the user typed: it is the literal
        // name of a folder they just filed into, and a real folder may legitimately be called
        // "Q3 {final}". Proposing it would mint a rule that can never run — every dry run reporting
        // it "needs {final}, which this file doesn't have" — with no way to express the real folder
        // short of renaming it. `resolveDestination`'s carve-out only exempts ABSOLUTE literals, so
        // decline instead of offering a rule that is inert from birth. Same call as the
        // extension-less fallback below: no offer beats a bad one.
        guard !dest.contains("{"), !dest.contains("}") else { return nil }

        // Applied to the TEMPLATE only: the conditions below are derived from the folder's real
        // name, and the brace guard above is about a folder literally called "Q3 {final}".
        let template = generalizingTrailingYear(in: dest, fileName: fileName,
                                                modificationDate: modificationDate, now: now)

        // The facts the offered rule is checked against — the same shape both surfaces evaluate,
        // so "it matches its own example" means what it says.
        let facts = exampleFacts(fileName: fileName, destination: dest, evidence: evidence,
                                 modificationDate: modificationDate)

        // Already covered? A saved, runnable rule that matches this very file and lands it in this
        // very folder has nothing to teach, and offering it again is how a user ends up with four
        // rules that say the same thing.
        if AutomationRuleSet.eligible(evidence.existingRules).rules.contains(where: {
            $0.destinationTemplate == template
                && AutomationEvaluator.matches($0, facts, now: now)
        }) { return nil }

        let keys = rankedKeys(dest: dest, evidence: evidence, facts: facts)
        let kind = FileKind.of(fileName: fileName)
        var variants = phrasings(keys: keys, kind: kind, fileName: fileName, index: evidence.index)
        // Offered FIRST when they apply, because they are the better rule: a person bucket is the
        // one destination whose defining axis a word-based rule cannot express.
        variants = personVariants(dest: dest, template: template, facts: facts,
                                  keys: keys, evidence: evidence) + variants

        // **Every variant has to match the file it was learned from.** The two tokenizers in play
        // do not agree word for word (see the type doc), and a proposal that cannot match its own
        // example is worse than no proposal: it is saved, reviewed, enabled, and silently never
        // fires.
        variants = variants.filter { variant in
            let probe = AutomationRule(name: "probe", matchMode: .all, conditions: variant.conditions,
                                       destinationTemplate: variant.destinationTemplate ?? template)
            guard AutomationEvaluator.matches(probe, facts, now: now) else { return false }
            // A variant that redirects has to RESOLVE too, and to the folder the example actually
            // went to. `{person}` reproducing `Immigration/OCI/Daughter` is the claim being made; if
            // it resolved anywhere else the offer would quietly re-file the example.
            guard let redirected = variant.destinationTemplate else { return true }
            guard case .resolved(let path) = AutomationEvaluator.resolveDestination(
                    redirected, for: facts, providerName: nil, now: now)
            else { return false }
            return path == dest
        }
        // Two phrasings can collapse to the same conditions (one key, or no kind to add); keep the
        // first, which is the better-ranked one.
        var seen = Set<[AutomationCondition]>()
        variants = variants.filter { seen.insert($0.conditions).inserted }
        guard let best = variants.first else { return nil }

        let rule = AutomationRule(name: ruleName(keys: keys, dest: dest, template: template),
                                  matchMode: .all,
                                  conditions: best.conditions,
                                  destinationTemplate: best.destinationTemplate ?? template)
        return Proposal(rule: rule, variants: variants, destinationTemplate: template)
    }

    // MARK: - Choosing what to key on

    /// One candidate rule key: how well it discriminates, and how often it comes back.
    struct Key: Equatable {
        let token: String
        let score: Double
        /// Share of the destination's filed documents that contain this word — see
        /// ``recurrenceOf(_:dest:index:)``. 0 when there is no memory to ask.
        var recurrence: Double = 0

        /// Whether something in the tree actually vouches for this word — a memory anchor, the
        /// folder's own name, or an identifier the folder has received before.
        ///
        /// **Only supported words may be conjoined.** The unsupported ones score on length alone
        /// (the no-memory fallback), and pairing two of those produces a rule keyed on an incidental
        /// word: `T-Mobile-bill-Mar.pdf` would learn `mentions “mobile” and “mar”`, which files
        /// March and nothing else. One such word can carry a rule; two cannot.
        var isSupported: Bool { score >= supportFloor }
    }

    /// How much of the destination's filed documents a word must appear in before it may key a rule.
    ///
    /// **This is the difference between a rule and a souvenir.** Swept over 1,428 real filings,
    /// F1 of the offered pair against the rest of the tree:
    ///
    /// | floor | 0 | 0.4 | 0.5 | **0.6** | 0.75 | 0.9 | 1.0 |
    /// |---|---|---|---|---|---|---|---|
    /// | F1 | 57.4 | 58.0 | 58.2 | **60.2** | 60.0 | 59.4 | 59.0 |
    /// | never fires | 4.8% | 4.0% | 4.0% | **1.2%** | 1.3% | 1.8% | 1.8% |
    ///
    /// A real peak rather than a slope: below it the rare words come back, above it the pool thins
    /// to words so common that precision starts paying for recall (71.2% / 50.4% at 1.0). Note that
    /// even floor 0 beats the shipped 48.7 — most of that gain is the *pair* being chosen rather
    /// than the words being filtered — but the floor is what takes "never fires again" from one
    /// rule in twenty-one to one in eighty.
    static let recurrenceFloor = 0.6

    /// The score below which a key is a guess rather than evidence — see ``Key/isSupported``.
    ///
    /// Naming the folder scores 2.0 and a known identifier 4.0, so both clear it outright; the
    /// length fallback lands at 0.0x by construction and never does. An anchor carries the weight
    /// the memory recorded, which is a rarity score — one below 1.0 is a word this tree barely
    /// distinguishes anything by, and belongs on the guess side of the line with the fallback.
    static let supportFloor = 1.0

    /// The words worth keying a rule on, strongest first.
    ///
    /// Candidates come from the domain that will do the *matching* — `FilingEngine.fileTokens` for
    /// the name and `FilingEngine.nameTokens` for the page — and are scored from the domain that
    /// has the *weights*, the memory's anchors. Picking from the scoring domain instead was the
    /// available shortcut and the wrong one: it yields words the evaluator never produces.
    ///
    /// **`score` ranks how well a word DISCRIMINATES, which is not the same question as whether it
    /// will ever be seen again.** An anchor's weight is its rarity, so ranking by it ranks by
    /// *least likely to recur*: `Home/Utilities/T-Mobile/2025`'s heaviest anchors are `awesome`
    /// (5.95, one marketing campaign) and `unlimited` (5.25), while `autopay` and `mobile` — in
    /// every bill the folder has ever received — rank below them. Measured over 1,432 real filings,
    /// keying on the two heaviest words made a rule that matched **nothing else in the tree 7.8% of
    /// the time** and recovered only 44.5% of the documents it should. So this is only half the
    /// input: ``recurrenceOf(_:dest:index:)`` supplies the other half, and ``rankedKeys`` returns
    /// both for the picker to weigh.
    static func rankedKeys(dest: String, evidence: Evidence, facts: AutomationFileFacts) -> [Key] {
        let nameTokens = facts.nameTokens
        let bodyTokens = facts.contentTokens
        let index = evidence.index
        // The folder's own name is a signal in its own right (it is the only one the no-memory path
        // has), read the same way the router reads it so `H-1B` and `H1B` are one folder.
        let destTokens = FilingRouter.pathTokens(of: dest)
        let anchors = anchorWeights(for: dest, index: index)
        let ceiling = anchorBreadthCeiling(destinations: index?.destinations.count ?? 0)

        var keys: [Key] = []
        for token in nameTokens.union(bodyTokens) {
            // A year is what `{year}` is for. Keying on one freezes the rule to a single year's
            // documents — the same defect `generalizingTrailingYear` exists to prevent, arriving
            // through the condition instead of through the destination.
            if FilingRouter.isYearToken(token) { continue }
            var score = 0.0
            if FilingRouter.isIdentifier(token) {
                // A digit-bearing word is either the best key there is or the worst. A receipt
                // number the destination's filed documents already carry names that folder alone;
                // the same shape from an invoice number nothing has seen before makes a rule that
                // matches exactly one file, forever. The memory decides which it is.
                //
                // A *bare* number never gets this far whatever the memory says — `fileTokens` keeps
                // only years among pure digits, so `mentionsAll` could not answer it. The
                // verification pass drops it if it ever does.
                guard let index, let weight = identifierWeight(token, dest: dest, index: index)
                else { continue }
                // Weighted exactly as `FilingRouter.rank` weights an identifier hit, so the word
                // that most nearly names this folder on its own also ranks first here.
                score += weight * FilingRouter.identifierBoost
            }
            if let weight = anchors[token] { score += weight }
            if destTokens.contains(token) { score += 2.0 }
            if score == 0 {
                // Nothing in the tree vouches for this word. With a memory loaded that is a verdict;
                // without one, fall back to the old shape — a long, non-generic word is all there is.
                guard index == nil, token.count >= 3, !stopTokens.contains(token) else { continue }
                score = Double(token.count) / 100.0        // longest-wins, below every real signal
            }
            // Breadth is a veto, not a penalty: a word hundreds of folders are known by cannot
            // route, however heavily this one folder happens to weight it.
            if let index, let postings = index.byAnchor[token], postings.count > ceiling { continue }
            keys.append(Key(token: token, score: score,
                            recurrence: recurrenceOf(token, dest: dest, index: index)))
        }
        // Ties break on the token so an offer is the same on every run — a Set's order is not.
        return keys.sorted { $0.score != $1.score ? $0.score > $1.score : $0.token < $1.token }
    }

    /// How often this word comes back: the share of the destination's already-filed documents whose
    /// first page contains it, and the answer to "will this rule ever fire again".
    ///
    /// **Read from the memory when it records it, estimated from the family when it does not.** The
    /// builder counts the documents a token appears in — that is where `weight`'s own term-frequency
    /// half comes from — and now stores the share alongside it. An artifact built before that has no
    /// `df`, so the fallback asks the folder's family instead: of the sibling folders that carry
    /// anchors at all (`Home/Utilities/T-Mobile/2022…2025`), how many list this word? `autopay` is
    /// in four of them and `awesome` in two, which separates a recurring word from a one-off without
    /// any change to the file. Measured, the recorded share is worth ~9 points of F1 over the
    /// estimate — enough to be worth rebuilding the memory for, and not enough to make an old
    /// artifact useless.
    static func recurrenceOf(_ token: String, dest: String, index: FilingRouter.Index?) -> Double {
        guard let index else { return 0 }
        let source = anchorSource(for: dest, index: index) ?? dest
        if let recorded = index.docFrequencyByFolder[source]?[token] { return recorded }
        // A digit-bearing word is stored hashed, on the other list, and its share is recorded there.
        // Without this it can never clear the floor — an account number is not an *anchor*, so the
        // readable map has nothing to say about it, and the one class of word that most nearly names
        // a folder on its own would be filtered out of every rule.
        if FilingRouter.isIdentifier(token) {
            let hashed = FilingMemory.hash(token, salt: index.salt)
            if let recorded = index.idDocFrequencyByFolder[source]?[hashed] { return recorded }
            // Recorded by an artifact that predates the share: reaching this line at all means the
            // folder has already received this identifier (the caller checked), and the builder only
            // records one that recurred in any folder big enough to say so. Treat that as evidence
            // rather than dropping the strongest key a rule can have.
            if identifierWeight(token, dest: dest, index: index) != nil { return 1.0 }
        }
        // No recorded share: how much of this folder's family is known by the word?
        let parent = source.contains("/") ? String(source[source.startIndex..<source.lastIndex(of: "/")!]) : source
        var family = Set(index.children[parent] ?? [])
        family.insert(parent)
        family.formUnion(index.children[source] ?? [])
        family.insert(source)
        let known = family.filter { !(index.anchorsByFolder[$0]?.isEmpty ?? true) }
        guard !known.isEmpty else { return 0 }
        return Double(known.filter { index.anchorsByFolder[$0]?[token] != nil }.count) / Double(known.count)
    }

    /// The anchors that name `dest`, inherited from the nearest ancestor that has any.
    ///
    /// **A cold folder has no anchors of its own, and it is the folder rules are for.** The home of
    /// a recurring document is `Home/Utilities/T-Mobile/{year}`, whose current-year bucket holds
    /// nothing in January — so scoring it on its own content gives every candidate word zero and
    /// the proposal falls back to the filename. Its parent holds twelve bills a year. Same rule,
    /// and the same reason, as the inheritance in ``FilingRouter/rank``.
    static func anchorWeights(for dest: String, index: FilingRouter.Index?) -> [String: Double] {
        guard let index, let source = anchorSource(for: dest, index: index) else { return [:] }
        return index.anchorsByFolder[source] ?? [:]
    }

    /// The folder whose anchors describe `dest` — itself, or the nearest ancestor that has any.
    /// Recurrence has to be read from the same folder the weights came from, or a cold bucket
    /// scores its parent's words against its own (empty) document count.
    static func anchorSource(for dest: String, index: FilingRouter.Index) -> String? {
        var path = dest
        while true {
            if let own = index.anchorsByFolder[path], !own.isEmpty { return path }
            guard let slash = path.lastIndex(of: "/") else { return nil }
            path = String(path[path.startIndex..<slash])
        }
    }

    /// How heavily the destination — or an ancestor, for the same cold-folder reason anchors are
    /// inherited — is known by this identifier, or nil when it has never received one.
    static func identifierWeight(_ token: String, dest: String, index: FilingRouter.Index) -> Double? {
        guard let postings = index.byIdHash[FilingMemory.hash(token, salt: index.salt)] else { return nil }
        return postings
            .filter { $0.folder == dest || dest.hasPrefix($0.folder + "/") }
            .map(\.weight)
            .max()
    }

    // MARK: - Choosing the conjunction

    /// The words that come back often enough to key a rule on, best first.
    ///
    /// **Filter by recurrence, rank by discrimination — in that order.** The two questions a rule
    /// has to answer are "will it fire again?" and "will it only take the right files?", and they
    /// pull opposite ways: the rarest word discriminates best and recurs worst. Ranking on a blend
    /// tries to serve both with one number and serves neither (measured: F1 50.9 against 48.6 for
    /// the weight-only ranking, when the achievable figure is 63). Filtering first and ranking
    /// second gets 57–60, because the conjunction — not the individual word — is what supplies the
    /// specificity, and a word only has to survive the floor to be allowed to do its job.
    static func recurringKeys(_ keys: [Key]) -> [Key] {
        let recurring = keys.filter { $0.recurrence >= recurrenceFloor }
        // No memory, or nothing clears the floor: fall back to the plain ranking rather than
        // refusing to propose. An install with no profile has no recurrence to read at all.
        return recurring.isEmpty ? keys : recurring
    }

    /// The two words to conjoin: the most recurring pair, and among equals the pair that reaches the
    /// fewest folders between them.
    ///
    /// **A rule files on the conjunction, so the conjunction is what has to be chosen.** Picking the
    /// two best words independently picks two words that often describe the same thing — `autopay`
    /// and `paying` are anchors of the same fourteen folders, so requiring both narrows nothing.
    /// The memory already says which folders each word is an anchor of, so the overlap of two
    /// posting lists is a free estimate of how much the pair still lets through.
    ///
    /// **Recurrence is compared in half-steps, and that ordering is the whole design.** Sorting on
    /// raw overlap first is a second rarity ranking wearing a different hat — it re-prefers the
    /// scarce word the floor was put there to demote (65.6% recall / 55.0% precision). Sorting on
    /// raw recurrence first spends precision on differences of a twelfth of a folder's documents
    /// (71.9% / 51.7%). Rounding to the nearest half treats 1.0 and 0.9 as the same answer and lets
    /// overlap decide between them: **67.3% / 54.5%, the best of the three (F1 60.2 against 59.8
    /// and 60.1)** — a small margin honestly, and the reason to prefer it over raw-recurrence is
    /// that it is the one that does not systematically drift toward either failure.
    ///
    /// Bounded to the strongest few candidates — this is quadratic, and a document's page routinely
    /// offers a dozen words that clear the floor.
    static func discriminatingPair(_ keys: [Key], index: FilingRouter.Index?) -> [String] {
        let pool = Array(keys.prefix(pairSearchPool))
        guard pool.count >= 2 else { return pool.map(\.token) }
        guard let index else { return pool.prefix(2).map(\.token) }
        var best: [String] = []
        var bestKey: (Double, Int, Double, String, String)?
        for i in pool.indices {
            for j in pool.index(after: i)..<pool.endIndex {
                let a = pool[i], b = pool[j]
                let fa = Set((index.byAnchor[a.token] ?? []).map(\.folder))
                let fb = Set((index.byAnchor[b.token] ?? []).map(\.folder))
                // Ties break on weight and then on the tokens — so the offer is the same on every
                // run whatever order the candidates arrived in.
                let key = (-(((a.recurrence + b.recurrence) * 2).rounded() / 2),
                           fa.intersection(fb).count,
                           -(a.score + b.score),
                           a.token, b.token)
                if bestKey == nil || isLower(key, than: bestKey!) {
                    bestKey = key
                    best = [a.token, b.token]
                }
            }
        }
        return best
    }

    /// Lexicographic comparison of the pair-ranking key. Swift compares tuples of up to six
    /// elements, but only when every element is `Comparable` in the same way — spelled out here so
    /// the ordering is readable rather than inferred.
    private static func isLower(_ a: (Double, Int, Double, String, String),
                                than b: (Double, Int, Double, String, String)) -> Bool {
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        if a.2 != b.2 { return a.2 < b.2 }
        if a.3 != b.3 { return a.3 < b.3 }
        return a.4 < b.4
    }

    /// How many candidates the pair search considers. Quadratic, and the words below the top few
    /// are there to be a third option rather than a serious pair.
    static let pairSearchPool = 8

    // MARK: - Phrasing

    /// The ways to phrase the rule, from the keys, best first.
    ///
    /// The ordering is deliberate: **two words is the default**, and the width sweep is not close —
    /// one word takes 73.5% of the right files but only 34.7% of what it takes belongs (F1 47.2),
    /// three takes 63.0% at 56.0% (F1 59.3), two takes 67.3% at 54.5% (**F1 60.2**). Narrower and
    /// broader are offered either side of it because the trade is real and which way to lean is the
    /// user's call, not this function's.
    static func phrasings(keys allKeys: [Key], kind: FileKind?, fileName: String,
                          index: FilingRouter.Index?) -> [Variant] {
        var out: [Variant] = []
        let keys = recurringKeys(allKeys)
        let tokens = keys.map(\.token)
        if keys.count >= 2, keys[0].isSupported, keys[1].isSupported {
            let pair = discriminatingPair(keys, index: index)
            out.append(Variant(conditions: [.mentionsAll(pair)], chipLabel: quoted(pair)))
            // Narrower: a third recurring word if there is one — measured 53.0% precision against
            // the pair's 54.1%, so it is a real alternative rather than a strictly worse one, and
            // it is what a person reaches for when the pair took something it shouldn't. Only the
            // kind when there is no third word left.
            if let third = keys.first(where: { !pair.contains($0.token) })?.token {
                let triple = pair + [third]
                out.append(Variant(conditions: [.mentionsAll(triple)], chipLabel: quoted(triple)))
            } else if let kind {
                out.append(Variant(conditions: [.mentionsAll(pair), .kindIs(kind)],
                                   chipLabel: "\(quoted(pair)) + \(kind.label)"))
            }
            out.append(Variant(conditions: [.mentionsAll([pair[0]])], chipLabel: quoted([pair[0]])))
        } else if let only = tokens.first {
            out.append(Variant(conditions: [.mentionsAll([only])], chipLabel: quoted([only])))
            if let kind {
                out.append(Variant(conditions: [.mentionsAll([only]), .kindIs(kind)],
                                   chipLabel: "\(quoted([only])) + \(kind.label)"))
            }
            // The old phrasing, kept as the loosest option: a glob matches a word inside a longer
            // one (`*mobile*` catches `T-Mobile`), which is sometimes exactly what a person means.
            out.append(Variant(conditions: [.nameMatches("*\(only)*")], chipLabel: "name *\(only)*"))
        }
        if out.isEmpty, let kind {
            out.append(Variant(conditions: [.kindIs(kind)], chipLabel: kind.label))
        }
        // Guarantee at least one condition — a name glob on the extension. With no distinctive
        // word, no content match, AND no extension to anchor on, the only fallback would be
        // `name matches *` — a match-EVERYTHING rule that files every loose file into this folder.
        // One token-less, extension-less example (e.g. "ab", "2024") isn't enough signal to learn a
        // rule from, so decline to propose rather than offer a dangerous universal glob.
        if out.isEmpty {
            let ext = (fileName as NSString).pathExtension
            guard !ext.isEmpty else { return [] }
            out.append(Variant(conditions: [.nameMatches("*.\(ext)")], chipLabel: "*.\(ext)"))
        }
        return out
    }

    private static func quoted(_ tokens: [String]) -> String {
        tokens.map { "“\($0)”" }.joined(separator: " + ")
    }

    /// The rule's display name — the folder it files into, which is what a person calls the rule
    /// ("T-Mobile"), falling back to the words it keys on. `{year}` and friends are skipped: a rule
    /// called "{year}" names nothing.
    static func ruleName(keys: [Key], dest: String, template: String) -> String {
        let literal = template.split(separator: "/").map(String.init)
            .last(where: { !$0.contains("{") })
        if let literal, !literal.isEmpty { return literal }
        if let first = keys.first?.token { return first.capitalized }
        return (dest as NSString).lastPathComponent
    }

    // MARK: - The example, as the evaluator sees it

    /// The filed file as ``AutomationFileFacts`` — name, kind, and the page the scan read, reduced
    /// to content tokens exactly as both live surfaces reduce them (`FilingEngine.nameTokens` over
    /// the extracted text). A rule verified against these facts behaves the same way in the
    /// Automations dry run and in the next Organize scan.
    static func exampleFacts(fileName: String, destination: String, evidence: Evidence,
                             modificationDate: Date?) -> AutomationFileFacts {
        let sample = evidence.pageSample.map { String($0.prefix(FilingRouter.contentSampleChars)) }
        return AutomationFileFacts(
            path: destination + "/" + fileName,
            name: fileName,
            parentFolderName: (destination as NSString).lastPathComponent,
            parentPath: destination,
            sizeBytes: 0,
            modificationDate: modificationDate,
            isDirectory: false,
            snippet: sample?.lowercased(),
            contentTokens: sample.map { FilingEngine.nameTokens($0) } ?? [])
            // **Attributed, or the self-match check below silently deletes every person variant.**
            // The verification step asks whether the offered rule matches its own example; a
            // `personIs` condition tested against facts with no people resolved is false for every
            // file, so the offer would be built and then thrown away with no trace.
            .attributing(evidence.index?.registry)
    }

    /// The rules only a household can express — offered when the folder just filed into is one
    /// person's, and the document says so.
    ///
    /// **Two offers, and the second is the point of the whole feature.** The first keys the rule on
    /// the person (`is Daughter's document` + the topic word), which is worth having because
    /// `mentionsAll(["daughter"])` is not the same claim — `father` is one person's given name and
    /// three others' surname, so a word-keyed person rule is wrong for most of this household and
    /// merely lucky for the rest.
    ///
    /// The second replaces the person's own folder with `{person}` and drops the person condition
    /// entirely: `Immigration/OCI/Daughter` becomes `Immigration/OCI/{person}`, so one rule files
    /// **everybody's** OCI card into their own folder. That is the generalisation the roadmap
    /// promised — one rule, seven people — and it is only safe to offer because the token resolves
    /// to `.unresolved` rather than guessing when a document names nobody or names two.
    static func personVariants(dest: String, template: String, facts: AutomationFileFacts,
                               keys: [Key], evidence: Evidence) -> [Variant] {
        guard let index = evidence.index, let registry = index.registry,
              // The document has to be about exactly one person — two people name no single folder.
              facts.personIds.count == 1, let personId = facts.personIds.first,
              let person = registry.people.first(where: { $0.id == personId }),
              // …and the folder has to be THEIRS. Filing Daughter's document into a shared folder
              // teaches nothing about people; it is an ordinary topic rule.
              index.folderPerson[dest] == personId else { return [] }

        // The topic, from the ranked keys — but never the person's own name, which the condition
        // now expresses properly. Without this the offer reads "is Daughter's document and mentions
        // 'daughter'", which is the word-keyed rule wearing a costume.
        let personWords = Set(PersonRegistry.words(person.displayName)
                              + person.fullNames.flatMap { PersonRegistry.words($0) }
                              + person.aliases.flatMap { PersonRegistry.words($0) })
        let topic = recurringKeys(keys).first { !personWords.contains($0.token) }?.token

        var out: [Variant] = []
        if let topic {
            out.append(Variant(conditions: [.personIs(personId), .mentionsAll([topic])],
                               chipLabel: "\(person.displayName) + “\(topic)”"))
        } else {
            out.append(Variant(conditions: [.personIs(personId)],
                               chipLabel: person.displayName))
        }

        // The fan-out. Only when the folder is named for the person — `Immigration/OCI/Daughter` — so
        // the substitution reproduces the path it was learned from rather than inventing one.
        let last = (dest as NSString).lastPathComponent
        if PersonRegistry.words(last) == PersonRegistry.words(person.displayName), let topic {
            let parent = (dest as NSString).deletingLastPathComponent
            let fanned = parent.isEmpty ? "{person}" : parent + "/{person}"
            out.append(Variant(conditions: [.mentionsAll([topic])], chipLabel: "everyone's “\(topic)”",
                               destinationTemplate: fanned))
        }
        return out
    }

    /// A destination ending in the example's own year becomes `{year}`.
    ///
    /// **A literal year freezes the one axis that varies.** A rule learned from a bill filed into
    /// `Home/Utilities/T-Mobile/2025` files every future bill into 2025 — and a rule learned in
    /// December misfiles everything from January. This is not a rare shape: the surveyed tree has
    /// 738 year-bucket folders, and they are where recurring documents go, which is exactly the
    /// kind of document a learned rule is for. Seen in the wild as a `DetailedBill` rule pinned to
    /// `Home/Utilities/T-Mobile/2026` that sent an April 2025 statement to an empty 2026 folder.
    ///
    /// **Only when the literal is the year this example resolves to.** `{year}` reads the filename
    /// first and the modification date second (see `AutomationEvaluator`), so substituting when
    /// they agree is a rewrite that cannot change where THIS file goes — it only generalises to the
    /// next one. When they disagree the user filed a 2025 document into 2026 on purpose, and that
    /// intent is kept verbatim.
    ///
    /// Spans (`2024-2026`) are left alone: `{year}` cannot reproduce one, so there is nothing to
    /// generalise to.
    static func generalizingTrailingYear(in dest: String, fileName: String,
                                         modificationDate: Date?, now: Date) -> String {
        let parts = dest.split(separator: "/").map(String.init)
        guard let last = parts.last, last.count == 4, Int(last) != nil,
              FolderProfileEntry.looksLikeYear(last) else { return dest }
        let resolved = FilingEngine.filenameYear(in: FilingEngine.fileTokens(fileName), now: now)
            ?? modificationDate.map { String(Calendar(identifier: .gregorian).component(.year, from: $0)) }
        guard resolved == last else { return dest }
        return (parts.dropLast() + ["{year}"]).joined(separator: "/")
    }
}
