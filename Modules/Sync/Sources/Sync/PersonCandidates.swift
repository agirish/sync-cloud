import Foundation

/// One proposed member of the household, and the evidence for it: enough for a dialog to say
/// *"folders called Daughter appear under School, Health and Family; is Daughter a person?"*
public struct PersonCandidate: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// The folder name as the tree spells it (`Daughter`, not `daughter`): the roster records the
    /// name the folders use, so the proposal carries the spelling, not a normalised form.
    public let name: String
    /// The distinct parent folders it appears under, relative to the surveyed root and sorted
    /// (`""` is the root). The evidence the dialog shows: a name under `Family`, `School` and
    /// `Health` reads as a person; one under `Work/Vendors` alone reads as a company.
    public let parents: [String]
    /// How many folders carry this name, counted once per folder: the blast radius, and the
    /// tie-breaker in the list's order.
    public let folderCount: Int
    /// How many household folders this name is a direct child of: `Family/Daughter` counts,
    /// `Family/Photos/Reference` does not. The rank, as the evidence of a person rather than a kind
    /// of document.
    public let householdParents: Int

    public init(name: String, parents: [String], folderCount: Int, householdParents: Int = 0) {
        self.name = name
        self.parents = parents
        self.folderCount = folderCount
        self.householdParents = householdParents
    }
}

/// Proposes household names from folder names, and does not decide them.
///
/// The cold start, shaped like ``JurisdictionCandidates``: on a fresh Mac the roster is the one
/// thing a walk can't work out, and `PersonNameLearning` needs a profile and roster to start from.
///
/// Repetition is not the signal: document-type words (`Reference`, `Application`, `Statements`)
/// repeat harder than people do, so a repeat rule proposes hundreds of names. What works is the
/// folder that says what its children are: `Family/Daughter` is a person because `Family` says so.
/// The match is on a direct child only; `Family/Photos/Reference` is not a person. On a real tree
/// this proposes a few dozen names and finds everyone except the user, whom the You step collects
/// first.
///
/// Ranked by how many household folders a name sits directly under, not by folder count, which
/// would put `Reference` above every person.
///
/// It still over-proposes, which is the right way to err: a missed name is one the user must think
/// of unprompted, an extra one is a tick to refuse. The dialog must also let the user add a name,
/// or someone with no `Family/` folder can never be recorded.
///
/// Pure: no disk, no `FileManager`, no clock. It reads only the tree it is handed.
public enum PersonCandidates {

    /// Parents whose children are people by construction.
    ///
    /// The signal that beats repetition, and why a person with a single folder is still found:
    /// `Family/Uncle` is proposable where a bare `Uncle` is not. Matched on the whole component,
    /// case-insensitively.
    public static let householdParents: Set<String> = [
        "family", "people", "household", "kids", "children", "members", "relatives"
    ]

    /// A name is this many characters: below three admits initials and stray codes; above twenty
    /// is a sentence.
    public static let nameLength = 3...20

    /// Folder names that pass every shape test and are not people.
    ///
    /// Deliberately short: only words shaped exactly like a given name that really do repeat
    /// across parents on an ordinary tree. Anything a human can refuse at a glance stays out of it,
    /// since over-proposing costs a tick, and a stoplist grown to cover every tool and brand will
    /// eventually cover a person's real name.
    public static let notPeople: Set<String> = [
        "archive", "archives", "backup", "backups", "current", "draft", "drafts", "final",
        "general", "inbox", "misc", "new", "old", "other", "others", "personal", "private",
        "public", "scans", "shared", "temp", "templates", "todo", "unfiled", "work"
    ]

    /// Candidate household names found in `tree`, strongest first.
    ///
    /// - Parameters:
    ///   - tree: the root's children, as a walk produced them: the shape
    ///     ``FolderSurveyBuilder/build(tree:root:profileId:registry:jurisdictionValues:)`` takes, so
    ///     one walk feeds both.
    ///   - known: names already on the roster, in any spelling. Matching proposals are dropped: the
    ///     dialog is for who is missing.
    /// - Returns: candidates by ``PersonCandidate/householdParents`` descending (the evidence, not
    ///   the size), then ``PersonCandidate/folderCount``, then name ascending. Names are unique, so
    ///   this is a total order and doesn't wobble between runs. `theOrderIsEvidenceFirstNotSizeFirst`
    ///   pins the keys.
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
            // A name nested under itself is one branch, not several (as in
            // `JurisdictionCandidates`, where `A/US/B/US` must not count twice).
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
            // A direct child of a household folder, not a descendant: `Family` says nothing about
            // `Family/Photos/Reference`. Counted once; "under one at all" is `householdHits > 0`.
            let householdHits = parents.count { parent in
                guard let last = parent.split(separator: "/").last else { return false }
                return householdParents.contains(last.folded)
            }
            guard householdHits > 0 else { return nil }
            return PersonCandidate(name: spelling, parents: parents.sorted(),
                                   folderCount: countByName[key] ?? 0,
                                   householdParents: householdHits)
        }
        // Ranked by the evidence, not by size: how many household folders a name sits directly
        // under. Folder count alone would rank `Reference` above every person; it only breaks ties.
        .sorted { ($0.householdParents, $0.folderCount, $1.name) > ($1.householdParents, $1.folderCount, $0.name) }
    }

    /// Whether a folder name could be somebody's.
    ///
    /// Shape only. Capitalised-then-lower excludes the all-caps names `JurisdictionCandidates`
    /// finds (`US`, `EMP`, `TODO`), so the two rules never claim the same component. A digit
    /// excludes `2024 Taxes`; whitespace excludes `Tax Returns` but not `Anne-Marie`.
    static func isNameShaped(_ name: String) -> Bool {
        guard nameLength.contains(name.count), !notPeople.contains(name.folded) else { return false }
        guard let first = name.first, first.isUppercase else { return false }
        // Letters, plus the joiners a name uses. No spaces: `Tax Returns` is name-shaped otherwise.
        guard name.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "." }) else {
            return false
        }
        // At least one lowercase letter, so an acronym is not a person; `IN` and `EMP` are the
        // jurisdiction rule's.
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
