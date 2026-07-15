import Foundation
import Sync

/// Structured search for the Differences table: turns a raw query into filter tokens plus free text,
/// and matches a `FileDifference` against them. Pure, so every rule is unit-testable.
///
/// Grammar (any word not recognized as a token is free text, matched as a substring of the path):
///   - `kind:<ext>`     — file extension, e.g. `kind:pdf`
///   - `>N` / `<N`      — size at least / at most N, unit b/kb/mb/gb (SI 1000-base, matching the
///                        displayed sizes); a bare number is bytes, e.g. `>10mb`, `<500kb`
///   - `only:left` / `only:right` — items present on only that side
///
/// Backwards-compatible by construction: a query with NO recognized tokens keeps the exact legacy
/// behavior — the whole raw string (spacing intact) is one case-insensitive substring over the
/// relative path — so phrase and trailing-space searches are unchanged.
enum DifferenceSearch {

    enum Token: Equatable {
        case kind(String)        // lowercased extension, no leading dot
        case sizeAtLeast(Int)    // bytes
        case sizeAtMost(Int)     // bytes
        case onlyLeft
        case onlyRight
    }

    struct Query: Equatable {
        var tokens: [Token]
        var freeText: String

        var isEmpty: Bool { tokens.isEmpty && freeText.isEmpty }

        func matches(_ difference: FileDifference) -> Bool {
            for token in tokens where !DifferenceSearch.matches(token, difference) { return false }
            if freeText.isEmpty { return true }
            return difference.relativePath.range(of: freeText, options: .caseInsensitive) != nil
        }
    }

    static func parse(_ raw: String) -> Query {
        let words = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var tokens: [Token] = []
        var freeWords: [String] = []
        for word in words {
            if let token = parseToken(word) {
                tokens.append(token)
            } else {
                freeWords.append(word)
            }
        }
        // No recognized tokens → preserve the raw string verbatim (legacy substring search).
        let freeText = tokens.isEmpty ? raw : freeWords.joined(separator: " ")
        return Query(tokens: tokens, freeText: freeText)
    }

    /// Removes the first word that parses to `token` from a raw query, leaving every other word as
    /// the user typed it. Backs a chip's ✕ button.
    static func removingToken(_ token: Token, from raw: String) -> String {
        var removed = false
        var kept: [String] = []
        for word in raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            if !removed, parseToken(word) == token {
                removed = true
                continue
            }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }

    // MARK: Matching

    private static func matches(_ token: Token, _ difference: FileDifference) -> Bool {
        switch token {
        case .kind(let ext):
            return (difference.relativePath as NSString).pathExtension.lowercased() == ext
        case .sizeAtLeast(let bytes):
            guard let size = difference.displaySize else { return false }
            return size >= bytes
        case .sizeAtMost(let bytes):
            guard let size = difference.displaySize else { return false }
            return size <= bytes
        case .onlyLeft:
            // Present on the left only ⇒ missing on the right.
            return difference.type == .missingOnRight
        case .onlyRight:
            return difference.type == .missingOnLeft
        }
    }

    // MARK: Tokenizing

    private static func parseToken(_ word: String) -> Token? {
        let lower = word.lowercased()
        if lower.hasPrefix("kind:") {
            let ext = String(lower.dropFirst("kind:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return ext.isEmpty ? nil : .kind(ext)
        }
        if lower == "only:left" { return .onlyLeft }
        if lower == "only:right" { return .onlyRight }
        if lower.hasPrefix(">"), let bytes = parseSize(String(lower.dropFirst())) { return .sizeAtLeast(bytes) }
        if lower.hasPrefix("<"), let bytes = parseSize(String(lower.dropFirst())) { return .sizeAtMost(bytes) }
        return nil
    }

    /// "10mb" / "1.5gb" / "500kb" / "1024" → bytes. SI (1000-base) to match the app's displayed
    /// sizes (`ByteCountFormatter` `.file`). Returns nil for anything that isn't a number + known
    /// unit, so an unrecognized `>`/`<` word stays plain free text.
    static func parseSize(_ string: String) -> Int? {
        guard !string.isEmpty else { return nil }
        var number = ""
        var unit = ""
        for character in string {
            if character.isNumber || character == "." { number.append(character) } else { unit.append(character) }
        }
        guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
        let multiplier: Double
        switch unit {
        case "", "b": multiplier = 1
        case "k", "kb": multiplier = 1_000
        case "m", "mb": multiplier = 1_000_000
        case "g", "gb": multiplier = 1_000_000_000
        default: return nil
        }
        // Guard the Double→Int conversion: `Int(_: Double)` TRAPS when the value isn't representable,
        // and this parses live on every keystroke — an over-large token (e.g. `>99999999999gb`) would
        // otherwise crash the window. Strict `<`: `Double(Int.max)` rounds up to 2^63, which is itself
        // one past `Int.max`, so `bytes < Double(Int.max)` is what keeps `Int(bytes)` in range.
        let bytes = (value * multiplier).rounded()
        guard bytes >= 0, bytes < Double(Int.max) else { return nil }
        return Int(bytes)
    }
}
