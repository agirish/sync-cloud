import Foundation

/// Why a document counts as someone's.
///
/// Ordered by how much it is worth looking at, not by how strong it is. *In their own folders* is
/// the tree's own filing and dominates by volume; *named elsewhere* is the payoff, because those
/// rows are candidate misfilings and no amount of browsing produces them.
public enum PersonEvidence: String, Sendable, Equatable, CaseIterable {
    /// The document sits under a folder whose `person` axis resolves to them.
    case ownFolder
    /// Their name is in the file's own name, and they are not already the folder's person.
    case namedInFile
    /// Page 1 named them — and named nobody else. **Never enough to claim a document**, which is why
    /// this evidence only ever appears on a review row; see ``PersonFiles``.
    case namedOnPage
    /// He said so. The only evidence that is a decision rather than a computation, and the only one
    /// that outranks everything else.
    case taggedByYou
}

/// Why a document is waiting for a verdict rather than being claimed or ignored.
public enum PersonReviewReason: Sendable, Equatable {
    /// Their name is in the filename, but only as a word other people answer to as well.
    /// `sharedWith` is how many of them.
    case sharedWordInName(word: String, sharedWith: Int)
    /// Page 1 named them, and named nobody else. The filename named no one at all.
    case namedOnPageOnly(form: String)
}

/// One document attributed to a person.
public struct PersonFile: Sendable, Equatable, Identifiable {
    /// Path relative to the surveyed root, as the corpus keys it.
    public let path: String
    public let evidence: PersonEvidence
    /// The name form that matched, for `namedInFile` — "Aditi Abhishek", "Mom". Nil for a folder
    /// match, where nothing in the document said anything.
    public let matchedForm: String?

    /// Why this row is waiting for a verdict — set only on ``PersonFileSet/review`` rows, where the
    /// user is being asked a question and has to be told what is being asked about.
    public let reason: PersonReviewReason?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }

    public init(path: String, evidence: PersonEvidence, matchedForm: String? = nil,
                reason: PersonReviewReason? = nil) {
        self.path = path
        self.evidence = evidence
        self.matchedForm = matchedForm
        self.reason = reason
    }
}

/// Where a person gather is in its life, for the surface that shows it.
///
/// The gather sweeps every surveyed document and reads a multi-megabyte corpus first, so there is
/// a real interval between accepting the offer and having the answer. The phase is what lets the
/// slot say so instead of sitting on the previous content — a slow accept with nothing on screen
/// reads as "nothing happened", which invites the second ⌘↩ that used to race two sweeps.
public enum PersonGatherPhase: Sendable, Equatable {
    /// The sweep is running; the slot should say so, not show stale content.
    case gathering
    /// The answer.
    case ready(PersonFileSet)
    /// The sweep could not run at all — today, only because the corpus has not been surveyed.
    /// The reason is shown in the slot itself: a transient banner is gone by the time the empty
    /// slot makes anyone wonder why nothing appeared.
    case failed(String)
}

/// Everything that is one person's, grouped by why.
public struct PersonFileSet: Sendable, Equatable {
    public let personId: String
    /// Files under a folder that is theirs, grouped by that folder, largest first.
    public let ownFolders: [(folder: String, files: [PersonFile])]
    /// Theirs by name, filed outside their folders — the candidate misfilings.
    public let elsewhere: [PersonFile]
    /// Evidence too weak to claim a document on, waiting for a verdict.
    ///
    /// **Not wrong — unreviewed.** Stage 1 suppressed these rows because there was nowhere to put
    /// them; this is where they belong, and a verdict on one is remembered so the same weak match
    /// never returns.
    public let review: [PersonFile]

    /// The answer to "how many are theirs" — **the claimed rows only.** Review rows are questions,
    /// not answers, and counting them here would make the header assert something the queue exists
    /// to ask.
    public var total: Int { ownFolders.reduce(0) { $0 + $1.files.count } + elsewhere.count }
    public var folderCount: Int { ownFolders.count }

    /// Public so callers outside this module can build one — the app target's supersede tests
    /// need an answer to put in a slot, and `@testable` is not available to them across the
    /// package boundary.
    ///
    /// **The ordering is an invariant this initialiser cannot enforce.** ``PersonFiles/gather(personId:corpus:profile:registry:)``
    /// hands over `ownFolders` sorted largest-first (ties by name) and each `files` sorted by path,
    /// and `PersonView` relies on it: the folder list is truncated with `prefix(8)`, so an unsorted
    /// set would silently show eight arbitrary folders while the header went on reporting the true
    /// total. Production only ever builds one through `gather`. A fixture that builds one directly
    /// and cares which rows are visible has to sort it the same way.
    public init(personId: String, ownFolders: [(folder: String, files: [PersonFile])],
                elsewhere: [PersonFile], review: [PersonFile] = []) {
        self.personId = personId
        self.ownFolders = ownFolders
        self.elsewhere = elsewhere
        self.review = review
    }

    /// The set as it will be once a verdict on `path` has been recorded.
    ///
    /// **Why the view does not simply re-gather.** Re-running the sweep is the obviously correct
    /// refresh and it is the wrong one to reach for here: it re-reads a 4.9 MB corpus and walks
    /// 10,171 documents to change one row, and — because the slot shows its phase — it puts a
    /// "Gathering…" spinner on screen between every keystroke of a review session. Twelve verdicts
    /// would be twelve sweeps.
    ///
    /// So the change is applied here instead, and this function exists to be **the same answer the
    /// next gather gives**, which is a property a test can hold it to rather than a hope: a
    /// confirmation moves the row to `elsewhere` as ``PersonEvidence/taggedByYou``, a rejection
    /// drops it, and nothing else moves. The verdict itself is already on disk by the time this is
    /// called; this is the display catching up, not a second source of truth.
    public func applying(verdict isTheirs: Bool, to path: String) -> PersonFileSet {
        guard review.contains(where: { $0.path == path }) else { return self }
        let remaining = review.filter { $0.path != path }
        guard isTheirs else {
            return PersonFileSet(personId: personId, ownFolders: ownFolders,
                                 elsewhere: elsewhere, review: remaining)
        }
        let claimed = elsewhere + [PersonFile(path: path, evidence: .taggedByYou)]
        return PersonFileSet(personId: personId, ownFolders: ownFolders,
                             elsewhere: claimed.sorted { $0.path < $1.path },
                             review: remaining)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.personId == rhs.personId && lhs.elsewhere == rhs.elsewhere && lhs.review == rhs.review
            && lhs.ownFolders.count == rhs.ownFolders.count
            && zip(lhs.ownFolders, rhs.ownFolders).allSatisfy { $0.folder == $1.folder && $0.files == $1.files }
    }
}

/// Answers "all of Aditi's files" — the question the People registry made possible and nothing yet
/// asks.
///
/// **Read-only and computed on demand.** Nothing here is written, and no verdict is persisted: this
/// is the first of the staged channels (folder and filename), which is already the useful half —
/// "in their folders" he could reach by browsing, and "theirs, filed elsewhere" is what no browse
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
    ///
    /// Throws only `CancellationError`, checked once per stride of documents: the sweep is the
    /// long half of a gather, and a superseded one (a second ⌘↩, or the scope cleared while it
    /// runs) should stop walking rather than finish an answer nobody will see. Outside a
    /// cancelled task the checks never fire, so synchronous callers just write `try`.
    /// The page sample a document offers, from the anchors the survey already extracted.
    ///
    /// **A sorted, de-duplicated bag of words, not the page.** ``FilingCorpus`` stores anchors that
    /// way so a diff of two corpora shows real change, which means word order is gone by the time
    /// anything reads them back. Two consequences, both measured over the live tree:
    ///
    /// - **Real phrases are lost.** "Aditi Abhishek" on page 1 sorts to `abhishek … aditi`, so the
    ///   phrase matcher cannot see it and the page can only ever contribute single distinctive
    ///   words. That is a ceiling on this channel, not a bug in it.
    /// - **Phrases could in principle be invented**, from tokens that happen to land next to each
    ///   other alphabetically. Measured across 1,304 documents carrying text: **zero**, which is why
    ///   there is no barrier token here separating the anchors. `PersonChannelReplayTests` asserts
    ///   that zero, so if a roster change ever makes it non-zero the fix is a barrier and this
    ///   comment is where to start.
    static func pageSample(_ document: FilingCorpusDocument) -> String? {
        document.anchors.isEmpty ? nil : document.anchors.joined(separator: " ")
    }

    /// Whether page-1 evidence is worth putting in front of the user for this person.
    ///
    /// **Exactly one person, or nothing** — and this single rule is what makes the channel usable.
    /// A page-1 mention is *testimony*: a swim-class invoice prints the parent who pays, a bank
    /// nomination form prints the spouse who is the nominee, and a joint account prints both. Asked
    /// of every document whose filename names nobody, the page named *somebody* on **4,568** of
    /// them — 2,011 for one person alone, all of them documents that merely mention her. Requiring
    /// the page to name one person and one only takes that to **635**, and the survivors are the
    /// case this channel exists for: her disability claim, his bank KYC form, her mother's broker
    /// form — scans whose names say nothing at all.
    ///
    /// Note what this is *not*: it is not the strength gate. `dani` is unique to Shweta and passes
    /// ``isStrong`` easily, and it is on all 2,011 of those rows. Strength asks "could this word
    /// mean somebody else"; this asks "is this document about one person or a household".
    static func pageNamesOnly(_ personId: String, in report: PersonMatchReport) -> PersonMatch? {
        var seen: PersonMatch?
        for match in report.matches {
            if let seen, seen.personId != match.personId { return nil }
            seen = match
        }
        guard let seen, seen.personId == personId else { return nil }
        return seen
    }

    public static func gather(personId: String, corpus: FilingCorpus, profile: FolderProfile,
                              registry: PersonRegistry,
                              tags: PersonTagIndex = PersonTagIndex(tags: [])) throws -> PersonFileSet {
        var byFolder: [String: [PersonFile]] = [:]
        var elsewhere: [PersonFile] = []
        var review: [PersonFile] = []
        // Confirmations that no channel produced a row for — a photo carries no text and no name
        // either way, so without this the verdict would be recorded and then invisible.
        var unseenConfirmations = tags.confirmedPaths(for: personId)
        // Resolved per FOLDER rather than per document: a folder with 112 files would otherwise
        // walk its ancestors 112 times, and the answer cannot differ between siblings.
        var folderPerson: [String: String?] = [:]
        let uniqueWords = Set(registry.tokenBreakdown(for: personId).unique)

        // Coarse on purpose: a cancellation check is cheap but not free, and 256 documents of
        // extra work after a cancel is invisible while 10,171 of them is the whole problem.
        let cancellationStride = 256
        var sinceCheck = 0

        for (path, document) in corpus.documents {
            sinceCheck += 1
            if sinceCheck >= cancellationStride {
                sinceCheck = 0
                try Task.checkCancellation()
            }
            let folder = (path as NSString).deletingLastPathComponent
            let owner: String?
            if let cached = folderPerson[folder] {
                owner = cached
            } else {
                owner = person(forPath: folder, profile: profile, registry: registry)
                folderPerson[folder] = owner
            }

            if owner == personId {
                byFolder[folder, default: []].append(PersonFile(path: path, evidence: .ownFolder))
                unseenConfirmations.remove(path)
                continue
            }

            // **His verdict outranks every channel, both ways.** A confirmation claims the document
            // whatever the evidence says, and a rejection ends the matter — which is the entire
            // reason the file exists: the channels are deterministic, so without a remembered "no"
            // the same weak match comes back on every gather forever.
            if let verdict = tags.verdict(personId: personId, path: path) {
                unseenConfirmations.remove(path)
                if verdict == .confirmed {
                    elsewhere.append(PersonFile(path: path, evidence: .taggedByYou))
                }
                continue
            }

            // Not her folder — so what the document *says* is the only thing that can speak for it.
            //
            // **Membership comes from the shipped `attribution(fileName:pageSample:)`**, which owns
            // the precedence rule the filing engine and the cross-person veto also use: the filename
            // outranks the page, and the page is read only when the name names nobody. Asking it
            // rather than re-deriving it is what keeps one answer to that question in the codebase.
            let name = (path as NSString).lastPathComponent
            let sample = pageSample(document)
            let (people, tier) = registry.attribution(fileName: name, pageSample: sample)
            guard people.contains(personId) else { continue }

            switch tier {
            case .fileName:
                // The strength gate, which `attribution` deliberately does not apply — see above.
                let stem = (name as NSString).deletingPathExtension
                let report = registry.explain(in: stem)
                guard let match = report.matches.first(where: { $0.personId == personId }) else {
                    continue
                }
                if isStrong(match, unique: uniqueWords) {
                    elsewhere.append(PersonFile(path: path, evidence: .namedInFile,
                                                matchedForm: match.form))
                } else {
                    // Weak: one word, and other people answer to it too. Not wrong — unreviewed.
                    let word = match.words.first ?? match.form
                    review.append(PersonFile(
                        path: path, evidence: .namedInFile, matchedForm: match.form,
                        reason: .sharedWordInName(
                            word: word,
                            sharedWith: registry.othersSharing(word, with: personId))))
                }
            case .pageText:
                guard let sample,
                      let match = pageNamesOnly(personId, in: registry.explain(in: sample))
                else { continue }
                // **Always a review row, never a claim.** The page is testimony; see `pageNamesOnly`.
                review.append(PersonFile(path: path, evidence: .namedOnPage,
                                         matchedForm: match.form,
                                         reason: .namedOnPageOnly(form: match.form)))
            case .identifier, .none:
                continue
            }
        }

        // Confirmations at paths the corpus no longer holds — the file was moved or deleted outside
        // the app since the verdict was made. Kept rather than dropped: a verdict silently vanishing
        // is worse than one pointing at a path that has moved, and the row still reveals.
        for path in unseenConfirmations.sorted() {
            elsewhere.append(PersonFile(path: path, evidence: .taggedByYou))
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
        return PersonFileSet(personId: personId, ownFolders: groups,
                             elsewhere: elsewhere.sorted { $0.path < $1.path },
                             review: review.sorted { $0.path < $1.path })
    }
}
