import Foundation

/// Why a document counts as someone's.
///
/// Ordered by how much it is worth looking at, not by strength. *In their own folders* is the
/// tree's own filing and dominates by volume; *named elsewhere* is the payoff: candidate
/// misfilings that no amount of browsing finds.
public enum PersonEvidence: String, Sendable, Equatable, CaseIterable {
    /// The document sits under a folder whose `person` axis resolves to them.
    case ownFolder
    /// Their name is in the file's own name, and they are not already the folder's person.
    case namedInFile
    /// Page 1 named them, and nobody else. Never enough to claim a document, so it only appears on
    /// a review row (``PersonFiles``).
    case namedOnPage
    /// The user said so: the only evidence that is a decision rather than a computation, and it
    /// outranks everything else.
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
    /// The name form that matched ("Daughter Father", "Mom"). Nil for a folder match, where nothing
    /// in the document said anything.
    public let matchedForm: String?

    /// Why this row is waiting for a verdict: set only on ``PersonFileSet/review`` rows, which ask
    /// the user a question and must say what about.
    public let reason: PersonReviewReason?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

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
/// The gather reads a multi-megabyte corpus and sweeps every surveyed document, so the answer
/// takes a while. The phase lets the slot say so rather than sit on old content, which would read
/// as "nothing happened" and invite a second ⌘↩.
public enum PersonGatherPhase: Sendable, Equatable {
    /// The sweep is running; the slot should say so, not show stale content.
    case gathering
    /// The answer.
    case ready(PersonFileSet)
    /// The sweep could not run (today only when the corpus hasn't been surveyed). The reason is
    /// shown in the slot itself, since a transient banner is gone by the time anyone wonders why.
    case failed(String)
}

/// Everything that is one person's, grouped by why.
public struct PersonFileSet: Sendable, Equatable {
    public let personId: String
    /// Files under a folder that is theirs, grouped by that folder, largest first.
    public let ownFolders: [(folder: String, files: [PersonFile])]
    /// Theirs by name, filed outside their folders: the candidate misfilings.
    public let elsewhere: [PersonFile]
    /// Evidence too weak to claim a document on, waiting for a verdict. Not wrong, unreviewed; a
    /// verdict on one is remembered, so the same weak match never returns.
    public let review: [PersonFile]

    /// How many are theirs: the claimed rows only. Review rows are questions, and counting them
    /// would make the header assert what the queue exists to ask.
    public var total: Int { ownFolders.reduce(0) { $0 + $1.files.count } + elsewhere.count }
    public var folderCount: Int { ownFolders.count }

    /// Public so the app target's tests can build one; `@testable` doesn't reach across the
    /// package boundary.
    ///
    /// This initialiser can't enforce the ordering:
    /// ``PersonFiles/gather(personId:corpus:profile:registry:tags:)`` sorts `ownFolders`
    /// largest-first (ties by name) and each `files` by path, and `PersonView` shows only the first
    /// eight folders. A fixture that cares which rows show must sort the same way.
    public init(personId: String, ownFolders: [(folder: String, files: [PersonFile])],
                elsewhere: [PersonFile], review: [PersonFile] = []) {
        self.personId = personId
        self.ownFolders = ownFolders
        self.elsewhere = elsewhere
        self.review = review
    }

    /// The set as it will be once a verdict on `path` has been recorded.
    ///
    /// The view doesn't re-gather: that re-reads a multi-megabyte corpus and walks every document
    /// to change one row, with a "Gathering…" spinner between verdicts of a review session.
    ///
    /// So this must give the same answer the next gather would, which tests hold it to: a
    /// confirmation moves the row to `elsewhere` as ``PersonEvidence/taggedByYou``, a rejection
    /// drops it, and nothing else moves. The verdict is already on disk; this is only the display
    /// catching up.
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

/// Answers "all of Daughter's files".
///
/// Read-only and computed on demand: nothing here is written. The channels are the person's own
/// folders, the filename, and page 1 (review rows only), with the user's own tags outranking all
/// three. "In their folders" could be reached by browsing; "theirs, filed elsewhere" can't.
///
/// ## Resolving a file's person
///
/// Other callers (`FilingRouter.makeIndex`, `FilingEngine.applyVerdicts`,
/// `PersonFilingFacts.make`, `PeopleOverview.make`) ask "whose folder is this?" of a folder they
/// already have. For an arbitrary file the answer means walking up the ancestors until one carries
/// the axis: `Family/Daughter/Classes/Swim/1.pdf` has it three levels up.
/// ``person(forPath:profile:registry:)`` is that walk.
public enum PersonFiles {

    /// The person whose folder this path is inside, nearest ancestor first.
    ///
    /// Nearest wins: `Immigration/OCI/Mother/Daughter` is Daughter's folder inside her mother's,
    /// and attributing its contents to Mother would over-attribute. Stopping at the first
    /// resolvable axis gives the innermost claim. The path itself is included, so asking about a
    /// folder answers for that folder.
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

    /// Whether a filename match is strong enough to attribute without asking.
    ///
    /// A shared word alone is not: `elder` is one person's first name and two others' surname, so
    /// it appears on every document any of them touched, and attributing on it buries the real
    /// rows. Strong is a phrase (the matcher consumed a multi-word form, so "Daughter Father" is
    /// hers) or a word unique to this person on the roster (`maiden`, `granny`). A weak match is
    /// not wrong but unreviewed, and goes to the review queue instead.
    ///
    /// ## Why this sits beside `attribute` rather than inside it
    ///
    /// `attribute` owns precedence (filename outranks page) and is shared with the filing engine
    /// and the cross-person veto. It applies no strength filter, rightly: there a shared word is
    /// checked against the destination folder's own person axis. Browsing has no destination to
    /// check against, so the same input needs a stricter answer here. Tightening `attribute`
    /// itself would change the filing path, which is already correct.
    static func isStrong(_ match: PersonMatch, unique: Set<String>) -> Bool {
        if match.isPhrase { return true }
        return !match.words.isEmpty && match.words.allSatisfy { unique.contains($0) }
    }

    /// The page sample a document offers, from the anchors the survey already extracted.
    ///
    /// A sorted, de-duplicated bag of words, not the page: ``FilingCorpus`` stores anchors that way
    /// so corpus diffs show real change. So real phrases are lost ("Daughter Father" sorts apart),
    /// and the page contributes only single distinctive words. Tokens that land next to each other
    /// alphabetically could in principle invent a phrase; on a real tree none do, so there is no
    /// barrier token. `PersonChannelReplayTests` asserts that; if it ever fails, add a barrier.
    static func pageSample(_ document: FilingCorpusDocument) -> String? {
        document.anchors.isEmpty ? nil : document.anchors.joined(separator: " ")
    }

    /// Whether page-1 evidence is worth putting in front of the user for this person.
    ///
    /// Exactly one person, or nothing: this rule is what makes the channel usable. A page-1
    /// mention is testimony (an invoice prints the parent who pays, a joint account prints both),
    /// and most pages name somebody. Requiring one person only cuts that to a few hundred,
    /// mostly the scans this channel exists for, whose names say nothing.
    ///
    /// Not the strength gate: a unique word passes ``isStrong`` yet is on many household
    /// documents. Strength asks "could this word mean somebody else"; this asks "is this document
    /// about one person or a household".
    static func pageNamesOnly(_ personId: String, in report: PersonMatchReport) -> PersonMatch? {
        var seen: PersonMatch?
        for match in report.matches {
            if let seen, seen.personId != match.personId { return nil }
            seen = match
        }
        guard let seen, seen.personId == personId else { return nil }
        return seen
    }

    /// Everything attributable to one person across the surveyed corpus.
    ///
    /// - Parameters:
    ///   - personId: the registry id.
    ///   - corpus: the surveyed documents, the file inventory. The profile knows folders; only the
    ///     corpus knows which documents exist, so a per-file answer needs no disk.
    ///
    /// Throws only `CancellationError`, checked once per stride of documents, so a superseded
    /// gather (a second ⌘↩, or the scope cleared) stops walking. Outside a cancelled task the
    /// checks never fire, so synchronous callers just write `try`.
    public static func gather(personId: String, corpus: FilingCorpus, profile: FolderProfile,
                              registry: PersonRegistry,
                              tags: PersonTagIndex = PersonTagIndex(tags: [])) throws -> PersonFileSet {
        var byFolder: [String: [PersonFile]] = [:]
        var elsewhere: [PersonFile] = []
        var review: [PersonFile] = []
        // Confirmations no channel produced a row for: a photo carries no text and maybe no name,
        // so the verdict would otherwise be recorded and invisible.
        var unseenConfirmations = tags.confirmedPaths(for: personId)
        // Resolved per folder, not per document: siblings can't differ, and a big folder would
        // otherwise walk its ancestors once per file.
        var folderPerson: [String: String?] = [:]
        let uniqueWords = Set(registry.tokenBreakdown(for: personId).unique)

        // Coarse on purpose: a check is cheap but not free, and 256 documents of work after a
        // cancel is invisible.
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

            // The user's verdict outranks every channel, both ways: a confirmation claims the
            // document whatever the evidence, and a rejection ends it. The channels are
            // deterministic, so without a remembered "no" the same weak match would return.
            if let verdict = tags.verdict(personId: personId, path: path) {
                unseenConfirmations.remove(path)
                if verdict == .confirmed {
                    elsewhere.append(PersonFile(path: path, evidence: .taggedByYou))
                }
                continue
            }

            // Not their folder, so only what the document says can speak for it. Membership comes
            // from `attribution`, which owns the precedence the filing engine and the veto also use:
            // filename outranks page, and the page is read only when the name names nobody.
            let name = (path as NSString).lastPathComponent
            let sample = pageSample(document)
            let (people, tier) = registry.attribution(fileName: name, pageSample: sample)
            guard people.contains(personId) else { continue }

            switch tier {
            case .fileName:
                // The strength gate, which `attribution` deliberately doesn't apply (see `isStrong`).
                let stem = (name as NSString).deletingPathExtension
                let report = registry.explain(in: stem)
                guard let match = report.matches.first(where: { $0.personId == personId }) else {
                    continue
                }
                if isStrong(match, unique: uniqueWords) {
                    elsewhere.append(PersonFile(path: path, evidence: .namedInFile,
                                                matchedForm: match.form))
                } else {
                    // Weak: one word that others answer to too. Not wrong, unreviewed.
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
                // Always a review row, never a claim: the page is testimony (`pageNamesOnly`).
                review.append(PersonFile(path: path, evidence: .namedOnPage,
                                         matchedForm: match.form,
                                         reason: .namedOnPageOnly(form: match.form)))
            case .identifier, .none:
                continue
            }
        }

        // Confirmations at paths the corpus no longer holds (moved or deleted outside the app).
        // Kept: a verdict silently vanishing is worse than one pointing at a moved path.
        for path in unseenConfirmations.sorted() {
            elsewhere.append(PersonFile(path: path, evidence: .taggedByYou))
        }

        // Largest folder first, ties by name so the order is stable across runs. Written out, not
        // as a tuple comparison with swapped operands, which reads like a bug. Two statements
        // with the element type spelled out, since chaining `map` into `sorted` here is too slow
        // for the type checker.
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
