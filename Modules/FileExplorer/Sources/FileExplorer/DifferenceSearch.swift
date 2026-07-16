import Foundation
import Design
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
///
/// The mechanics (tokenizer, verbatim-raw fallback, all-occurrences removal, family-last-wins
/// chips, the number+unit size parser) are Design's shared `TokenQuery` core; this grammar owns
/// only its token table and `matches()`.
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
        var tokens: [Token] = []
        // No recognized tokens → freeText preserves the raw string verbatim (legacy substring search).
        let freeText = TokenQuery.freeText(raw) { word in
            guard let token = parseToken(word) else { return false }
            // `kind:` is last-wins (like Tidy/Log families): a path has ONE extension, so two
            // conjunctive kind: tokens can never both match — the earlier one is dropped rather
            // than turning the query into a guaranteed-empty dead-end. Size bounds and only:
            // stay conjunctive; those combinations are legitimate (ranges).
            if case .kind = token {
                tokens.removeAll { if case .kind = $0 { return true } else { return false } }
            }
            tokens.append(token)
            return true
        }
        return Query(tokens: tokens, freeText: freeText)
    }

    // MARK: Chips (UI)

    /// A recognized filter word paired with its token, so the Compare search field can render
    /// removable chips. `raw` is the exact word typed, so a chip's ✕ removes precisely that word.
    struct Chip: Equatable, DimmableTokenChip {
        var raw: String
        var token: Token
        /// Whether this chip is part of the effective query. `parse` is last-wins for the `kind:`
        /// family, so when kind: appears twice only the LAST word filters anything; earlier ones
        /// render dimmed so the chips read as the query the filter actually runs.
        var isActive: Bool = true
    }

    /// Every recognized token word in `raw`, in typed order, as display chips. Free text is
    /// excluded. Within the `kind:` family only the last occurrence is `isActive` — matching
    /// `parse`'s last-wins semantics (via `TokenQuery.lastWinsChips`); size and only: chips are
    /// always active (conjunctive, so their family is nil).
    static func chips(_ raw: String) -> [Chip] {
        TokenQuery.lastWinsChips(raw) { word in
            guard let token = parseToken(word) else { return nil }
            if case .kind = token {
                return (Chip(raw: word, token: token), "kind")
            }
            return (Chip(raw: word, token: token), nil)
        }
    }

    /// Removes every occurrence of `word` from `raw` — see `TokenQuery.removing` for why ALL
    /// occurrences is the honest ✕ semantics under last-wins parsing.
    static func removing(_ raw: String, word: String) -> String {
        TokenQuery.removing(raw, word: word)
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

    /// "10mb" / "1.5gb" / "500kb" / "1024" → bytes, via the shared `TokenQuery` parser (SI
    /// 1000-base, overflow-guarded). Kept as this grammar's named entry point because Tidy's
    /// `DuplicateSearch` and the tests address the size vocabulary through it.
    static func parseSize(_ string: String) -> Int? {
        TokenQuery.parseSizeBytes(string)
    }
}
