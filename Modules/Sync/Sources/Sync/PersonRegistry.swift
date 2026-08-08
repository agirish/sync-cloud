import Foundation

/// One member of the household the tree files for.
///
/// The tree already knows these people — every category grows a folder named for each of them —
/// but until now the engine held them as bare tokens. A record is what lets *Mom* and *Muktha*
/// be the same person, and lets "Shweta R Dani" on a PAN card resolve to the same person as the
/// folder called `Shweta`.
public struct Person: Sendable, Equatable {
    /// Stable identity, never displayed — survives renames and added variants.
    public let id: String
    /// What the tree calls them: the folder name, usually a first name.
    public let displayName: String
    /// `me`, `wife`, `daughter`, … — display-only today; recorded because relationship words
    /// ("my wife") are what a future classifier brief will want to print.
    public let relationship: String?
    /// Every full form a document might print — "Shweta Dani", "Shweta Ravindra Dani",
    /// "Shweta R Dani", "Shweta Abhishek". Matching tries these before any single word.
    public let fullNames: [String]
    /// What the tree calls them when it is not using their name — "Mom", "Mother".
    public let aliases: [String]

    public init(id: String, displayName: String, relationship: String? = nil,
                fullNames: [String] = [], aliases: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.relationship = relationship
        self.fullNames = fullNames
        self.aliases = aliases
    }
}

extension Person: Decodable {
    private enum Key: String, CodingKey { case id, displayName, relationship, fullNames, aliases }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        relationship = try c.decodeIfPresent(String.self, forKey: .relationship)
        fullNames = try c.decodeIfPresent([String].self, forKey: .fullNames) ?? []
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
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

    struct Phrase: Sendable {
        let tokens: [String]
        let id: String
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
        self.people = people
        self.source = source
        var phraseList: [Phrase] = []
        var tokensByPerson: [String: Set<String>] = [:]
        var givenClaims: [String: [String]] = [:]
        for p in people {
            var tokens = Set<String>()
            for name in [p.displayName] + p.fullNames + p.aliases {
                let words = PersonRegistry.words(name)
                // Initials ("Shweta R Dani") stay in the phrase but are never standalone keys.
                for w in words where w.count >= 2 { tokens.insert(w) }
                if words.count >= 2 { phraseList.append(Phrase(tokens: words, id: p.id)) }
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

    /// The people this text names, as registry ids.
    ///
    /// Runs its own tokenizer over the raw string rather than accepting tokens, deliberately:
    /// the two tokenizers already in play disagree (`nameTokens` splits camelCase,
    /// `FilingRouter.tokenize` does not), and person identity asked through either would inherit
    /// that disagreement. Phrase matching also needs *order*, which every Set-of-tokens caller
    /// has already destroyed.
    public func detect(in text: String) -> Set<String> {
        guard !people.isEmpty else { return [] }
        let tokens = PersonRegistry.words(text)
        guard !tokens.isEmpty else { return [] }
        var found: Set<String> = []
        var consumed = [Bool](repeating: false, count: tokens.count)
        for phrase in phrases where phrase.tokens.count <= tokens.count {
            var i = 0
            while i + phrase.tokens.count <= tokens.count {
                var matches = true
                for j in 0..<phrase.tokens.count
                where consumed[i + j] || tokens[i + j] != phrase.tokens[j] {
                    matches = false
                    break
                }
                if matches {
                    for j in 0..<phrase.tokens.count { consumed[i + j] = true }
                    found.insert(phrase.id)
                    i += phrase.tokens.count
                } else {
                    i += 1
                }
            }
        }
        for (i, t) in tokens.enumerated() where !consumed[i] && t.count >= 2 {
            if let id = strong[t] {
                found.insert(id)
            } else if let id = given[t] {
                found.insert(id)
            }
        }
        return found
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
        for name in [p.displayName] + p.fullNames + p.aliases {
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
            p.id != id && ([p.displayName] + p.fullNames + p.aliases).contains { name in
                PersonRegistry.words(name).contains(token)
            }
        }.count
    }

    /// Lowercased ASCII-alphanumeric runs, in order, 1-character runs kept — the initial in
    /// "Shweta R Dani" is part of the phrase even though it could never stand alone.
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s.lowercased().unicodeScalars {
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
