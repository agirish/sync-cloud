import Foundation

/// Turns one "the user filed THIS file into THAT folder" example into a proposed
/// ``AutomationRule``: the deterministic, learn-by-example complement to the AI filing backend.
///
/// A proposal keys on what the destination has actually *received* (``FilingMemory`` and
/// ``FolderProfile``), not on a word the file name shares with the folder's name, which routes
/// only about one file in eight correctly; `*Statement*` → `Finance/US/Chase` would take every
/// payslip and lease carrying "statement".
///
/// - Several words, not one: a conjunction (``AutomationCondition/mentionsAll``), so `mobile` ∧
///   `autopay` names T-Mobile bills rather than everything mentioning either.
/// - Words that come back, ranked by how well they discriminate, in that order. Recurrence is a
///   filter (``recurrenceFloor``) and rarity the ranking inside it: rarity alone prefers one-off
///   words like a marketing campaign's `awesome` over `autopay`, which is in every bill.
/// - The pair is chosen, not two independent words (``discriminatingPair(_:index:)``). Replayed
///   over 1,428 real filings, this gives 67% recall at 54% precision, and only 1.3% of rules
///   never fire again.
/// - Refused when a word anchors so many folders it can route nothing.
/// - Content counts, not just the name, so `Scan 2026-03-02.pdf` can still seed a real rule.
/// - Inherited from the parent when the folder is cold (an empty `…/T-Mobile/{year}` bucket in
///   January), as ``FilingRouter/rank`` inherits evidence.
/// - Verified against its own example through ``AutomationEvaluator``. The memory's anchors come
///   from ``FilingRouter/tokenize`` but `mentionsAll` matches on ``FilingEngine/nameTokens``, so a
///   word only the first produces would make a rule that never fires.
///
/// With no profile loaded, the name/kind heuristics below apply. Pure and framework-free so it's
/// unit-testable and lives in Sync.
public enum AutomationRuleProposer {

    /// One way to phrase the rule, as a complete set of conditions (ALL of which must hold).
    ///
    /// A rule is a *conjunction*, and the choice a person wants is how tightly to draw it, so the
    /// variants are offered as narrower / balanced / broader.
    public struct Variant: Sendable, Equatable, Hashable, Identifiable {
        public let conditions: [AutomationCondition]
        /// Compact text for the picker chip, e.g. `“tmobile” + “autopay”`. The full sentence is
        /// ``summary``; the chip has to fit three-across in an inline prompt.
        public let chipLabel: String
        /// A destination this phrasing needs instead of the proposal's. nil for every phrasing but
        /// the `{person}` fan-out, which sends each person's copy to their own folder. A variant
        /// that changes where files land must say so, or picking it would keep the literal folder.
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

    /// What the scan already knows about this file and this tree. Every field is optional: with
    /// none of it, a proposal falls back to the filename-and-extension heuristic.
    public struct Evidence: Sendable {
        /// The document's first page as the scan read it, the text ``FilingRouter`` scores. Bounded
        /// to ``FilingRouter/contentSampleChars`` here, so a caller handing over a whole document
        /// can't change which words a rule keys on.
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
    /// For the no-memory path only. With a memory, ``anchorBreadthCeiling`` decides, because
    /// "generic" depends on the tree: "insurance" is generic among 40 insurance folders and a good
    /// key with a single `Home/Insurance`.
    private static let stopTokens: Set<String> = [
        "the", "and", "for", "with", "from", "copy", "final", "draft", "new", "old", "doc",
        "document", "file", "scan", "img", "image", "photo", "untitled", "report", "bill",
        "invoice", "receipt", "statement", "letter", "note", "notes",
    ]

    /// How many folders may carry a word as an anchor before it is refused as a rule key.
    ///
    /// A word recorded for 400 of 3,000 folders discriminates nothing; one recorded for two all but
    /// names one. Scaled to the tree, with a floor so a small tree doesn't refuse every word.
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
        // A relative destination is stored as a template, and the evaluator reports any leftover
        // `{…}` as unresolvable. A real folder called "Q3 {final}" would make a rule that can
        // never run (only absolute literals are exempt), so decline: no offer beats a bad one.
        guard !dest.contains("{"), !dest.contains("}") else { return nil }

        // Applied to the template only: the conditions below come from the folder's real name.
        let template = generalizingTrailingYear(in: dest, fileName: fileName,
                                                modificationDate: modificationDate, now: now)

        // The facts the offered rule is checked against, in the shape both surfaces evaluate, so
        // "it matches its own example" means what it says.
        let facts = exampleFacts(fileName: fileName, destination: dest, evidence: evidence,
                                 modificationDate: modificationDate)

        // Already covered by a saved, runnable rule that files this file into this folder: offering
        // it again would leave the user with duplicate rules.
        if AutomationRuleSet.eligible(evidence.existingRules).rules.contains(where: {
            $0.destinationTemplate == template
                && AutomationEvaluator.matches($0, facts, now: now)
        }) { return nil }

        let keys = rankedKeys(dest: dest, evidence: evidence, facts: facts)
        let kind = FileKind.of(fileName: fileName)
        var variants = phrasings(keys: keys, kind: kind, fileName: fileName, index: evidence.index)
        // Offered first when they apply: a person's folder is the one destination a word-based rule
        // can't express.
        variants = personVariants(dest: dest, template: template, facts: facts,
                                  keys: keys, evidence: evidence) + variants

        // Every variant has to match the file it was learned from. The two tokenizers don't agree
        // word for word (see the type doc), and a rule that can't match its own example would be
        // saved, enabled, and silently never fire.
        variants = variants.filter { variant in
            let probe = AutomationRule(name: "probe", matchMode: .all, conditions: variant.conditions,
                                       destinationTemplate: variant.destinationTemplate ?? template)
            guard AutomationEvaluator.matches(probe, facts, now: now) else { return false }
            // A variant that redirects must also resolve to the folder the example went to
            // (`{person}` reproducing `Immigration/OCI/Daughter`), or it would re-file the example.
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
        /// Share of the destination's filed documents that contain this word
        /// (``recurrenceOf(_:dest:index:)``). 0 when there is no memory to ask.
        var recurrence: Double = 0

        /// Whether something in the tree vouches for this word: a memory anchor, the folder's own
        /// name, or an identifier the folder has received. Only supported words may be conjoined:
        /// unsupported ones score on length alone, and `T-Mobile-bill-Mar.pdf` would learn
        /// `mentions “mobile” and “mar”`, which files March and nothing else.
        var isSupported: Bool { score >= supportFloor }
    }

    /// How much of the destination's filed documents a word must appear in before it may key a rule.
    /// 0.6 is the peak of a sweep over 1,428 real filings (F1 60.2, with 1.2% of rules never firing
    /// against 4.8% at 0): lower lets rare words back in, higher thins the pool to words so common
    /// that precision pays for recall.
    static let recurrenceFloor = 0.6

    /// The score below which a key is a guess rather than evidence (``Key/isSupported``). Naming the
    /// folder scores 2.0 and the length fallback 0.0x, so one always clears it and the other never
    /// does. An anchor below 1.0 is a word this tree barely tells anything apart by.
    static let supportFloor = 1.0

    /// The words worth keying a rule on, strongest first.
    ///
    /// Candidates come from the tokenizers that do the *matching* (`FilingEngine.fileTokens` for the
    /// name, `FilingEngine.nameTokens` for the page) and are scored by the memory's anchors. Picking
    /// from the anchors instead would yield words the evaluator never produces.
    ///
    /// `score` ranks how well a word discriminates, not whether it will be seen again: an anchor's
    /// weight is its rarity, so a one-off `awesome` outranks `autopay`, which is in every bill.
    /// ``recurrenceOf(_:dest:index:)`` supplies the other half, and each key carries both.
    static func rankedKeys(dest: String, evidence: Evidence, facts: AutomationFileFacts) -> [Key] {
        let nameTokens = facts.nameTokens
        let bodyTokens = facts.contentTokens
        let index = evidence.index
        // The folder's own name is a signal too (the only one without a memory), read as the router
        // reads it so `H-1B` and `H1B` are one folder.
        let destTokens = FilingRouter.pathTokens(of: dest)
        let anchors = anchorWeights(for: dest, index: index)
        let ceiling = anchorBreadthCeiling(destinations: index?.destinations.count ?? 0)

        var keys: [Key] = []
        for token in nameTokens.union(bodyTokens) {
            // A year is what `{year}` is for. Keying on one freezes the rule to a single year's
            // documents, as a literal year folder would (`generalizingTrailingYear`).
            if FilingRouter.isYearToken(token) { continue }
            var score = 0.0
            if FilingRouter.isIdentifier(token) {
                // A digit-bearing word is the best key or the worst: an account number the folder
                // has received names it alone, while a fresh invoice number matches one file,
                // forever. The memory decides which. A bare number can't be matched by `mentionsAll`
                // (`fileTokens` keeps only years among pure digits); verification drops it.
                guard let index, let weight = identifierWeight(token, dest: dest, index: index)
                else { continue }
                // Weighted as `FilingRouter.rank` weights an identifier hit, so the word that most
                // nearly names this folder also ranks first here.
                score += weight * FilingRouter.identifierBoost
            }
            if let weight = anchors[token] { score += weight }
            if destTokens.contains(token) { score += 2.0 }
            if score == 0 {
                // Nothing in the tree vouches for this word. With a memory that is a verdict; without
                // one, a long, non-generic word is all there is.
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
    /// Read from the memory when it records the share. An older artifact without `df` falls back
    /// to the folder's family: of the related folders with anchors
    /// (`Home/Utilities/T-Mobile/2022…2025`), how many list this word. The recorded share is worth
    /// about 9 points of F1 over the estimate.
    static func recurrenceOf(_ token: String, dest: String, index: FilingRouter.Index?) -> Double {
        guard let index else { return 0 }
        let source = anchorSource(for: dest, index: index) ?? dest
        if let recorded = index.docFrequencyByFolder[source]?[token] { return recorded }
        // A digit-bearing word is stored hashed, on the other list, with its share. Without this an
        // account number, the word that most nearly names a folder, could never clear the floor.
        if FilingRouter.isIdentifier(token) {
            let hashed = FilingMemory.hash(token, salt: index.salt)
            if let recorded = index.idDocFrequencyByFolder[source]?[hashed] { return recorded }
            // An older artifact without the share: the folder has received this identifier, and the
            // builder records only ones that recurred, so treat it as evidence rather than drop
            // the strongest key a rule can have.
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

    /// The anchors that name `dest`, inherited from the nearest ancestor that has any. A cold
    /// folder, such as January's empty `Home/Utilities/T-Mobile/{year}` bucket, is exactly what
    /// rules are for, and its parent holds the year's bills. As in ``FilingRouter/rank``.
    static func anchorWeights(for dest: String, index: FilingRouter.Index?) -> [String: Double] {
        guard let index, let source = anchorSource(for: dest, index: index) else { return [:] }
        return index.anchorsByFolder[source] ?? [:]
    }

    /// The folder whose anchors describe `dest`: itself, or the nearest ancestor that has any.
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

    /// How heavily the destination, or an ancestor (as anchors are inherited), is known by this
    /// identifier; nil when it has never received one.
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
    /// Filter by recurrence, then rank by discrimination. "Will it fire again?" and "will it take
    /// only the right files?" pull opposite ways, and a blended score serves neither (F1 about 51,
    /// against 57–60 for filter-then-rank). The conjunction supplies the specificity, so a word only
    /// has to clear the floor.
    static func recurringKeys(_ keys: [Key]) -> [Key] {
        let recurring = keys.filter { $0.recurrence >= recurrenceFloor }
        // No memory, or nothing clears the floor: fall back to the plain ranking rather than
        // refusing to propose.
        return recurring.isEmpty ? keys : recurring
    }

    /// The two words to conjoin: the most recurring pair, and among equals the pair that reaches the
    /// fewest folders between them.
    ///
    /// The conjunction is what files, so it is what is chosen: two words picked independently often
    /// describe the same thing (`autopay` and `paying` anchor the same folders), and requiring both
    /// narrows nothing. The overlap of their posting lists estimates what the pair lets through.
    ///
    /// Recurrence is compared in half-steps, then overlap breaks the tie. Overlap first re-prefers
    /// the scarce words the floor demotes; raw recurrence first spends precision on tiny
    /// differences. Half-steps scored best (F1 60.2) and drift toward neither failure.
    ///
    /// Bounded to the strongest few candidates, since this is quadratic.
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
                // Ties break on weight, then on the tokens, so the offer is the same on every run.
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

    /// Lexicographic comparison of the pair-ranking key, spelled out so the ordering is readable
    /// rather than inferred.
    private static func isLower(_ a: (Double, Int, Double, String, String),
                                than b: (Double, Int, Double, String, String)) -> Bool {
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        if a.2 != b.2 { return a.2 < b.2 }
        if a.3 != b.3 { return a.3 < b.3 }
        return a.4 < b.4
    }

    /// How many candidates the pair search considers. Quadratic, and words below the top few serve
    /// as a third option rather than a serious pair.
    static let pairSearchPool = 8

    // MARK: - Phrasing

    /// The ways to phrase the rule, from the keys, best first.
    ///
    /// Two words is the default, by a clear margin (F1 60.2, against 59.3 for three and 47.2 for
    /// one). Narrower and broader are offered either side because the trade is real and which way
    /// to lean is the user's call.
    static func phrasings(keys allKeys: [Key], kind: FileKind?, fileName: String,
                          index: FilingRouter.Index?) -> [Variant] {
        var out: [Variant] = []
        let keys = recurringKeys(allKeys)
        let tokens = keys.map(\.token)
        if keys.count >= 2, keys[0].isSupported, keys[1].isSupported {
            let pair = discriminatingPair(keys, index: index)
            out.append(Variant(conditions: [.mentionsAll(pair)], chipLabel: quoted(pair)))
            // Narrower: a third recurring word if there is one, for when the pair took something it
            // shouldn't. The kind only when no third word is left.
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
            // The loosest option: a glob matches a word inside a longer one (`*mobile*` catches
            // `T-Mobile`), which is sometimes exactly what a person means.
            out.append(Variant(conditions: [.nameMatches("*\(only)*")], chipLabel: "name *\(only)*"))
        }
        if out.isEmpty, let kind {
            out.append(Variant(conditions: [.kindIs(kind)], chipLabel: kind.label))
        }
        // Fall back to a name glob on the extension. With no extension either, the only fallback
        // would be `name matches *`, a rule that files every loose file here, so decline instead.
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

    /// The rule's display name: the folder it files into ("T-Mobile"), else the words it keys on.
    /// `{year}` and friends are skipped: a rule called "{year}" names nothing.
    static func ruleName(keys: [Key], dest: String, template: String) -> String {
        let literal = template.split(separator: "/").map(String.init)
            .last(where: { !$0.contains("{") })
        if let literal, !literal.isEmpty { return literal }
        if let first = keys.first?.token { return first.capitalized }
        return (dest as NSString).lastPathComponent
    }

    // MARK: - The example, as the evaluator sees it

    /// The filed file as ``AutomationFileFacts``: name, kind, and the page the scan read, reduced to
    /// content tokens as both live surfaces reduce them, so a rule verified here behaves the same in
    /// the Automations dry run and the next Organize scan.
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
            // Attributed, or the self-match check silently drops every person variant: `personIs`
            // is false for facts with no people resolved.
            .attributing(evidence.index?.registry)
    }

    /// The rules only a household can express, offered when the folder just filed into is one
    /// person's and the document says so.
    ///
    /// The first keys on the person (`is Daughter's document` + the topic word), not on their name
    /// as a word: a name can be one person's given name and others' surname.
    ///
    /// The second replaces the person's folder with `{person}` and drops the person condition:
    /// `Immigration/OCI/{person}` files everybody's OCI card into their own folder. Safe only
    /// because the token is `.unresolved`, never a guess, when a document names nobody or two.
    static func personVariants(dest: String, template: String, facts: AutomationFileFacts,
                               keys: [Key], evidence: Evidence) -> [Variant] {
        guard let index = evidence.index, let registry = index.registry,
              // The document has to be about exactly one person: two name no single folder.
              facts.personIds.count == 1, let personId = facts.personIds.first,
              let person = registry.people.first(where: { $0.id == personId }),
              // …and the folder has to be theirs. A shared folder teaches nothing about people.
              index.folderPerson[dest] == personId else { return [] }

        // The topic, from the ranked keys, but never the person's own name, which the condition
        // already expresses.
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

        // The fan-out, only when the folder is named for the person (`Immigration/OCI/Daughter`), so
        // the substitution reproduces the path it was learned from.
        let last = (dest as NSString).lastPathComponent
        if PersonRegistry.words(last) == PersonRegistry.words(person.displayName), let topic {
            let parent = (dest as NSString).deletingLastPathComponent
            let fanned = parent.isEmpty ? "{person}" : parent + "/{person}"
            out.append(Variant(conditions: [.mentionsAll([topic])], chipLabel: "everyone’s “\(topic)”",
                               destinationTemplate: fanned))
        }
        return out
    }

    /// A destination ending in the example's own year becomes `{year}`. A literal year would freeze
    /// the one axis that varies: a rule learned in `Home/Utilities/T-Mobile/2025` would file every
    /// future bill into 2025. Year folders are where recurring documents go, which is what learned
    /// rules are for.
    ///
    /// Only when the literal is the year this example resolves to (filename first, then
    /// modification date, as `AutomationEvaluator` reads it), so this file goes where it went. When
    /// they disagree the user filed it there on purpose, and the folder is kept. Spans
    /// (`2024-2026`) are left alone: `{year}` can't reproduce one.
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
