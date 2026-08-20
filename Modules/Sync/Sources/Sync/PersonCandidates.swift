import Foundation

/// One proposed member of the household, and the evidence for it — enough for a dialog to say
/// *"folders called Aditi appear under School, Health and Family; is Aditi a person?"*
public struct PersonCandidate: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// The folder name as the tree spells it — `Aditi`, not `aditi`. The roster records the name the
    /// folders use, so the proposal has to carry the spelling rather than a normalised form.
    public let name: String
    /// The distinct parent folders it appears under, relative to the surveyed root and sorted.
    /// `""` is the root itself. **This is the evidence and it is what the dialog shows**: a name
    /// under `Family`, `School` and `Health` reads as a person; one under `Work/Vendors` alone reads
    /// as a company.
    public let parents: [String]
    /// How many folders carry this name, counted once per folder. The blast radius, and what the
    /// list is ordered by.
    public let folderCount: Int
    /// How many household folders this name is a direct child of — `Family/Aditi` counts, and
    /// `Family/Photos/Reference` does not. The rank, because it is the evidence that this is a
    /// person rather than a kind of document.
    public let householdParents: Int

    public init(name: String, parents: [String], folderCount: Int, householdParents: Int = 0) {
        self.name = name
        self.parents = parents
        self.folderCount = folderCount
        self.householdParents = householdParents
    }
}

/// Proposes household names from folder names — **and does not decide them.**
///
/// The same shape as ``JurisdictionCandidates`` and for the same reason: on a fresh machine the
/// roster is the one thing a walk cannot work out for itself. `PersonNameLearning` already learns
/// name *forms* from filenames, but it needs a profile and a roster to start from, and a machine
/// being set up has neither. This is the cold start.
///
/// **Measured against this machine's real roster and tree, and every earlier rule was thrown out by
/// the measurement rather than by review.** Run over `~/Documents` and compared with the seven
/// people in `people.json`:
///
/// | Rule | Proposed | Of the 7 found |
/// |---|---|---|
/// | repeats under ≥2 distinct parents | **214** | 7 |
/// | repeats across ≥2 top-level branches | **134** | 7 |
/// | anywhere beneath a household folder | **79** | 6 |
/// | **direct child of a household folder** | **28** | **6** |
///
/// The first two are the shape `JurisdictionCandidates` uses, and on a document tree they are close
/// to useless: `Reference` (41 folders), `Application` (32) and `Statements` (29) all outranked
/// every real person. Document-type words repeat *harder* than people do, so repetition cannot be
/// the signal — 214 names to confirm is not a step, it is a second job.
///
/// What works is the one folder that says what its children are. `Family/Aditi` is a person because
/// `Family` said so; `Family/Photos/Reference` is not, which is why the match is on a **direct**
/// child (matching anywhere in the path is the 79-name row).
///
/// **The seventh person is the user, and the form already asked.** The one roster member this misses
/// on the reference tree is `Abhishek`, who has no `Family/Abhishek` because the tree is his — and
/// the You step collects him before this step is reached. That is a property of the design rather
/// than a lucky escape: the proposer's job is *everyone else*.
///
/// Ranked by how many household folders a name sits directly under, not by folder count: on the
/// reference tree the count ordering put `Reference` above every person. With the evidence ordering,
/// six of the seven lead the list.
///
/// **It still over-proposes, and that is the direction to err in.** A name it misses is a person the
/// user must think of unprompted; a name it over-proposes is one tick to refuse with the evidence
/// beside it. `Events`, `Cray` and `Hiring` are in those 28. The dialog must also let the user ADD
/// a name, or a household member with no `Family/` folder can never be recorded at all.
///
/// Pure: no disk, no `FileManager`, no clock. It reads the tree it is handed and nothing else.
public enum PersonCandidates {

    /// Parents whose children are people by construction.
    ///
    /// **The one signal that beats repetition**, and the reason a person with a single folder is
    /// still findable: a folder called `Family` says what its children are, so `Family/Anuraag` is
    /// proposable where a bare `Anuraag` under one parent is not. Matched on the whole component,
    /// case-insensitively.
    public static let householdParents: Set<String> = [
        "family", "people", "household", "kids", "children", "members", "relatives"
    ]

    /// A name is this many characters. Below three admits initials and stray codes; above twenty is
    /// a sentence rather than a name.
    public static let nameLength = 3...20

    /// Folder names that pass every shape test and are not people.
    ///
    /// **A stoplist is a weak instrument and this one is deliberately short.** It carries only words
    /// that (a) look exactly like a given name — capitalised, alphabetic, ordinary length — and
    /// (b) really do repeat across parents on an ordinary tree, so repetition cannot filter them.
    /// Anything the evidence line would let a human refuse at a glance is left in: over-proposing
    /// costs a tick, and a long list is one that quietly drops somebody's actual name. `Claude` is
    /// on this tree and is not on it here for exactly that reason — a stoplist that grows to cover
    /// every tool and brand will eventually cover a person.
    public static let notPeople: Set<String> = [
        "archive", "archives", "backup", "backups", "current", "draft", "drafts", "final",
        "general", "inbox", "misc", "new", "old", "other", "others", "personal", "private",
        "public", "scans", "shared", "temp", "templates", "todo", "unfiled", "work"
    ]

    /// Candidate household names found in `tree`, strongest first.
    ///
    /// - Parameters:
    ///   - tree: the root's children, as a walk produced them — the shape
    ///     ``FolderSurveyBuilder/build(tree:root:profileId:registry:jurisdictionValues:)`` takes, so
    ///     one walk feeds both without either guessing at the other's convention.
    ///   - known: names already on the roster, in any spelling. Proposed names that match one are
    ///     dropped: the dialog is for who is *missing*, and offering somebody the user already added
    ///     reads as the app not knowing what it has.
    /// - Returns: candidates ordered by ``PersonCandidate/householdParents`` descending — the
    ///   evidence, not the size — then by ``PersonCandidate/folderCount``, then by name ascending.
    ///   The strongest is first and the order does not wobble between runs: names are unique in the
    ///   result, so the comparison is a total order rather than a stable-sort assumption.
    ///   Ordering on the raw count instead put `Reference` above every real person on the reference
    ///   tree, which is why the count only breaks ties. `theOrderIsEvidenceFirstNotSizeFirst` is
    ///   what holds these three keys in this order.
    public static func propose(tree: [FileNode], known: Set<String> = []) -> [PersonCandidate] {
        var folders: [String] = []
        for node in tree { collect(node, prefix: "", into: &folders) }

        let knownFolded = Set(known.map { $0.folded })
        var parentsByName: [String: Set<String>] = [:]
        var countByName: [String: Int] = [:]
        var spellingByName: [String: String] = [:]

        for path in folders {
            let cut = path.lastIndex(of: "/")
            let name = cut.map { String(path[path.index(after: $0)...]) } ?? path
            guard isNameShaped(name), !knownFolded.contains(name.folded) else { continue }
            let parent = cut.map { String(path[path.startIndex..<$0]) } ?? ""
            // A name nested under itself is one branch, not several — the same correction
            // `JurisdictionCandidates` needed, where `A/US/B/US` cleared a parent bar on its own.
            guard !parent.split(separator: "/").contains(where: { $0.folded == name.folded })
            else { continue }
            let key = name.folded
            parentsByName[key, default: []].insert(parent)
            countByName[key, default: 0] += 1
            // First spelling wins, and the walk is sorted, so this is stable between runs.
            if spellingByName[key] == nil { spellingByName[key] = name }
        }

        return parentsByName.compactMap { key, parents -> PersonCandidate? in
            guard let spelling = spellingByName[key] else { return nil }
            // **A direct child of a household folder, not a descendant.** `Family` says what its
            // children are; it says nothing about `Family/Photos/Reference`. Matching anywhere in
            // the path proposed 79 names on the reference tree with `Reference(41)` at the top.
            //
            // Counted once and tested as a count: "is it under one at all" is exactly
            // `householdHits > 0`, and asking the same question twice through two separate
            // `parents` walks is two places for one rule to drift.
            let householdHits = parents.count { parent in
                guard let last = parent.split(separator: "/").last else { return false }
                return householdParents.contains(last.folded)
            }
            guard householdHits > 0 else { return nil }
            return PersonCandidate(name: spelling, parents: parents.sorted(),
                                   folderCount: countByName[key] ?? 0,
                                   householdParents: householdHits)
        }
        // **Ranked by the evidence, not by size.** Sorting on folder count alone put `Reference`,
        // which is a direct child of one household folder and 41 folders elsewhere, above every
        // real person on the reference tree. How many *household* folders a name sits directly
        // under is the signal; the raw count only breaks ties.
        .sorted { ($0.householdParents, $0.folderCount, $1.name) > ($1.householdParents, $1.folderCount, $0.name) }
    }

    /// Whether a folder name could be somebody's.
    ///
    /// **Shape only, and each clause earns its place on the reference tree.** Capitalised-then-lower
    /// excludes the all-caps names `JurisdictionCandidates` exists to find (`US`, `HPE`, `TODO`) —
    /// the two rules read the same tree and must not both claim the same component. A digit excludes
    /// `2024` and `2024 Taxes`. Whitespace excludes `Tax Returns` without excluding `Anne-Marie`.
    static func isNameShaped(_ name: String) -> Bool {
        guard nameLength.contains(name.count), !notPeople.contains(name.folded) else { return false }
        guard let first = name.first, first.isUppercase else { return false }
        // Letters, plus the joiners a name really uses. No spaces: a folder called `Tax Returns` is
        // shaped like a name in every other respect.
        guard name.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "." }) else {
            return false
        }
        // At least one lowercase letter, so an acronym is not a person. `IN` and `HPE` are the
        // jurisdiction rule's to propose; a name that is entirely uppercase is not a given name.
        return name.dropFirst().contains { $0.isLowercase }
    }

    /// Walks a node and its children, recording every folder path relative to the root.
    private static func collect(_ node: FileNode, prefix: String, into folders: inout [String]) {
        guard node.isDirectory else { return }
        let path = prefix.isEmpty ? node.name : prefix + "/" + node.name
        folders.append(path)
        for child in node.children ?? [] { collect(child, prefix: path, into: &folders) }
    }
}

private extension StringProtocol {
    /// Case- and diacritic-folded, which is how two spellings of one name are recognised as one.
    var folded: String {
        String(self).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
