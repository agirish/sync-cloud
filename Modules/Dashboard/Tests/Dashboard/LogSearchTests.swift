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

    @Test func invalidTokenishWordsStayFreeText() {
        let query = LogSearch.parse("since:soon level:")
        #expect(query.level == nil && query.since == nil)
        #expect(query.text == "since:soon level:")
    }

    @Test func duplicateFamilyChipsMarkEarlierOnesInactive() {
        // Parse is last-wins within a family (level and since are single-valued); chips read as the
        // effective query, so the superseded earlier chip renders inactive while both keep their
        // exact raw word for ✕ removal.
        let chips = LogSearch.chips("level:error level:warn since:1h")
        #expect(chips.count == 3)
        #expect(chips[0].raw == "level:error" && chips[0].isActive == false)
        #expect(chips[1].raw == "level:warn" && chips[1].isActive == true)
        #expect(chips[2].raw == "since:1h" && chips[2].isActive == true)
        #expect(LogSearch.parse("level:error level:warn").level == .warning)

        #expect(LogSearch.chips("level:error since:1h").map(\.isActive) == [true, true])

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

    @Test func removingDropsEveryOccurrenceOfTheWord() {
        // Chips are keyed by raw text, so the ✕ clears all duplicates of the word. With
        // `level:warn level:error level:warn`, removing only the first warn would leave the
        // effective (last-wins) filter unchanged and the ✕ would seem dead.
        #expect(LogSearch.removing("level:warn level:error level:warn", word: "level:warn") == "level:error")
        // And the effective query really flips once the duplicates are gone.
        #expect(LogSearch.parse(LogSearch.removing("level:warn level:error level:warn", word: "level:warn")).level == .error)
    }

    /// Full-grammar characterization: one query with every token family, multi-word free text and a
    /// superseded duplicate, pinning `parse` and `chips()` together so they agree on last-wins.
    @Test func fullGrammarSnapshotPinsParseAndChipsTogether() {
        let raw = "level:err since:30m level:WARN disk full"

        // Parse: last level wins (err is superseded), since parses to seconds, the free words join
        // in order, and the tokens never leak into the text.
        let query = LogSearch.parse(raw)
        #expect(query == LogSearch.Query(level: .warning, since: 1800, text: "disk full"))

        // Chips: every recognized token in typed order, raw preserved verbatim for ✕ removal,
        // labels canonicalized, and only the superseded family member inactive.
        #expect(LogSearch.chips(raw) == [
            LogSearch.Chip(raw: "level:err", label: "level: error", isActive: false),
            LogSearch.Chip(raw: "since:30m", label: "since: 30m", isActive: true),
            LogSearch.Chip(raw: "level:WARN", label: "level: warn", isActive: true),
        ])

        // The effective query behaves as the active chips read: warning level, 30-minute window,
        // "disk full" substring.
        #expect(query.matches(entry(.warning, "Disk full while copying", agoSeconds: 60), now: now))
        #expect(!query.matches(entry(.error, "Disk full while copying", agoSeconds: 60), now: now))  // superseded level must NOT match
        #expect(!query.matches(entry(.warning, "Disk full while copying", agoSeconds: 3600), now: now)) // outside since:30m
        #expect(!query.matches(entry(.warning, "Copy finished", agoSeconds: 60), now: now))              // free text still filters
    }
}
