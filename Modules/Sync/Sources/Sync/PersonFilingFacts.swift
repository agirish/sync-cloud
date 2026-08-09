import Foundation

/// One top-level area of the tree a person has folders in.
public struct PersonArea: Sendable, Equatable {
    public let name: String
    public let folders: Int
    public let documents: Int

    public init(name: String, folders: Int, documents: Int) {
        self.name = name
        self.folders = folders
        self.documents = documents
    }
}

/// What the app actually knows about one person, and what that knowledge buys when filing.
///
/// **This exists because a list of names is not an answer.** The People section used to print six
/// names, which told the user nothing about why the app was holding them or what would change if
/// one were edited. Every number here is derived — from the roster, the surveyed profile, and the
/// filing memory — so the section can say *what* is known rather than merely *who*.
///
/// Computed in `Sync` rather than in the view for the usual reason: a rule the UI states is a rule
/// that should be testable without a window.
public struct PersonFilingFacts: Sendable, Equatable {
    public let personId: String
    /// The name forms matched against a document, longest first — the display order is the
    /// *matching* order, so the list doubles as an explanation of precedence.
    public let matchedForms: [String]
    /// Words that identify this person on their own.
    public let uniqueWords: [String]
    /// Words another member of the household also answers to, with how many others — `abhishek` is
    /// shared with three. These are the reason matching is phrase-first.
    public let sharedWords: [(word: String, othersSharing: Int)]
    /// Folders whose `axes.person` resolves to this person, shallowest first.
    public let folders: [String]
    /// Documents already filed into those folders, from the filing memory.
    public let filedDocuments: Int
    /// Where those folders are, by the top level of the tree they sit under, busiest first —
    /// `Family 34 · School 12 · Immigration 10`.
    ///
    /// **A count alone does not say what a person's record covers.** "56 folders" is a number;
    /// "Family, School, Immigration" is what she has documents about, and it makes a thin record
    /// (`Girish — Family 5`) visible as thin rather than merely small.
    public let areas: [PersonArea]

    public var folderCount: Int { folders.count }

    /// Whether any single word names this person and nobody else.
    public var hasAnyUniqueWord: Bool { !uniqueWords.isEmpty }

    /// Whether a document can be attributed to this person **at all**.
    ///
    /// Two ways to qualify, and the second is why this is not simply ``hasAnyUniqueWord``: a
    /// distinctive word (`dani`, `muktha`), **or** a multi-word form the matcher can find as a
    /// phrase. Abhishek has no unique word — `abhishek` and `girish` are each three other people's
    /// too — yet "Abhishek Girish" names him unambiguously, so warning him to "add a full name"
    /// when he already has one is advice he cannot act on.
    ///
    /// **This is the whole difference between a caution that means something and one that fires on
    /// every row.** Rendered before it existed, all seven of a real household were amber.
    public var isAttributable: Bool {
        hasAnyUniqueWord || matchedForms.contains { PersonRegistry.words($0).count >= 2 }
    }

    /// "“abhishek” (also 3 others)", … — the shared-word detail, phrased once so the row's tooltip
    /// and the editor cannot describe the same fact differently.
    public var sharedSummary: String {
        sharedWords.map { entry in
            entry.othersSharing == 1 ? "“\(entry.word)” (also 1 other)"
                                     : "“\(entry.word)” (also \(entry.othersSharing) others)"
        }.joined(separator: ", ")
    }

    public init(personId: String, matchedForms: [String], uniqueWords: [String],
                sharedWords: [(word: String, othersSharing: Int)], folders: [String],
                filedDocuments: Int, areas: [PersonArea] = []) {
        self.personId = personId
        self.matchedForms = matchedForms
        self.uniqueWords = uniqueWords
        self.sharedWords = sharedWords
        self.folders = folders
        self.filedDocuments = filedDocuments
        self.areas = areas
    }

    /// Nothing known — the state a half-typed draft is in.
    public static let none = PersonFilingFacts(personId: "", matchedForms: [], uniqueWords: [],
                                               sharedWords: [], folders: [], filedDocuments: 0)

    public static func == (a: PersonFilingFacts, b: PersonFilingFacts) -> Bool {
        a.personId == b.personId && a.matchedForms == b.matchedForms
            && a.uniqueWords == b.uniqueWords && a.folders == b.folders
            && a.filedDocuments == b.filedDocuments
            && a.sharedWords.map(\.word) == b.sharedWords.map(\.word)
            && a.sharedWords.map(\.othersSharing) == b.sharedWords.map(\.othersSharing)
            && a.areas == b.areas
    }

    /// Everything known about one person.
    ///
    /// `profile` and `memory` are optional because both are survey artifacts: a roster edited on a
    /// machine that has never been surveyed still reports its names and its shared words, and simply
    /// has no folders or documents to count. That is the honest answer, not a degraded one.
    public static func make(for person: Person, registry: PersonRegistry,
                            profile: FolderProfile?, memory: FilingMemory?) -> PersonFilingFacts {
        let breakdown = registry.tokenBreakdown(for: person.id)
        let shared = breakdown.shared.map { word in
            (word: word, othersSharing: registry.othersSharing(word, with: person.id))
        }
        // Longest first: that is the order `detect` tries them in, and the order is the rule.
        let forms = ([person.displayName] + person.fullNames + person.aliases)
            .reduce(into: [String]()) { out, name in
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !out.contains(trimmed) { out.append(trimmed) }
            }
            .sorted { a, b in
                let wa = PersonRegistry.words(a).count, wb = PersonRegistry.words(b).count
                return wa == wb ? a.localizedStandardCompare(b) == .orderedAscending : wa > wb
            }

        var folders: [String] = []
        var docs = 0
        var areaFolders: [String: Int] = [:]
        var areaDocs: [String: Int] = [:]
        if let profile {
            for (path, entry) in profile.folders {
                guard let axis = entry.axes["person"],
                      registry.person(forAxisValue: axis) == person.id else { continue }
                folders.append(path)
                let filed = memory?.folders[path]?.docs ?? 0
                docs += filed
                // The top level of the path is the area. Anything deeper would be a different
                // answer for every person and would not group.
                let area = String(path.split(separator: "/").first ?? "")
                if !area.isEmpty {
                    areaFolders[area, default: 0] += 1
                    areaDocs[area, default: 0] += filed
                }
            }
            folders.sort { a, b in
                let da = a.split(separator: "/").count, db = b.split(separator: "/").count
                return da == db ? a.localizedStandardCompare(b) == .orderedAscending : da < db
            }
        }
        // Busiest first by documents, then by folders, then by name — a stable order, so the line
        // does not reshuffle between two renders of the same data.
        let areas = areaFolders.map { name, count in
            PersonArea(name: name, folders: count, documents: areaDocs[name] ?? 0)
        }.sorted { a, b in
            if a.documents != b.documents { return a.documents > b.documents }
            if a.folders != b.folders { return a.folders > b.folders }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return PersonFilingFacts(personId: person.id, matchedForms: forms,
                                 uniqueWords: breakdown.unique, sharedWords: shared,
                                 folders: folders, filedDocuments: docs, areas: areas)
    }
}
