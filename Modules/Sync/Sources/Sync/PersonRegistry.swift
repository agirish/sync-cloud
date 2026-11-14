import Foundation

/// One member of the household the tree files for.
///
/// The tree already has a folder for each of them in every category; a record is what lets *Mom*
/// and *Granny* be one person, and "Mother I Maiden" on a PAN card resolve to the folder called
/// `Mother`.
public struct Person: Sendable, Equatable, Identifiable {
    /// Stable identity, never displayed; survives renames and added variants. A `let`, unlike the
    /// rest: `axes.person` and saved rules resolve through it, so a rename must not orphan them.
    public let id: String
    /// What the tree calls them: the folder name, usually a first name.
    public var displayName: String
    /// `me`, `wife`, `daughter`, …: orders the roster (``PeopleOrder``) and is otherwise for display.
    public var relationship: String?
    /// Every full form a document might print: "Mother Maiden", "Mother I Maiden", "Mother
    /// Father". Matching tries these before any single word.
    public var fullNames: [String]
    /// What the tree calls them when not using their name: "Mom", "Mother".
    public var aliases: [String]

    public init(id: String, displayName: String, relationship: String? = nil,
                fullNames: [String] = [], aliases: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.relationship = relationship
        self.fullNames = fullNames
        self.aliases = aliases
    }

    /// Every name form this person answers to: display name, full names, aliases, in that order.
    ///
    /// One definition for "what does this person go by": the token index and phrase list are
    /// built from it, `displayForm(of:person:)`, `tokenBreakdown(for:)` and `othersSharing` read
    /// it, and ``FolderSurveyBuilder`` matches folder names against it. Separate copies would let a
    /// new form reach some and not others.
    ///
    /// Order is part of the contract: the display name leads, since the matched form is the one
    /// shown back to the user.
    public var nameForms: [String] { [displayName] + fullNames + aliases }

    /// An id derived from a display name: lowercased ASCII words joined by `-`, or `person` when
    /// the name yields nothing usable (a name only in a non-Latin script).
    ///
    /// Not a UUID: people read these ids in `people.json` and compare them with `axes.person` by
    /// eye. Uniqueness is ``PeopleStore``'s job, since only it knows the rest of the roster.
    public static func idCandidate(from displayName: String) -> String {
        let words = PersonRegistry.words(displayName)
        return words.isEmpty ? "person" : words.joined(separator: "-")
    }
}

extension Person: Codable {
    private enum Key: String, CodingKey, CaseIterable {
        case id, displayName, relationship, fullNames, aliases
    }

    /// The keys of a person record this build models: everything `init(from:)` reads and
    /// `encode(to:)` writes, deliberately the same set. Derived from `Key`, so a new field can't be
    /// missed here, which would make ``PeopleStore`` carry a key it writes and prefer the stale
    /// carried copy forever.
    static let modelledKeys: Set<String> = Set(Key.allCases.map(\.rawValue))
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        relationship = try c.decodeIfPresent(String.self, forKey: .relationship)
        fullNames = try c.decodeIfPresent([String].self, forKey: .fullNames) ?? []
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    /// Written back in the shape the file already has, with empty collections omitted: the file
    /// is read and hand-edited, and `"aliases": []` on most people is noise.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(relationship, forKey: .relationship)
        if !fullNames.isEmpty { try c.encode(fullNames, forKey: .fullNames) }
        if !aliases.isEmpty { try c.encode(aliases, forKey: .aliases) }
    }
}

/// One person named by a piece of text, and what named them.
public struct PersonMatch: Sendable, Equatable {
    public let personId: String
    /// The name form that matched, spelled as the roster spells it: "Daughter Father", "Mom".
    public let form: String
    /// The words it consumed, in order.
    public let words: [String]
    /// Whether a multi-word form matched (which is what makes a shared surname safe), or a single
    /// distinctive word did.
    public let isPhrase: Bool

    public init(personId: String, form: String, words: [String], isPhrase: Bool) {
        self.personId = personId
        self.form = form
        self.words = words
        self.isPhrase = isPhrase
    }
}

/// A word that names somebody in the roster but was spent inside a longer name.
///
/// The most useful thing an explanation can say: "Father" in "Daughter Father" would have named
/// her father, and didn't, because the phrase claimed it first.
public struct AbsorbedWord: Sendable, Equatable {
    public let word: String
    /// The person it would have named on its own.
    public let wouldHaveNamed: String
    /// The longer form that claimed it.
    public let absorbedInto: String

    public init(word: String, wouldHaveNamed: String, absorbedInto: String) {
        self.word = word
        self.wouldHaveNamed = wouldHaveNamed
        self.absorbedInto = absorbedInto
    }
}

/// The outcome of matching one piece of text: who it names, and what it nearly named.
public struct PersonMatchReport: Sendable, Equatable {
    public let matches: [PersonMatch]
    public let absorbed: [AbsorbedWord]

    public init(matches: [PersonMatch], absorbed: [AbsorbedWord]) {
        self.matches = matches
        self.absorbed = absorbed
    }

    public static let empty = PersonMatchReport(matches: [], absorbed: [])
    public var isEmpty: Bool { matches.isEmpty }
}

/// The household, compiled for matching.
///
/// A household's names overlap: "Father" is one person's first name and others' surname, so a
/// token intersection reads "Daughter Father" as two people. So matching is phrase-first, longest
/// wins, and a match consumes its span: the surname in "Daughter Father" is spent on Daughter.
/// What remains is attributed only where it can't mislead: a token unique to one person (`maiden`,
/// `granny`), or a shared token standing alone that is exactly one person's first name (`elder`
/// alone is Dad).
///
/// The strong/weak split is computed from the registry, never hand-maintained, so adding a person
/// or a variant re-derives it.
public struct PersonRegistry: Sendable {

    /// Where the roster came from, shown in Settings: "seeded from your folder names" and "from
    /// the file you wrote" are different claims about how much the app knows.
    public enum Source: String, Sendable, Equatable {
        /// Read from `people.json`.
        case file
        /// Derived from the profile's `axes.person` values and alias map: no full names, so phrase
        /// matching has only the folder labels.
        case profileAxis
    }

    public let people: [Person]
    public let source: Source
    /// Ids that arrived more than once and were collapsed to one record, sorted and unique.
    /// `people` is already repaired, so this is the only way `PeopleStore`'s load-time warning can
    /// see a repeated id. Usually empty.
    public let repeatedIds: [String]

    struct Phrase: Sendable {
        let tokens: [String]
        let id: String
        /// The form exactly as registered ("Mother I Maiden", not `mother i maiden`), so an
        /// explanation quotes what the user typed rather than the tokenizer's view of it.
        let display: String
    }

    /// Multi-word name forms, longest first.
    let phrases: [Phrase]
    /// Single token → the one person whose names contain it. Absent when shared.
    let strong: [String: String]
    /// Shared single token → the one person whose first name it is: the reading used when the
    /// token stands alone. Absent when two people share the first name too.
    let given: [String: String]

    public var isEmpty: Bool { people.isEmpty }

    public init(people: [Person], source: Source = .file) {
        // From here on an id names exactly one person. A hand-edited `people.json` can repeat an
        // id (the in-app paths can't), and each reader would then answer differently. Worse,
        // `givenClaims` publishes only a given name claimed by one id, so a duplicate would
        // disable that person's given-name matching. Last record wins, as `PeopleStore` warns at
        // load, at the first one's position, so the repair doesn't reorder the roster.
        let deduped = PersonRegistry.uniqueById(people)
        self.people = deduped
        self.source = source
        self.repeatedIds = PersonRegistry.repeatedIds(in: people)
        var phraseList: [Phrase] = []
        var tokensByPerson: [String: Set<String>] = [:]
        var givenClaims: [String: [String]] = [:]
        for p in deduped {
            var tokens = Set<String>()
            for name in p.nameForms {
                let words = PersonRegistry.words(name)
                // Initials ("Mother I Maiden") stay in the phrase but are never standalone keys.
                for w in words where w.count >= 2 { tokens.insert(w) }
                if words.count >= 2 {
                    phraseList.append(Phrase(tokens: words, id: p.id, display: name))
                }
            }
            tokensByPerson[p.id] = tokens
            if let first = PersonRegistry.words(p.displayName).first, first.count >= 2 {
                givenClaims[first, default: []].append(p.id)
            }
        }
        var owners: [String: Set<String>] = [:]
        for (id, tokens) in tokensByPerson {
            for t in tokens { owners[t, default: []].insert(id) }
        }
        var strongMap: [String: String] = [:]
        for (token, ids) in owners where ids.count == 1 { strongMap[token] = ids.first! }
        strong = strongMap
        var givenMap: [String: String] = [:]
        for (token, claims) in givenClaims
        where claims.count == 1 && (owners[token]?.count ?? 0) > 1 {
            givenMap[token] = claims[0]
        }
        given = givenMap
        phrases = phraseList.sorted {
            $0.tokens.count != $1.tokens.count ? $0.tokens.count > $1.tokens.count
                                               : $0.tokens.lexicographicallyPrecedes($1.tokens)
        }
    }

    /// The ids that appear more than once in `people`, sorted and unique.
    ///
    /// Read off the raw list, before `uniqueById` collapses it and leaves nothing to count.
    static func repeatedIds(in people: [Person]) -> [String] {
        var seen = Set<String>()
        var repeated = Set<String>()
        for p in people where !seen.insert(p.id).inserted { repeated.insert(p.id) }
        return repeated.sorted()
    }

    /// One record per id: the last one listed, at the first one's position.
    ///
    /// `internal` so tests can check what it keeps: a whole record, not a merge. A union of two
    /// records' name forms is a person neither entry describes, and would contradict the load-time
    /// warning that says which one wins.
    static func uniqueById(_ people: [Person]) -> [Person] {
        var positions: [String: Int] = [:]
        var kept: [Person] = []
        for p in people {
            if let at = positions[p.id] {
                kept[at] = p            // later record wins, earlier slot keeps the order
            } else {
                positions[p.id] = kept.count
                kept.append(p)
            }
        }
        return kept
    }

    /// The people this text names, as registry ids.
    ///
    /// Runs its own tokenizer over the raw string rather than taking tokens: `nameTokens` and
    /// `FilingRouter.tokenize` disagree (camelCase), and phrase matching needs word order, which a
    /// set of tokens has lost.
    public func detect(in text: String) -> Set<String> {
        Set(explain(in: text).matches.map(\.personId))
    }

    /// The same matching, with its reasoning kept.
    ///
    /// `detect` is defined in terms of this, so the explanation shown to the user ("who would
    /// this file be attributed to, and why") can never disagree with the engine. There is one
    /// matcher; `detect` throws the reasons away.
    public func explain(in text: String) -> PersonMatchReport {
        guard !people.isEmpty else { return .empty }
        let tokens = PersonRegistry.words(text)
        guard !tokens.isEmpty else { return .empty }

        var consumedBy = [Phrase?](repeating: nil, count: tokens.count)
        var matches: [PersonMatch] = []
        for phrase in phrases where phrase.tokens.count <= tokens.count {
            var i = 0
            while i + phrase.tokens.count <= tokens.count {
                var isMatch = true
                for j in 0..<phrase.tokens.count
                where consumedBy[i + j] != nil || tokens[i + j] != phrase.tokens[j] {
                    isMatch = false
                    break
                }
                if isMatch {
                    for j in 0..<phrase.tokens.count { consumedBy[i + j] = phrase }
                    matches.append(PersonMatch(personId: phrase.id, form: phrase.display,
                                               words: phrase.tokens, isPhrase: true))
                    i += phrase.tokens.count
                } else {
                    i += 1
                }
            }
        }

        // Words a longer name spent, and who they would have named: `father` inside "Daughter
        // Father" would otherwise name her father too. This is the core of the explanation.
        var absorbed: [AbsorbedWord] = []
        for (i, token) in tokens.enumerated() {
            guard let phrase = consumedBy[i] else { continue }
            guard let wouldName = strong[token] ?? given[token], wouldName != phrase.id else { continue }
            if absorbed.contains(where: { $0.word == token && $0.absorbedInto == phrase.display }) { continue }
            absorbed.append(AbsorbedWord(word: token, wouldHaveNamed: wouldName,
                                         absorbedInto: phrase.display))
        }

        for (i, t) in tokens.enumerated() where consumedBy[i] == nil && t.count >= 2 {
            guard let id = strong[t] ?? given[t] else { continue }
            // Compared on `words`, not `form`: `form` is the roster's spelling (`Mom`) and `t` is
            // lowercased, so comparing `form` would list `Mom - Mom passport.pdf`'s match twice.
            if matches.contains(where: { $0.personId == id && !$0.isPhrase && $0.words == [t] }) { continue }
            matches.append(PersonMatch(personId: id, form: displayForm(of: t, person: id),
                                       words: [t], isPhrase: false))
        }
        return PersonMatchReport(matches: matches, absorbed: absorbed)
    }

    /// A single matched word, spelled the way the roster spells it: `Mom`, not `mom`.
    private func displayForm(of token: String, person id: String) -> String {
        guard let p = people.first(where: { $0.id == id }) else { return token }
        for name in p.nameForms
        where PersonRegistry.words(name) == [token] {
            return name
        }
        return token
    }

    /// Who a document is about, from its name and — only when its name says nothing — its text.
    ///
    /// One precedence rule, in one place. The filename is the user's own label; a page-1 mention
    /// is testimony (an application prints its sponsor, an affidavit a witness). So a name that
    /// declares a person decides alone, and the page is read only when the name names nobody,
    /// which is what gives `Scan 2026-08-02.pdf` any attribution. The cross-person veto and the
    /// `personIs` rule condition both come here.
    public func attribute(fileName: String, pageSample: String?,
                          identity: PersonIdentityIndex? = nil) -> Set<String> {
        attribution(fileName: fileName, pageSample: pageSample, identity: identity).people
    }

    /// Which tier of ``attribution(fileName:pageSample:identity:)`` produced the answer.
    ///
    /// The tiers are not equally believable, so surfaces must say which one spoke: "named in the
    /// file" and "page 1 reads" are different claims for a review row to put to the user.
    public enum AttributionTier: String, Sendable, Equatable {
        /// Nobody was named by anything.
        case none
        /// The file's own name: the user's own label, and the only tier that can claim a document
        /// on its own.
        case fileName
        /// Page 1 named them. Testimony, not a label: a joint bank form names a nominee, an invoice
        /// the payer. Worth reviewing, never assuming (``PersonFiles``).
        case pageText
        /// An identifier the person's folders have received. Never above a name anybody wrote.
        case identifier
    }

    /// Who a document is about, and which tier said so.
    ///
    /// ``attribute(fileName:pageSample:identity:)`` is this with the tier thrown away, so there is
    /// one implementation of the precedence rule, shared by the cross-person veto, the `personIs`
    /// rule condition and the person gather.
    public func attribution(fileName: String, pageSample: String?,
                            identity: PersonIdentityIndex? = nil)
        -> (people: Set<String>, tier: AttributionTier) {
        let named = detect(in: (fileName as NSString).deletingPathExtension)
        if !named.isEmpty { return (named, .fileName) }
        guard let pageSample else { return ([], .none) }
        let byName = detect(in: pageSample)
        if !byName.isEmpty { return (byName, .pageText) }
        // Last, and only when nothing was named: an account number is strong evidence in an image
        // scan but the most surprising to be attributed by, so it never overrides a written name.
        let byId = identity?.people(in: pageSample) ?? []
        return byId.isEmpty ? ([], .none) : (byId, .identifier)
    }

    /// The person a profile's `axes.person` value names, or nil when the registry can't say,
    /// including when it names two, which must not resolve arbitrarily.
    public func person(forAxisValue value: String) -> String? {
        let ids = detect(in: value)
        return ids.count == 1 ? ids.first : nil
    }

    /// A registry from a profile with no `people.json`: one person per canonical axis value, with
    /// aliases attached to the person they resolve to. More than a fallback: without the alias map,
    /// `Mom - passport.pdf` would be vetoed from the folder whose axis says `granny`.
    public static func seeded(from profile: FolderProfile) -> PersonRegistry {
        var aliasesByCanonical: [String: [String]] = [:]
        for (alias, canonical) in profile.personAliases {
            aliasesByCanonical[canonical, default: []].append(alias)
        }
        var ids = profile.personTokens
        ids.subtract(profile.personAliases.keys)
        ids.formUnion(aliasesByCanonical.keys)
        let people = ids.sorted().map { id in
            Person(id: id, displayName: id, aliases: aliasesByCanonical[id]?.sorted() ?? [])
        }
        return PersonRegistry(people: people, source: .profileAxis)
    }

    /// Every word this person is known by, split into those that identify them on their own and
    /// those another household member also answers to. Derived, never stored, since adding a
    /// person can demote a token to shared. Settings shows this.
    public func tokenBreakdown(for id: String) -> (unique: [String], shared: [String]) {
        guard let p = people.first(where: { $0.id == id }) else { return ([], []) }
        var tokens = Set<String>()
        for name in p.nameForms {
            for w in PersonRegistry.words(name) where w.count >= 2 { tokens.insert(w) }
        }
        var unique: [String] = []
        var shared: [String] = []
        for t in tokens.sorted() {
            if strong[t] == id { unique.append(t) } else { shared.append(t) }
        }
        return (unique, shared)
    }

    /// How many other people in the roster also answer to `token`.
    public func othersSharing(_ token: String, with id: String) -> Int {
        people.filter { p in
            p.id != id && p.nameForms.contains { name in
                PersonRegistry.words(name).contains(token)
            }
        }.count
    }

    /// Lowercased ASCII-alphanumeric runs, in order, 1-character runs kept: the initial in "Mother
    /// I Maiden" is part of the phrase though it never stands alone.
    ///
    /// Public because anything derived from a name elsewhere (Settings takes initials with it)
    /// must use the matcher's own split, or it disagrees on exactly the hard names.
    public static func words(_ s: String) -> [String] {
        split(s.lowercased())
    }

    /// The same runs, in the string's own spelling, for a caller that shows what the tree wrote
    /// rather than what the matcher compares.
    ///
    /// Over the same `split` as `words`, so keys built from either agree: with a non-ASCII name
    /// (`José García`) a separate Unicode split would never match the matcher's keys. The helper
    /// follows the matcher, not the other way round, because `words` builds the `strong` and
    /// `given` maps every roster is matched through.
    public static func spelledWords(_ s: String) -> [String] {
        split(s)
    }

    /// Where a name breaks into words. One rule, so `words` and `spelledWords` cannot drift.
    private static func split(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch), ch.isASCII {
                current.unicodeScalars.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

extension PersonRegistry: Equatable {
    /// The compiled maps are a pure function of `people`, so identity is the roster and where it
    /// came from.
    public static func == (a: PersonRegistry, b: PersonRegistry) -> Bool {
        a.people == b.people && a.source == b.source
    }
}
