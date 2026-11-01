import Foundation
import Testing
@testable import Sync

/// His three files of 2026-11-01, and the five calls that came of them (GS–GW): a home that rests
/// on one shared word, a survey and a paid model that could not displace it, and corrections that
/// taught nothing beyond the file in hand. The whole-tree numbers are in `FilingCardReplayTests`.
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

    /// GY: even an unsure survey home leads over a word match, carrying its own (Low) badge.
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
        let routed = FileSyncManager.route(card, index: index, snippets: ["/Inbox/scan.pdf": page],
                                           providerRoot: Self.root, rejectedByFile: [:]).suggestion
        #expect(routed.best?.path == Self.root + "/" + routerBest.relativePath)
        #expect(routed.best?.confidence == .low)
        #expect(!routed.isBatchEligible)
    }

    @Test func aTaughtHomeAndAnAgreeingHighAreLeftAlone() throws {
        let snippets = ["/Inbox/FedEx invoice - India courier .pdf": Self.invoicePage]
        let taught = FilingDestination(path: Self.root + "/Health/Medical/India", base: .high, evidence: .name,
                                       reasons: ["Remembered"], newSegments: [], remembered: true)
        let kept = FileSyncManager.route(Self.keywordCard(taught), index: Self.customsIndex, snippets: snippets,
                                         providerRoot: Self.root, rejectedByFile: [:])
        #expect(kept.suggestion.best == taught, "a rule the user taught outranks the survey")

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

    static func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 5000).write(to: url)
    }

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
        try Self.write(root.appendingPathComponent("TODO/FedEx invoice - India courier .pdf"))
        try Self.write(root.appendingPathComponent("TODO/Mint Order - 2026.pdf"))
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
        try Self.write(first)
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

        // A survey that has looked since has the document itself: the filing is not counted twice.
        m.filingSurveyedAt = Date().addingTimeInterval(60)
        #expect(m.filedSinceSurvey(under: root.path).isEmpty)
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

    /// TE287's fixture — a cloud-only lease the scan placed by name — refined with Claude.
    static func refine(agree: Bool) async throws -> (FileSyncManager, URL, FilingDownloadAndReadTests.Cloud, String, Seen) {
        let (m, root, cloud, ticket) = try await FilingDownloadAndReadTests.makeScan()
        let seen = Seen()
        let settings = ScratchDefaults("gz-\(UUID().uuidString)")
        settings.set(false, forKey: FileSyncManager.reuseVerdictsDefaultsKey)
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
}
