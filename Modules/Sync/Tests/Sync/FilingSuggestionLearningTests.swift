import Foundation
import Testing
@testable import Sync

/// How suggestions weigh evidence and learn: one shared word is a lead, not a home; the survey
/// and a paid model's shortlisted pick lead over a word match; and corrections and filings teach
/// beyond the file in hand. The whole-tree numbers are in `FilingCardReplayTests`.
@Suite struct FilingSuggestionLearningTests {

    static let root = "/root"

    static func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                 modificationDate: Date(timeIntervalSince1970: 1_790_000_000), fileSize: 40_000)
    }

    /// A tree from relative paths: a trailing `/` is a folder, anything else a file in one.
    static func tree(_ paths: [String]) -> [FileNode] {
        var folders: Set<String> = []
        var files: [String: [String]] = [:]
        for p in paths {
            if p.hasSuffix("/") {
                var f = String(p.dropLast())
                while !f.isEmpty { folders.insert(f); f = (f as NSString).deletingLastPathComponent }
            } else {
                var f = (p as NSString).deletingLastPathComponent
                files[f, default: []].append(p)
                while !f.isEmpty { folders.insert(f); f = (f as NSString).deletingLastPathComponent }
            }
        }
        func node(_ rel: String) -> FileNode {
            let kids = folders.filter { ($0 as NSString).deletingLastPathComponent == rel }.sorted().map(node)
                + (files[rel] ?? []).map { file(root + "/" + $0) }
            return FileNode(id: root + "/" + rel, name: (rel as NSString).lastPathComponent,
                            isDirectory: true, children: kids)
        }
        return folders.filter { !$0.contains("/") }.sorted().map(node)
    }

    static let household = tree([
        "Immigration/Reference/H-1B Policy Posts – Sep 2025/",
        "Immigration/Customs/USA/US Customs Form.pdf",
        "Health/Medical/India/",
        "Purchases/US/Amazon/",
        "Purchases/US/FedEx/",
    ])

    static func card(_ name: String, in taxonomy: [FileNode] = household,
                     rejectedWords: [String: Set<String>] = [:]) -> FilingSuggestion? {
        FilingEngine.suggest(looseFiles: [file("/Inbox/" + name)], taxonomy: taxonomy, providerRoot: root,
                             now: Date(timeIntervalSince1970: 1_793_000_000),
                             rejectedWords: rejectedWords).first
    }

    // MARK: GS — one shared word is a lead, not a home

    @Test func oneSharedFolderWordIsMediumAndNeverBatched() throws {
        let sep = try #require(Self.card("Duplicate Files Report - Sep 2026.md")?.best)
        #expect(sep.path.hasSuffix("H-1B Policy Posts – Sep 2025"))
        #expect(sep.confidence == .medium, "“sep” alone made this High")
        let india = try #require(Self.card("FedEx invoice - India courier .pdf"))
        let medical = try #require(india.candidates.first { $0.path.hasSuffix("Health/Medical/India") })
        #expect(medical.confidence == .medium, "“india” alone made this High")
        #expect(!india.replacingCandidates([medical]).isBatchEligible,
                "a one-word match must not be moved by File All Confident")
    }

    @Test func aNameWordWithASecondSharedWordStaysHigh() throws {
        // Two folder-name words.
        let tesla = try #require(Self.card("Tesla insurance card 2026.pdf",
                                           in: Self.tree(["Vehicles/Tesla/Insurance/"]))?.best)
        #expect(tesla.path.hasSuffix("Vehicles/Tesla/Insurance"))
        #expect(tesla.confidence == .high)
        // One folder-name word, and a word the files already in it share.
        let mint = try #require(Self.card("Mint Order - 2026.pdf",
                                          in: Self.tree(["Purchases/US/US Mint/Mint Order - 2025.pdf"]))?.best)
        #expect(mint.path.hasSuffix("Purchases/US/US Mint"), "got \(mint.path)")
        #expect(mint.confidence == .high)
    }

    /// Two halves of one camelCase word are one word: `FedEx invoice.pdf` shares only "FedEx" with
    /// `Purchases/US/FedEx`, though it tokenizes to `fed` and `ex`.
    @Test func aCamelCaseWordCountsOnce() throws {
        let fedex = try #require(Self.card("FedEx invoice - India courier .pdf")?
            .candidates.first { $0.path.hasSuffix("Purchases/US/FedEx") })
        #expect(fedex.confidence == .medium, "“fed, ex” counted as two words")
    }

    // MARK: GT — the survey leads over a home found by matching words

    static func index(_ memory: [String: [String]], folders: [String]) -> FilingRouter.Index {
        let entries = memory.mapValues { anchors in
            FilingMemoryEntry(docs: 4, anchors: anchors.map { FilingMemoryToken(token: $0, weight: 4, docFrequency: 1) },
                              idHashes: [])
        }
        return FilingRouter.makeIndex(destinations: folders, profile: nil,
                                      memory: FilingMemory(profileId: "t", salt: "s", folders: entries))
    }

    static let customsIndex = index(["Immigration/Customs/USA": ["customs", "courier", "waybill", "shipment", "declaration"],
                                     "Health/Medical/India": ["prescription", "clinic", "patient"]],
                                    folders: ["Immigration/Customs/USA", "Health/Medical/India",
                                              "Immigration/Reference/H-1B Policy Posts – Sep 2025",
                                              "Purchases/US/Amazon", "Purchases/US/FedEx"])
    static let invoicePage = "FedEx International courier waybill shipment customs declaration India"

    static func keywordCard(_ best: FilingDestination) -> FilingSuggestion {
        FilingSuggestion(filePath: "/Inbox/FedEx invoice - India courier .pdf",
                         fileName: "FedEx invoice - India courier .pdf", size: 1, modificationDate: nil,
                         candidates: [best], providerRoot: root)
    }

    @Test func theSurveysHomeReplacesAKeywordHomeEvenAHighOne() throws {
        let ranking = FilingRouter.rank(fileName: "FedEx invoice - India courier .pdf",
                                        contentSnippet: Self.invoicePage, index: Self.customsIndex)
        #expect(ranking.best?.relativePath == "Immigration/Customs/USA")
        #expect(ranking.confidence >= .medium && ranking.confidence < .high,
                "the case GT is about is a Medium survey home against a High word match: \(ranking.confidence)")
        let keyword = FilingDestination(path: Self.root + "/Health/Medical/India", base: .high, evidence: .name,
                                        reasons: ["Matches “india, medical” in a folder you already keep"],
                                        newSegments: [])
        let routed = FileSyncManager.route(Self.keywordCard(keyword), index: Self.customsIndex,
                                           snippets: ["/Inbox/FedEx invoice - India courier .pdf": Self.invoicePage],
                                           providerRoot: Self.root, rejectedByFile: [:])
        #expect(routed.suggestion.best?.path == Self.root + "/Immigration/Customs/USA")
        #expect(routed.suggestion.candidates.contains { $0.path == keyword.path }, "the word match stays as an alternate")
    }

    /// Even an unsure survey home leads over a word match, carrying its own (Low) badge.
    @Test func anUnsureSurveyHomeStillLeadsOverAWordMatch() throws {
        let index = Self.index(["Immigration/Customs/USA": ["customs", "courier"],
                                "Purchases/US/FedEx": ["courier", "invoice"]],
                               folders: ["Immigration/Customs/USA", "Purchases/US/FedEx", "Health/Medical/India"])
        let page = "courier"
        let ranking = FilingRouter.rank(fileName: "scan.pdf", contentSnippet: page, index: index)
        let routerBest = try #require(ranking.best)
        #expect(ranking.confidence == .low, "the case GY is about is a Low survey home: \(ranking.confidence)")
        let keyword = FilingDestination(path: Self.root + "/Health/Medical/India", base: .high, evidence: .name,
                                        reasons: ["Matches “india, medical”"], newSegments: [])
        let card = FilingSuggestion(filePath: "/Inbox/scan.pdf", fileName: "scan.pdf", size: 1,
                                    modificationDate: nil, candidates: [keyword], providerRoot: Self.root)
        let outcome = FileSyncManager.route(card, index: index, snippets: ["/Inbox/scan.pdf": page],
                                            providerRoot: Self.root, rejectedByFile: [:])
        let routed = outcome.suggestion
        #expect(outcome.routed)
        #expect(routed.best?.path == Self.root + "/" + routerBest.relativePath)
        #expect(routed.best?.confidence == .low)
        #expect(!routed.isBatchEligible)
        #expect(routed.candidates.contains(keyword), "the word match stays as a second choice")
    }

    /// A taught home is left alone too: `FilingRouteOverlayTests.arememberedHomeIsNeverReplaced`.
    @Test func anAgreeingHighIsLeftAlone() throws {
        let snippets = ["/Inbox/FedEx invoice - India courier .pdf": Self.invoicePage]
        let agreeing = FilingDestination(path: Self.root + "/Immigration/Customs/USA", base: .high, evidence: .name,
                                         reasons: ["Matches “customs, usa”"], newSegments: [])
        let same = FileSyncManager.route(Self.keywordCard(agreeing), index: Self.customsIndex, snippets: snippets,
                                         providerRoot: Self.root, rejectedByFile: [:])
        #expect(same.suggestion.best?.confidence == .high,
                "a router agreeing at Medium must not demote a High out of the blind batch")
    }

    // MARK: GT — on Refine, a paid answer the survey shortlisted leads

    static func refine(_ verdict: FilingVerdict, shortlist: [String], leads: Bool,
                       blind: Bool = false) -> FilingDestination? {
        let keyword = FilingDestination(path: root + "/Health/Medical/India", base: .high, evidence: .name,
                                        reasons: ["Matches “india, medical”"], newSegments: [])
        let s = keywordCard(keyword)
        return FilingEngine.applyVerdicts([s.filePath: verdict], to: [s],
                                          existingRelative: ["Immigration", "Immigration/Customs",
                                                             "Immigration/Customs/USA", "Health", "Health/Medical",
                                                             "Health/Medical/India", "Purchases", "Purchases/US",
                                                             "Purchases/US/FedEx"],
                                          providerRoot: root,
                                          contentBlind: blind ? [s.filePath] : [],
                                          routerShortlists: [s.filePath: shortlist],
                                          shortlistVerdictsLead: leads).first?.best
    }

    @Test func aRefineAnswerFromTheShortlistLeadsOverAKeywordHigh() {
        let customs = FilingVerdict(relativePath: "Immigration/Customs/USA", confidence: .medium, reason: "courier invoice")
        let shortlist = ["Immigration/Customs/USA", "Purchases/US/FedEx", "Health/Medical/India"]
        #expect(Self.refine(customs, shortlist: shortlist, leads: true)?.path == Self.root + "/Immigration/Customs/USA")
        // The free scan keeps the confidence rule; so does an answer the survey did not shortlist,
        // one the model gave without reading the page, and one it was unsure of.
        #expect(Self.refine(customs, shortlist: shortlist, leads: false)?.path == Self.root + "/Health/Medical/India")
        #expect(Self.refine(customs, shortlist: ["Purchases/US/FedEx"], leads: true)?.path
                == Self.root + "/Health/Medical/India")
        #expect(Self.refine(customs, shortlist: shortlist, leads: true, blind: true)?.path
                == Self.root + "/Health/Medical/India")
        let unsure = FilingVerdict(relativePath: "Immigration/Customs/USA", confidence: .low, reason: "maybe")
        #expect(Self.refine(unsure, shortlist: shortlist, leads: true)?.path == Self.root + "/Health/Medical/India")
    }

    // MARK: Claude's answer past the shortlist, on Refine

    /// The card from the screenshot: a weak router home, two alternates, and Claude naming a folder
    /// the router never shortlisted.
    static func pastShortlist(_ verdict: FilingVerdict, home: FilingConfidence = .low, kept: Bool = true,
                              blind: Bool = false, homeEvidence: FilingDestination.Evidence = .content) -> FilingSuggestion? {
        let weak = FilingDestination(path: root + "/Finance/US/Social Security/2026", base: home, evidence: homeEvidence,
                                     reasons: ["Matched “age”"], newSegments: [])
        let second = FilingDestination(path: root + "/Finance/US", base: .low, evidence: .content,
                                       reasons: ["Matched “age”"], newSegments: [])
        let third = FilingDestination(path: root + "/Health", base: .low, evidence: .name,
                                      reasons: ["Matched “record”"], newSegments: [])
        let s = FilingSuggestion(filePath: "/Inbox/DIVIT110226IMMZNRECORD.pdf", fileName: "DIVIT110226IMMZNRECORD.pdf",
                                 size: 1, modificationDate: nil, candidates: [weak, second, third], providerRoot: root)
        return FilingEngine.applyVerdicts([s.filePath: verdict], to: [s],
                                          existingRelative: ["Finance", "Finance/US", "Finance/US/Social Security",
                                                             "Finance/US/Social Security/2026", "Health",
                                                             "Health/Medical", "Health/Medical/Kaiser"],
                                          providerRoot: root,
                                          contentBlind: blind ? [s.filePath] : [],
                                          routerShortlists: [s.filePath: ["Finance/US/Social Security/2026",
                                                                           "Finance/US", "Health"]],
                                          shortlistVerdictsLead: true,
                                          answersPastShortlistKept: kept).first
    }

    static let kaiser = FilingVerdict(relativePath: "Health/Medical/Kaiser", confidence: .medium,
                                      reason: "Immunization record from Kaiser")

    @Test func claudesReadAnswerPastTheShortlistLeadsOverAWeakHome() throws {
        let card = try #require(Self.pastShortlist(Self.kaiser))
        #expect(card.candidates.map(\.path) == [Self.root + "/Health/Medical/Kaiser",
                                                 Self.root + "/Finance/US/Social Security/2026",
                                                 Self.root + "/Finance/US", Self.root + "/Health"])
    }

    @Test func pastTheShortlistAnythingShortOfThatGoesSecond() throws {
        let second = [Self.root + "/Finance/US/Social Security/2026", Self.root + "/Health/Medical/Kaiser",
                      Self.root + "/Finance/US", Self.root + "/Health"]
        // The router's home is not weak.
        #expect(Self.pastShortlist(Self.kaiser, home: .medium)?.candidates.map(\.path) == second)
        #expect(Self.pastShortlist(Self.kaiser, home: .high)?.candidates.map(\.path) == second)
        // Claude didn't read the page, or wasn't sure.
        let blind = try #require(Self.pastShortlist(Self.kaiser, blind: true, homeEvidence: .name))
        #expect(blind.candidates.map(\.path) == second)
        #expect(blind.candidates[1].confidence == .low, "a blind answer can't claim more than Low")
        // Over a home read from the page, a blind answer is not even an alternate (the rule before).
        #expect(Self.pastShortlist(Self.kaiser, blind: true)?.candidates.map(\.path)
                == [Self.root + "/Finance/US/Social Security/2026", Self.root + "/Finance/US", Self.root + "/Health"])
        let unsure = FilingVerdict(relativePath: "Health/Medical/Kaiser", confidence: .low, reason: "maybe")
        #expect(Self.pastShortlist(unsure)?.candidates.map(\.path) == second)
    }

    @Test func pastTheShortlistAnAnswerThatIsNotClaudesIsDropped() {
        // The scan, and a Refine that ran on this Mac: the card is as it was.
        #expect(Self.pastShortlist(Self.kaiser, kept: false)?.candidates.map(\.path)
                == [Self.root + "/Finance/US/Social Security/2026", Self.root + "/Finance/US", Self.root + "/Health"])
    }

    @Test func pastTheShortlistAnAnswerThatAgreesLeavesTheCardAlone() throws {
        let agrees = FilingVerdict(relativePath: "Finance/US/Social Security/2026", confidence: .high, reason: "same")
        // Off the shortlist, so the card's own home is the only way it matches.
        let s = FilingSuggestion(filePath: "/Inbox/a.pdf", fileName: "a.pdf", size: 1, modificationDate: nil,
                                 candidates: [FilingDestination(path: Self.root + "/Finance/US/Social Security/2026",
                                                                base: .low, evidence: .content,
                                                                reasons: ["Matched “age”"], newSegments: [])],
                                 providerRoot: Self.root)
        let card = try #require(FilingEngine.applyVerdicts([s.filePath: agrees], to: [s],
                                                           existingRelative: ["Finance", "Finance/US",
                                                                              "Finance/US/Social Security",
                                                                              "Finance/US/Social Security/2026"],
                                                           providerRoot: Self.root,
                                                           routerShortlists: [s.filePath: ["Finance/US"]],
                                                           shortlistVerdictsLead: true,
                                                           answersPastShortlistKept: true).first)
        #expect(card == s)
    }

    // MARK: GU — a rejection teaches the word, for that folder

    @Test func aRejectedWordStopsMatchingThatFolderAloneForOtherFiles() throws {
        let india = Self.root + "/Health/Medical/India"
        let refused = [india: Set(["india"])]
        let before = try #require(Self.card("India passport scan.pdf"))
        #expect(before.candidates.contains { $0.path == india })
        let after = Self.card("India passport scan.pdf", rejectedWords: refused)
        #expect(after?.candidates.contains { $0.path == india } != true,
                "“india” was rejected for this folder and is still the whole case for it")
        // A second shared word is a case of its own.
        let report = try #require(Self.card("India medical report.pdf", rejectedWords: refused))
        #expect(report.candidates.contains { $0.path == india })
    }

    @Test func sharedNameWordsAreTheFoldersOwnWords() {
        #expect(FilingEngine.sharedNameWords(fileName: "FedEx invoice - India courier .pdf",
                                             folderPath: Self.root + "/Health/Medical/India",
                                             providerRoot: Self.root) == ["india"])
        // The provider root's own path is not the folder's name.
        #expect(FilingEngine.sharedNameWords(fileName: "root notes 2026.pdf",
                                             folderPath: Self.root + "/Notes/2026",
                                             providerRoot: Self.root) == ["notes"])
    }

    @MainActor
    @Test func tryAnotherRecordsTheWord() async {
        let m = FileSyncManager()
        m.filingRuleDefaults = ScratchDefaults("gu-\(UUID().uuidString)")
        let india = FilingDestination(path: Self.root + "/Health/Medical/India", confidence: .high,
                                      reasons: [], newSegments: [])
        let s = Self.keywordCard(india)
        m.filingSuggestions = [s]
        await m.tryAnotherFolder(for: s)
        #expect(m.filingWordRejections == [FilingWordRejection(word: "india", path: india.path)])
        #expect(m.filingRejectedWords(under: URL(fileURLWithPath: Self.root)) == [india.path: ["india"]])
        m.clearFilingRejections()
        #expect(m.filingWordRejections.isEmpty)
    }
}

// MARK: - On disk: GV and GW

@Suite @MainActor struct FilingSuggestionLearningDiskTests {


    static func manager(_ root: URL, folders: [String]) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingRuleDefaults = ScratchDefaults("learning-\(UUID().uuidString)")
        m.filingFolderProfile = FilingScanRouterWiringTests.profile(folders, root: root.path)
        m.filingMemory = FilingScanRouterWiringTests.memory("Health/Medical/India", ["prescription", "clinic"])
        return m
    }

    static func card(_ root: URL, _ name: String, suggested: String) -> FilingSuggestion {
        FilingSuggestion(filePath: root.appendingPathComponent("TODO/\(name)").path, fileName: name, size: 5000,
                         modificationDate: nil,
                         candidates: [FilingDestination(path: root.appendingPathComponent(suggested).path,
                                                        confidence: .medium, reasons: [], newSegments: [])],
                         providerRoot: root.path)
    }

    // MARK: GV — filing elsewhere is a rejection, unless it is inside the suggestion

    @Test func choosingAnotherFolderRejectsTheSuggestionButASubfolderDoesNot() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingGV")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = Self.manager(root, folders: ["Health/Medical/India", "Purchases/US"])
        try writeFilingFile(root.appendingPathComponent("TODO/FedEx invoice - India courier .pdf"))
        try writeFilingFile(root.appendingPathComponent("TODO/Mint Order - 2026.pdf"))
        // The picker makes a new folder before it files into it, as he did for both.
        for made in ["Immigration/Customs/USA/Shipments", "Purchases/US/US Mint", "Health/Medical/India"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(made),
                                                    withIntermediateDirectories: true)
        }

        let fedex = Self.card(root, "FedEx invoice - India courier .pdf", suggested: "Health/Medical/India")
        let shipments = root.appendingPathComponent("Immigration/Customs/USA/Shipments").path
        #expect(await m.applyFilingSuggestion(fedex, to: FilingDestination(path: shipments, confidence: .high,
                                                                           reasons: [], newSegments: [])) == .moved)
        let india = root.appendingPathComponent("Health/Medical/India").path
        #expect(m.filingWordRejections == [FilingWordRejection(word: "india", path: india)])
        #expect(m.filingRejections.contains { $0.path == india })

        let mint = Self.card(root, "Mint Order - 2026.pdf", suggested: "Purchases/US")
        let usMint = root.appendingPathComponent("Purchases/US/US Mint").path
        #expect(await m.applyFilingSuggestion(mint, to: FilingDestination(path: usMint, confidence: .high,
                                                                          reasons: [], newSegments: [])) == .moved)
        #expect(!m.filingRejections.contains { $0.path.hasSuffix("Purchases/US") },
                "a folder inside the suggested one is a more specific answer, not a correction")
    }

    // MARK: GW — a filing teaches the next scan at once

    @Test func aFilingIntoAnEmptyFolderTeachesTheRouterAtOnce() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingGW")
        defer { try? FileManager.default.removeItem(at: root) }
        let shipments = "Immigration/Customs/USA/Shipments"
        let folders = ["Health/Medical/India", "Immigration/Customs/USA", shipments]
        let m = Self.manager(root, folders: folders)
        let first = root.appendingPathComponent("TODO/FedEx invoice - India courier .pdf")
        try writeFilingFile(first)
        for folder in folders {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        m.filingPageSamples[first.path] = "FedEx International Air Waybill courier shipment duties"

        let next = "FedEx invoice - Pune courier.pdf"
        let page = "FedEx International Air Waybill courier shipment"
        m.prepareFilingRouter(destinations: Set(folders), providerRoot: root.path)
        let before = try #require(m.filingRouterIndex)
        #expect(FilingRouter.rank(fileName: next, contentSnippet: page, index: before).best?.relativePath != shipments)

        let card = Self.card(root, first.lastPathComponent, suggested: "Health/Medical/India")
        #expect(await m.applyFilingSuggestion(card, to: FilingDestination(path: root.appendingPathComponent(shipments).path,
                                                                          confidence: .high, reasons: [],
                                                                          newSegments: [])) == .moved)
        #expect(m.filingFiledSinceSurvey.count == 1)
        m.prepareFilingRouter(destinations: Set(folders), providerRoot: root.path)
        let after = try #require(m.filingRouterIndex)
        #expect(FilingRouter.rank(fileName: next, contentSnippet: page, index: after).best?.relativePath == shipments,
                "the folder just filed into is what the next courier invoice should be offered")

        // Undone — the file back where it came from — it stops teaching, at the next router build.
        let landed = root.appendingPathComponent(shipments).appendingPathComponent(first.lastPathComponent)
        try FileManager.default.moveItem(at: landed, to: first)
        m.prepareFilingRouter(destinations: Set(folders), providerRoot: root.path)
        let undone = try #require(m.filingRouterIndex)
        #expect(m.filingFiledSinceSurvey.isEmpty)
        #expect(FilingRouter.rank(fileName: next, contentSnippet: page, index: undone).best?.relativePath != shipments,
                "an undone filing still taught the folder")

        // A survey that has looked since has the document itself: the filing is not counted twice.
        m.learnFromFiling(fileName: first.lastPathComponent, sourcePath: first.path,
                          into: root.appendingPathComponent(shipments).path)
        m.filingSurveyedAt = Date().addingTimeInterval(60)
        #expect(m.filedSinceSurvey(under: root.path).isEmpty)
    }

    /// Ask Claude's filings teach too: a file its card moves teaches the folder, and a folder moved
    /// or a rename teaches nothing.
    @Test func aMoveAskClaudeAppliesTeachesTheRouter() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingGWAskClaude")
        defer { try? FileManager.default.removeItem(at: root) }
        let shipments = root.appendingPathComponent("Immigration/Customs/USA/Shipments")
        try FileManager.default.createDirectory(at: shipments, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("TODO/FedEx invoice - India courier .pdf")
        try writeFilingFile(file)
        let folder = root.appendingPathComponent("TODO/Old Trip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let m = Self.manager(root, folders: ["Immigration/Customs/USA/Shipments"])
        let outcome = await m.applyPlan([(id: 0, change: .move(from: file.path, toFolder: shipments.path)),
                                         (id: 1, change: .move(from: folder.path, toFolder: shipments.path))],
                                        actionName: "File", isHidden: { _ in false }, protected: [])
        #expect(outcome.doneCount == 2)
        #expect(m.filingFiledSinceSurvey.map(\.folder) == [shipments.path])
        #expect(m.filingFiledSinceSurvey.first?.filedPath == shipments.appendingPathComponent(file.lastPathComponent).path)
    }

    @Test func theMergeKeepsTheBuildersRules() {
        let memory = FilingMemory(profileId: "p", salt: "s", folders: [
            "A": FilingMemoryEntry(docs: 4, anchors: [FilingMemoryToken(token: "pge", weight: 3.1, docFrequency: 1),
                                                      FilingMemoryToken(token: "autopay", weight: 2.0, docFrequency: 0.5)],
                                   idHashes: [FilingMemoryToken(token: "h1", weight: 2)], folderModified: 7),
            "B": FilingMemoryEntry(docs: 2, anchors: [FilingMemoryToken(token: "kaiser", weight: 2.5, docFrequency: 1)],
                                   idHashes: []),
        ])
        let merged = FilingSurvey.memory(memory, addingFiled: ["A": [["pge", "outage"]], "New": [["courier", "kaiser"]]])
        let a = merged.folders["A"]!
        #expect(a.docs == 5)
        #expect(a.anchors.first { $0.token == "pge" }?.weight == 3.1, "a kept token keeps its stored weight")
        #expect(a.anchors.first { $0.token == "pge" }?.docFrequency == 1)
        #expect(!a.anchors.contains { $0.token == "outage" }, "one sighting in a folder of five is the builder's noise")
        #expect(a.idHashes == memory.folders["A"]!.idHashes && a.folderModified == 7)
        let new = merged.folders["New"]!
        #expect(new.docs == 1)
        #expect(Set(new.anchors.map(\.token)) == ["courier", "kaiser"])
        #expect(new.anchors.first { $0.token == "courier" }!.weight > new.anchors.first { $0.token == "kaiser" }!.weight,
                "a word no folder uses is rarer than one another folder does")
        #expect(merged.folders["B"] == memory.folders["B"], "an untouched folder is untouched")
    }
}

// MARK: - GZ: Refine reads what is only in the cloud

@Suite @MainActor struct FilingRefineDownloadsTests {

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var excerpts: [String: String?] = [:]
        private(set) var prompts: [FilingSpendPreflight] = []
        func saw(_ files: [FilingCandidateFile]) { lock.lock(); for f in files { excerpts[f.fileName] = f.contentSnippet }; lock.unlock() }
        func prompt(_ p: FilingSpendPreflight) { lock.lock(); prompts.append(p); lock.unlock() }
    }

    /// A cloud-only lease the scan placed by name, refined with Claude.
    static func refine(agree: Bool) async throws -> (FileSyncManager, URL, FilingDownloadAndReadTests.Cloud, String, Seen) {
        let (m, root, cloud, ticket) = try await FilingDownloadAndReadTests.makeScan()
        let seen = Seen()
        let settings = ScratchDefaults("gz-\(UUID().uuidString)")
        settings.set(false, forKey: FileSyncManager.reuseVerdictsDefaultsKey)
        // Its page goes with its name only because its folder is shared without asking (TE335).
        AskClaudePrivacy.shareWithoutAsking(root.path, in: settings)
        m.filingContentDefaults = settings
        m.filingBackendIdentity = { tier in tier == .refine ? "cloud:claude-opus-5" : FileSyncManager.onDeviceBackendIdentity }
        m.filingCloudSpendConfirmer = { p in seen.prompt(p); return agree }
        m.filingClassifier = { _, files, tier in
            if tier == .refine { seen.saw(files) }
            return [:]
        }
        await m.refineFilingSuggestions(m.filingSuggestions)
        return (m, root, cloud, ticket, seen)
    }

    @Test func refineDownloadsACloudOnlyFileAndSendsItsPage() async throws {
        let (m, root, cloud, ticket, seen) = try await Self.refine(agree: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(seen.prompts.first?.downloadCount == 1, "the price must say a file will download")
        #expect(cloud.asked == [ticket])
        let name = (ticket as NSString).lastPathComponent
        #expect(seen.excerpts[name] == "lease tenancy landlord rent", "Claude was sent the name alone")
        #expect(m.filingNotDownloaded.isEmpty)
        // The survey read the page too, so a card Claude left alone is placed from it.
        #expect(m.filingSuggestions.first { $0.filePath == ticket }?.best?.path
                == root.appendingPathComponent(FilingDownloadAndReadTests.target).path)
    }

    @Test func nothingDownloadsWhenTheChargeIsDeclined() async throws {
        let (m, root, cloud, ticket, seen) = try await Self.refine(agree: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(seen.prompts.count == 1)
        #expect(cloud.asked.isEmpty, "a declined Refine downloaded a file")
        #expect(m.filingNotDownloaded == [ticket])
    }
}

// MARK: - GT on the Refine pass itself

@Suite @MainActor struct FilingRefineShortlistTests {

    /// Refine hands its own shortlists to the overlay with `shortlistVerdictsLead`, so Claude's pick
    /// from the survey's shortlist replaces a keyword High — the wiring, not just the rule.
    @Test func refineLetsClaudesShortlistedPickLead() async throws {
        let root = "/R"
        let m = FileSyncManager()
        let settings = ScratchDefaults("gt-refine-\(UUID().uuidString)")
        settings.set(false, forKey: FileSyncManager.reuseVerdictsDefaultsKey)
        m.filingContentDefaults = settings
        m.filingBackendIdentity = { tier in tier == .refine ? "cloud:claude-opus-5" : FileSyncManager.onDeviceBackendIdentity }
        m.filingCloudSpendConfirmer = { _ in true }
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Immigration/Customs/USA", confidence: .medium, reason: "courier"))
            })
        }
        let folders: Set<String> = ["Immigration", "Immigration/Customs", "Immigration/Customs/USA",
                                    "Health", "Health/Medical", "Health/Medical/India"]
        m.filingFolderProfile = FilingScanRouterWiringTests.profile(Array(folders), root: root)
        m.filingMemory = FilingScanRouterWiringTests.memory("Immigration/Customs/USA", ["fedex", "courier", "invoice"])
        m.filingLastProviderRoot = root
        m.filingLastTaxonomyFolders = folders.sorted()
        m.filingLastExistingFolders = folders
        m.prepareFilingRouter(destinations: folders)
        let keyword = FilingDestination(path: root + "/Health/Medical/India", base: .high, evidence: .name,
                                        reasons: ["Matches “india, medical”"], newSegments: [])
        m.filingSuggestions = [FilingSuggestion(filePath: "/Inbox/FedEx invoice - India courier .pdf",
                                                fileName: "FedEx invoice - India courier .pdf", size: 1,
                                                modificationDate: nil, candidates: [keyword], providerRoot: root)]
        let summary = await m.refineFilingSuggestions(m.filingSuggestions)
        #expect(summary?.changed == 1)
        #expect(m.filingSuggestions.first?.best?.path == root + "/Immigration/Customs/USA")
    }

    /// Claude names a folder the router never shortlisted. Against `home`, on the backend `refine`
    /// routes to. Returns the manager after the pass.
    private func refinePastTheShortlist(home: FilingConfidence, refine backend: String) async -> FileSyncManager {
        let root = "/R"
        let m = FileSyncManager()
        let settings = ScratchDefaults("refine-past-shortlist-\(UUID().uuidString)")
        settings.set(false, forKey: FileSyncManager.reuseVerdictsDefaultsKey)
        m.filingContentDefaults = settings
        m.filingBackendIdentity = { tier in tier == .refine ? backend : FileSyncManager.onDeviceBackendIdentity }
        m.filingCloudSpendConfirmer = { _ in true }
        m.filingClassifier = { _, files, _ in
            Dictionary(uniqueKeysWithValues: files.map {
                ($0.filePath, FilingVerdict(relativePath: "Health/Medical/Kaiser", confidence: .medium, reason: "Kaiser record"))
            })
        }
        let folders: Set<String> = ["Immigration", "Immigration/Customs", "Immigration/Customs/USA",
                                    "Health", "Health/Medical", "Health/Medical/India", "Health/Medical/Kaiser"]
        m.filingFolderProfile = FilingScanRouterWiringTests.profile(Array(folders), root: root)
        m.filingMemory = FilingScanRouterWiringTests.memory("Immigration/Customs/USA", ["fedex", "courier", "invoice"])
        m.filingLastProviderRoot = root
        m.filingLastTaxonomyFolders = folders.sorted()
        m.filingLastExistingFolders = folders
        m.prepareFilingRouter(destinations: folders)
        let card = [FilingDestination(path: root + "/Immigration/Customs/USA", base: home, evidence: .name,
                                      reasons: ["Matches “courier”"], newSegments: []),
                    FilingDestination(path: root + "/Health/Medical/India", base: .low, evidence: .name,
                                      reasons: ["Matches “india”"], newSegments: [])]
        m.filingSuggestions = [FilingSuggestion(filePath: "/Inbox/FedEx invoice - India courier .pdf",
                                                fileName: "FedEx invoice - India courier .pdf", size: 1,
                                                modificationDate: nil, candidates: card, providerRoot: root)]
        _ = await m.refineFilingSuggestions(m.filingSuggestions)
        return m
    }

    @Test func refineLetsClaudesAnswerPastTheShortlistReplaceAWeakHome() async {
        let m = await refinePastTheShortlist(home: .low, refine: "cloud:claude-opus-5")
        #expect(m.filingSuggestions.first?.best?.path == "/R/Health/Medical/Kaiser")
        #expect(m.filingLastRefine?.changed == 1)
        #expect(m.filingLastRefineReport?.offered == 0)
    }

    @Test func refineKeepsClaudesAnswerPastTheShortlistSecondAndSaysSo() async throws {
        let m = await refinePastTheShortlist(home: .high, refine: "cloud:claude-opus-5")
        let card = try #require(m.filingSuggestions.first)
        #expect(card.candidates.map(\.path) == ["/R/Immigration/Customs/USA", "/R/Health/Medical/Kaiser",
                                                 "/R/Health/Medical/India"])
        #expect(m.filingLastRefine?.changed == 0)
        #expect(m.filingLastRefineReport?.offered == 1)
        #expect(m.banner?.message == "Refined 1 suggestion — no home changed. "
                + "Claude picked another folder for 1 file: Try Another Folder shows it.")
    }

    /// The control: the same answer from this Mac's model is dropped, which is also what proves
    /// Kaiser is off the router's shortlist (on it, the medium answer would lead either way).
    @Test func refineOnThisMacStillDropsAnAnswerPastTheShortlist() async throws {
        let m = await refinePastTheShortlist(home: .low, refine: FileSyncManager.onDeviceBackendIdentity)
        let card = try #require(m.filingSuggestions.first)
        #expect(card.candidates.map(\.path) == ["/R/Immigration/Customs/USA", "/R/Health/Medical/India"])
        #expect(m.filingLastRefineReport?.offered == 0)
    }
}
