import Foundation
import Sync

/// Structured search for the Differences table: turns a raw query into filter tokens plus free text,
/// and matches a `FileDifference` against them. Pure, so every rule is unit-testable.
///
/// Grammar (any word not recognized as a token is free text, matched as a substring of the path):
///   - `kind:<ext>`     — file extension, e.g. `kind:pdf`, or a class alias (`kind:image`);
///                        LAST-WINS when repeated — two extensions can never both match one path,
///                        so conjunction would be a guaranteed dead-end
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

    /// Class aliases for `kind:` — a single word matching a fixed extension set, shared with the
    /// Tidy ▸ Duplicates search so `kind:image` means the same thing on every surface. Deliberately
    /// tiny: one alias, fixed list, everything else stays an exact extension match.
    static let kindClasses: [String: Set<String>] = [
        "image": ["jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp"],
    ]

    static func parse(_ raw: String) -> Query {
        let words = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var tokens: [Token] = []
        var freeWords: [String] = []
        for word in words {
            if let token = parseToken(word) {
                // `kind:` is last-wins (like Tidy/Log families): a path has ONE extension, so two
                // conjunctive kind: tokens can never both match — the earlier one is dropped rather
                // than turning the query into a guaranteed-empty dead-end. Size bounds and only:
                // stay conjunctive; those combinations are legitimate (ranges).
                if case .kind = token {
                    tokens.removeAll { if case .kind = $0 { return true } else { return false } }
                }
                tokens.append(token)
            } else {
                freeWords.append(word)
            }
        }
        // No recognized tokens → preserve the raw string verbatim (legacy substring search).
        let freeText = tokens.isEmpty ? raw : freeWords.joined(separator: " ")
        return Query(tokens: tokens, freeText: freeText)
    }

    // MARK: Chips (UI)

    /// A recognized filter word paired with its token, so the Compare search field can render
    /// removable chips. `raw` is the exact word typed, so a chip's ✕ removes precisely that word.
    struct Chip: Equatable {
        var raw: String
        var token: Token
        /// Whether this chip is part of the effective query. `parse` is last-wins for the `kind:`
        /// family, so when kind: appears twice only the LAST word filters anything; earlier ones
        /// render dimmed so the chips read as the query the filter actually runs.
        var isActive: Bool = true
    }

    /// Every recognized token word in `raw`, in typed order, as display chips. Free text is
    /// excluded. Within the `kind:` family only the last occurrence is `isActive` — matching
    /// `parse`'s last-wins semantics; size and only: chips are always active (conjunctive).
    static func chips(_ raw: String) -> [Chip] {
        var out: [Chip] = []
        var lastKindIndex: Int?
        for word in raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            guard let token = parseToken(word) else { continue }
            if case .kind = token {
                if let previous = lastKindIndex { out[previous].isActive = false }
                lastKindIndex = out.count
            }
            out.append(Chip(raw: word, token: token))
        }
        return out
    }

    /// Removes every occurrence of `word` from `raw`, leaving every other word as the user typed
    /// it. Backs a chip's ✕ button. ALL occurrences, deliberately: chips are keyed by their raw
    /// text, so with `kind:pdf ... kind:pdf` one ✕ clearing both duplicates is the honest
    /// semantics — removing only the first would leave the filter visibly unchanged.
    static func removing(_ raw: String, word: String) -> String {
        raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { $0 != word }
            .joined(separator: " ")
    }

    // MARK: Matching

    private static func matches(_ token: Token, _ difference: FileDifference) -> Bool {
        switch token {
        case .kind(let ext):
            let fileExtension = (difference.relativePath as NSString).pathExtension.lowercased()
            if let classExtensions = kindClasses[ext] {
                return classExtensions.contains(fileExtension)
            }
            return fileExtension == ext
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
