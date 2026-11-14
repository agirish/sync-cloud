import Foundation
import Testing
@testable import Sync

/// TE341: the filing scorecard's verdicts and its summary, on records built by hand.
@Suite struct FilingScorecardVerdictTests {
    static let root = "/R"
    static let offeredAt = Date(timeIntervalSince1970: 1_000_000)

    static func offer(_ path: String, runnerUp: String? = nil, offeredNew: [String] = [],
                      confidence: FilingConfidence = .medium, evidence: FilingScorecard.Evidence = .survey,
                      picker: FilingScorecard.Picker = .mac) -> FilingScorecard.Offer {
        FilingScorecard.Offer(path: root + "/" + path, confidence: confidence, evidence: evidence, picker: picker,
                              runnerUp: runnerUp.map { root + "/" + $0 }, offeredNew: offeredNew.map { root + "/" + $0 },
                              root: root, at: offeredAt)
    }

    static func judge(_ offer: FilingScorecard.Offer, landedIn folder: String,
                      made: Date? = nil) -> FilingScorecard.Record {
        FilingScorecard.record(offer, landedFile: root + "/" + folder + "/f.pdf", folderCreated: { _ in made })
    }

    @Test func theExactFolderIsKeptAndAFolderInsideItIsDeeper() {
        let o = Self.offer("Finance/Taxes")
        #expect(Self.judge(o, landedIn: "Finance/Taxes").verdict == .kept)
        let deeper = Self.judge(o, landedIn: "Finance/Taxes/2025")
        #expect(deeper.verdict == .deeper)
        #expect(deeper.change == nil)
        // A sibling whose name starts the same is not inside it.
        #expect(Self.judge(o, landedIn: "Finance/Taxes 2025").verdict == .changed)
    }

    @Test func aChangeSaysWhereItWent() {
        let o = Self.offer("Health/Medical/India", runnerUp: "Finance/Shipments")
        let runnerUp = Self.judge(o, landedIn: "Finance/Shipments")
        #expect((runnerUp.verdict, runnerUp.change) == (.changed, .runnerUp))
        let made = Self.judge(o, landedIn: "Finance/Couriers", made: Self.offeredAt.addingTimeInterval(30))
        #expect(made.change == .newFolder)
        let old = Self.judge(o, landedIn: "Finance/Couriers", made: Self.offeredAt.addingTimeInterval(-30))
        #expect(old.change == .other, "a folder that was there before the offer isn't his new one")
    }

    @Test func aNewFolderTheCardOfferedIsNeverHisNewFolder() {
        let o = Self.offer("Travel/Trips", runnerUp: "Travel", offeredNew: ["Travel/Trips/Japan 2026"])
        let r = Self.judge(o, landedIn: "Travel/Trips/Japan 2026", made: Self.offeredAt.addingTimeInterval(5))
        #expect(r.verdict == .deeper, "inside the first pick, so deeper before anything else")
        let o2 = Self.offer("School", runnerUp: "Work", offeredNew: ["Family/Divit 2026"])
        let r2 = Self.judge(o2, landedIn: "Family/Divit 2026", made: Self.offeredAt.addingTimeInterval(5))
        #expect(r2.change == .other)
    }

    @Test func onlyFileHereOnTheRenamedOfferIsKept() {
        let o = Self.offer("Travel/Japan 2026", offeredNew: ["Travel/Japan 2026"])
        let renamed = FilingScorecard.record(o, landedFile: "/R/Travel/Tokyo 2026/f.pdf", renamedOffer: true,
                                             folderCreated: { _ in Self.offeredAt.addingTimeInterval(5) })
        #expect(renamed.verdict == .kept)
        // A sibling he made himself in the picker is his new folder, not the offer renamed.
        let made = Self.judge(o, landedIn: "Travel/Receipts", made: Self.offeredAt.addingTimeInterval(5))
        #expect((made.verdict, made.change) == (.changed, .newFolder))
    }

    @Test func fileHereKnowsTheRenamedOfferFromChooseAFolder() {
        let offered = FilingDestination(path: "/R/Travel/Japan 2026", confidence: .medium, reasons: ["Named like its siblings"],
                                        newSegments: ["Japan 2026"])
        let card = FilingSuggestion(filePath: "/R/TODO/t.pdf", fileName: "t.pdf", size: 1, modificationDate: nil,
                                    candidates: [offered], providerRoot: "/R").offeredAnew(at: Self.offeredAt)
        #expect(FileSyncManager.isRenamedOffer(offered.renamingNewFolder(to: "Tokyo 2026"), of: card))
        #expect(!FileSyncManager.isRenamedOffer(offered, of: card), "the offer as offered is judged as kept anyway")
        let chosen = FilingDestination(path: "/R/Travel/Receipts", confidence: .high, reasons: ["You chose this folder"],
                                       newSegments: [])
        #expect(!FileSyncManager.isRenamedOffer(chosen, of: card))
    }

    /// The card spells iCloud Drive's Documents one way and the folder picker the other.
    @Test func theSameFolderThroughALinkOrInOtherCaseIsTheSameFolder() throws {
        let dir = try makeCanonicalTempRoot(prefix: "ScorecardLink")
        defer { try? FileManager.default.removeItem(at: dir) }
        let documents = dir.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents.appendingPathComponent("Taxes/2025"), withIntermediateDirectories: true)
        let cloud = dir.appendingPathComponent("CloudDocs")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cloud.appendingPathComponent("Documents"), withDestinationURL: documents)
        let offer = FilingScorecard.Offer(path: cloud.path + "/Documents/Taxes", confidence: .high, evidence: .survey,
                                          picker: .mac, root: cloud.path, at: Self.offeredAt)
        func verdict(_ folder: String) -> FilingScorecard.Verdict {
            FilingScorecard.record(offer, landedFile: folder + "/f.pdf", folderCreated: { _ in nil }).verdict
        }
        #expect(verdict(documents.path + "/Taxes") == .kept)
        #expect(verdict(documents.path + "/Taxes/2025") == .deeper)
        #expect(verdict(cloud.path + "/Documents/TAXES") == .kept)
        #expect(verdict(documents.path) == .changed)
    }

    @Test func theAreaIsTheTopFolderItLandedIn() {
        #expect(Self.judge(Self.offer("A"), landedIn: "School/US/Divit").area == "School")
        let outside = FilingScorecard.record(Self.offer("A"), landedFile: "/Elsewhere/x/f.pdf", folderCreated: { _ in nil })
        #expect(outside.area == nil)
    }

    @Test func evidenceComesFromWhatChoseTheFolder() {
        func d(remembered: Bool = false, content: Bool = false, survey: Bool = false, ai: Bool = false) -> FilingDestination {
            FilingDestination(path: "/R/A", confidence: .high, reasons: [], newSegments: [], fromContent: content,
                              remembered: remembered, fromAI: ai, fromSurvey: survey)
        }
        #expect(FilingScorecard.Evidence(d(remembered: true, content: true, survey: true, ai: true)) == .rule)
        #expect(FilingScorecard.Evidence(d(content: true, ai: true)) == .model)
        // A scan's model pick is this Mac's: only Refine's answer is Claude's.
        #expect(FilingScorecard.Offer([d(ai: true)], root: "/R")?.picker == .mac)
        #expect(FilingScorecard.Evidence(d(content: true, survey: true)) == .page)
        #expect(FilingScorecard.Evidence(d(survey: true)) == .survey)
        #expect(FilingScorecard.Evidence(d()) == .name)
    }
}

@Suite struct FilingScorecardSummaryTests {
    static let root = "/R"
    static let now = Date(timeIntervalSince1970: 2_000_000_000)

    static func r(_ verdict: FilingScorecard.Verdict, daysAgo: Double = 1, confidence: FilingConfidence = .high,
                  evidence: FilingScorecard.Evidence = .survey, offered: String = "A/x", landed: String = "A/x",
                  change: FilingScorecard.Change? = nil, picker: FilingScorecard.Picker = .mac,
                  revision: Int = 1, name: String = "f.pdf") -> FilingScorecard.Record {
        FilingScorecard.Record(at: now.addingTimeInterval(-daysAgo * 86_400), picker: picker, confidence: confidence,
                               evidence: evidence, offered: root + "/" + offered, landed: root + "/" + landed,
                               file: root + "/" + landed + "/" + name, root: root, verdict: verdict,
                               change: change, revision: revision)
    }

    @Test func theTotalsCountOnlyThisMacsPicksInRange() {
        let records = [
            Self.r(.kept), Self.r(.kept), Self.r(.deeper),
            Self.r(.changed, change: .runnerUp), Self.r(.changed, change: .newFolder), Self.r(.changed),
            Self.r(.kept, daysAgo: 40),                               // out of 30 days
            Self.r(.kept, picker: .claude), Self.r(.changed, picker: .claude),
            FilingScorecard.ruleRecord(landedFile: "/R/B/g.pdf", root: Self.root, at: Self.now),
        ]
        let s = FilingScorecard.summary(records, range: .days30, now: Self.now)
        #expect((s.all.kept, s.all.deeper, s.all.changed) == (2, 1, 3))
        #expect((s.runnerUp, s.newFolder, s.other) == (1, 1, 1))
        #expect((s.refine.kept, s.refine.total) == (1, 2))
        #expect(s.rules == 1)
        let ninety = FilingScorecard.summary(records, range: .days90, now: Self.now)
        #expect(ninety.all.kept == 3)
        #expect(FilingScorecard.summary(records, range: .all, now: Self.now).all.total == 7)
    }

    @Test func panelsSplitByConfidenceEvidenceAndArea() {
        let records = [
            Self.r(.kept, confidence: .high, evidence: .rule, landed: "School/US"),
            Self.r(.changed, confidence: .low, evidence: .name, offered: "Health/India", landed: "Finance/Shipments"),
            Self.r(.kept, confidence: .medium, evidence: .page, offered: "Finance/Bank", landed: "Finance/Bank"),
            Self.r(.changed, confidence: .high, evidence: .name, offered: "School", landed: "Immigration/H-1B"),
        ]
        let s = FilingScorecard.summary(records, range: .all, now: Self.now)
        #expect(s.byConfidence.map(\.label) == ["High", "Medium", "Needs your pick"])
        #expect(s.byConfidence.map(\.replay) == [0.767, 0.565, 0.29])
        #expect(s.byConfidence.map(\.total) == [2, 1, 1])
        #expect(s.byEvidence.map(\.label) == ["Your rule", "Page 1", "Name word"],
                "in a fixed order, and only kinds with filings")
        #expect(s.byEvidence.last?.kept == 0)
        #expect(s.byEvidence.last?.changed == 2)
        // Most filings first, then by name.
        #expect(s.byArea.map(\.label) == ["Finance", "Immigration", "School"])
        #expect(s.byArea.first?.kept == 1)
        #expect(s.byArea.first?.changed == 1)
    }

    @Test func changesAreNewestFirstAndARepeatedChangeIsOffered() {
        let records = [
            Self.r(.changed, daysAgo: 5, offered: "Health/India", landed: "Finance/Shipments", name: "fedex.pdf"),
            Self.r(.changed, daysAgo: 1, offered: "Health/India", landed: "Finance/Shipments", name: "courier.pdf"),
            Self.r(.changed, daysAgo: 3, offered: "Immigration", landed: "Work/Reports", name: "report.md"),
            Self.r(.deeper, daysAgo: 2, offered: "Purchases", landed: "Purchases/US Mint", name: "mint.pdf"),
        ]
        let s = FilingScorecard.summary(records, range: .all, now: Self.now)
        #expect(s.changes.map(\.fileName) == ["courier.pdf", "report.md", "fedex.pdf"], "deeper ones aren't changes")
        #expect(s.repeats.count == 1)
        #expect(s.repeats.first?.count == 2)
        #expect(s.repeats.first?.latest.fileName == "courier.pdf", "the rule is offered for the newest file")
        #expect(FilingScorecard.display(s.repeats[0].landed, root: Self.root) == "Finance › Shipments")
    }

    @Test func byUpdateAppearsOnlyAcrossTwoFilingChanges() {
        let one = FilingScorecard.summary([Self.r(.kept), Self.r(.changed)], range: .all, now: Self.now)
        #expect(one.byUpdate.isEmpty)
        let two = FilingScorecard.summary([Self.r(.kept, revision: 1), Self.r(.changed, revision: 1),
                                           Self.r(.kept, revision: 2)], range: .all, now: Self.now)
        #expect(two.byUpdate.map(\.label) == ["Update 2", "Before"], "newest first; the oldest reads Before")
        #expect(two.byUpdate.map(\.total) == [1, 2])
    }

    @Test func theLineIsOneLineInEveryState() {
        let empty = FilingScorecard.summary([], range: .days30, now: Self.now)
        #expect(FilingScorecard.line(empty, hasAny: false) == "First pick kept: none yet")
        #expect(FilingScorecard.line(empty, hasAny: true) == "First pick kept: none in the last 30 days")
        let s = FilingScorecard.summary([Self.r(.kept), Self.r(.deeper), Self.r(.changed)], range: .days30, now: Self.now)
        #expect(FilingScorecard.line(s, hasAny: true) == "First pick kept 1 of 3 · last 30 days")
    }
}

@Suite @MainActor struct FilingScorecardStoreTests {
    @Test func recordsSurviveAReloadAndAYearOldOneIsDropped() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FilingScorecardStore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("SyncCloud/filing-scorecard.jsonl")
        let now = Date()
        let store = FilingScorecardStore(fileURL: url, now: now)
        #expect(!store.hasAny)
        let fresh = FilingScorecardSummaryTests.r(.kept, name: "fresh.pdf")
        var old = FilingScorecardSummaryTests.r(.changed, name: "old.pdf")
        old.at = now.addingTimeInterval(-400 * 86_400)
        var recent = fresh
        recent.at = now
        store.append([recent, old])
        // The write is queued off the main actor: wait for the file to hold both lines.
        await waitUntil("both lines are written") {
            ((try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").count ?? 0) >= 2
        }
        let reloaded = FilingScorecardStore(fileURL: url, now: now)
        #expect(reloaded.records.map(\.fileName) == ["fresh.pdf"])
        #expect(reloaded.records.first == recent, "every field round-trips")
    }

    @Test func undoForgetsTheNewestFilingOfAFileAndRedoBringsItBack() {
        let store = FilingScorecardStore(fileURL: nil)
        let earlier = FilingScorecardSummaryTests.r(.kept, daysAgo: 3, landed: "A", name: "a.pdf")
        let later = FilingScorecardSummaryTests.r(.changed, daysAgo: 1, landed: "A", name: "a.pdf")
        let b = FilingScorecardSummaryTests.r(.changed, landed: "B", name: "b.pdf")
        store.append([earlier, later, b])
        store.forget(landedAt: [later.file, "/R/elsewhere.pdf"])
        #expect(store.records == [earlier, b], "one Undo takes back one filing: the newest")
        store.restore(landedAt: [later.file])
        #expect(store.records.contains(later))
        #expect(store.records.count == 3)
        store.restore(landedAt: [later.file])
        #expect(store.records.count == 3, "nothing more to bring back")
    }

    @Test func aLineThisBuildCantReadIsKeptAndRulesAloneAreNotAnyFilings() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FilingScorecardForeign")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("filing-scorecard.jsonl")
        let foreign = #"{"evidence":"somethingNew","picker":"mac","verdict":"kept"}"#
        try (foreign + "\n").write(to: url, atomically: true, encoding: .utf8)
        let store = FilingScorecardStore(fileURL: url)
        #expect(store.records.isEmpty)
        store.append([FilingScorecard.ruleRecord(landedFile: "/R/Bills/x.pdf", root: "/R")])
        #expect(!store.hasAny, "a rule's filing isn't one of this Mac's picks")
        await waitUntil("the write lands") {
            ((try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").count ?? 0) >= 2
        }
        #expect((try? String(contentsOf: url, encoding: .utf8))?.contains(foreign) == true,
                "a newer build's line survives an older build's save")
    }

    @Test func aFilesFirstOfferOutlivesTheStore() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "FilingScorecardOffers")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("filing-scorecard.jsonl")
        let first = FilingScorecardVerdictTests.offer("Health/Medical/India")
        let later = FilingScorecardVerdictTests.offer("Finance/Shipments")
        let store = FilingScorecardStore(fileURL: url, now: first.at)
        #expect(store.firstOffer(for: "/R/TODO/f.pdf", fresh: first) == first)
        #expect(store.firstOffer(for: "/R/TODO/f.pdf", fresh: later) == first)
        await waitUntil("the offers are written") {
            FileManager.default.fileExists(atPath: FilingScorecardStore.offersURL(url).path)
        }
        let relaunched = FilingScorecardStore(fileURL: url, now: first.at.addingTimeInterval(3600))
        #expect(relaunched.firstOffer(for: "/R/TODO/f.pdf", fresh: later) == first, "a relaunch keeps it")
        relaunched.settle(["/R/TODO/f.pdf"])
        #expect(relaunched.firstOffer(for: "/R/TODO/f.pdf", fresh: later) == later, "filed: the next card is a new offer")
    }
}

/// On disk, through the manager: the first pick survives Try Another, a filing is judged against
/// it, and Undo takes the record back. One manager and one defaults suite for the suite.
@Suite(.serialized) @MainActor struct FilingScorecardFilingTests {
    /// One manager and one defaults suite for every test here: a defaults suite per test costs a
    /// cfprefsd wipe on the main actor, which the parking suites feel.
    static let shared: FileSyncManager = {
        let m = FileSyncManager()
        m.filingRuleDefaults = ScratchDefaults("scorecard-\(UUID().uuidString)")
        m.undoManager = UndoManager()
        m.filingScorecard = FilingScorecardStore(fileURL: nil)
        return m
    }()
    var m: FileSyncManager { Self.shared }

    static func card(_ root: URL, _ name: String, _ folders: [String], confidence: FilingConfidence = .high) -> FilingSuggestion {
        FilingSuggestion(filePath: root.appendingPathComponent("TODO/\(name)").path, fileName: name, size: 5000,
                         modificationDate: nil,
                         candidates: folders.map {
                             FilingDestination(path: root.appendingPathComponent($0).path, confidence: confidence,
                                               reasons: [], newSegments: [], fromSurvey: true)
                         },
                         providerRoot: root.path)
    }

    @Test func fileHereOnTheFirstPickIsKeptAndUndoTakesItBack() async throws {
        let root = try makeCanonicalTempRoot(prefix: "ScorecardKept")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("TODO/Divit enrollment.pdf"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("School/Divit"), withIntermediateDirectories: true)
        m.publishFilingSuggestions([Self.card(root, "Divit enrollment.pdf", ["School/Divit", "School"])])
        let card = try #require(m.filingSuggestions.first)
        #expect(card.firstOffer?.path == root.appendingPathComponent("School/Divit").path)
        #expect(card.firstOffer?.evidence == .survey)

        let before = m.filingScorecard.records.count
        #expect(await m.applyFilingSuggestion(card, to: try #require(card.best)) == .moved)
        #expect(m.filingScorecard.records.count == before + 1)
        #expect(m.filingScorecard.records.last?.verdict == .kept)
        #expect(m.filingScorecard.records.last?.area == "School")

        m.undoManager?.undo()
        await waitUntil("the undo drains") { m.activeFileOperationsCount == 0 && m.filingScorecard.records.count == before }
        #expect(m.filingScorecard.records.count == before, "an undone filing doesn't count")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("TODO/Divit enrollment.pdf").path))
    }

    @Test func aFilingAfterTryAnotherIsAChangeToTheRunnerUp() async throws {
        let root = try makeCanonicalTempRoot(prefix: "ScorecardTryAnother")
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "FedEx invoice - India courier.pdf"
        try writeBytes(root.appendingPathComponent("TODO/\(name)"))
        for f in ["Health/Medical/India", "Finance/Shipments"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(f), withIntermediateDirectories: true)
        }
        m.publishFilingSuggestions([Self.card(root, name, ["Health/Medical/India", "Finance/Shipments"], confidence: .medium)])
        await m.tryAnotherFolder(for: try #require(m.filingSuggestions.first))
        let after = try #require(m.filingSuggestions.first)
        #expect(after.best?.path == root.appendingPathComponent("Finance/Shipments").path, "premise: the runner-up leads")
        #expect(after.firstOffer?.path == root.appendingPathComponent("Health/Medical/India").path,
                "Try Another keeps the first pick")

        #expect(await m.applyFilingSuggestion(after, to: try #require(after.best)) == .moved)
        let record = try #require(m.filingScorecard.records.last)
        #expect((record.verdict, record.change) == (.changed, .runnerUp))
        #expect(record.confidence == .medium)
        m.clearFilingRejections()
    }

    @Test func aRescanAfterTryAnotherKeepsTheFirstPick() async throws {
        let root = try makeCanonicalTempRoot(prefix: "ScorecardRescan")
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "courier receipt.pdf"
        try writeBytes(root.appendingPathComponent("TODO/\(name)"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Finance/Shipments"), withIntermediateDirectories: true)
        m.publishFilingSuggestions([Self.card(root, name, ["Health/Medical/India", "Finance/Shipments"])])
        await m.tryAnotherFolder(for: try #require(m.filingSuggestions.first))
        // A rescan leaves the rejected folder out: its card leads with the runner-up.
        m.publishFilingSuggestions([Self.card(root, name, ["Finance/Shipments"])])
        let card = try #require(m.filingSuggestions.first)
        #expect(card.firstOffer?.path == root.appendingPathComponent("Health/Medical/India").path)
        #expect(await m.applyFilingSuggestion(card, to: try #require(card.best)) == .moved)
        #expect(m.filingScorecard.records.last?.verdict == .changed)
        m.clearFilingRejections()
    }

    @Test func fileAllConfidentCountsEachAndRedoCountsItAgain() async throws {
        let root = try makeCanonicalTempRoot(prefix: "ScorecardBatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = m.filingScorecard.records.count
        var cards: [FilingSuggestion] = []
        for name in ["a 2025.pdf", "b 2025.pdf"] {
            try writeBytes(root.appendingPathComponent("TODO/\(name)"))
            cards.append(FilingSuggestion(filePath: root.appendingPathComponent("TODO/\(name)").path, fileName: name, size: 5000,
                                          modificationDate: nil,
                                          candidates: [FilingDestination(path: root.appendingPathComponent("Bills").path,
                                                                         confidence: .high, reasons: [], newSegments: ["Bills"])],
                                          providerRoot: root.path))
        }
        m.publishFilingSuggestions(cards)
        await m.applyRecommendedFiling(m.filingSuggestions)
        #expect(m.filingScorecard.records.count == before + 2)
        #expect(m.filingScorecard.records.suffix(2).map(\.verdict) == [.kept, .kept])

        m.undoManager?.undo()
        await waitUntil("the undo drains") { m.activeFileOperationsCount == 0 && m.filingScorecard.records.count == before }
        #expect(m.filingScorecard.records.count == before)
        m.undoManager?.redo()
        await waitUntil("the redo drains") { m.activeFileOperationsCount == 0 && m.filingScorecard.records.count == before + 2 }
        #expect(m.filingScorecard.records.count == before + 2, "filed again, counted again: \(m.filingScorecard.records.count) vs \(before) + 2, ops \(m.activeFileOperationsCount)")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Bills/a 2025.pdf").path), "premise: the redo moved it")
    }

    @Test func aCardTheAppAnswersAnewIsJudgedOnItsNewAnswer() throws {
        let root = try makeCanonicalTempRoot(prefix: "ScorecardReoffer")
        defer { try? FileManager.default.removeItem(at: root) }
        m.publishFilingSuggestions([Self.card(root, "scan.pdf", ["Scans"], confidence: .low)])
        let id = try #require(m.filingSuggestions.first?.id)
        let read = FilingDestination(path: root.appendingPathComponent("Health/Labs").path, confidence: .high,
                                     reasons: [], newSegments: [], fromContent: true, fromSurvey: true)
        m.replaceFilingSuggestion(id, candidates: [read])
        #expect(m.filingSuggestions.first?.firstOffer?.path == root.appendingPathComponent("Scans").path,
                "a replacement that isn't an offer keeps the first pick")
        m.replaceFilingSuggestion(id, candidates: [read], reoffer: true)
        let offer = try #require(m.filingSuggestions.first?.firstOffer)
        #expect(offer.path == read.path)
        #expect((offer.confidence, offer.evidence) == (.high, .page))
        // A later publish (another pass's) keeps a card's first pick.
        m.publishFilingSuggestions(m.filingSuggestions)
        #expect(m.filingSuggestions.first?.firstOffer == offer)
    }
}

/// Ask Claude's filing cards: rows that carry the survey's offer are judged at Apply; a change
/// Claude proposed, an unticked row and a refused one are not.
@Suite struct FilingScorecardAskClaudeTests {
    @Test func appliedFilingRowsAreJudgedAgainstWhatTheSurveyOffered() {
        var best = FilingHelpAnswer.Suggestion(folder: "/R/Health/Medical/India", relativePath: "Health/Medical/India",
                                               confidence: .medium, reason: "", evidenceToken: nil)
        let runner = FilingHelpAnswer.Suggestion(folder: "/R/Finance/Shipments", relativePath: "Finance/Shipments",
                                                 confidence: .medium, reason: "", evidenceToken: "Courier")
        #expect(best.evidence == .survey)
        #expect(runner.evidence == .page)
        best.evidence = .rule
        let offer = FilingScorecard.Offer([best, runner], root: "/R")
        #expect(offer?.runnerUp == "/R/Finance/Shipments")
        #expect(offer?.evidence == .rule)

        var moved = AskClaudePlan.Row(id: 0, name: "fedex.pdf", change: .move(from: "/R/TODO/fedex.pdf", toFolder: "/R/Finance/Shipments"),
                                      ticked: true)
        moved.offer = offer
        moved.applied = true
        var asOffered = AskClaudePlan.Row(id: 1, name: "rx.pdf", change: .move(from: "/R/TODO/rx.pdf", toFolder: "/R/Health/Medical/India"),
                                          ticked: true)
        asOffered.offer = offer
        asOffered.applied = true
        var proposed = AskClaudePlan.Row(id: 2, name: "a.pdf", change: .move(from: "/R/TODO/a.pdf", toFolder: "/R/Work"), ticked: true)
        proposed.applied = true
        var unticked = AskClaudePlan.Row(id: 3, name: "b.pdf", change: .move(from: "/R/TODO/b.pdf", toFolder: "/R/Work"), ticked: false)
        unticked.offer = offer
        var refused = AskClaudePlan.Row(id: 4, name: "c.pdf", change: .move(from: "/R/TODO/c.pdf", toFolder: "/R/Work"), ticked: true)
        refused.offer = offer
        refused.applied = false
        let plan = AskClaudePlan(title: "File 5", subtitle: "", rows: [moved, asOffered, proposed, unticked, refused])
        // Every row has a landing here, so only `applied` can keep the last two out.
        let records = FilingScorecard.records(plan, landed: [0: "/R/Finance/Shipments/fedex.pdf",
                                                            1: "/R/Health/Medical/India/rx.pdf",
                                                            2: "/R/Work/a.pdf", 3: "/R/Work/b.pdf", 4: "/R/Work/c.pdf"],
                                              folderCreated: { _ in nil })
        #expect(records.map(\.fileName) == ["fedex.pdf", "rx.pdf"])
        #expect(records.map(\.verdict) == [.changed, .kept])
        #expect(records.first?.change == .runnerUp)
        #expect(records.allSatisfy { $0.picker == .mac && $0.area != nil })
    }
}

@Suite struct FilingScorecardOfferEqualityTests {
    /// A rescan offering the same folders later must give an equal card: the scan caches compare
    /// suggestions whole.
    @Test func anOfferIsTheSameWhateverTimeItWasMade() {
        let a = FilingScorecardVerdictTests.offer("School", runnerUp: "Work")
        var b = a
        b.at = a.at.addingTimeInterval(60)
        #expect(a == b)
        b.runnerUp = nil
        #expect(a != b)
    }
}
