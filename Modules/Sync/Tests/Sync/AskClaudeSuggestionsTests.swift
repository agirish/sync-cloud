import Foundation
import Testing
@testable import Sync

/// The chip above Ask Claude's box: one at a time, never about a hidden folder, and only
/// while the box is free.
@Suite struct AskClaudeSuggestionsTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private func downloads(_ arrivals: [Date], hidden: Bool = false, source: String = "iCloud") -> AskClaudeSuggestions.Folder {
        .init(name: "Downloads", place: "\(source) › Downloads", arrivals: arrivals, hidden: hidden)
    }

    private func pick(_ facts: AskClaudeSuggestions.Facts, box: AskClaudeSuggestions.Box = .init(),
                      memory: AskClaudeSuggestions.Memory = .init()) -> AskClaudeSuggestions.Suggestion? {
        AskClaudeSuggestions.suggestion(facts, box: box, memory: memory, now: now, timeZone: utc)
    }

    @Test func newDownloadsAsksToFileThemNamingOnlyTheFolder() throws {
        let old = (0..<19).map { _ in ago(3 * 24 * 60) }
        let chip = try #require(pick(.init(workspace: "Browse", downloads: [downloads(old + (1...6).map { ago(Double($0)) })])))
        #expect(chip.text == "6 new files in Downloads")
        #expect(chip.action == "File them?")
        #expect(chip.question == "File the new files in iCloud › Downloads")
        #expect(chip.kind == .downloads)
    }

    @Test func fewerThanThreeNewFilesIsNoChip() {
        #expect(pick(.init(workspace: "Browse", downloads: [downloads([ago(1), ago(2)])])) == nil)
    }

    /// The first look counts the last day; a click moves "new" to the moment of the click.
    @Test func newMeansSinceTheLastClickOrTheLastDay() throws {
        let facts = AskClaudeSuggestions.Facts(workspace: "Browse",
                                               downloads: [downloads([ago(25 * 60), ago(26 * 60), ago(27 * 60), ago(5), ago(6), ago(7)])])
        let chip = try #require(pick(facts))
        #expect(chip.count == 3)
        var memory = AskClaudeSuggestions.Memory()
        #expect(chip.key == "downloads:iCloud › Downloads")
        AskClaudeSuggestions.clicked(chip, memory: &memory, now: now)
        #expect(pick(facts, memory: memory) == nil)
        let later = AskClaudeSuggestions.suggestion(
            .init(workspace: "Browse", downloads: [downloads(facts.downloads[0].arrivals + [now + 60, now + 120, now + 180])]),
            box: .init(), memory: memory, now: now + 300, timeZone: utc)
        #expect(later?.count == 3)
    }

    /// ✕ waits for more: six then six stays away, six then seven comes back.
    @Test func puttingAwayWaitsUntilMoreArrive() throws {
        let six = (1...6).map { ago(Double($0)) }
        let chip = try #require(pick(.init(workspace: "Browse", downloads: [downloads(six)])))
        var memory = AskClaudeSuggestions.Memory()
        AskClaudeSuggestions.putAway(chip, memory: &memory)
        #expect(pick(.init(workspace: "Browse", downloads: [downloads(six)]), memory: memory) == nil)
        #expect(pick(.init(workspace: "Browse", downloads: [downloads(six + [ago(0.5)])]), memory: memory)?.count == 7)
    }

    @Test func aHiddenDownloadsGivesNoChipAtAll() {
        #expect(pick(.init(workspace: "Browse", downloads: [downloads((1...9).map { ago(Double($0)) }, hidden: true)])) == nil)
    }

    @Test func theChipWaitsWhileTheBoxIsBusy() {
        let facts = AskClaudeSuggestions.Facts(workspace: "Browse", downloads: [downloads((1...6).map { ago(Double($0)) })])
        #expect(pick(facts) != nil)
        for busy in [AskClaudeSuggestions.Box(isRunning: true), .init(hasQueued: true), .init(isEditing: true),
                     .init(isListening: true), .init(hasDraft: true), .init(canAsk: false),
                     // Items attached for a question of their own: the chip's click would send them.
                     .init(hasAttachments: true)] {
            #expect(pick(facts, box: busy) == nil)
        }
    }

    @Test func aKindTurnedOffNeverShows() {
        let facts = AskClaudeSuggestions.Facts(workspace: "Browse", downloads: [downloads((1...6).map { ago(Double($0)) })])
        #expect(pick(facts, memory: .init(off: [.downloads])) == nil)
    }

    @Test func theInboxCountsLikeDownloadsButNeverTwiceForTheSameFiles() throws {
        let files = (1...4).map { ago(Double($0)) }
        let inbox = AskClaudeSuggestions.Folder(name: "TODO", place: "iCloud › TODO", arrivals: files, hidden: false)
        let chip = try #require(pick(.init(workspace: "Organize", inbox: inbox)))
        #expect(chip.text == "4 new files in TODO")
        #expect(chip.question == "File the new files in iCloud › TODO")
        let inside = AskClaudeSuggestions.Folder(name: "TODO", place: "iCloud › Downloads › TODO", arrivals: files, hidden: false)
        #expect(pick(.init(workspace: "Organize", downloads: [downloads([])], inbox: inside)) == nil)
    }

    @Test func aFreshScanSaysWhatItFoundAndAsksForASummary() throws {
        let chip = try #require(pick(.init(workspace: "Compare", comparison: .init(count: 38, scannedAt: ago(20), hidden: false))))
        #expect(chip.text.hasPrefix("The ") && chip.text.hasSuffix(" scan found 38 differences"))
        #expect(chip.action == "Ask about them")
        #expect(chip.question == "Sum up Compare’s 38 differences by kind and folder")
        #expect(pick(.init(workspace: "Compare", comparison: .init(count: 1, scannedAt: ago(20), hidden: false)))?.question
                == "Sum up Compare’s 1 difference by kind and folder")
    }

    @Test func aStaleEmptyOrHiddenComparisonGivesNoChip() {
        #expect(pick(.init(workspace: "Compare", comparison: .init(count: 38, scannedAt: ago(61), hidden: false))) == nil)
        #expect(pick(.init(workspace: "Compare", comparison: .init(count: 0, scannedAt: ago(5), hidden: false))) == nil)
        #expect(pick(.init(workspace: "Compare", comparison: .init(count: 38, scannedAt: ago(5), hidden: true))) == nil)
    }

    /// After a click or ✕, only a later scan with a different count brings it back.
    @Test func theNextScanBringsItBackOnlyWhenTheCountChanged() throws {
        let first = AskClaudeSuggestions.Comparison(count: 38, scannedAt: ago(30), hidden: false)
        let chip = try #require(pick(.init(workspace: "Compare", comparison: first)))
        for clicked in [true, false] {
            var memory = AskClaudeSuggestions.Memory()
            if clicked { AskClaudeSuggestions.clicked(chip, memory: &memory, now: now) }
            else { AskClaudeSuggestions.putAway(chip, memory: &memory) }
            #expect(pick(.init(workspace: "Compare", comparison: first), memory: memory) == nil)
            #expect(pick(.init(workspace: "Compare", comparison: .init(count: 38, scannedAt: ago(5), hidden: false)), memory: memory) == nil)
            #expect(pick(.init(workspace: "Compare", comparison: .init(count: 40, scannedAt: ago(5), hidden: false)), memory: memory)?.count == 40)
        }
    }

    /// One at a time: the workspace on screen wins, then the newest.
    @Test func theKindForTheScreenWinsThenTheNewest() {
        let facts = AskClaudeSuggestions.Facts(
            workspace: "Compare",
            downloads: [downloads((1...6).map { ago(Double($0)) }),
                        downloads((1...4).map { ago(Double($0) / 10) }, source: "Dropbox")],
            comparison: .init(count: 38, scannedAt: ago(40), hidden: false))
        #expect(pick(facts)?.kind == .compare)
        var browse = facts
        browse.workspace = "Browse"
        #expect(pick(browse)?.question == "File the new files in Dropbox › Downloads")
    }

    /// The count is the filing card's: no installers, unfinished downloads, dot files, or anything
    /// in a hidden folder.
    @Test func arrivalsCountWhatTheFilingCardWouldFileAndNothingHidden() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AskClaudeSuggestionsTests-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: dir) }
        try fm.createDirectory(atPath: dir + "/Taxes", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dir + "/Trips", withIntermediateDirectories: true)
        for name in ["a.pdf", "b.jpg", "Trips/c.pdf", "Taxes/1.pdf", "Taxes/2.pdf", "Zoom.pkg", "report.pdf.crdownload", ".DS_Store", ".secret"] {
            #expect(fm.createFile(atPath: dir + "/" + name, contents: Data("x".utf8)))
        }
        let before = Date().addingTimeInterval(-60)
        let arrivals = AskClaudeSuggestions.arrivals(in: dir, isHidden: { $0.hasSuffix("/Taxes") })
        #expect(arrivals.count == 3)
        #expect(arrivals.allSatisfy { $0 > before })
    }

    @Test func memoryRoundTripsThroughDefaultsAndSuggestionsStartOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "AskClaudeSuggestionsTests-\(UUID().uuidString)"))
        #expect(AskClaudeSuggestions.isEnabled(defaults))
        #expect(AskClaudeSuggestions.Memory.load(defaults) == .init())
        let memory = AskClaudeSuggestions.Memory(seen: ["downloads:iCloud › Downloads": .init(since: now, putAwayAt: 6)],
                                                 off: [.compare])
        memory.save(defaults)
        #expect(AskClaudeSuggestions.Memory.load(defaults) == memory)
    }
}
