import Testing
import Foundation
import Events
@testable import Dashboard

/// Coverage for the Activity Log token search: `level:` / `since:` parsing, backward-compatible free
/// text, and the combined match predicate.
@Suite struct LogSearchTests {

    private let now = Date(timeIntervalSince1970: 2_000_000)
    private func entry(_ level: LogLevel, _ message: String, agoSeconds: TimeInterval = 0) -> LogEntry {
        LogEntry(timestamp: now.addingTimeInterval(-agoSeconds), level: level, message: message)
    }

    @Test func parsesLevelTokens() {
        #expect(LogSearch.parseLevel("level:error") == .error)
        #expect(LogSearch.parseLevel("level:WARN") == .warning)
        #expect(LogSearch.parseLevel("level:info") == .info)
        #expect(LogSearch.parseLevel("level:debug") == .debug)
        #expect(LogSearch.parseLevel("level:") == nil)
        #expect(LogSearch.parseLevel("error") == nil) // a bare word is free text, not a token
    }

    @Test func parsesSinceTokens() {
        #expect(LogSearch.parseSince("since:45s") == 45)
        #expect(LogSearch.parseSince("since:30m") == 1800)
        #expect(LogSearch.parseSince("since:1h") == 3600)
        #expect(LogSearch.parseSince("since:2d") == 172_800)
        #expect(LogSearch.parseSince("since:") == nil)
        #expect(LogSearch.parseSince("since:soon") == nil)
    }

    @Test func noTokensPreservesRawText() {
        let query = LogSearch.parse("disk full")
        #expect(query.level == nil && query.since == nil)
        #expect(query.text == "disk full")
    }

    @Test func parsesTokensAlongsideFreeText() {
        let query = LogSearch.parse("level:error since:1h dropbox")
        #expect(query.level == .error)
        #expect(query.since == 3600)
        #expect(query.text == "dropbox")
    }

    @Test func matchingAppliesEveryPart() {
        let query = LogSearch.parse("level:error since:1h copy")
        #expect(query.matches(entry(.error, "Copy failed", agoSeconds: 600), now: now))      // error, 10m ago, has "copy"
        #expect(!query.matches(entry(.warning, "Copy skipped", agoSeconds: 600), now: now))   // wrong level
        #expect(!query.matches(entry(.error, "Copy failed", agoSeconds: 7200), now: now))     // 2h ago → too old
        #expect(!query.matches(entry(.error, "Scan complete", agoSeconds: 600), now: now))    // no "copy"
    }

    @Test func invalidTokenishWordsStayFreeText() {
        let query = LogSearch.parse("since:soon level:")
        #expect(query.level == nil && query.since == nil)
        #expect(query.text == "since:soon level:")
    }

    @Test func chipsListRecognizedTokensAndSkipFreeText() {
        let chips = LogSearch.chips("level:error since:1h dropbox")
        #expect(chips == [LogSearch.Chip(raw: "level:error", label: "level: error"),
                          LogSearch.Chip(raw: "since:1h", label: "since: 1h")])
    }

    @Test func chipLabelKeepsTheTypedSinceValueButCanonicalizesLevel() {
        // The since value survives exactly as typed; the level label is the canonical name even when
        // abbreviated.
        #expect(LogSearch.chips("since:30m") == [LogSearch.Chip(raw: "since:30m", label: "since: 30m")])
        #expect(LogSearch.chips("level:err") == [LogSearch.Chip(raw: "level:err", label: "level: error")])
        #expect(LogSearch.chips("level:WARN") == [LogSearch.Chip(raw: "level:WARN", label: "level: warn")])
    }

    @Test func duplicateFamilyChipsMarkEarlierOnesInactive() {
        // parse is last-wins within a family (level/since are single-valued); chips must read as
        // the effective query, so the superseded earlier chip renders inactive while both keep
        // their exact raw word for ✕ removal.
        let chips = LogSearch.chips("level:error level:warn since:1h")
        #expect(chips.count == 3)
        #expect(chips[0].raw == "level:error" && chips[0].isActive == false)
        #expect(chips[1].raw == "level:warn" && chips[1].isActive == true)
        #expect(chips[2].raw == "since:1h" && chips[2].isActive == true)
        // The effective query really is the last one.
        #expect(LogSearch.parse("level:error level:warn").level == .warning)

        // Different families never supersede each other.
        #expect(LogSearch.chips("level:error since:1h").map(\.isActive) == [true, true])

        // Three of a kind: only the last stays active.
        let triple = LogSearch.chips("since:1h since:2h since:3h")
        #expect(triple.map(\.isActive) == [false, false, true])
    }

    @Test func chipsAreEmptyWithoutTokens() {
        #expect(LogSearch.chips("disk full since:soon").isEmpty)
    }

    @Test func removingDropsOnlyTheChipWordVerbatim() {
        #expect(LogSearch.removing("level:error since:1h dropbox", word: "level:error") == "since:1h dropbox")
        #expect(LogSearch.removing("level:error since:1h dropbox", word: "since:1h") == "level:error dropbox")
    }

    @Test func removingLeavesFreeTextWhenNoTokensLeft() {
        #expect(LogSearch.removing("dropbox level:error", word: "level:error") == "dropbox")
    }
}
