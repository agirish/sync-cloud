import Foundation
import Design
import Events

/// Structured tokens for the Activity Log search, `level:` and `since:` on top of free text, in
/// Compare's token grammar. A query with no recognized tokens is a plain case-insensitive message
/// substring. Pure, so parsing and matching are unit-tested without a view.
///
/// The mechanics (tokenizer, all-occurrences removal, last-wins chips, duration parser) are
/// Design's shared `TokenQuery`; this grammar owns only its token table and `matches()`.
enum LogSearch {

    struct Query: Equatable {
        /// Exact level, e.g. `level:error` (distinct from the severity *chips*, which are a threshold).
        var level: LogLevel?
        /// "Newer than" window in seconds, e.g. `since:1h`.
        var since: TimeInterval?
        var text: String

        func matches(_ entry: LogEntry, now: Date) -> Bool {
            if let level, entry.level != level { return false }
            if let since, now.timeIntervalSince(entry.timestamp) > since { return false }
            if text.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(text)
        }
    }

    static func parse(_ raw: String) -> Query {
        var level: LogLevel?
        var since: TimeInterval?
        // No recognized tokens: freeText keeps the raw string verbatim, a plain substring search.
        let text = TokenQuery.freeText(raw) { word in
            if let parsedLevel = parseLevel(word) {
                level = parsedLevel
                return true
            }
            if let parsedSince = parseSince(word) {
                since = parsedSince
                return true
            }
            return false
        }
        return Query(level: level, since: since, text: text)
    }

    static func parseLevel(_ word: String) -> LogLevel? {
        let lower = word.lowercased()
        guard lower.hasPrefix("level:") else { return nil }
        switch String(lower.dropFirst("level:".count)) {
        case "error", "err": return .error
        case "warning", "warn": return .warning
        case "info": return .info
        case "debug": return .debug
        default: return nil
        }
    }

    // MARK: Chips (UI)

    /// A recognized filter word paired with a label, so the search bar can draw removable chips like
    /// Compare's. Its label keeps the value as typed: "1h", not "3600s".
    typealias Chip = TokenChip

    /// The `level:`/`since:` words in `raw`, in order, as chips; free text is excluded. Within each
    /// family only the last is `isActive`, matching `parse` (via `TokenQuery.lastWinsChips`).
    static func chips(_ raw: String) -> [Chip] {
        TokenQuery.lastWinsChips(raw) { word in
            if let level = parseLevel(word) {
                // The canonical level name, the log's own [WARN]/[ERROR] vocabulary, whatever
                // abbreviation was typed (`level:err`, `level:warn`).
                return (Chip(raw: word, label: "level: \(level.rawValue.lowercased())"), "level")
            }
            if parseSince(word) != nil {
                return (Chip(raw: word, label: "since: \(word.lowercased().dropFirst("since:".count))"), "since")
            }
            return nil
        }
    }

    /// Removes every occurrence of `word` from `raw`; `TokenQuery.removing` says why all of them is
    /// the honest ✕ under last-wins parsing.
    static func removing(_ raw: String, word: String) -> String {
        TokenQuery.removing(raw, word: word)
    }

    /// "1h" / "30m" / "2d" / "45s" → seconds. Nil for anything else, so an unrecognized `since:` word
    /// falls through to free text instead of filtering everything out.
    static func parseSince(_ word: String) -> TimeInterval? {
        let lower = word.lowercased()
        guard lower.hasPrefix("since:") else { return nil }
        return TokenQuery.parseDurationSeconds(String(lower.dropFirst("since:".count)))
    }
}
