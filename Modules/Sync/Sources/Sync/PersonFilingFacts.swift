import Foundation

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
                filedDocuments: Int) {
        self.personId = personId
        self.matchedForms = matchedForms
        self.uniqueWords = uniqueWords
        self.sharedWords = sharedWords
        self.folders = folders
        self.filedDocuments = filedDocuments
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
        if let profile {
            for (path, entry) in profile.folders {
                guard let axis = entry.axes["person"],
                      registry.person(forAxisValue: axis) == person.id else { continue }
                folders.append(path)
                docs += memory?.folders[path]?.docs ?? 0
            }
            folders.sort { a, b in
                let da = a.split(separator: "/").count, db = b.split(separator: "/").count
                return da == db ? a.localizedStandardCompare(b) == .orderedAscending : da < db
            }
        }
        return PersonFilingFacts(personId: person.id, matchedForms: forms,
                                 uniqueWords: breakdown.unique, sharedWords: shared,
                                 folders: folders, filedDocuments: docs)
    }
}
