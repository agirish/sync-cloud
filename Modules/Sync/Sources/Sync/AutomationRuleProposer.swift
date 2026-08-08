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
/// So a proposal is now built from ``FilingMemory`` and ``FolderProfile`` — what the destination has
/// actually *received* — which took the same routing decision to **58.2%**:
///
/// - **Several words, not one.** A rule keys on a conjunction (``AutomationCondition/mentionsAll``),
///   so `T-Mobile` ∧ `autopay` names T-Mobile bills rather than everything mentioning either.
/// - **The words the destination is known by.** A candidate word is scored by the IDF weight the
///   memory recorded for it *in that folder*, so `myatt` beats `account` without a hand-written
///   stop-list deciding so.
/// - **Rejected when it is not discriminating.** A word carried as an anchor by hundreds of folders
///   cannot route anything; the memory's posting list says how many, and that is the test.
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

        public var id: [AutomationCondition] { conditions }

        /// The plain-words sentence, e.g. `mentions “tmobile” and “autopay” · kind is PDF`.
        public var summary: String { conditions.map(\.summary).joined(separator: " · ") }

        public init(conditions: [AutomationCondition], chipLabel: String) {
            self.conditions = conditions
            self.chipLabel = chipLabel
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
        if evidence.existingRules.contains(where: {
            $0.enabled && $0.isRunnable && $0.destinationTemplate == template
                && AutomationEvaluator.matches($0, facts, now: now)
        }) { return nil }

        let keys = rankedKeys(dest: dest, evidence: evidence, facts: facts)
        let kind = FileKind.of(fileName: fileName)
        var variants = phrasings(keys: keys, kind: kind, fileName: fileName)

        // **Every variant has to match the file it was learned from.** The two tokenizers in play
        // do not agree word for word (see the type doc), and a proposal that cannot match its own
        // example is worse than no proposal: it is saved, reviewed, enabled, and silently never
        // fires.
        variants = variants.filter { variant in
            let probe = AutomationRule(name: "probe", matchMode: .all, conditions: variant.conditions,
                                       destinationTemplate: template)
            return AutomationEvaluator.matches(probe, facts, now: now)
        }
        // Two phrasings can collapse to the same conditions (one key, or no kind to add); keep the
        // first, which is the better-ranked one.
        var seen = Set<[AutomationCondition]>()
        variants = variants.filter { seen.insert($0.conditions).inserted }
        guard let best = variants.first else { return nil }

        let rule = AutomationRule(name: ruleName(keys: keys, dest: dest, template: template),
                                  matchMode: .all,
                                  conditions: best.conditions,
                                  destinationTemplate: template)
        return Proposal(rule: rule, variants: variants, destinationTemplate: template)
    }

    // MARK: - Choosing what to key on

    /// One candidate rule key and how strongly the tree vouches for it.
    struct Key: Equatable {
        let token: String
        let score: Double

        /// Whether something in the tree actually vouches for this word — a memory anchor, the
        /// folder's own name, or an identifier the folder has received before.
        ///
        /// **Only supported words may be conjoined.** The unsupported ones score on length alone
        /// (the no-memory fallback), and pairing two of those produces a rule keyed on an incidental
        /// word: `T-Mobile-bill-Mar.pdf` would learn `mentions “mobile” and “mar”`, which files
        /// March and nothing else. One such word can carry a rule; two cannot.
        var isSupported: Bool { score >= supportFloor }
    }

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
            keys.append(Key(token: token, score: score))
        }
        // Ties break on the token so an offer is the same on every run — a Set's order is not.
        return keys.sorted { $0.score != $1.score ? $0.score > $1.score : $0.token < $1.token }
    }

    /// The anchors that name `dest`, inherited from the nearest ancestor that has any.
    ///
    /// **A cold folder has no anchors of its own, and it is the folder rules are for.** The home of
    /// a recurring document is `Home/Utilities/T-Mobile/{year}`, whose current-year bucket holds
    /// nothing in January — so scoring it on its own content gives every candidate word zero and
    /// the proposal falls back to the filename. Its parent holds twelve bills a year. Same rule,
    /// and the same reason, as the inheritance in ``FilingRouter/rank``.
    static func anchorWeights(for dest: String, index: FilingRouter.Index?) -> [String: Double] {
        guard let index else { return [:] }
        var path = dest
        while true {
            if let own = index.anchorsByFolder[path], !own.isEmpty { return own }
            guard let slash = path.lastIndex(of: "/") else { return [:] }
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

    // MARK: - Phrasing

    /// The ways to phrase the rule, from the keys, best first.
    ///
    /// The ordering is deliberate: **two words is the default**, because one over-matches and three
    /// is usually one incidental word away from matching nothing but this file. Narrower and
    /// broader sit either side of it so the choice on offer is how tight to draw the rule.
    static func phrasings(keys: [Key], kind: FileKind?, fileName: String) -> [Variant] {
        var out: [Variant] = []
        let tokens = keys.map(\.token)
        if keys.count >= 2, keys[0].isSupported, keys[1].isSupported {
            let pair = Array(tokens.prefix(2))
            out.append(Variant(conditions: [.mentionsAll(pair)], chipLabel: quoted(pair)))
            if let kind {
                out.append(Variant(conditions: [.mentionsAll(pair), .kindIs(kind)],
                                   chipLabel: "\(quoted(pair)) + \(kind.label)"))
            }
            out.append(Variant(conditions: [.mentionsAll([tokens[0]])], chipLabel: quoted([tokens[0]])))
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
