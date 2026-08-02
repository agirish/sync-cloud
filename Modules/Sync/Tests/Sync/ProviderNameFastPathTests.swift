import Foundation
import Testing
@testable import Sync

/// Pins the fast paths added to `normalizedComponent` and `nearNameKey` against the
/// implementations they short-circuit.
///
/// Both are pure optimizations: they must return, byte for byte, what the slow path would have
/// returned. `legacyNormalizedComponent` / `legacyNearNameKey` below are that slow path kept
/// verbatim, and every case is asserted against BOTH it and a written-out expectation — two
/// implementations agreeing only proves they agree.
@Suite struct ProviderNameFastPathTests {

    // MARK: - The pre-change implementations, verbatim

    private func legacyNormalizedComponent(_ name: String) -> String {
        let precomposed = name.precomposedStringWithCanonicalMapping
        var trimmed = precomposed.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? precomposed : trimmed
    }

    private func legacyNearNameKey(_ path: String, foldCase: Bool) -> String {
        let normalized = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { legacyNormalizedComponent(String($0)) }
            .joined(separator: "/")
        return foldCase ? normalized.lowercased() : normalized
    }

    /// Every name that must survive the fast path unchanged, and every name that must fall off it.
    /// Used by several tests, so a case added here is covered by all of them at once.
    private static let names: [String] = [
        "", "a", "file.txt", "Some Folder", "a.b.c", "UPPER", "x y z", "a..b",
        "-", "_", "0", "~", "!@#$%^&()", "a\tb", "a\nb",              // interior control chars
        " leading", "trailing ", "both ", "trailing.", "trailing..", "dot.", "…", "..",
        ".", "  ", " . ", "\t", "\n", "\r", "\u{0B}", "\u{0C}",       // vanish-entirely cases
        "café", "cafe\u{0301}", "naïve", "🗂", "Ünicode", "日本語", "a\u{00A0}b",  // NBSP interior
        "ends\u{00A0}", "\u{00A0}starts",                             // NBSP edges (non-ASCII ws)
        "ends\u{0085}",                                               // NEL, in the set but not ASCII
    ]

    private static let paths: [String] = names + [
        "a/b", "a/b/c.txt", "/leading", "trailing/", "a//b", "/", "//", "a/ b/c", "a/b /c",
        "a/b./c", "Swimming /x.txt", "café/naïve.txt", "a/cafe\u{0301}/b", "dir./file",
        " /x", "x/ ", "a/./b", "a/../b",
    ]

    // MARK: - Equivalence with the slow path

    @Test func normalizedComponentMatchesThePreChangeImplementation() {
        for name in Self.names {
            #expect(ProviderNameRules.normalizedComponent(name) == legacyNormalizedComponent(name),
                    "normalizedComponent diverged for \(debugForm(name))")
        }
    }

    @Test func nearNameKeyMatchesThePreChangeImplementation() {
        for path in Self.paths {
            for foldCase in [true, false] {
                #expect(ProviderNameRules.nearNameKey(forRelativePath: path, foldCase: foldCase)
                        == legacyNearNameKey(path, foldCase: foldCase),
                        "nearNameKey(foldCase: \(foldCase)) diverged for \(debugForm(path))")
            }
        }
    }

    /// The written-out answers, so the pair above cannot agree on a wrong one.
    @Test func normalizesTheDocumentedForms() {
        #expect(ProviderNameRules.normalizedComponent("file.txt") == "file.txt")
        #expect(ProviderNameRules.normalizedComponent("trailing ") == "trailing")
        #expect(ProviderNameRules.normalizedComponent(" leading") == "leading")
        #expect(ProviderNameRules.normalizedComponent("dot.") == "dot")
        #expect(ProviderNameRules.normalizedComponent("dot..") == "dot")
        #expect(ProviderNameRules.normalizedComponent("a.b") == "a.b", "interior dot is kept")
        #expect(ProviderNameRules.normalizedComponent("x y") == "x y", "interior space is kept")
        // A component that would vanish keeps its precomposed form rather than collapsing to "".
        #expect(ProviderNameRules.normalizedComponent(" ") == " ")
        #expect(ProviderNameRules.normalizedComponent(".") == ".")
        // NFC: decomposed and precomposed spellings meet.
        #expect(ProviderNameRules.normalizedComponent("cafe\u{0301}") == "café")
        #expect(ProviderNameRules.nearNameKey(forRelativePath: "a/cafe\u{0301}/b", foldCase: false) == "a/café/b")
        #expect(ProviderNameRules.nearNameKey(forRelativePath: "Swimming /x.txt", foldCase: false) == "Swimming/x.txt")
    }

    // MARK: - The two properties the fast paths rest on

    /// The ASCII whitespace list is hard-coded in `ProviderNameRules`. Rather than trust it to
    /// have been remembered correctly, walk every ASCII scalar and compare against the very
    /// `CharacterSet` the slow path trims with. If Foundation's set ever disagrees, the fast
    /// path would silently stop stripping something — this is the tripwire.
    @Test func asciiWhitespacePredicateMatchesFoundation() {
        // "." is excluded from the first assertion and asserted separately: it is stripped by the
        // slow path without being whitespace, so folding it into the comparison as `|| byte == "."`
        // made that expectation unconditionally true for it — a hole exactly where the trailing-dot
        // rule lives.
        let dot = UInt8(ascii: ".")
        for byte in UInt8(0)...UInt8(127) where byte != dot {
            let scalar = Unicode.Scalar(byte)
            let foundationSaysWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            // A single-scalar name made of this byte: the slow path trims it to empty and so
            // hands back the original, which tells us nothing — so probe it as an EDGE byte on a
            // name with a real body, which is exactly how the predicate is used.
            let probe = "a" + String(scalar)
            let stripped = legacyNormalizedComponent(probe) != probe
            #expect(foundationSaysWhitespace == stripped,
                    "byte 0x\(String(byte, radix: 16)): Foundation says \(foundationSaysWhitespace), slow path stripped \(stripped)")
            // And the predicate the fast path uses must agree with Foundation on every one.
            #expect(ProviderNameRules.hasNothingToNormalize(probe) == !foundationSaysWhitespace,
                    "byte 0x\(String(byte, radix: 16)): fast-path predicate disagrees")
        }
        // The trailing dot: stripped by the slow path, so the predicate must reject it, and it
        // must not be classified as whitespace.
        #expect(!CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(dot)))
        #expect(legacyNormalizedComponent("a.") == "a", "premise: the slow path strips a trailing dot")
        #expect(!ProviderNameRules.hasNothingToNormalize("a."), "the fast path must not claim \"a.\" is a no-op")
    }

    /// `asciiLowercased` is only ever reached for strings the ASCII predicate accepted, and over
    /// that domain it must be indistinguishable from `lowercased()`. Checked scalar by scalar
    /// rather than on a sample, because the whole justification is "ASCII case mapping is
    /// byte-local" and one exception would be enough to break a diff key.
    @Test func asciiLowercaseMatchesFoundationForEveryAsciiScalar() {
        for byte in UInt8(0)...UInt8(127) {
            let s = "x" + String(Unicode.Scalar(byte)) + "Y"
            #expect(ProviderNameRules.asciiLowercased(s) == s.lowercased(),
                    "byte 0x\(String(byte, radix: 16)) lowercases differently")
        }
        // And on the real shapes it sees.
        for path in Self.paths where ProviderNameRules.pathHasNothingToNormalize(path) {
            #expect(ProviderNameRules.asciiLowercased(path) == path.lowercased(), "path \(debugForm(path))")
        }
    }

    /// The path-level predicate scans without splitting, so it must agree with applying the
    /// component-level one to each component the split would have produced.
    @Test func pathPredicateAgreesWithPerComponentPredicate() {
        for path in Self.paths {
            let perComponent = path
                .split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { ProviderNameRules.hasNothingToNormalize(String($0)) }
            #expect(ProviderNameRules.pathHasNothingToNormalize(path) == perComponent,
                    "predicates disagree for \(debugForm(path))")
        }
    }

    /// A name the fast path accepts must be returned identically — the property that makes the
    /// short-circuit legal at all.
    @Test func anythingTheFastPathAcceptsIsUnchangedByTheSlowPath() {
        for name in Self.names where ProviderNameRules.hasNothingToNormalize(name) {
            #expect(legacyNormalizedComponent(name) == name,
                    "fast path accepted \(debugForm(name)) but the slow path would have changed it")
        }
        for path in Self.paths where ProviderNameRules.pathHasNothingToNormalize(path) {
            #expect(legacyNearNameKey(path, foldCase: false) == path,
                    "fast path accepted path \(debugForm(path)) but the slow path would have changed it")
        }
    }

    private func debugForm(_ s: String) -> String {
        "\"\(s.unicodeScalars.map { $0.value < 0x20 || $0.value > 0x7E ? "\\u{\(String($0.value, radix: 16))}" : String($0) }.joined())\""
    }
}
