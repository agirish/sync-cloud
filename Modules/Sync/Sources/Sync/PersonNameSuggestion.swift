import Foundation

/// A name form the tree keeps using for someone whose record does not have it.
public struct PersonNameSuggestion: Sendable, Equatable, Identifiable {
    public let personId: String
    /// The form spelled as the documents spell it — "Muktha Girish", not `muktha girish`.
    public let form: String
    /// How many filed documents use it. Recurrence is the whole claim: one file is an anecdote.
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

/// Learns name forms from documents already filed — the roster growing from the tree rather than
/// from typing.
///
/// **The rule is deliberately narrow, and the measurement is why.** The obvious version — recurring
/// word runs in the filenames inside a person's folders — is almost all noise on a real tree:
/// `Credit Report Shweta` (9 files), `Bio Pages MUKTHA`, `Wedding Gifts Anuraag`. The obvious fix,
/// vetoing words that many folders carry, is **backwards here**: a family surname is *broad*
/// precisely because the family is everywhere (`girish` is carried by 161 folders, `dani` by 73),
/// while document words like `oci` are narrow. Filtering on breadth keeps "Aditi OCI" and throws
/// away "Muktha Girish", which is the opposite of what is wanted.
///
/// So this suggests only what it can be *sure* is name-shaped: a run in which **every word is
/// already a name word of somebody on the roster**, starting with a word of the person whose folder
/// it is. That cannot invent "Pratiksha" out of nothing — discovering an entirely new word still
/// takes a human, and the section says so — but it has no false positives to apologise for.
/// Measured on the real tree: **0 suggestions** with the roster complete, and "Muktha Girish"
/// (7 occurrences) the moment her record lacks it.
public enum PersonNameLearning {

    /// The minimum number of documents that must use a form. One file is a typo; two is a habit.
    static let minimumOccurrences = 2
    /// Longest run considered — "Shweta Ravindra Dani" is three, and nothing in a real roster is
    /// longer without picking up document words.
    static let maximumWords = 3

    /// Suggestions for every person, from the filenames inside their folders.
    ///
    /// `fileNames` maps a folder's relative path to the names of the files directly inside it —
    /// passed in rather than read here, so the rule is testable without a disk and the I/O stays
    /// where the caller can schedule it.
    public static func suggestions(registry: PersonRegistry, profile: FolderProfile,
                                   fileNames: [String: [String]],
                                   dismissed: Set<String> = []) -> [PersonNameSuggestion] {
        guard !registry.isEmpty else { return [] }
        // Every word anybody in the household answers to. A run made only of these is a name;
        // a run containing anything else is a filename.
        var nameWords: Set<String> = []
        // The words a run may START with, per person: their DISPLAY name and their aliases — what
        // the household calls them — not every word they answer to.
        //
        // **Their full names are deliberately excluded, and a test caught why.** Aditi's record
        // holds "Aditi Abhishek", so `abhishek` is one of her words; a file called
        // `Report for Abhishek Girish.pdf` sitting in her folder then offered her *father's* name
        // as another name for her. A form leads with the given name in this household, and that is
        // the only word that identifies whose form it is.
        var leadWordsByPerson: [String: Set<String>] = [:]
        var formsByPerson: [String: Set<String>] = [:]
        // Every known form, whoever owns it — a run that is already somebody's name is never a
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
                // Longest first, and a match consumes nothing — a three-word form and the two-word
                // form inside it are both worth offering, and the user picks.
                for length in stride(from: min(maximumWords, lowered.count), through: 2, by: -1) {
                    for start in 0...(lowered.count - length) {
                        let run = Array(lowered[start..<(start + length)])
                        // Leads with what the household CALLS them — see `leadWordsByPerson`.
                        // Without this, every `<document type> <person>` filename in the tree is a
                        // candidate, and a shared surname hands one person another's name.
                        guard leads.contains(run[0]) else { continue }
                        guard run.allSatisfy({ nameWords.contains($0) }) else { continue }
                        let key = run.joined(separator: " ")
                        guard formsByPerson[personId]?.contains(key) != true else { continue }
                        // Already somebody's name — a document in Aditi's folder that says
                        // "Abhishek Girish" is naming her father, not teaching a form for her.
                        guard !claimedForms.contains(key) else { continue }
                        counts[personId, default: [:]][key, default: 0] += 1
                        // **Deterministic, not first-seen.** `fileNames` is a dictionary, so
                        // "the first one encountered" is whatever order the hash table happened to
                        // yield — the evidence shown for the same tree would change between two
                        // runs. Alphabetically first is arbitrary but stable, and stable is what
                        // makes the offer trustworthy.
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
        // Most-used first, then longest — a three-word form is the more specific teaching.
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
    static func spelledWords(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The folders to read, for a caller that has to do the reading — every folder the profile
    /// records as somebody's.
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
