import Testing
import Foundation
@testable import Sync

/// Every channel that can claim a document for a person, replayed over the **live** corpus and
/// scored against the tree's own filing.
///
/// ## Why this exists before the review queue does
///
/// The queue's whole proposition is that weak evidence is *unreviewed* rather than wrong. That is a
/// claim about precision, and it was never measured — stage 1 suppressed weak matches precisely
/// because there was nowhere to put them and no number to justify showing them. Putting them in
/// front of the user makes the number matter: a queue whose rows are mostly wrong is worse than no
/// queue, because every row costs a decision.
///
/// **The corpus is already labelled.** For every document under a folder whose `person` axis
/// resolves, that person is ground truth — the household filed it there. So each channel can be
/// asked the same question the queue will ask, and its answer compared with the answer the tree
/// already gives.
///
/// ## The population this can score is not the population the queue holds
///
/// This is the limit to state before quoting any number from here. Ground truth exists **only** for
/// documents already inside somebody's person folder — and those are exactly the documents the
/// queue will *not* contain, because a document whose folder claims it is attributed by the folder
/// channel and never reaches review. The queue holds documents in nobody's folder, where nothing
/// says who is right.
///
/// So the precisions below are an **upper bound** for the queue's rows, not an estimate of them. On
/// a person-filed document the filename and the folder usually agree, and that agreement is part of
/// what is being measured. What the replay can say honestly is the *ordering* — filename beats page,
/// strong beats weak — and how often a channel actively **contradicts** the tree's own filing, which
/// is the one failure mode that would make the queue lie. ``queueSize`` counts the real rows
/// separately, and they are unlabelled by construction.
///
/// The numbers this printed on 2026-08-09 are recorded in `ROADMAP.md` item 22 and in the design
/// artifact. What is *asserted* is deliberately coarser than what is printed: the tree is his live
/// `~/Documents` and he edits it while work is in progress, so pinning "the page channel is 94.1%"
/// would make this a tripwire for his filing rather than for this code.
@Suite(.enabled(if: LiveProfile.isAvailable && LiveCorpus.isAvailable,
                "no live filing corpus on this machine — channel replay skipped"),
       .machinePinned(.liveProfile))
struct PersonChannelReplayTests {

    // MARK: - The labelled corpus

    /// One document, with the person its folder says it belongs to — or nil when no folder claims it.
    struct Document {
        let path: String
        /// The folder's verdict: ground truth where it exists, and absent for exactly the documents
        /// the review queue is made of.
        let truth: String?
        let doc: FilingCorpusDocument
    }

    static let registry: PersonRegistry = LiveCorpus.registry

    static let allDocuments: [Document] = {
        guard let corpus = LiveCorpus.corpus, let profile = LiveProfile.profile else { return [] }
        var folderPerson: [String: String?] = [:]
        var out: [Document] = []
        for (path, doc) in corpus.documents {
            let folder = (path as NSString).deletingLastPathComponent
            let owner: String?
            if let cached = folderPerson[folder] {
                owner = cached
            } else {
                owner = PersonFiles.person(forPath: folder, profile: profile, registry: registry)
                folderPerson[folder] = owner
            }
            out.append(Document(path: path, truth: owner, doc: doc))
        }
        return out.sorted { $0.path < $1.path }
    }()

    /// The scorable half — every document a folder already claims.
    static let labelled: [Document] = allDocuments.filter { $0.truth != nil }

    // MARK: - Asking one channel

    /// What a channel said about one document: the single person it claimed, or nil for no opinion.
    ///
    /// **One person or none, never a set.** A channel that names two people has not attributed the
    /// document — it has produced exactly the over-attribution the registry took to zero — so it is
    /// scored as an abstention rather than as half a hit. Counting it as correct whenever either
    /// half matched is how a channel that names everybody scores 100%.
    static func claim(_ report: PersonMatchReport, strongOnly: Bool) -> String? {
        var ids = Set<String>()
        for m in report.matches {
            if strongOnly, !PersonFiles.isStrong(m, unique: unique(m.personId)) { continue }
            ids.insert(m.personId)
        }
        return ids.count == 1 ? ids.first : nil
    }

    static let uniqueWords: [String: Set<String>] = {
        var out: [String: Set<String>] = [:]
        for p in registry.people { out[p.id] = Set(registry.tokenBreakdown(for: p.id).unique) }
        return out
    }()

    static func unique(_ id: String) -> Set<String> { uniqueWords[id] ?? [] }

    /// The page sample a channel reads, from the anchors the corpus already holds.
    ///
    /// **This is a sorted, de-duplicated bag, not text** — see ``PersonChannelReplayTests/aSortedBagHasNoPhrasesToFind()``.
    static func pageSample(_ doc: FilingCorpusDocument) -> String? {
        doc.anchors.isEmpty ? nil : doc.anchors.joined(separator: " ")
    }

    struct Score {
        var claimed = 0
        var correct = 0
        var precision: Double { claimed == 0 ? 0 : Double(correct) / Double(claimed) }
        /// Claims that named somebody **other** than the folder's own person. The failure the queue
        /// cannot afford: not silence, but a confident wrong name.
        var contradictions: Int { claimed - correct }
        var line: String {
            String(format: "%5d claimed  %5d correct  %6.1f%%  %3d contradict",
                   claimed, correct, precision * 100, contradictions)
        }
        mutating func record(_ claim: String?, truth: String) {
            guard let claim else { return }
            claimed += 1
            if claim == truth { correct += 1 }
        }
    }

    struct Report {
        var fileStrong = Score()
        var fileWeak = Score()
        var pageStrong = Score()
        var pageWeak = Score()
        /// The page channel asked of every document rather than only of the ones whose filename
        /// names nobody — what it would score if precedence were dropped.
        var pageIgnoringPrecedence = Score()
        /// Phrase matches found in a sorted anchor bag. Every one of them is fabricated: the bag has
        /// no word order, so an adjacency in it means alphabetical luck, not what the page said.
        var fabricatedPhrases = 0
        var documentsWithText = 0
        /// Documents no folder claims, for which some channel has an opinion — the real queue.
        var queueSize = 0
        var queueStrong = 0
    }

    static let report: Report = {
        var r = Report()
        for item in allDocuments {
            let stem = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let fileReport = registry.explain(in: stem)
            let sample = pageSample(item.doc)
            let pageReport = sample.map { registry.explain(in: $0) } ?? .empty
            if sample != nil {
                r.documentsWithText += 1
                r.fabricatedPhrases += pageReport.matches.filter(\.isPhrase).count
            }

            // Precedence, exactly as `attribute(fileName:pageSample:)` applies it: the page is read
            // only when the name names nobody.
            let effective = fileReport.isEmpty ? pageReport : fileReport
            let isPage = fileReport.isEmpty && !pageReport.isEmpty
            let strong = claim(effective, strongOnly: true)
            let weak = strong == nil ? claim(effective, strongOnly: false) : nil

            guard let truth = item.truth else {
                // No folder claims it — this is a queue row, and nothing labels it.
                if strong != nil || weak != nil { r.queueSize += 1 }
                if strong != nil { r.queueStrong += 1 }
                continue
            }
            if isPage {
                r.pageStrong.record(strong, truth: truth)
                r.pageWeak.record(weak, truth: truth)
            } else {
                r.fileStrong.record(strong, truth: truth)
                r.fileWeak.record(weak, truth: truth)
            }
            if sample != nil {
                r.pageIgnoringPrecedence.record(claim(pageReport, strongOnly: true), truth: truth)
            }
        }
        return r
    }()

    // MARK: - Non-vacuity: the replay has to be looking at something

    @Test func theLabelledCorpusIsTheRealOneAndIsLarge() {
        let size: Comment = """
            the person-filed corpus was 1,375 documents when this was written; \
            \(Self.labelled.count) means the profile or the corpus is not the real one
            """
        #expect(Self.labelled.count > 800, size)
        #expect(Set(Self.labelled.compactMap(\.truth)).count >= 5,
                "ground truth should span most of the household")
        #expect(Self.report.documentsWithText > 200,
                "a corpus whose documents carry no anchors cannot score the page channel")
    }

    // MARK: - The report

    /// Prints the table the roadmap quotes. The assertions are below, and are about relationships
    /// rather than about his filing on any given day.
    @Test func printsThePerChannelScoreboard() {
        let r = Self.report
        var out = "\n── Person channel replay ── \(Self.allDocuments.count) documents, "
        out += "\(Self.labelled.count) person-filed (scorable), \(r.documentsWithText) with page-1 text\n"
        out += "  folder (ground truth)     \(Self.labelled.count) claimed, 100.0% by construction\n"
        out += "  named in file · strong    \(r.fileStrong.line)\n"
        out += "  named in file · weak      \(r.fileWeak.line)\n"
        out += "  named on page · strong    \(r.pageStrong.line)\n"
        out += "  named on page · weak      \(r.pageWeak.line)\n"
        out += "  page, precedence dropped  \(r.pageIgnoringPrecedence.line)\n"
        out += "  sorted-bag phrases fabricated: \(r.fabricatedPhrases)\n"
        out += "  QUEUE (no folder claims them, unlabelled): \(r.queueSize) rows, "
        out += "\(r.queueStrong) of them on strong evidence\n"
        print(out)
        #expect(r.fileStrong.claimed > 0)
    }

    // MARK: - What the design depends on

    /// **The filename outranks the page, and this is the number that says so.**
    ///
    /// `attribute` reads the page only when the name names nobody. Asked of every document instead,
    /// the page channel contradicts the tree's own filing far more often — it is testimony rather
    /// than a label, and an invoice for a swim class prints the parent who pays for it, not the
    /// child who takes it.
    @Test func theFilenameOutranksThePage() {
        let r = Self.report
        let why: Comment = """
            filename \(r.fileStrong.line) vs page with precedence dropped \
            \(r.pageIgnoringPrecedence.line)
            """
        #expect(r.fileStrong.precision > r.pageIgnoringPrecedence.precision, why)
    }

    /// **A strong match beats a weak one — which is what makes the strength gate a gate.**
    ///
    /// Asserted on the page channel, where the gap is real and large. The filename channel's weak
    /// tier is *also* accurate on this population (97%) — see the suite doc: on a document the
    /// household already filed under a person, a weak name match usually agrees with the folder,
    /// which is precisely the bias that makes these numbers an upper bound.
    @Test func strongPageEvidenceOutscoresWeak() {
        let r = Self.report
        #expect(r.pageWeak.claimed > 0, "no weak page matches at all — the queue would be empty")
        let why: Comment = "page strong \(r.pageStrong.line) vs page weak \(r.pageWeak.line)"
        #expect(r.pageStrong.precision > r.pageWeak.precision, why)
    }

    /// **The queue exists and is small enough to review.**
    ///
    /// These rows have no ground truth by construction — no folder claims them, which is why they
    /// are in the queue. What can be asserted is that the population is real and that it is a
    /// review-sized list rather than the 204-row flood that suppressing weak evidence was avoiding.
    @Test func theQueueIsARealAndReviewableSize() {
        let r = Self.report
        #expect(r.queueSize > 0, "nothing to review — the queue would never show a row")
        let size: Comment = "\(r.queueSize) queue rows across the whole tree"
        #expect(r.queueSize < Self.allDocuments.count / 4, size)
    }

    /// **A channel that contradicts the tree's own filing is the one failure the queue cannot
    /// absorb**, so both name channels are held to a low contradiction rate on the labelled half.
    @Test func noChannelOftenContradictsTheTree() {
        let r = Self.report
        for (name, score) in [("file strong", r.fileStrong), ("file weak", r.fileWeak),
                              ("page strong", r.pageStrong), ("page weak", r.pageWeak)] {
            guard score.claimed >= 20 else { continue }
            let why: Comment = "\(name): \(score.line)"
            #expect(score.precision > 0.75, why)
        }
    }

    /// Per-person sizing: what each person's view would actually hold, split by group.
    @Test func printsPerPersonQueueSizing() {
        struct Row { var elsewhereFile = 0; var elsewherePage = 0; var queueFile = 0; var queuePage = 0 }
        var rows: [String: Row] = [:]
        for item in Self.allDocuments {
            let stem = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let fileReport = Self.registry.explain(in: stem)
            let sample = Self.pageSample(item.doc)
            let pageReport = sample.map { Self.registry.explain(in: $0) } ?? .empty
            let effective = fileReport.isEmpty ? pageReport : fileReport
            let viaPage = fileReport.isEmpty && !pageReport.isEmpty
            for m in effective.matches {
                guard m.personId != item.truth else { continue }   // already in their own folder
                let strong = PersonFiles.isStrong(m, unique: Self.unique(m.personId))
                var r = rows[m.personId] ?? Row()
                switch (strong, viaPage) {
                case (true, false):  r.elsewhereFile += 1
                case (true, true):   r.elsewherePage += 1
                case (false, false): r.queueFile += 1
                case (false, true):  r.queuePage += 1
                }
                rows[m.personId] = r
            }
        }
        var out = "\n── Per person ── elsewhere(file/page) · queue(file/page)\n"
        for id in Self.registry.people.map(\.id).sorted() {
            let r = rows[id] ?? Row()
            out += String(format: "  %-10s elsewhere %4d + %4d page   queue %4d + %4d page\n",
                          (id as NSString).utf8String!, r.elsewhereFile, r.elsewherePage,
                          r.queueFile, r.queuePage)
        }
        print(out)
        #expect(!rows.isEmpty)
    }

    /// What each person's view actually holds, from the shipping ``PersonFiles/gather`` — not a
    /// re-derivation of it. The queue has to be a review-sized list per person, not per household.
    @Test func printsWhatEachPersonsViewHolds() throws {
        guard let corpus = LiveCorpus.corpus, let profile = LiveProfile.profile else { return }
        var out = "\n── Each person's view (live gather) ──\n"
        var totalReview = 0
        for person in Self.registry.people.sorted(by: { $0.id < $1.id }) {
            let set = try PersonFiles.gather(personId: person.id, corpus: corpus,
                                             profile: profile, registry: Self.registry)
            let byName = set.review.filter { $0.evidence == .namedInFile }.count
            let byPage = set.review.filter { $0.evidence == .namedOnPage }.count
            totalReview += set.review.count
            out += String(format: "  %-9@  %5d in folders (%3d)  %4d elsewhere  %4d to review (%d name + %d page)\n",
                          person.id as NSString,
                          set.herFolders.reduce(0) { $0 + $1.files.count }, set.folderCount,
                          set.elsewhere.count, set.review.count, byName, byPage)
        }
        out += "  TOTAL to review across the household: \(totalReview)\n"
        print(out)
        #expect(totalReview > 0)
    }

    /// **A sorted token bag has no phrases to find, and any it yields were never on the page.**
    ///
    /// The corpus stores page-1 anchors as a *sorted, de-duplicated set* — word order is gone by the
    /// time anything reads it back. So a phrase match in that bag is alphabetical luck (`girish`
    /// next to `krishnamurthy` because *g* precedes *k*), not something the document said.
    ///
    /// **Measured: zero, over 1,304 documents with text.** A barrier token between anchors was
    /// written to prevent this and then deleted, because it prevented nothing — the mechanism had no
    /// measurable work to do. This assertion is what replaces it: if a roster change ever makes the
    /// count non-zero, the hazard has become real and the barrier is the fix. Non-vacuity is
    /// asserted alongside, so a corpus that stopped carrying anchors cannot pass this quietly.
    @Test func aSortedBagHasNoPhrasesToFind() {
        let r = Self.report
        #expect(r.documentsWithText > 200, "no anchors to search — this assertion would be vacuous")
        let fabricated: Comment = """
            \(r.fabricatedPhrases) phrase matches came out of a sorted anchor bag; the bag has no \
            word order, so each one is alphabetical adjacency being read as a full name. Separate \
            the anchors with a barrier token before feeding them to the matcher.
            """
        #expect(r.fabricatedPhrases == 0, fabricated)
    }
}

/// The live filing corpus and roster, for the replay.
enum LiveCorpus {
    static let corpus: FilingCorpus? = {
        guard let dir = FilingProfileStore.defaultDirectory(),
              let id = FilingProfileStore.activeProfileId(in: dir) else { return nil }
        return FilingSurveyStore.corpus(id: id, in: dir)
    }()

    static let registry: PersonRegistry = {
        guard let dir = FilingProfileStore.defaultDirectory(),
              let id = FilingProfileStore.activeProfileId(in: dir) else {
            return PersonRegistry(people: [])
        }
        return FilingProfileStore.personRegistry(id: id, profile: LiveProfile.profile, in: dir)
    }()

    static var isAvailable: Bool { (corpus?.documents.count ?? 0) > 0 && !registry.isEmpty }
}
