import Foundation

/// Why a document counts as someone's.
///
/// Ordered by how much it is worth looking at, not by how strong it is. *In her folders* is the
/// tree's own filing and dominates by volume; *named elsewhere* is the payoff, because those rows
/// are candidate misfilings and no amount of browsing produces them.
public enum PersonEvidence: String, Sendable, Equatable, CaseIterable {
    /// The document sits under a folder whose `person` axis resolves to her.
    case herFolder
    /// Her name is in the file's own name, and she is not already the folder's person.
    case namedInFile
}

/// One document attributed to a person.
public struct PersonFile: Sendable, Equatable, Identifiable {
    /// Path relative to the surveyed root, as the corpus keys it.
    public let path: String
    public let evidence: PersonEvidence
    /// The name form that matched, for `namedInFile` — "Aditi Abhishek", "Mom". Nil for a folder
    /// match, where nothing in the document said anything.
    public let matchedForm: String?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }

    public init(path: String, evidence: PersonEvidence, matchedForm: String? = nil) {
        self.path = path
        self.evidence = evidence
        self.matchedForm = matchedForm
    }
}

/// Everything that is one person's, grouped by why.
public struct PersonFileSet: Sendable, Equatable {
    public let personId: String
    /// Files under a folder that is hers, grouped by that folder, largest first.
    public let herFolders: [(folder: String, files: [PersonFile])]
    /// Hers by name, filed somewhere that is not hers — the candidate misfilings.
    public let elsewhere: [PersonFile]

    public var total: Int { herFolders.reduce(0) { $0 + $1.files.count } + elsewhere.count }
    public var folderCount: Int { herFolders.count }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.personId == rhs.personId && lhs.elsewhere == rhs.elsewhere
            && lhs.herFolders.count == rhs.herFolders.count
            && zip(lhs.herFolders, rhs.herFolders).allSatisfy { $0.folder == $1.folder && $0.files == $1.files }
    }
}

/// Answers "all of Aditi's files" — the question the People registry made possible and nothing yet
/// asks.
///
/// **Read-only and computed on demand.** Nothing here is written, and no verdict is persisted: this
/// is the first of the staged channels (folder and filename), which is already the useful half —
/// "in her folders" he could reach by browsing, and "hers, filed elsewhere" is what no browse
/// produces. Page-1 membership and his own tags come later and are decisions rather than
/// computations.
///
/// ## The resolver this needed, and why it did not exist
///
/// "Which person's folder is this document under?" was written inline in four places
/// (`FilingRouter.makeIndex`, `FilingEngine.applyVerdicts`, `PersonFilingFacts.make`,
/// `PeopleOverview.make`), each of them asking it of a folder it already had. None of them could
/// answer it for an arbitrary *file*, because that needs walking up the ancestors until a folder
/// carries the axis — a document sits at `Family/Aditi/Classes/Swim/1.pdf` and the person axis is
/// three levels above it. ``person(forPath:)`` is that walk, and it is the piece the whole feature
/// was missing.
public enum PersonFiles {

    /// The person whose folder this path is inside, nearest ancestor first.
    ///
    /// **Nearest wins, and that is the whole subtlety.** `Immigration/OCI/Shweta/Aditi` is Aditi's
    /// folder inside her mother's; attributing its contents to Shweta because her folder is also an
    /// ancestor would be over-attribution of exactly the kind the registry's phrase matching took
    /// to zero. Walking up and stopping at the first resolvable axis gives the innermost claim.
    ///
    /// The path itself is included in the walk, so asking about a folder answers for that folder.
    public static func person(forPath path: String, profile: FolderProfile,
                              registry: PersonRegistry) -> String? {
        var current = path
        while !current.isEmpty, current != "/" {
            if let value = profile.folders[current]?.axes["person"],
               let id = registry.person(forAxisValue: value) {
                return id
            }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current else { break }
            current = parent
        }
        return nil
    }

    /// Whether a filename match is strong enough to attribute **without asking**.
    ///
    /// **A shared word alone is not**, and the corpus says why in one number: attributing on any
    /// match at all gave Dad *204* files "elsewhere" against 3 in his own folders, because `girish`
    /// is his first name, his wife's surname and his son's surname, so it appears on every document
    /// any of the three ever touched — `Muktha Girish - 2015-Win8MapR.pdf` among them.
    ///
    /// Two things are strong enough. A **phrase** — the matcher consumed a multi-word form, so
    /// "Aditi Abhishek" is hers and spends the surname doing it. Or a token **unique to her** in
    /// the roster: `dani`, `muktha`, `divit` name exactly one person and nobody else can claim
    /// them.
    ///
    /// This is the same discipline that took the router's over-attribution from 36 to 0, applied
    /// to a different question. What it deliberately does NOT do is guess: a weak match is not
    /// wrong, it is *unreviewed*, and the review queue that will hold it is the next stage. Until
    /// that exists a weak match is simply not shown, which is the honest half — it never claims
    /// something is hers on evidence four people could satisfy.
    ///
    /// ## Why this sits beside `attribute(fileName:pageSample:)` rather than inside it
    ///
    /// That function owns **precedence** — filename outranks page — and is shared with the filing
    /// engine and the cross-person veto. It applies no strength filter, and it is right not to:
    /// there, a shared word is checked against the destination folder's own person axis, so the
    /// veto has counter-evidence and a weak match is safe to consider. **Browsing has no
    /// destination to check against.** "Is this hers?" asked with nothing on the other side makes
    /// a shared word genuinely ambiguous, which is why the same input needs a stricter answer here
    /// — 204 rows against 3 real ones, measured. Changing `attribute` itself would tighten the
    /// filing path, which the corpus says is already correct.
    static func isStrong(_ match: PersonMatch, unique: Set<String>) -> Bool {
        if match.isPhrase { return true }
        return !match.words.isEmpty && match.words.allSatisfy { unique.contains($0) }
    }

    /// Everything attributable to one person across the surveyed corpus.
    ///
    /// - Parameters:
    ///   - personId: the registry id.
    ///   - corpus: the surveyed documents — **the file inventory**. The profile knows folders; only
    ///     the corpus knows which documents exist, so this is what makes a per-file answer possible
    ///     at all without touching the disk.
    public static func gather(personId: String, corpus: FilingCorpus, profile: FolderProfile,
                              registry: PersonRegistry) -> PersonFileSet {
        var byFolder: [String: [PersonFile]] = [:]
        var elsewhere: [PersonFile] = []
        // Resolved per FOLDER rather than per document: a folder with 112 files would otherwise
        // walk its ancestors 112 times, and the answer cannot differ between siblings.
        var folderPerson: [String: String?] = [:]
        let uniqueWords = Set(registry.tokenBreakdown(for: personId).unique)

        for path in corpus.documents.keys {
            let folder = (path as NSString).deletingLastPathComponent
            let owner: String?
            if let cached = folderPerson[folder] {
                owner = cached
            } else {
                owner = person(forPath: folder, profile: profile, registry: registry)
                folderPerson[folder] = owner
            }

            if owner == personId {
                byFolder[folder, default: []].append(PersonFile(path: path, evidence: .herFolder))
                continue
            }
            // Not her folder — so her NAME on the file is the only thing that can claim it, and
            // that claim is the interesting one.
            //
            // **Membership comes from the shipped `attribute(fileName:pageSample:)`**, which owns
            // the precedence rule the filing engine and the cross-person veto both use: the
            // filename outranks the page, and the page is consulted only when the name names
            // nobody. Stage 1 has no page channel, so `nil` — but it is called rather than
            // reimplemented so that when the page channel lands, precedence is already right here.
            let name = (path as NSString).lastPathComponent
            guard registry.attribute(fileName: name, pageSample: nil).contains(personId) else {
                continue
            }
            // …and then the strength gate, which `attribute` deliberately does not apply.
            let stem = (name as NSString).deletingPathExtension
            let report = registry.explain(in: stem)
            guard let match = report.matches.first(where: { $0.personId == personId }),
                  isStrong(match, unique: uniqueWords) else { continue }
            elsewhere.append(PersonFile(path: path, evidence: .namedInFile, matchedForm: match.form))
        }

        // Largest folder first, ties broken by name so the order is stable across runs.
        //
        // Written out rather than as one tuple comparison: the tuple form that does this reads
        // `($0.count, $1.folder) > ($1.count, $0.folder)`, with the folder operands deliberately
        // swapped to flip that half back to ascending. It was correct and looked exactly like the
        // bug where someone mixed up the operands, which is a bad thing for a sort nobody had a
        // test for.
        // Split across two statements with the element type spelled out: chaining `map` into
        // `sorted` with a ternary inside the predicate defeats the type checker outright ("unable
        // to type-check this expression in reasonable time"), which is the other reason the
        // original was a one-line tuple comparison.
        var groups: [(folder: String, files: [PersonFile])] = byFolder.map {
            (folder: $0.key, files: $0.value.sorted { $0.path < $1.path })
        }
        groups.sort { a, b in
            if a.files.count != b.files.count { return a.files.count > b.files.count }
            return a.folder < b.folder
        }
        return PersonFileSet(personId: personId, herFolders: groups,
                             elsewhere: elsewhere.sorted { $0.path < $1.path })
    }
}
