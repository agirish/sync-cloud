import Foundation

/// Name-pattern ignore rules for the Differences list (e.g. `.DS_Store`, `*.tmp`,
/// `node_modules`). A pattern matches when ANY path component of an item's relative path
/// matches it, so `node_modules` hides a match at any depth and everything inside it.
/// Matching is case-insensitive with `*` (any run) and `?` (any one character) wildcards —
/// the same conventions as shell globs, scoped to a single name component.
public enum IgnoreRules {
    /// Patterns folded and scalar-decomposed once, so a scan pays for it once.
    ///
    /// ``matches(_:patterns:)`` folds on every call and is called once per differing item against
    /// the same handful of patterns, so a pass over *n* items with *k* patterns paid *n·k* pattern
    /// folds to learn *k* distinct things. The item side was worse in kind rather than degree: the
    /// fold lived inside the matcher, so a path of *d* components paid *d·k* folds of the NAME —
    /// the same component re-normalized once for every pattern it was tested against, where *d* is
    /// the honest count. Compiling lifts the pattern fold out of the scan and the name fold out of
    /// the inner loop. Same shape, and the same reasoning, as the regex pre-compile in
    /// ``DuplicateFinder``.
    public struct Compiled: Sendable {
        fileprivate let patterns: [[Unicode.Scalar]]

        public var isEmpty: Bool { patterns.isEmpty }

        public init(_ patterns: [String]) {
            self.patterns = patterns.map { IgnoreRules.folded($0) }
        }
    }

    /// True when any component of `path` matches any of `patterns`.
    ///
    /// Compiles on every call, which is right for a one-off and wrong inside a loop — a caller
    /// testing many paths against the same patterns should hoist a ``Compiled`` and use
    /// ``matches(_:compiled:)``.
    public static func matches(_ path: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        return matches(path, compiled: Compiled(patterns))
    }

    /// True when any component of `path` matches any of the pre-compiled `patterns`.
    public static func matches(_ path: String, compiled: Compiled) -> Bool {
        guard !compiled.isEmpty else { return false }
        for component in path.split(separator: "/") {
            // Folded ONCE per component, not once per (component, pattern) pair.
            let name = folded(component)
            for pattern in compiled.patterns where matches(name: name, pattern: pattern) {
                return true
            }
        }
        return false
    }

    /// Case-insensitive wildcard match of one name component against one pattern.
    static func nameMatches(_ name: String, pattern: String) -> Bool {
        matches(name: folded(name), pattern: folded(pattern))
    }

    /// Case folding plus canonical precomposition, down to the scalars the matcher walks.
    ///
    /// Both sides precompose (NFC) before the scalar walk: patterns arrive NFC from the
    /// keyboard while on-disk names are often NFD (HFS+ heritage, NFD-normalizing providers),
    /// and a scalar-exact comparison made an NFC "Résumé*" silently never match — the same
    /// fold `ProviderNameRules.normalizedComponent` applies for the same reason. Precomposing
    /// also lets `?` treat an accented letter as one unit for canonical cases; a grapheme that
    /// stays multi-scalar even precomposed (emoji ZWJ sequences) still counts per scalar —
    /// accepted, since such names in ignore patterns are vanishingly rare.
    ///
    /// **Not redundant with Swift's own string comparison**, which is canonical-equivalence-based
    /// and would make this fold inert. The matcher compares `Unicode.Scalar` values one at a time,
    /// and at that level `é` and `e` + `◌́` are simply different — which is the whole reason the
    /// walk cannot be written against `Character`.
    fileprivate static func folded<S: StringProtocol>(_ s: S) -> [Unicode.Scalar] {
        Array(String(s).precomposedStringWithCanonicalMapping.lowercased().unicodeScalars)
    }

    /// Iterative `*` backtracking (the classic two-pointer glob), so a pathological
    /// pattern can't recurse deeply. Both sides arrive already folded by ``folded(_:)``.
    private static func matches(name n: [Unicode.Scalar], pattern p: [Unicode.Scalar]) -> Bool {
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
