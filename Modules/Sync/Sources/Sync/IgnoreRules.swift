import Foundation

/// Name-pattern ignore rules for the Differences list (e.g. `.DS_Store`, `*.tmp`,
/// `node_modules`). A pattern matches when any path component of an item's relative path matches
/// it, so `node_modules` hides a match at any depth and everything inside it. Case-insensitive, with
/// shell-glob `*` and `?` wildcards, scoped to one name component.
public enum IgnoreRules {
    /// Patterns folded to scalars once, so a scan over many items pays for it once rather than per
    /// item, as ``DuplicateFinder`` pre-compiles its regexes.
    public struct Compiled: Sendable {
        fileprivate let patterns: [[Unicode.Scalar]]

        public var isEmpty: Bool { patterns.isEmpty }

        public init(_ patterns: [String]) {
            self.patterns = patterns.map { IgnoreRules.folded($0) }
        }
    }

    /// True when any component of `path` matches any of `patterns`.
    ///
    /// Compiles on every call: fine for a one-off. In a loop, hoist a ``Compiled`` and use
    /// ``matches(_:compiled:)``.
    public static func matches(_ path: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        return matches(path, compiled: Compiled(patterns))
    }

    /// True when any component of `path` matches any of the pre-compiled `patterns`.
    public static func matches(_ path: String, compiled: Compiled) -> Bool {
        guard !compiled.isEmpty else { return false }
        for component in path.split(separator: "/") {
            // Folded once per component, not once per (component, pattern) pair.
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

    /// Case folding plus canonical precomposition, down to the scalars the matcher walks. **Both
    /// sides are NFC**: patterns come NFC from the keyboard while on-disk names are often NFD, and a
    /// scalar-exact match would never let `Résumé*` match (as in
    /// `ProviderNameRules.normalizedComponent`). It also lets `?` take an accented letter as one
    /// unit; a grapheme still multi-scalar after precomposing (emoji ZWJ) counts per scalar, which is
    /// accepted. Needed because the matcher compares scalars, not `Character`s.
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

    /// Normalization for a user-entered pattern: trimmed, with path separators removed, since
    /// patterns match single name components. nil when nothing usable remains.
    public static func normalized(_ raw: String) -> String? {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "")
        return trimmed.isEmpty ? nil : trimmed
    }
}
