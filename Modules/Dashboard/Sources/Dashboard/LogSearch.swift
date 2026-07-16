import Foundation
import Events

/// Structured tokens for the Activity Log search — `level:` and `since:` on top of free text —
/// carrying the Compare token grammar to the log. A query with no recognized tokens is exactly the
/// legacy case-insensitive message substring, so the existing filter, history, and grouping behavior
/// is unchanged. Pure, so the parsing and matching are unit-tested without a view.
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
        let words = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var level: LogLevel?
        var since: TimeInterval?
        var freeWords: [String] = []
        var matchedAnyToken = false
        for word in words {
            if let parsedLevel = parseLevel(word) {
                level = parsedLevel; matchedAnyToken = true
            } else if let parsedSince = parseSince(word) {
                since = parsedSince; matchedAnyToken = true
            } else {
                freeWords.append(word)
            }
        }
        // No recognized tokens → keep the raw string verbatim (legacy substring search).
        let text = matchedAnyToken ? freeWords.joined(separator: " ") : raw
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

    /// "1h" / "30m" / "2d" / "45s" → seconds. Returns nil for anything else, so an unrecognized
    /// `since:` word falls through to plain free text rather than silently filtering everything out.
    static func parseSince(_ word: String) -> TimeInterval? {
        let lower = word.lowercased()
        guard lower.hasPrefix("since:") else { return nil }
        let value = String(lower.dropFirst("since:".count))
        var number = "", unit = ""
        for character in value {
            if character.isNumber || character == "." { number.append(character) } else { unit.append(character) }
        }
        guard let magnitude = Double(number), magnitude.isFinite, magnitude >= 0 else { return nil }
        let multiplier: Double
        switch unit {
        case "s", "sec": multiplier = 1
        case "m", "min": multiplier = 60
        case "h", "hr": multiplier = 3600
        case "d", "day", "days": multiplier = 86_400
        default: return nil
        }
        return magnitude * multiplier
    }
}
