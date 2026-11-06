import Foundation

/// A name form the tree keeps using for someone whose record does not have it.
public struct PersonNameSuggestion: Sendable, Equatable, Identifiable {
    public let personId: String
    /// The form spelled as the documents spell it: "Granny Elder", not `granny elder`.
    public let form: String
    /// How many filed documents use it. Recurrence is the claim: one file is an anecdote.
    public let occurrences: Int
    /// One filename that uses it, so the offer can show its evidence rather than assert a count.
    public let exampleFile: String

    public var id: String { personId + "|" + form.lowercased() }

    public init(personId: String, form: String, occurrences: Int, exampleFile: String) {
        self.personId = personId
        self.form = form
        self.occurrences = occurrences
        self.exampleFile = exampleFile
    }
}

/// Learns name forms from documents already filed, so the roster grows from the tree rather than
/// from typing.
///
/// Deliberately narrow. Any recurring word run in a person's filenames is mostly noise
/// (`Credit Report Mother`, `Wedding Gifts Uncle`), and vetoing words many folders carry is
/// backwards: a family surname is broad because the family is everywhere, while document words
/// like `oci` are narrow.
///
/// So this suggests only runs in which every word is already a name word of someone on the roster,
/// starting with a word of the person whose folder it is. It can't discover a brand-new word (that
/// still takes a human, and the section says so), but it gives no false positives: on a complete
/// roster it suggests nothing.
public enum PersonNameLearning {

    /// The minimum number of documents that must use a form. One file is a typo; two is a habit.
    static let minimumOccurrences = 2
    /// Longest run considered: "Mother Inlaw Maiden" is three, and longer runs pick up document
    /// words.
    static let maximumWords = 3

    /// Suggestions for every person, from the filenames inside their folders.
    ///
    /// `fileNames` maps a folder's relative path to the names of the files directly inside it,
    /// passed in so the rule tests without a disk and the caller schedules the I/O.
    public static func suggestions(registry: PersonRegistry, profile: FolderProfile,
                                   fileNames: [String: [String]],
                                   dismissed: Set<String> = []) -> [PersonNameSuggestion] {
        guard !registry.isEmpty else { return [] }
        // Every word anybody in the household answers to. A run made only of these is a name;
        // a run containing anything else is a filename.
        var nameWords: Set<String> = []
        // The words a run may start with, per person: their display name and aliases (what the
        // household calls them), not every word they answer to. Full names are excluded: a
        // daughter whose full name carries her father's name would otherwise be offered "Father
        // Elder", from a file about him in her folder, as a name of hers.
        var leadWordsByPerson: [String: Set<String>] = [:]
        var formsByPerson: [String: Set<String>] = [:]
        // Every known form, whoever owns it: a run that is already somebody's name is never a
        // discovery about somebody else.
        var claimedForms: Set<String> = []
        for person in registry.people {
            var words: Set<String> = []
            var leads: Set<String> = []
            var forms: Set<String> = []
            for name in [person.displayName] + person.fullNames + person.aliases {
                let parts = PersonRegistry.words(name)
                words.formUnion(parts.filter { $0.count >= 2 })
                forms.insert(parts.joined(separator: " "))
            }
            for name in [person.displayName] + person.aliases {
                leads.formUnion(PersonRegistry.words(name).filter { $0.count >= 2 })
            }
            leadWordsByPerson[person.id] = leads
            formsByPerson[person.id] = forms
            claimedForms.formUnion(forms)
            nameWords.formUnion(words)
        }

        var counts: [String: [String: Int]] = [:]      // person → form → count
        var spelling: [String: [String: String]] = [:] // person → form → as written
        var example: [String: [String: String]] = [:]

        for (folder, names) in fileNames {
            guard let axis = profile.folders[folder]?.axes["person"],
                  let personId = registry.person(forAxisValue: axis),
                  let leads = leadWordsByPerson[personId] else { continue }
            for fileName in names {
                let written = spelledWords((fileName as NSString).deletingPathExtension)
                let lowered = written.map { $0.lowercased() }
                guard lowered.count >= 2 else { continue }
                // Longest first, and a match consumes nothing: a three-word form and the two-word
                // form inside it are both offered, and the user picks.
                for length in stride(from: min(maximumWords, lowered.count), through: 2, by: -1) {
                    for start in 0...(lowered.count - length) {
                        let run = Array(lowered[start..<(start + length)])
                        // Leads with what the household calls them (`leadWordsByPerson`).
                        // Otherwise every `<document type> <person>` filename is a candidate, and a
                        // shared surname hands one person another's name.
                        guard leads.contains(run[0]) else { continue }
                        guard run.allSatisfy({ nameWords.contains($0) }) else { continue }
                        let key = run.joined(separator: " ")
                        guard formsByPerson[personId]?.contains(key) != true else { continue }
                        // Already somebody's name: "Father Elder" in Daughter's folder names her
                        // father, not a form for her.
                        guard !claimedForms.contains(key) else { continue }
                        counts[personId, default: [:]][key, default: 0] += 1
                        // Alphabetically first, not first-seen: `fileNames` is a dictionary, so
                        // first-seen would change the evidence shown between runs on the same tree.
                        let asWritten = written[start..<(start + length)].joined(separator: " ")
                        if let existing = example[personId]?[key] {
                            if fileName.localizedStandardCompare(existing) == .orderedAscending {
                                example[personId, default: [:]][key] = fileName
                                spelling[personId, default: [:]][key] = asWritten
                            }
                        } else {
                            example[personId, default: [:]][key] = fileName
                            spelling[personId, default: [:]][key] = asWritten
                        }
                    }
                }
            }
        }

        var out: [PersonNameSuggestion] = []
        for (personId, forms) in counts {
            for (key, count) in forms where count >= minimumOccurrences {
                let form = spelling[personId]?[key] ?? key
                let suggestion = PersonNameSuggestion(
                    personId: personId, form: form, occurrences: count,
                    exampleFile: example[personId]?[key] ?? "")
                guard !dismissed.contains(suggestion.id) else { continue }
                out.append(suggestion)
            }
        }
        // Most-used first, then longest: a three-word form is the more specific teaching.
        out.sort { a, b in
            if a.occurrences != b.occurrences { return a.occurrences > b.occurrences }
            let wa = PersonRegistry.words(a.form).count, wb = PersonRegistry.words(b.form).count
            if wa != wb { return wa > wb }
            return a.form.localizedStandardCompare(b.form) == .orderedAscending
        }
        return out
    }

    /// Words as the filename writes them, so a suggestion can be offered in the tree's own spelling
    /// rather than lowercased by the matcher's tokenizer.
    ///
    /// Uses the matcher's own word boundaries, via ``PersonRegistry/spelledWords(_:)``: keys built
    /// here are compared with the matcher's, so a second split rule would disagree on non-ASCII names.
    static func spelledWords(_ s: String) -> [String] {
        PersonRegistry.spelledWords(s)
    }

    /// The folders a caller must read: every folder the profile records as somebody's.
    public static func personFolders(registry: PersonRegistry,
                                     profile: FolderProfile) -> [String] {
        profile.folders.compactMap { path, entry in
            guard let axis = entry.axes["person"],
                  registry.person(forAxisValue: axis) != nil else { return nil }
            return path
        }
        .sorted()
    }
}
