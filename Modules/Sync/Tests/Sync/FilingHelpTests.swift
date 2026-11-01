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

    @Test func noProfileAndOutsideTheSurveyedFolderSaySo() async {
        let bare = FileSyncManager()
        #expect(await bare.whereToFile("/x/a.pdf", snippet: nil, isHidden: { _ in false }).outcome == .noProfile)
        let m = manager("help-outside", root: root, anchors: ["Taxes/2025": ["wages"]])
        let outside = await m.whereToFile("/Users/someone/Dropbox/a.pdf", snippet: nil, isHidden: { _ in false })
        #expect(outside.outcome == .outsideProfile(surveyed: root))
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

    @Test func theWordReadFromTheFileGoesOnlyWithReadFilesOn() {
        let off = AskClaudeFiling.result(card, readsFiles: false)
        #expect(!off.contains("W-2"))
        #expect(off.contains("best: iCloud › Documents › Taxes › 2025 · Medium · Matched a word read from the file"))
        #expect(off.contains("runner-up: iCloud › Documents › Work · Medium · Fits how this folder is used"))
        #expect(AskClaudeFiling.result(card, readsFiles: true).contains("Matched “W-2”"))
        // Never a path.
        #expect(!off.contains("/c/"))
    }

    @Test func itSaysHowOldTheSurveyIsAndWhatTheCardOffers() {
        let text = AskClaudeFiling.result(card, readsFiles: false)
        #expect(text.contains("30 days old"))
        #expect(text.contains("Go to Folder and Refine with Claude"))
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
