import Foundation
import PDFKit
import Testing
@testable import Sync

/// What the card says, measured on the household's own filed documents: the whole free scan, not
/// the router alone.
///
/// The router's tables (``FilingRouter``) measure one phase. A card is decided by three: the
/// keyword engine, then the router overlay, then (with a backend) the classifier. A card can be
/// wrong where the router is right and loses (`Duplicate Files Report - Sep 2026.md` leading with a
/// High H-1B folder on the word "sep"), and no router table can see that.
///
/// Held out by a stable hash: one document in five is taken out of the tree, the memory is rebuilt
/// from the other four without it, and it is handed back as a loose file. Its card's leading home
/// is then compared with the folder the user actually filed it in.
///
/// Content is the survey's tokens, not the page. The corpus keeps page 1's anchors, never its text
/// (see ``FilingCorpus``), so the snippet each phase reads is those anchors joined. That is the same
/// for every variant measured here, so it compares them fairly; it is not a re-measurement of the
/// router's own published figures.
@Suite(.enabled(if: LiveProfile.isAvailable && LiveCorpus.isAvailable,
                "no live filing profile and corpus on this machine — card replay skipped"),
       .machinePinned(.liveProfile))
struct FilingCardReplayTests {

    struct Tally: CustomStringConvertible {
        var cards = 0
        var right = 0
        var rightOrParent = 0
        var byConfidence: [FilingConfidence: (shown: Int, right: Int)] = [:]
        var oneWordHigh = 0

        mutating func add(best: FilingDestination?, gold: String, root: String, oneWordHigh: Bool) {
            cards += 1
            guard let best else { return }
            let rel = String(best.path.dropFirst(root.count + 1))
            let hit = rel == gold
            if hit { right += 1 }
            if hit || gold.hasPrefix(rel + "/") { rightOrParent += 1 }
            var c = byConfidence[best.confidence] ?? (0, 0)
            c.shown += 1
            if hit { c.right += 1 }
            byConfidence[best.confidence] = c
            if oneWordHigh { self.oneWordHigh += 1 }
        }

        func share(_ n: Int, of d: Int) -> String {
            d == 0 ? "—" : String(format: "%.1f%%", 100 * Double(n) / Double(d))
        }

        var description: String {
            var lines = ["cards \(cards) · top-1 \(share(right, of: cards)) · right-or-parent \(share(rightOrParent, of: cards))"]
            for c in [FilingConfidence.high, .medium, .low] {
                let v = byConfidence[c] ?? (0, 0)
                lines.append("  \(c): shown \(v.shown) (\(share(v.shown, of: cards))), right \(share(v.right, of: v.shown))")
            }
            lines.append("  High resting on one shared name word: \(oneWordHigh)")
            return lines.joined(separator: "\n")
        }
    }

    /// One fifth, chosen by path so every run holds out the same documents.
    static func isHeldOut(_ path: String) -> Bool {
        var h: UInt64 = 1469598103934665603
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h % 5 == 0
    }

    /// The held-out fifth, staged once for every test here: the walk, the memory and the index are
    /// seconds each against 3,000 folders.
    struct Fixture {
        static let root = "/R"
        let profile: FolderProfile
        let train: FilingCorpus
        let memory: FilingMemory
        let folders: Set<String>
        let learned: FilingEngine.LearnedTaxonomy
        let index: FilingRouter.Index
        let loose: [FileNode]
        /// Inbox path → the folder the user filed it in.
        let gold: [String: String]
        /// Inbox path → page 1, as the survey's anchors.
        let snippets: [String: String]
        /// Inbox path → the anchors the document brings when it is filed.
        let anchors: [String: Set<String>]
        /// Inbox path → where it came from in the corpus, and what the survey recorded for it.
        var original: [String: (path: String, doc: FilingCorpusDocument)] = [:]

        static let shared: Fixture? = {
            guard let profile = LiveProfile.profile, let corpus = LiveCorpus.corpus else { return nil }
            var train = corpus
            var heldOut: [(path: String, doc: FilingCorpusDocument)] = []
            for (path, doc) in corpus.documents where FilingCardReplayTests.isHeldOut(path) {
                train.documents[path] = nil
                let folder = (path as NSString).deletingLastPathComponent
                if !folder.isEmpty, !doc.isBlank, profile.folders[folder] != nil { heldOut.append((path, doc)) }
            }
            heldOut.sort { $0.path < $1.path }
            let memory = FilingSurvey.buildMemory(corpus: train, folderModified: [:])

            // The tree the keyword engine walks: every surveyed folder, holding the documents still in it.
            let folders = Set(profile.folders.keys)
            var filesIn: [String: [String]] = [:]
            for path in train.documents.keys {
                filesIn[(path as NSString).deletingLastPathComponent, default: []].append(path)
            }
            var childFolders: [String: [String]] = [:]
            var tops: [String] = []
            for f in folders {
                let parent = (f as NSString).deletingLastPathComponent
                if parent.isEmpty || !folders.contains(parent) { tops.append(f) } else { childFolders[parent, default: []].append(f) }
            }
            func node(_ rel: String) -> FileNode {
                let kids = (childFolders[rel] ?? []).map(node)
                    + (filesIn[rel] ?? []).map {
                        FileNode(id: root + "/" + $0, name: ($0 as NSString).lastPathComponent,
                                 isDirectory: false, fileSize: 8192)
                    }
                return FileNode(id: root + "/" + rel, name: (rel as NSString).lastPathComponent,
                                isDirectory: true, children: kids)
            }
            let taxonomy = tops.sorted().map(node)

            var loose: [FileNode] = []
            var gold: [String: String] = [:]
            var snippets: [String: String] = [:]
            var anchors: [String: Set<String>] = [:]
            var original: [String: (path: String, doc: FilingCorpusDocument)] = [:]
            for (i, item) in heldOut.enumerated() {
                let name = (item.path as NSString).lastPathComponent
                let id = "/Inbox/\(i)/\(name)"
                loose.append(FileNode(id: id, name: name, isDirectory: false,
                                      modificationDate: Date(timeIntervalSince1970: TimeInterval(item.doc.modified)),
                                      fileSize: max(item.doc.size, 8192)))
                gold[id] = (item.path as NSString).deletingLastPathComponent
                snippets[id] = item.doc.anchors.joined(separator: " ")
                anchors[id] = FilingSurvey.filedAnchors(fileName: name, page1: nil).union(item.doc.anchors)
                original[id] = item
            }
            return Fixture(profile: profile, train: train, memory: memory, folders: folders,
                           learned: FilingEngine.learnTaxonomy(taxonomy, providerRoot: root, options: FilingOptions()),
                           index: FilingRouter.makeIndex(destinations: Array(folders), profile: profile,
                                                         memory: memory, registry: LiveCorpus.registry),
                           loose: loose, gold: gold, snippets: snippets, anchors: anchors,
                           original: original)
        }()

        /// The free scan's cards, as `findFilingSuggestions` builds them with no backend: phase 1,
        /// phase 2's re-suggest for the unsure files, the router overlay, the cross-person sweep.
        func cards(_ files: [FileNode], index: FilingRouter.Index? = nil) -> (keyword: [FilingSuggestion], card: [FilingSuggestion]) {
            let now = Date(timeIntervalSince1970: 1_793_000_000)
            let options = FilingOptions()
            var suggestions = FilingEngine.suggest(looseFiles: files, learned: learned, providerRoot: Self.root,
                                                   now: now, options: options)
            let unsure = Set(suggestions.filter { !$0.hasConfidentHome }.map(\.filePath))
            let content = snippets.filter { unsure.contains($0.key) }
                .mapValues { Set(FilingRouter.tokenize($0)) }
            suggestions = FilingEngine.suggest(looseFiles: files, learned: learned, providerRoot: Self.root,
                                               contentTokens: content, now: now, options: options)
            let keyword = suggestions
            suggestions = FileSyncManager.applyRoutes(suggestions, index: index ?? self.index,
                                                      snippets: snippets, providerRoot: Self.root).suggestions
            suggestions = FilingEngine.refusingCrossPersonHomes(
                suggestions, providerRoot: Self.root, profile: profile, registry: LiveCorpus.registry,
                pageSamples: snippets)
            return (keyword, suggestions)
        }
    }

    @Test func theFreeScansCardsOnTheHeldOutFifth() throws {
        let f = try #require(Fixture.shared)
        let root = Fixture.root
        let (keywordOnly, suggestions) = f.cards(f.loose)

        var keyword = Tally(), card = Tally(), router = Tally()
        for (k, s) in zip(keywordOnly, suggestions) {
            let g = f.gold[s.filePath]!
            keyword.add(best: k.best, gold: g, root: root, oneWordHigh: Self.restsOnOneWord(k.best))
            card.add(best: s.best, gold: g, root: root, oneWordHigh: Self.restsOnOneWord(s.best))
            let r = FilingRouter.rank(fileName: s.fileName, contentSnippet: f.snippets[s.filePath], index: f.index)
            router.add(best: r.best.map {
                FilingDestination(path: root + "/" + $0.relativePath, confidence: r.confidence,
                                  reasons: [], newSegments: [])
            }, gold: g, root: root, oneWordHigh: false)
        }
        print("[card-replay] held out \(f.loose.count) of \(f.train.documents.count + f.loose.count)+ documents")
        print("[card-replay] keyword engine alone\n\(keyword)")
        print("[card-replay] router alone\n\(router)")
        print("[card-replay] the card (keyword → router → cross-person)\n\(card)")
        // The bar: the survey leads, so the card is about as right as the router and its badge
        // means what it says. Floors sit a little under the measured 42.1% (High right 76.7%; a
        // word match the survey agrees with keeps its High), so a change that loses them fails here
        // and says by how much.
        #expect(card.right * 100 >= card.cards * 40, "cards right first time fell below 40%:\n\(card)")
        let high = card.byConfidence[.high] ?? (0, 0)
        #expect(high.right * 100 >= high.shown * 75, "a High badge is right less than 75% of the time:\n\(card)")
        #expect(card.cards > 500, "the held-out fifth is too small to say anything: \(card.cards)")
    }

    /// A filing teaches the next card. For every folder with two or more held-out documents, the
    /// first is filed (folded into the memory as a filing in SyncCloud folds it) and the rest are
    /// placed with and without it. The folders that matter most are the cold ones, left empty by the
    /// hold-out, which stand for a folder made or emptied since the survey.
    @Test func aFilingTeachesTheNextCard() throws {
        let f = try #require(Fixture.shared)
        var byFolder: [String: [FileNode]] = [:]
        for file in f.loose { byFolder[f.gold[file.id]!, default: []].append(file) }
        var filed: [String: [Set<String>]] = [:]
        var next: [FileNode] = []
        var resurveyed = f.train
        for (folder, files) in byFolder where files.count >= 2 {
            filed[folder] = [f.anchors[files[0].id]!]
            next += files.dropFirst()
            let o = f.original[files[0].id]!
            resurveyed.documents[o.path] = o.doc
        }
        // The oracle: what a survey that had read those documents would build.
        let oracle = FilingRouter.makeIndex(destinations: Array(f.folders), profile: f.profile,
                                            memory: FilingSurvey.buildMemory(corpus: resurveyed, folderModified: [:]),
                                            registry: LiveCorpus.registry)
        var survey = Tally()
        for c in f.cards(next, index: oracle).card {
            survey.add(best: c.best, gold: f.gold[c.filePath]!, root: Fixture.root, oneWordHigh: false)
        }
        print("[card-replay] GW — a full re-survey instead (the oracle)\n\(survey)")
        let taught = FilingRouter.makeIndex(destinations: Array(f.folders), profile: f.profile,
                                            memory: FilingSurvey.memory(f.memory, addingFiled: filed,
                                                                        foldersWith: FilingSurvey.folderFrequency(f.train)),
                                            registry: LiveCorpus.registry)
        let roughly = FilingRouter.makeIndex(destinations: Array(f.folders), profile: f.profile,
                                             memory: FilingSurvey.memory(f.memory, addingFiled: filed),
                                             registry: LiveCorpus.registry)
        var rough = Tally()
        for c in f.cards(next, index: roughly).card {
            rough.add(best: c.best, gold: f.gold[c.filePath]!, root: Fixture.root, oneWordHigh: false)
        }
        print("[card-replay] GW — after, rarity read off the memory alone\n\(rough)")
        let coldFolders = Set(byFolder.keys).subtracting(f.train.documents.keys.map {
            ($0 as NSString).deletingLastPathComponent
        })
        var before = Tally(), after = Tally(), coldBefore = Tally(), coldAfter = Tally()
        for (b, a) in zip(f.cards(next).card, f.cards(next, index: taught).card) {
            let g = f.gold[b.filePath]!
            before.add(best: b.best, gold: g, root: Fixture.root, oneWordHigh: false)
            after.add(best: a.best, gold: g, root: Fixture.root, oneWordHigh: false)
            if coldFolders.contains(g) {
                coldBefore.add(best: b.best, gold: g, root: Fixture.root, oneWordHigh: false)
                coldAfter.add(best: a.best, gold: g, root: Fixture.root, oneWordHigh: false)
            }
        }
        print("[card-replay] GW — the next document of \(filed.count) folders, before one was filed\n\(before)")
        print("[card-replay] GW — after\n\(after)")
        print("[card-replay] GW — cold folders only, before\n\(coldBefore)")
        print("[card-replay] GW — cold folders only, after\n\(coldAfter)")
        // Measured against the re-survey it stands in for, not against doing nothing: adding true
        // documents moves cards in both directions, and the survey would move them too.
        #expect(after.right + after.cards / 100 >= survey.right,
                "the merge lost more than a point to a real re-survey: \(after.right) vs \(survey.right)")
        #expect(coldAfter.right > coldBefore.right, "a filing taught a cold folder nothing")
    }

    /// Three of his real files, through today's code: read from where he filed them and placed
    /// against the tree as the survey last saw it, which has neither `Shipments` nor `US Mint` (he
    /// made both in the picker as he filed). Prints each card and the router's shortlist (what
    /// Refine shows the model); asserts only that none leads High on one word.
    @Test func hisThreeFilesOf1101() throws {
        let f = try #require(Fixture.shared)
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/Documents/"
        let files: [(name: String, nowAt: String?)] = [
            ("Duplicate Files Report - Sep 2026.md", nil),   // he deleted it; its name is what misled
            ("FedEx invoice - India courier .pdf", "Immigration/Customs/USA/Shipments"),
            ("Mint Order - 2026.pdf", "Purchases/US/US Mint"),
            // And two cloud-only files from his Downloads, placed by name as the scan places them:
            // a JAL e-ticket (Travel/Trips) and his father's registration.
            ("JAL eTicket - Sep 2026.pdf", nil),
            ("KMC Certificate of Registration.pdf", nil),
        ]
        guard let dir = FilingProfileStore.defaultDirectory(),
              let id = FilingProfileStore.activeProfileId(in: dir),
              let memory = FilingProfileStore.memory(id: id, in: dir) else { return }
        let index = FilingRouter.makeIndex(destinations: Array(f.folders), profile: f.profile,
                                           memory: memory, registry: LiveCorpus.registry)
        var loose: [FileNode] = []
        var snippets = f.snippets
        for (i, file) in files.enumerated() {
            let id = "/TODO/\(i)/\(file.name)"
            loose.append(FileNode(id: id, name: file.name, isDirectory: false,
                                  modificationDate: Date(timeIntervalSince1970: 1_790_000_000), fileSize: 40_000))
            if let at = file.nowAt, let text = Self.page1(home + at + "/" + file.name) { snippets[id] = text }
        }
        let fixture = Fixture(profile: f.profile, train: f.train, memory: memory, folders: f.folders,
                              learned: f.learned, index: index, loose: loose, gold: [:],
                              snippets: snippets, anchors: [:])
        for s in fixture.cards(loose).card {
            let best = s.best.map { "\($0.path.dropFirst(Fixture.root.count + 1)) [\($0.confidence)] \($0.reasons.first ?? "")" } ?? "no home"
            let shortlist = FilingRouter.rank(fileName: s.fileName, contentSnippet: snippets[s.filePath],
                                              index: index, limit: 8).candidates.map(\.relativePath)
            print("[his-three] \(s.fileName) (read: \(snippets[s.filePath] != nil))\n  card: \(best)\n  shortlist: \(shortlist)")
            #expect(!Self.restsOnOneWord(s.best), "\(s.fileName) still leads High on one shared word")
        }
    }

    static func page1(_ path: String) -> String? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
              let text = doc.page(at: 0)?.string, !text.isEmpty else { return nil }
        return text
    }

    /// Whether a card's home is a keyword name match on exactly one shared non-year word, the
    /// shape of a High these files must not get. Read from the reason the engine wrote, which names
    /// the hits.
    static func restsOnOneWord(_ d: FilingDestination?) -> Bool {
        guard let d, d.confidence == .high, !d.remembered, !d.fromAI else { return false }
        return d.reasons.contains { r in
            guard r.hasPrefix("Matches “"), let close = r.range(of: "” in a folder") else { return false }
            let hits = r[r.index(r.startIndex, offsetBy: 9)..<close.lowerBound]
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return hits.filter { !($0.count == 4 && Int($0) != nil) }.count == 1
        }
    }
}
