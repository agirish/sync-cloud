import Foundation
import Testing
@testable import Sync

/// Filing help for Ask Claude (TE255): one file, the Filing profile, the router To File uses.
@MainActor
@Suite struct FilingHelpTests {

    private static func profile(_ id: String, root: String, _ folders: [String]) -> FolderProfile {
        let entries = folders.map {
            FolderProfileEntry(path: $0, role: .destination, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 2, subfolderCount: 0, axes: [:])
        }
        return FolderProfile(profileId: id, root: root,
                             folders: Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }),
                             personTokens: [])
    }

    private static func memory(_ id: String, _ anchors: [String: [String]]) -> FilingMemory {
        FilingMemory(profileId: id, salt: "s", folders: anchors.mapValues { words in
            FilingMemoryEntry(docs: 4, anchors: words.map { FilingMemoryToken(token: $0, weight: 4.0) }, idHashes: [])
        })
    }

    private func manager(_ id: String, root: String, anchors: [String: [String]]) -> FileSyncManager {
        let m = FileSyncManager()
        // Its own rules store: filing help reads saved rules first (TE286).
        m.filingRuleDefaults = ScratchDefaults("FilingHelp-\(id)")
        m.filingFolderProfile = Self.profile(id, root: root, Array(anchors.keys))
        m.filingMemory = Self.memory(id, anchors)
        return m
    }

    private let root = "/never-on-disk-filing-help/Documents"

    @Test func aW2GoesToTheTaxYearFolderWithItsReason() async throws {
        let m = manager("help-w2", root: root, anchors: ["Taxes/2025": ["wages", "employer"],
                                                         "Home/Utilities": ["electric", "meter"]])
        let answer = await m.whereToFile(root + "/Downloads/scan.pdf", snippet: "Wages, tips, employer 2025",
                                         isHidden: { _ in false })
        guard case .suggested(let suggestions) = answer.outcome else { Issue.record("no suggestion: \(answer)"); return }
        let best = try #require(suggestions.first)
        #expect(best.relativePath == "Taxes/2025")
        #expect(best.folder == root + "/Taxes/2025")
        #expect(best.reason.hasPrefix("Matched “"))
        #expect(best.evidenceToken != nil)
    }

    /// A hidden folder is never a candidate, even when it is the one that fits best.
    @Test func aHiddenFolderIsNeverNamed() async {
        let anchors = ["Private/Medical": ["electric", "meter", "statement"], "Home/Utilities": ["electric"]]
        let m = manager("help-hidden", root: root, anchors: anchors)
        let hidden = root + "/Private"
        let answer = await m.whereToFile(root + "/bill.pdf", snippet: "electric meter statement",
                                         isHidden: { $0 == hidden || $0.hasPrefix(hidden + "/") })
        guard case .suggested(let suggestions) = answer.outcome else { Issue.record("no suggestion: \(answer)"); return }
        #expect(!suggestions.contains { $0.relativePath.hasPrefix("Private") })
        #expect(suggestions.first?.relativePath == "Home/Utilities")
        // The control: shown, it is the better home.
        let open = await m.whereToFile(root + "/bill.pdf", snippet: "electric meter statement", isHidden: { _ in false })
        guard case .suggested(let shown) = open.outcome else { Issue.record("no suggestion"); return }
        #expect(shown.first?.relativePath == "Private/Medical")
    }

    @Test func anUnsureAnswerCarriesARunnerUp() async {
        let m = manager("help-unsure", root: root, anchors: ["Home/Insurance": ["policy"], "Work/Insurance": ["policy"]])
        let answer = await m.whereToFile(root + "/insurance policy.pdf", snippet: nil, isHidden: { _ in false })
        guard case .suggested(let suggestions) = answer.outcome else { Issue.record("no suggestion: \(answer)"); return }
        #expect(suggestions.count == 2)
        #expect(suggestions.allSatisfy { $0.confidence != .high })
    }

    /// TE284: the file can sit anywhere on this Mac; only a place they name has to be surveyed.
    @Test func aFileOutsideTheSurveyIsPlacedAndAPlaceOutsideItSaysSo() async {
        let bare = FileSyncManager()
        #expect(await bare.whereToFile("/x/a.pdf", snippet: nil, isHidden: { _ in false }).outcome == .noProfile)
        let m = manager("help-outside", root: root, anchors: ["Taxes/2025": ["wages", "employer"], "Home": ["meter"]])
        let downloads = await m.whereToFile("/Users/someone/Downloads/scan.pdf", snippet: "wages employer",
                                            isHidden: { _ in false })
        guard case .suggested(let s) = downloads.outcome else { Issue.record("no suggestion: \(downloads)"); return }
        #expect(s.first?.relativePath == "Taxes/2025")
        let dropbox = await m.whereToFile("/Users/someone/Downloads/scan.pdf", snippet: "wages employer",
                                          preferring: "/Users/someone/Dropbox", isHidden: { _ in false })
        #expect(dropbox.outcome == .outsideProfile(surveyed: root))
        // The surveyed folder itself is in the survey: no preference, the plain answer.
        let whole = await m.whereToFile("/Users/someone/Downloads/scan.pdf", snippet: "wages employer",
                                        preferring: root, isHidden: { _ in false })
        #expect(whole.outcome == downloads.outcome)
    }

    private func candidate(_ path: String, _ score: Double) -> FilingRouter.Candidate {
        FilingRouter.Candidate(relativePath: path, score: score, evidenceToken: nil, sharedAnchors: 1)
    }

    /// Decision FX: the named place's folders lead unless a High answer says the file belongs
    /// elsewhere; a stronger folder outside it then makes the answer unsure.
    @Test func aNamedPlaceIsPreferredButAPlainHomeElsewhereStands() {
        let unsure = FilingRouter.Ranking(candidates: [candidate("Home/Receipts", 10), candidate("Travel/Trips", 9),
                                                       candidate("Work", 2)], margin: 0.1)
        let preferred = FileSyncManager.preferring(unsure, under: "travel")
        #expect(preferred.candidates.map(\.relativePath) == ["Travel/Trips", "Home/Receipts", "Work"])
        #expect(preferred.confidence == .low, "a stronger folder outside the place must leave it unsure")
        let plain = FilingRouter.Ranking(candidates: [candidate("Taxes/2025", 10), candidate("Travel", 2)], margin: 0.8)
        #expect(FileSyncManager.preferring(plain, under: "Travel") == plain)
        let stronger = FilingRouter.Ranking(candidates: [candidate("Home", 10), candidate("Travel/Trips", 9),
                                                         candidate("Travel", 1)], margin: 0.1)
        let led = FileSyncManager.preferring(stronger, under: "Travel")
        #expect(led.best?.relativePath == "Travel/Trips")
        #expect(led.confidence == .low, "the margin is taken against the strongest of the rest, not the next in the place")
        let ahead = FilingRouter.Ranking(candidates: [candidate("Travel/Trips", 10), candidate("Travel", 9),
                                                      candidate("Home", 3)], margin: 0.1)
        #expect(FileSyncManager.preferring(ahead, under: "Travel").confidence == ahead.confidence)
        // Nothing in the place ranked: the plain answer.
        #expect(FileSyncManager.preferring(unsure, under: "Health") == unsure)
        #expect(FileSyncManager.preferring(unsure, under: nil) == unsure)
    }

    @Test func outsidePlaceIsMarkedOnTheSuggestion() async {
        let m = manager("help-place", root: root, anchors: ["Taxes/2025": ["wages", "employer"], "Travel/Trips": ["airlines"]])
        let answer = await m.whereToFile("/elsewhere/w2.pdf", snippet: "wages employer", preferring: root + "/Travel",
                                         isHidden: { _ in false })
        guard case .suggested(let s) = answer.outcome else { Issue.record("no suggestion: \(answer)"); return }
        #expect(s.first?.relativePath == "Taxes/2025" && s.first?.outsidePlace == true)
    }

    /// The satellite map is built by each To File scan for that scan's tree. After a Dropbox scan
    /// its folders are Dropbox's, and the same relative paths in iCloud must not be demoted by it.
    @Test func aSatelliteMapFromAnotherTreeDemotesNothing() async {
        let m = manager("help-satellite", root: root, anchors: ["Taxes/2025": ["wages", "employer", "w2"],
                                                               "Archive/Taxes": ["wages"]])
        m.filingSatelliteHomes = ["Taxes/2025": ["Archive/Taxes"]]
        m.filingSatelliteRoot = "/never-on-disk-filing-help/Dropbox"
        let elsewhere = await m.whereToFile(root + "/w2.pdf", snippet: "wages employer w2", isHidden: { _ in false })
        guard case .suggested(let s) = elsewhere.outcome else { Issue.record("no suggestion: \(elsewhere)"); return }
        #expect(s.first?.relativePath == "Taxes/2025", "Dropbox's map demoted iCloud's folder")
        // The control: built for this tree, the map applies, and the copy gives way to its home.
        m.filingSatelliteRoot = root
        let own = await m.whereToFile(root + "/w2.pdf", snippet: "wages employer w2", isHidden: { _ in false })
        guard case .suggested(let o) = own.outcome else { Issue.record("no suggestion: \(own)"); return }
        #expect(o.first?.relativePath == "Archive/Taxes")
    }

    @Test func aSurveyFolderIsFoundByPathOrByItsName() {
        let m = manager("help-named", root: root, anchors: ["Travel": [], "Travel/Trips": [], "Work/Trips": [],
                                                           "Work/Old/Trips": []])
        #expect(m.filingSurveyFolder(named: "travel") == root + "/Travel")
        #expect(m.filingSurveyFolder(named: "Documents/Travel/Trips/") == root + "/Travel/Trips")
        #expect(m.filingSurveyFolder(named: "Trips") == root + "/Travel/Trips", "the shallowest, then by path")
        #expect(m.filingSurveyFolder(named: "Documents") == root)
        #expect(m.filingSurveyFolder(named: "Dropbox") == nil)
        #expect(FileSyncManager().filingSurveyFolder(named: "Travel") == nil)
    }

    @Test func aSurveyThreeWeeksOldIsStale() {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        #expect(FilingHelpAnswer(outcome: .noMatch, surveyedAt: now.addingTimeInterval(-20 * 86_400)).isStale(now: now) == false)
        #expect(FilingHelpAnswer(outcome: .noMatch, surveyedAt: now.addingTimeInterval(-21 * 86_400)).isStale(now: now))
        #expect(FilingHelpAnswer(outcome: .noMatch, surveyedAt: nil).isStale(now: now) == false)
    }

    /// Refine waits for the scan whose cards are on screen: one started while it waited replaces
    /// the one it began waiting on.
    @Test func refineWaitsForTheScanThatReplacedTheOneItWaitedOn() async {
        let m = FileSyncManager()
        var finished: [String] = []
        var waited = false
        let (firstGate, openFirst) = AsyncStream<Void>.makeStream()
        let (secondGate, openSecond) = AsyncStream<Void>.makeStream()
        let second = Task { @MainActor in
            for await _ in secondGate { break }
            finished.append("second")
        }
        m.filingScanTask = Task { @MainActor in
            for await _ in firstGate { break }
            m.filingScanTask = second
            finished.append("first")
        }
        let waiting = Task { @MainActor in
            await m.latestFilingScan()
            waited = true
        }
        // Waiting on the first scan, which then ends and hands over to the second: the wait
        // must still be on, held by the second.
        for _ in 0..<50 { await Task.yield() }
        openFirst.yield()
        openFirst.finish()
        for _ in 0..<200 where finished.isEmpty { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        #expect(finished == ["first"] && !waited, "the wait ended with the scan it began on")
        openSecond.yield()
        openSecond.finish()
        await waiting.value
        #expect(waited && finished == ["first", "second"])
    }

    /// Counted in calendar days, as Restructure counts them, so the card and Restructure agree on
    /// the same survey: late on the 1st to early on the 22nd is 21 days, though under 21 × 24 h.
    @Test func theSurveysAgeIsCountedInCalendarDays() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let surveyed = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 23)))
        let now = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 1)))
        let answer = FilingHelpAnswer(outcome: .noMatch, surveyedAt: surveyed)
        #expect(answer.surveyAgeDays(now: now, calendar: utc) == 21)
        #expect(answer.isStale(now: now, calendar: utc))
    }
}

/// What Claude is told about filing help's card (TE255).
@Suite struct AskClaudeFilingResultTests {

    private let card = AskClaudeFilingCard(
        fileName: "scan.pdf", filePath: "/c/Downloads/scan.pdf", kind: .suggestions,
        folders: [.init(label: "iCloud › Documents › Taxes › 2025", path: "/c/Documents/Taxes/2025", confidence: "Medium",
                        reason: "Matched “W-2” read from the file — a word this folder’s documents use", fromFile: true),
                  .init(label: "iCloud › Documents › Work", path: "/c/Documents/Work", confidence: "Medium",
                        reason: "Fits how this folder is used", fromFile: false)],
        staleDays: 30, canRefine: true)

    /// The word, and the folder it picked: "Taxes › 2025" for a scan named scan.pdf says it is a
    /// tax document (review of TE319–TE323).
    @Test func theWordReadFromTheFileGoesOnlyWithReadFilesOn() {
        let off = AskClaudeFiling.result(card, readsFiles: false)
        #expect(!off.contains("W-2") && !off.contains("Taxes"))
        #expect(off.contains("best: a folder picked by a word read from the file · Medium · on their card, not sent to you"))
        #expect(off.contains("runner-up: iCloud › Documents › Work · Medium · Fits how this folder is used"))
        #expect(AskClaudeFiling.result(card, readsFiles: true).contains("Matched “W-2”"))
        // Never a path.
        #expect(!off.contains("/c/"))
    }

    @Test func itSaysHowOldTheSurveyIsAndWhatTheCardOffers() {
        let text = AskClaudeFiling.result(card, readsFiles: false)
        #expect(text.contains("30 days old"))
        #expect(text.contains("Go to Folder and Move Here, and Refine with Claude"))
        #expect(text.contains("Nothing was moved."))
    }

    @Test func noProfileAndOutsideAskClaudeNotToGuess() {
        let none = AskClaudeFilingCard(fileName: "a.pdf", filePath: "/x/a.pdf", kind: .noProfile)
        #expect(AskClaudeFiling.result(none, readsFiles: false).contains("Don’t guess"))
        let outside = AskClaudeFilingCard(fileName: "a.pdf", filePath: "/x/a.pdf", kind: .outside(surveyed: "~/Documents"))
        #expect(AskClaudeFiling.result(outside, readsFiles: false).contains("covers ~/Documents only"))
        #expect(AskClaudeFiling.label(.low) == "Needs your pick")
    }
}
