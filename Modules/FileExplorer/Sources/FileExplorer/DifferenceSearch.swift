import Foundation
import Design
import Sync

/// Structured search for the Differences table: turns a raw query into filter tokens plus free text,
/// and matches a `FileDifference` against them. Pure, so every rule is unit-testable.
///
/// Grammar (any word not recognized as a token is free text, matched as a substring of the path):
///   - `kind:<ext>`     — file extension, e.g. `kind:pdf`, or a class alias (`kind:image`);
///                        last wins when repeated, since one path can't match two extensions
///   - `>N` / `<N`      — size at least / at most N, unit b/kb/mb/gb (SI 1000-base, matching the
///                        displayed sizes); a bare number is bytes, e.g. `>10mb`, `<500kb`
///   - `only:left` / `only:right` — items present on only that side
///
/// A query with no recognized tokens is the whole raw string, spacing intact, as one
/// case-insensitive substring over the relative path, so phrase and trailing-space searches work.
///
/// The mechanics (tokenizer, raw fallback, removal, last-wins chips, size parser) are Design's
/// shared `TokenQuery`; this grammar owns only its token table and `matches()`.
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

        /// `pathRootName` is the Path column's anchor for the rows being searched. Free text
        /// matches what the table shows: `relativePath` or the anchored Path-column text, since
        /// the anchor ("Home", or "Top level") appears in no `relativePath` and visible text must
        /// be findable.
        func matches(_ difference: FileDifference, pathRootName: String?) -> Bool {
            for token in tokens where !DifferenceSearch.matches(token, difference) { return false }
            if freeText.isEmpty { return true }
            if difference.relativePath.range(of: freeText, options: .caseInsensitive) != nil { return true }
            return DifferencesQuery.pathColumnText(parentPath: difference.parentPath, rootName: pathRootName)
                .range(of: freeText, options: .caseInsensitive) != nil
        }
    }

    /// Class aliases for `kind:`, shared with the Duplicates lens search so `kind:image` means the
    /// same everywhere. Deliberately tiny: everything else is an exact extension match.
    static let kindClasses: [String: Set<String>] = [
        "image": ["jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp"],
    ]

    static func parse(_ raw: String) -> Query {
        var tokens: [Token] = []
        // No recognized tokens → freeText keeps the raw string verbatim (one substring search).
        let freeText = TokenQuery.freeText(raw) { word in
            guard let token = parseToken(word) else { return false }
            // `kind:` is last-wins, like the lens and Log families: a path has one extension, so
            // an earlier kind: is dropped rather than emptying the query. Size bounds and only:
            // stay conjunctive, since ranges are legitimate.
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
        /// Whether this chip is part of the effective query. `kind:` is last-wins in `parse`, so
        /// earlier kind: chips render dimmed and the chips read as the query that actually runs.
        var isActive: Bool = true
    }

    /// Every recognized token word in `raw`, in typed order, as display chips; free text is
    /// excluded. Only the last `kind:` is `isActive`, matching `parse` (via
    /// `TokenQuery.lastWinsChips`); size and only: chips have no family, so are always active.
    static func chips(_ raw: String) -> [Chip] {
        TokenQuery.lastWinsChips(raw) { word in
            guard let token = parseToken(word) else { return nil }
            if case .kind = token {
                return (Chip(raw: word, token: token), "kind")
            }
            return (Chip(raw: word, token: token), nil)
        }
    }

    /// Removes every occurrence of `word` from `raw`. See `TokenQuery.removing` for why ✕ removes
    /// all of them under last-wins parsing.
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
    /// 1000-base, overflow-guarded). The named entry point `DuplicateSearch` and the tests use.
    static func parseSize(_ string: String) -> Int? {
        TokenQuery.parseSizeBytes(string)
    }
}
