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
}
