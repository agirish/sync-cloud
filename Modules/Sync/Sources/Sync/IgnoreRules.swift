import Foundation

/// Name-pattern ignore rules for the Differences list (e.g. `.DS_Store`, `*.tmp`,
/// `node_modules`). A pattern matches when ANY path component of an item's relative path
/// matches it, so `node_modules` hides a match at any depth and everything inside it.
/// Matching is case-insensitive with `*` (any run) and `?` (any one character) wildcards —
/// the same conventions as shell globs, scoped to a single name component.
public enum IgnoreRules {
    /// True when any component of `path` matches any of `patterns`.
    public static func matches(_ path: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        for component in path.split(separator: "/") {
            for pattern in patterns where nameMatches(String(component), pattern: pattern) {
                return true
            }
        }
        return false
    }

    /// Case-insensitive wildcard match of one name component against one pattern.
    /// Iterative `*` backtracking (the classic two-pointer glob), so a pathological
    /// pattern can't recurse deeply.
    ///
    /// Both sides precompose (NFC) before the scalar walk: patterns arrive NFC from the
    /// keyboard while on-disk names are often NFD (HFS+ heritage, NFD-normalizing providers),
    /// and a scalar-exact comparison made an NFC "Résumé*" silently never match — the same
    /// fold `ProviderNameRules.normalizedComponent` applies for the same reason. Precomposing
    /// also lets `?` treat an accented letter as one unit for canonical cases; a grapheme that
    /// stays multi-scalar even precomposed (emoji ZWJ sequences) still counts per scalar —
    /// accepted, since such names in ignore patterns are vanishingly rare.
    static func nameMatches(_ name: String, pattern: String) -> Bool {
        let n = Array(name.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars)
        let p = Array(pattern.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars)
        var nIdx = 0, pIdx = 0
        var starIdx = -1, backtrackNIdx = 0

        while nIdx < n.count {
            if pIdx < p.count, p[pIdx] == "?" || p[pIdx] == n[nIdx] {
                nIdx += 1
                pIdx += 1
            } else if pIdx < p.count, p[pIdx] == "*" {
                starIdx = pIdx
                backtrackNIdx = nIdx
                pIdx += 1
            } else if starIdx >= 0 {
                pIdx = starIdx + 1
                backtrackNIdx += 1
                nIdx = backtrackNIdx
            } else {
                return false
            }
        }
        while pIdx < p.count, p[pIdx] == "*" { pIdx += 1 }
        return pIdx == p.count
    }

    /// Normalization for a user-entered pattern: trimmed, with any path separators removed —
    /// patterns match single name components, never whole paths. Returns nil when nothing
    /// usable remains.
    public static func normalized(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "")
        return trimmed.isEmpty ? nil : trimmed
    }
}
