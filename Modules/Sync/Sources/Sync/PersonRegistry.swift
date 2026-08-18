import Foundation

/// One member of the household the tree files for.
///
/// The tree already knows these people — every category grows a folder named for each of them —
/// but until now the engine held them as bare tokens. A record is what lets *Mom* and *Muktha*
/// be the same person, and lets "Shweta R Dani" on a PAN card resolve to the same person as the
/// folder called `Shweta`.
public struct Person: Sendable, Equatable, Identifiable {
    /// Stable identity, never displayed — survives renames and added variants.
    ///
    /// `let`, unlike everything below it: the id is what a folder's `axes.person` and every saved
    /// rule will resolve through, so renaming *Shweta* to *Shweta D.* must not orphan them.
    public let id: String
    /// What the tree calls them: the folder name, usually a first name.
    public var displayName: String
    /// `me`, `wife`, `daughter`, … — display-only today; recorded because relationship words
    /// ("my wife") are what a future classifier brief will want to print.
    public var relationship: String?
    /// Every full form a document might print — "Shweta Dani", "Shweta Ravindra Dani",
    /// "Shweta R Dani", "Shweta Abhishek". Matching tries these before any single word.
    public var fullNames: [String]
    /// What the tree calls them when it is not using their name — "Mom", "Mother".
    public var aliases: [String]

    public init(id: String, displayName: String, relationship: String? = nil,
                fullNames: [String] = [], aliases: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.relationship = relationship
        self.fullNames = fullNames
        self.aliases = aliases
    }

    /// Every name form this person answers to — display name, full names, aliases, in that order.
    ///
    /// One definition, because "what does this person go by" is asked in five places and the answer
    /// has to be the same in all of them: the token index and the phrase list are built from it,
    /// `displayForm(of:person:)` and `tokenBreakdown(for:)` compare against it, `othersSharing`
    /// scans it, and ``FolderSurveyBuilder`` matches folder names against it to recognise a
    /// person-bucket. (The first two are private, so they are named in prose rather than linked.) Spelled out separately in each, a new form source reaches some and not others,
    /// and a folder starts matching for the person axis while failing to count as a person folder.
    ///
    /// Order is part of the contract: the display name leads, because the phrase list records the
    /// form it matched and that is the one shown back to the user.
    public var nameForms: [String] { [displayName] + fullNames + aliases }

    /// An id derived from a display name — lowercased ASCII words joined by `-`, or a timestamp-free
    /// fallback when the name yields nothing usable (a name written only in a non-Latin script).
    ///
    /// Deliberately not a UUID: these ids are read by a human in `people.json` and compared against
    /// the profile's `axes.person` values by eye. Uniqueness is the caller's job — ``PeopleStore``
    /// disambiguates, because only it knows the rest of the roster.
    public static func idCandidate(from displayName: String) -> String {
        let words = PersonRegistry.words(displayName)
        return words.isEmpty ? "person" : words.joined(separator: "-")
    }
}

extension Person: Codable {
    private enum Key: String, CodingKey { case id, displayName, relationship, fullNames, aliases }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        relationship = try c.decodeIfPresent(String.self, forKey: .relationship)
        fullNames = try c.decodeIfPresent([String].self, forKey: .fullNames) ?? []
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    /// Written back in the shape the file already has, and **empty collections are omitted** — the
    /// file is meant to be read and hand-edited, and `"aliases": []` on five of seven people is
    /// noise that makes the two who have them harder to see.
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
    /// The name form that matched, spelled as the roster spells it — "Aditi Abhishek", "Mom".
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
/// This is the single most useful thing an explanation can say: "Abhishek" in "Aditi Abhishek"
/// *would* have named her father, and did not, because the phrase claimed it first.
public struct AbsorbedWord: Sendable, Equatable {
    public let word: String
    /// The person it would have named on its own.
    public let wouldHaveNamed: String
    /// The longer form that claimed it.
    public let absorbedInto: String
    /// Whose form that was.
    public let absorbedFor: String

    public init(word: String, wouldHaveNamed: String, absorbedInto: String, absorbedFor: String) {
        self.word = word
        self.wouldHaveNamed = wouldHaveNamed
        self.absorbedInto = absorbedInto
        self.absorbedFor = absorbedFor
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
/// **This family's names overlap, and that is the whole problem.** "Abhishek" is one person's
/// first name and three others' surname; "Girish" is Dad's first name, Mom's surname, and
/// Abhishek's surname. A token intersection cannot attribute either — it reads "Aditi Abhishek"
/// as evidence for two people. So matching is **phrase-first, longest wins, and a match consumes
/// its span**: the surname in "Aditi Abhishek" is spent on Aditi and never doubles as evidence
/// for Abhishek. What remains is attributed only where it cannot mislead — a token unique to one
/// person (`dani`, `muktha`), or a shared token standing alone that is exactly one person's first
/// name (`girish` by itself is Dad).
///
/// The strong/weak split is **computed from the registry, never hand-maintained** — adding a
/// seventh person re-derives it, so a variant added later can demote a token from unique to
/// shared without anything else changing.
public struct PersonRegistry: Sendable {

    /// Where the roster came from — shown in Settings, because "six people, seeded from your
    /// folder names" and "six people, from the file you wrote" are different claims about how
    /// much the app actually knows.
    public enum Source: String, Sendable, Equatable {
        /// Read from `people.json`.
        case file
        /// Derived from the profile's `axes.person` values and alias map — no full names, so
        /// phrase matching has nothing to work with beyond the folder labels themselves.
        case profileAxis
    }

    public let people: [Person]
    public let source: Source
    /// Ids that arrived more than once and were collapsed to one record, sorted and unique.
    ///
    /// **A reducer has to report what it gave up, or the thing it repaired becomes unsayable.**
    /// `people` above is the repaired roster, and nothing in it records that a repair happened —
    /// so `PeopleStore`'s load-time warning, which is the only thing that tells the user their
    /// file repeats an id, had no way to see one once this collapse existed. (It scanned the
    /// roster it was handed, and silently stopped firing the moment that roster was clean. Caught
    /// by its own test, not by reasoning.) Empty is the ordinary case.
    public let repeatedIds: [String]

    struct Phrase: Sendable {
        let tokens: [String]
        let id: String
        /// The form exactly as it was registered — "Shweta R Dani", not `shweta r dani`. Carried so
        /// an explanation can quote what the user typed into the roster rather than the tokenizer's
        /// view of it.
        let display: String
    }

    /// Multi-word name forms, longest first.
    let phrases: [Phrase]
    /// Single token → the one person whose names contain it. Absent when shared.
    let strong: [String: String]
    /// Shared single token → the one person whose *first name* it is — the reading a person
    /// picks up when the token stands alone. Absent when two people share the first name too.
    let given: [String: String]

    public var isEmpty: Bool { people.isEmpty }

    public init(people: [Person], source: Source = .file) {
        // **An id names exactly one person from here down, and this is where that becomes true.**
        // A hand-edited `people.json` can list the same id twice — the in-app paths cannot, since
        // `add` derives a unique id and `update` matches on one — and every reader below then
        // answered differently: the phrase list took BOTH records, the token map took the LAST,
        // `PeopleStore.person(id:)` takes the FIRST, and the Settings list drew the first record
        // twice because `ForEach` keys on the id. One roster, four answers, in one window.
        //
        // The quiet one was `givenClaims`, which appends per record and then only publishes a
        // given name claimed by exactly one id: a person listed twice claimed their own given
        // name twice, so `claims.count == 1` was false and their given-name matching was
        // *disabled by the duplicate*. Measured, not reasoned: with the fix reverted,
        // `detect(in: "Girish statement.pdf")` on a roster listing Girish twice returns NOTHING.
        //
        // Last wins, which is what `PeopleStore` already warns at load and what the two derived
        // maps already did; the first occurrence's POSITION is kept, since the roster is written
        // in display order and a repair should not also reorder it.
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
                // Initials ("Shweta R Dani") stay in the phrase but are never standalone keys.
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
    /// Read off the RAW list, before `uniqueById` collapses it — which is the whole point: after
    /// the collapse there is nothing left to count.
    static func repeatedIds(in people: [Person]) -> [String] {
        var seen = Set<String>()
        var repeated = Set<String>()
        for p in people where !seen.insert(p.id).inserted { repeated.insert(p.id) }
        return repeated.sorted()
    }

    /// One record per id — the last one listed, at the first one's position.
    ///
    /// Separate and `internal` so the rule can be tested for what it keeps as well as what it
    /// drops: the winner is a whole record, not a merge of the two. Merging was the alternative
    /// and is rejected deliberately — a union of two records' name forms is a person neither
    /// entry describes, and it would contradict the load-time warning that says which one wins.
    /// A duplicate is a mistake in a file somebody typed, and the honest repair is to pick one.
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
    /// Runs its own tokenizer over the raw string rather than accepting tokens, deliberately:
    /// the two tokenizers already in play disagree (`nameTokens` splits camelCase,
    /// `FilingRouter.tokenize` does not), and person identity asked through either would inherit
    /// that disagreement. Phrase matching also needs *order*, which every Set-of-tokens caller
    /// has already destroyed.
    public func detect(in text: String) -> Set<String> {
        Set(explain(in: text).matches.map(\.personId))
    }

    /// The same matching, with its reasoning kept.
    ///
    /// **`detect` is defined in terms of this, deliberately.** The explanation exists to be shown
    /// to the user — "who would this file be attributed to, and why" — and an explanation produced
    /// by a second implementation is a thing that can disagree with the engine while looking
    /// authoritative. There is one matcher; this is it, and `detect` throws the reasons away.
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

        // Words a longer name spent. These are the whole reason phrase matching exists: `abhishek`
        // inside "Aditi Abhishek" would otherwise name her father as well, so reporting what was
        // absorbed — and who it would have named — is the explanation, not a footnote.
        var absorbed: [AbsorbedWord] = []
        for (i, token) in tokens.enumerated() {
            guard let phrase = consumedBy[i] else { continue }
            guard let wouldName = strong[token] ?? given[token], wouldName != phrase.id else { continue }
            if absorbed.contains(where: { $0.word == token && $0.absorbedInto == phrase.display }) { continue }
            absorbed.append(AbsorbedWord(word: token, wouldHaveNamed: wouldName,
                                         absorbedInto: phrase.display, absorbedFor: phrase.id))
        }

        for (i, t) in tokens.enumerated() where consumedBy[i] == nil && t.count >= 2 {
            guard let id = strong[t] ?? given[t] else { continue }
            // Compared on `words`, not on `form`: `form` is the roster's spelling (`Mom`) and `t`
            // is the lowercased token (`mom`), so this only ever matched a roster that happens to
            // be all lowercase — and `Mom - Mom passport.pdf` produced the same match twice in a
            // list whose whole purpose is to be shown to the user.
            if matches.contains(where: { $0.personId == id && !$0.isPhrase && $0.words == [t] }) { continue }
            matches.append(PersonMatch(personId: id, form: displayForm(of: t, person: id),
                                       words: [t], isPhrase: false))
        }
        return PersonMatchReport(matches: matches, absorbed: absorbed)
    }

    /// A single matched word, spelled the way the roster spells it — `Mom` rather than `mom`.
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
    /// **One precedence rule, in one place, because two would eventually disagree.** The filename
    /// is the user's own label; a page-1 mention is testimony, and an application prints its
    /// sponsor, a report card names a sibling, an affidavit names a witness. So a file whose name
    /// declares a person is judged on that alone, and the page is consulted only when the name
    /// names nobody — which is what gives `Scan 2026-08-02.pdf` any attribution at all.
    ///
    /// The cross-person veto and the `personIs` rule condition both come here. Before this existed
    /// the veto had the rule inline, and a rule condition written to match "either" would have been
    /// a second, quietly different answer to the same question.
    public func attribute(fileName: String, pageSample: String?,
                          identity: PersonIdentityIndex? = nil) -> Set<String> {
        attribution(fileName: fileName, pageSample: pageSample, identity: identity).people
    }

    /// Which tier of ``attribution(fileName:pageSample:identity:)`` produced the answer.
    ///
    /// The tiers are not equally believable and the surfaces that show them have to say which one
    /// spoke — "named in the file" and "page 1 reads" are different claims, and a review row that
    /// confused them would be asking the user to judge evidence it had misdescribed.
    public enum AttributionTier: String, Sendable, Equatable {
        /// Nobody was named by anything.
        case none
        /// The file's own name — the user's own label, and the only tier that can claim a document
        /// on its own.
        case fileName
        /// Page 1 named them. **Testimony, not a label**: measured over the live tree, this tier
        /// puts 2,011 documents in one person's set purely because a joint bank form names her as
        /// nominee and a swim-class invoice names her as the payer. Worth reviewing, never worth
        /// assuming — see ``PersonFiles``.
        case pageText
        /// An identifier the person's folders have received. Never above a name anybody wrote.
        case identifier
    }

    /// Who a document is about, and which tier said so.
    ///
    /// ``attribute(fileName:pageSample:identity:)`` is this with the tier thrown away, so there is
    /// exactly one implementation of the precedence rule. Two would eventually disagree, and this
    /// one is shared by the cross-person veto, the `personIs` rule condition and the person gather.
    public func attribution(fileName: String, pageSample: String?,
                            identity: PersonIdentityIndex? = nil)
        -> (people: Set<String>, tier: AttributionTier) {
        let named = detect(in: (fileName as NSString).deletingPathExtension)
        if !named.isEmpty { return (named, .fileName) }
        guard let pageSample else { return ([], .none) }
        let byName = detect(in: pageSample)
        if !byName.isEmpty { return (byName, .pageText) }
        // **Last, and only when nothing was named.** An account number is the strongest evidence in
        // a scan that reads as an image — but it is also the most surprising to be attributed by,
        // so it never overrides a name anybody actually wrote. This is the tier that gives
        // `Scan 2026-08-02.pdf` an answer at all.
        let byId = identity?.people(in: pageSample) ?? []
        return byId.isEmpty ? ([], .none) : (byId, .identifier)
    }

    /// The person a profile's `axes.person` value names, or nil when the registry cannot say —
    /// including when the value somehow names two, which must not resolve arbitrarily.
    public func person(forAxisValue value: String) -> String? {
        let ids = detect(in: value)
        return ids.count == 1 ? ids.first : nil
    }

    /// A registry from a profile that has no `people.json` — one person per canonical axis value,
    /// aliases attached to the person they resolve to.
    ///
    /// This is deliberately more than a fallback: the alias map alone fixes the misfire where
    /// `Mom - passport.pdf` was vetoed *against* the folder whose axis says `muktha`, because the
    /// flattened token set knew both words but not that they are one person.
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

    /// Every word this person is known by, split into the ones that identify them **on their own**
    /// and the ones another member of the household also answers to.
    ///
    /// Derived from the roster, never stored: adding a seventh person can demote a token from
    /// unique to shared, and a hand-maintained list would not notice. This is what Settings shows
    /// when it says `abhishek` is shared with three others.
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

    /// Lowercased ASCII-alphanumeric runs, in order, 1-character runs kept — the initial in
    /// "Shweta R Dani" is part of the phrase even though it could never stand alone.
    ///
    /// Public because the matcher's own splitting rule is the only correct way to derive anything
    /// *from* a name elsewhere — Settings takes initials with it, and a second hand-rolled split
    /// would disagree with matching on exactly the names that are hard.
    public static func words(_ s: String) -> [String] {
        split(s.lowercased())
    }

    /// The same runs, in the string's **own spelling** — for a caller that has to show the user
    /// what the tree wrote rather than what the matcher compares.
    ///
    /// **Beside `words` and over the same `split`, because the two used to disagree.** The name
    /// learner cut filenames on Unicode letters and numbers while this matcher cuts ASCII-only, so
    /// for a roster holding `José García` the guard that stops one person being offered another's
    /// name was comparing `josé garcía` against keys spelled `jos garc a`. It could never match, so
    /// the run was rejected — conservative, and therefore silent, which is why it had no test.
    ///
    /// Aligning the derived helper to the matcher rather than widening the matcher is deliberate:
    /// `words` builds the persisted `strong` and `given` maps every existing roster is matched
    /// through, and this file already declares it the authority for anything derived from a name.
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
