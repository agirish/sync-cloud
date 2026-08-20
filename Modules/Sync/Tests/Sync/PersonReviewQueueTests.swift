import Testing
import Foundation
@testable import Sync

/// The review queue: the page-text channel, the weak-name channel, and his verdicts.
///
/// **What stage 1 threw away, and why it could not keep it.** Weak evidence was suppressed because
/// there was nowhere to put it — a shared word like `abhishek` alone names four people, so showing
/// it as an answer would have been a wrong answer. It is not wrong, it is *unreviewed*, and these
/// are the rules that decide what reaches him and what a verdict does to it.
@Suite struct PersonReviewQueueTests {

    // MARK: Fixtures — a household whose names overlap the way the real one does

    private static var registry: PersonRegistry {
        PersonRegistry(people: [
            Person(id: "abhishek", displayName: "Abhishek", fullNames: ["Abhishek Girish"]),
            Person(id: "aditi", displayName: "Aditi", fullNames: ["Aditi Abhishek"]),
            Person(id: "shweta", displayName: "Shweta", fullNames: ["Shweta Dani"]),
            Person(id: "girish", displayName: "Girish", fullNames: ["Girish Krishnamurthy"],
                   aliases: ["Dad"]),
            Person(id: "muktha", displayName: "Muktha", fullNames: ["Muktha Girish"],
                   aliases: ["Mom"]),
        ])
    }

    private static func entry(_ path: String, person: String?) -> FolderProfileEntry {
        FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [], acceptsNewFiles: true,
                           fileCount: 1, subfolderCount: 0,
                           axes: person.map { ["person": $0] } ?? [:])
    }

    private static func profile(_ folders: [(String, String?)]) -> FolderProfile {
        var map: [String: FolderProfileEntry] = [:]
        for (path, person) in folders { map[path] = entry(path, person: person) }
        return FolderProfile(profileId: "t", root: "/root", folders: map, personTokens: [])
    }

    /// A corpus whose documents carry page-1 anchors. **Anchors are sorted and de-duplicated on
    /// disk**, and the fixtures sort them too so they cannot accidentally test an ordering the real
    /// file never has.
    private static func corpus(_ docs: [(String, [String])]) -> FilingCorpus {
        FilingCorpus(profileId: "t", salt: "s",
                     documents: Dictionary(uniqueKeysWithValues: docs.map { path, anchors in
                         (path, FilingCorpusDocument(size: 1, modified: 0,
                                                     anchors: anchors.sorted(), idHashes: []))
                     }))
    }

    private static func gather(_ personId: String, corpus: FilingCorpus, profile: FolderProfile,
                               tags: [PersonTag] = []) throws -> PersonFileSet {
        try PersonFiles.gather(personId: personId, corpus: corpus, profile: profile,
                               registry: registry, tags: PersonTagIndex(tags: tags))
    }

    private static let inbox = profile([("Shared", nil), ("Shared/Inbox", nil)])

    // MARK: - The weak-name channel

    /// **The rows stage 1 suppressed now arrive as questions.** `girish` alone is Dad's given name,
    /// his wife's surname and his sons' — enough to ask about, never enough to claim.
    @Test func aSharedWordInTheNameQueuesRatherThanClaims() throws {
        let c = Self.corpus([("Shared/Inbox/Girish - insurance card.pdf", [])])
        let set = try Self.gather("girish", corpus: c, profile: Self.inbox)
        #expect(set.elsewhere.isEmpty, "a shared word must never claim a document on its own")
        #expect(set.review.count == 1)
        let row = try #require(set.review.first)
        #expect(row.evidence == .namedInFile)
        guard case .sharedWordInName(let word, let sharedWith) = row.reason else {
            Issue.record("expected a shared-word reason, got \(String(describing: row.reason))")
            return
        }
        #expect(word == "girish")
        #expect(sharedWith == 2, "muktha and abhishek both carry `girish` in a name")
    }

    /// A phrase still claims outright — the queue must not swallow the evidence that already works.
    @Test func aPhraseStillClaimsWithoutAsking() throws {
        let c = Self.corpus([("Shared/Inbox/Muktha Girish - Resume.pdf", [])])
        let set = try Self.gather("muktha", corpus: c, profile: Self.inbox)
        #expect(set.elsewhere.count == 1)
        #expect(set.review.isEmpty)
        // …and the surname it spent is not also evidence for the man who shares it.
        let dad = try Self.gather("girish", corpus: c, profile: Self.inbox)
        #expect(dad.elsewhere.isEmpty)
        #expect(dad.review.isEmpty, "the phrase consumed `girish`; it must not resurface as a question")
    }

    // MARK: - The page-text channel

    /// **A page-1 mention only ever queues.** It is testimony: an invoice prints the parent who
    /// pays, a nomination form prints the spouse. Measured over the live tree, letting the page
    /// claim documents put 2,011 rows in one person's "filed elsewhere" — all of them documents
    /// that merely mention her.
    @Test func aPageMentionQueuesAndNeverClaims() throws {
        let c = Self.corpus([("Shared/Inbox/Scan 2026-03-14.pdf", ["muktha", "policy", "renewal"])])
        let set = try Self.gather("muktha", corpus: c, profile: Self.inbox)
        #expect(set.elsewhere.isEmpty, "the page may never claim a document")
        #expect(set.review.count == 1)
        let row = try #require(set.review.first)
        #expect(row.evidence == .namedOnPage)
        guard case .namedOnPageOnly = row.reason else {
            Issue.record("expected a page reason, got \(String(describing: row.reason))")
            return
        }
    }

    /// **The rule that made the channel usable: exactly one person, or nothing.**
    ///
    /// A household document names several family members — and says nothing about whose it is.
    /// Over the live tree this single condition took the page channel from 4,568 rows to 635.
    @Test func aPageNamingTwoPeopleNamesNobody() throws {
        let c = Self.corpus([("Shared/Inbox/Scan.pdf", ["muktha", "dani", "nomination"])])
        for person in ["muktha", "shweta"] {
            let set = try Self.gather(person, corpus: c, profile: Self.inbox)
            #expect(set.review.isEmpty,
                    "\(person): a page naming two people has not said whose the document is")
            #expect(set.elsewhere.isEmpty)
        }
    }

    /// **Precedence, and it is `attribution`'s to own.** A filename that names somebody is judged on
    /// that alone; the page is not consulted, so a document named for Aditi never queues for the
    /// woman page 1 happens to mention.
    @Test func aNameOnTheFileStopsThePageBeingRead() throws {
        let c = Self.corpus([("Shared/Inbox/Aditi Abhishek - report card.pdf",
                              ["muktha", "school", "term"])])
        let mum = try Self.gather("muktha", corpus: c, profile: Self.inbox)
        #expect(mum.review.isEmpty, "the filename named somebody, so the page is not testimony here")
        let aditi = try Self.gather("aditi", corpus: c, profile: Self.inbox)
        #expect(aditi.elsewhere.count == 1)
    }

    /// A document already in her own folder is claimed by the folder and never queued — the folder
    /// channel is ground truth and outranks every question.
    @Test func aDocumentInHerOwnFolderIsNeverQueued() throws {
        let p = Self.profile([("Family", nil), ("Family/Muktha", "Muktha")])
        let c = Self.corpus([("Family/Muktha/Scan.pdf", ["muktha", "policy"])])
        let set = try Self.gather("muktha", corpus: c, profile: p)
        #expect(set.review.isEmpty)
        #expect(set.ownFolders.first?.files.count == 1)
    }

    // MARK: - Verdicts

    /// **"Not hers" sticks.** The channels are deterministic, so without a remembered refusal the
    /// same weak match returns on every gather forever. This is the whole reason the file exists.
    @Test func aRejectionKeepsTheSameWeakMatchFromReturning() throws {
        let path = "Shared/Inbox/Girish - insurance card.pdf"
        let c = Self.corpus([(path, [])])
        #expect(try Self.gather("girish", corpus: c, profile: Self.inbox).review.count == 1)

        let rejected = [PersonTag(personId: "girish", key: .path(path), verdict: .rejected,
                                  recordedPath: path)]
        let after = try Self.gather("girish", corpus: c, profile: Self.inbox, tags: rejected)
        #expect(after.review.isEmpty, "the refusal must not have to be made twice")
        #expect(after.elsewhere.isEmpty)
    }

    /// A confirmation claims the document — and says *he* claimed it, not the evidence.
    @Test func aConfirmationClaimsTheDocumentAsHisVerdict() throws {
        let path = "Shared/Inbox/Scan 2026-03-14.pdf"
        let c = Self.corpus([(path, ["muktha", "policy"])])
        let tags = [PersonTag(personId: "muktha", key: .path(path), verdict: .confirmed,
                              recordedPath: path)]
        let set = try Self.gather("muktha", corpus: c, profile: Self.inbox, tags: tags)
        #expect(set.review.isEmpty)
        #expect(set.elsewhere.map(\.path) == [path])
        #expect(set.elsewhere.first?.evidence == .taggedByYou)
    }

    /// **A confirmation on a document no channel would ever produce still shows.**
    ///
    /// The design's own example is a photo: it carries no text and no name either way, so nothing
    /// computes a row for it. Without this the verdict would be recorded and then invisible, which
    /// is indistinguishable from not having been recorded.
    @Test func aConfirmationOnSilentEvidenceStillAppears() throws {
        let path = "Shared/Inbox/IMG_2214.HEIC"
        let c = Self.corpus([(path, [])])
        let tags = [PersonTag(personId: "aditi", key: .fingerprint("fp"), verdict: .confirmed,
                              recordedPath: path)]
        let set = try Self.gather("aditi", corpus: c, profile: Self.inbox, tags: tags)
        #expect(set.elsewhere.map(\.path) == [path])
        #expect(set.elsewhere.first?.evidence == .taggedByYou)
    }

    /// A confirmation whose file has since left the corpus is kept rather than dropped — a verdict
    /// silently vanishing is worse than one pointing at a path that has moved.
    @Test func aConfirmationOutlivesTheDocumentLeavingTheCorpus() throws {
        let tags = [PersonTag(personId: "aditi", key: .fingerprint("fp"), verdict: .confirmed,
                              recordedPath: "Gone/Away.pdf")]
        let set = try Self.gather("aditi", corpus: Self.corpus([]), profile: Self.inbox, tags: tags)
        #expect(set.elsewhere.map(\.path) == ["Gone/Away.pdf"])
    }

    /// A verdict is about one person, and one person's answer does not settle another's.
    ///
    /// **The queue never asks two people about the same filename**, which is worth stating because
    /// it is not obvious: a shared word standing alone resolves through the registry's *given-name*
    /// rule, so `girish` on its own is Dad and is never also a question for the wife and sons who
    /// carry it as a surname. What can collide is a verdict against a computed row, and that is what
    /// this holds: rejecting for him leaves her confirmation on the same document standing.
    @Test func oneVerdictDoesNotSettleAnotherPersonsQuestion() throws {
        let path = "Shared/Inbox/Girish - insurance card.pdf"
        let c = Self.corpus([(path, [])])
        let tags = [
            PersonTag(personId: "girish", key: .path(path), verdict: .rejected, recordedPath: path),
            PersonTag(personId: "muktha", key: .path(path), verdict: .confirmed, recordedPath: path),
        ]
        let his = try Self.gather("girish", corpus: c, profile: Self.inbox, tags: tags)
        #expect(his.review.isEmpty)
        #expect(his.elsewhere.isEmpty)
        let hers = try Self.gather("muktha", corpus: c, profile: Self.inbox, tags: tags)
        #expect(hers.elsewhere.map(\.path) == [path], "his refusal must not withdraw her claim")
    }

    /// The premise the test above relies on, asserted rather than assumed: a lone shared word is a
    /// question for exactly one person.
    @Test func aLoneSharedWordAsksOnlyThePersonWhoseGivenNameItIs() throws {
        let c = Self.corpus([("Shared/Inbox/Girish - insurance card.pdf", [])])
        #expect(try Self.gather("girish", corpus: c, profile: Self.inbox).review.count == 1)
        for surnameHolder in ["muktha", "abhishek"] {
            let set = try Self.gather(surnameHolder, corpus: c, profile: Self.inbox)
            #expect(set.review.isEmpty, "\(surnameHolder) carries `girish` as a surname only")
        }
    }

    // MARK: - The optimistic update has to be the same answer

    /// **`applying(verdict:to:)` must equal what the next gather returns**, or the screen and the
    /// file disagree until something reloads.
    ///
    /// The view does not re-gather after a verdict — it would re-read a 4.9 MB corpus and walk
    /// 10,171 documents to change one row, putting a spinner between every keystroke of a review
    /// session. That optimisation is only safe if the shortcut and the real thing agree, so this
    /// asserts it directly rather than trusting the two to have been written the same way.
    @Test(arguments: [true, false])
    func theOptimisticUpdateMatchesTheNextGather(isTheirs: Bool) throws {
        let path = "Shared/Inbox/Scan 2026-03-14.pdf"
        let c = Self.corpus([(path, ["muktha", "policy"]),
                             ("Shared/Inbox/Muktha Girish - Resume.pdf", [])])
        let before = try Self.gather("muktha", corpus: c, profile: Self.inbox)
        #expect(before.review.count == 1, "the fixture has to have something to judge")

        let shortcut = before.applying(verdict: isTheirs, to: path)
        let tags = [PersonTag(personId: "muktha", key: .path(path),
                              verdict: isTheirs ? .confirmed : .rejected, recordedPath: path)]
        let regathered = try Self.gather("muktha", corpus: c, profile: Self.inbox, tags: tags)
        #expect(shortcut == regathered)
        // Non-vacuity: the two would also match if `applying` did nothing and the verdict were
        // ignored. Something has to have changed.
        #expect(shortcut != before)
    }

    /// Applying a verdict to a path that is not in the queue changes nothing — a stale click from a
    /// list that has already moved on must not invent a row.
    @Test func applyingAVerdictToAnUnqueuedPathIsInert() throws {
        let c = Self.corpus([("Shared/Inbox/Scan.pdf", ["muktha"])])
        let set = try Self.gather("muktha", corpus: c, profile: Self.inbox)
        #expect(set.applying(verdict: true, to: "Nothing/Here.pdf") == set)
    }

    // MARK: - The count the header shows

    /// **Review rows are questions, not answers, so they are not in the total.** A header that
    /// counted them would assert exactly what the queue exists to ask.
    @Test func theTotalCountsClaimsAndNotQuestions() throws {
        let c = Self.corpus([("Shared/Inbox/Muktha Girish - Resume.pdf", []),
                             ("Shared/Inbox/Scan.pdf", ["muktha", "policy"])])
        let set = try Self.gather("muktha", corpus: c, profile: Self.inbox)
        #expect(set.elsewhere.count == 1)
        #expect(set.review.count == 1)
        #expect(set.total == 1, "the page row is a question and must not be counted as hers")
    }
}
