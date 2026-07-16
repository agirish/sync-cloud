import Foundation
import Design
import Events

/// Structured tokens for the Activity Log search — `level:` and `since:` on top of free text —
/// carrying the Compare token grammar to the log. A query with no recognized tokens is exactly the
/// legacy case-insensitive message substring, so the existing filter, history, and grouping behavior
/// is unchanged. Pure, so the parsing and matching are unit-tested without a view.
///
/// The mechanics (tokenizer, all-occurrences removal, family-last-wins chips, the number+unit
/// duration parser) are Design's shared `TokenQuery` core; this grammar owns only its token table
/// (`level:` / `since:`) and `matches()`.
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
        // No recognized tokens → freeText keeps the raw string verbatim (legacy substring search).
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

    /// A recognized filter word paired with a human label, so the search bar can render removable
    /// chips like Compare's. `raw` is the exact word the user typed (e.g. `since:1h`), so a chip's ✕
    /// removes precisely that word and its label reflects the value chosen — `since:1h` stays "1h",
    /// not a normalized "3600s".
    struct Chip: Equatable, DimmableTokenChip {
        var raw: String
        var label: String
        /// Whether this chip is part of the effective query. `parse` is last-wins within a family
        /// (level/since are single-valued), so when the same family appears twice only the LAST
        /// word filters anything; earlier ones render dimmed so the chips read as the query the
        /// filter actually runs. Their ✕ still removes the superseded word exactly.
        var isActive: Bool = true
    }

    /// The `level:`/`since:` words in `raw`, in order, as display chips. Free text is excluded, so the
    /// chips are exactly the active structured filters. Within each family only the last occurrence is
    /// `isActive` — matching `parse`'s last-wins semantics (via `TokenQuery.lastWinsChips`).
    static func chips(_ raw: String) -> [Chip] {
        TokenQuery.lastWinsChips(raw) { word in
            if let level = parseLevel(word) {
                // Canonical level name (matches the log's own [WARN]/[ERROR] vocabulary) regardless of
                // the abbreviation typed (`level:err`, `level:warn`).
                return (Chip(raw: word, label: "level: \(level.rawValue.lowercased())"), "level")
            }
            if parseSince(word) != nil {
                return (Chip(raw: word, label: "since: \(word.lowercased().dropFirst("since:".count))"), "since")
            }
            return nil
        }
    }

    /// Removes every occurrence of `word` from `raw` — see `TokenQuery.removing` for why ALL
    /// occurrences is the honest ✕ semantics under last-wins parsing.
    static func removing(_ raw: String, word: String) -> String {
        TokenQuery.removing(raw, word: word)
    }

    /// "1h" / "30m" / "2d" / "45s" → seconds. Returns nil for anything else, so an unrecognized
    /// `since:` word falls through to plain free text rather than silently filtering everything out.
    static func parseSince(_ word: String) -> TimeInterval? {
        let lower = word.lowercased()
        guard lower.hasPrefix("since:") else { return nil }
        return TokenQuery.parseDurationSeconds(String(lower.dropFirst("since:".count)))
    }
}
