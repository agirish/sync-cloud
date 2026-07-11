import Testing
import Foundation
@testable import Sync

/// Pins the name-pattern ignore matcher: single-component wildcard semantics,
/// case-insensitivity, any-depth component matching, and input normalization.
@Suite struct IgnoreRulesTests {

    @Test func testExactNameMatchesAnyComponent() {
        #expect(IgnoreRules.matches(".DS_Store", patterns: [".DS_Store"]))
        #expect(IgnoreRules.matches("Docs/.DS_Store", patterns: [".DS_Store"]))
        #expect(IgnoreRules.matches("node_modules/lib/index.js", patterns: ["node_modules"]))
        #expect(!IgnoreRules.matches("Docs/report.txt", patterns: [".DS_Store"]))
    }

    @Test func testStarWildcard() {
        #expect(IgnoreRules.nameMatches("draft.tmp", pattern: "*.tmp"))
        #expect(IgnoreRules.nameMatches(".tmp", pattern: "*.tmp"))
        #expect(!IgnoreRules.nameMatches("draft.tmpx", pattern: "*.tmp"))
        #expect(IgnoreRules.nameMatches("anything", pattern: "*"))
        #expect(IgnoreRules.nameMatches("a-b-c", pattern: "a*c"))
        #expect(!IgnoreRules.nameMatches("a-b-d", pattern: "a*c"))
        // Multiple stars with backtracking.
        #expect(IgnoreRules.nameMatches("prefix_mid_suffix.log", pattern: "*mid*.log"))
    }

    @Test func testQuestionMarkWildcard() {
        #expect(IgnoreRules.nameMatches("a1.txt", pattern: "a?.txt"))
        #expect(!IgnoreRules.nameMatches("a12.txt", pattern: "a?.txt"))
    }

    @Test func testMatchingIsCaseInsensitive() {
        #expect(IgnoreRules.nameMatches("Thumbs.DB", pattern: "thumbs.db"))
        #expect(IgnoreRules.matches("Backup/PHOTO.TMP", patterns: ["*.tmp"]))
    }

    @Test func testPatternMatchesComponentNotWholePath() {
        // A pattern never spans a "/": "Docs*.tmp" must not match a file inside Docs.
        #expect(!IgnoreRules.matches("Docs/x.tmp", patterns: ["Docs*x.tmp"]))
        #expect(IgnoreRules.matches("Docs/x.tmp", patterns: ["x.tmp"]))
    }

    @Test func testEmptyPatternsMatchNothing() {
        #expect(!IgnoreRules.matches("anything", patterns: []))
    }

    @Test func testNormalizedTrimsAndStripsSeparators() {
        #expect(IgnoreRules.normalized("  *.tmp \n") == "*.tmp")
        #expect(IgnoreRules.normalized("a/b") == "ab")
        #expect(IgnoreRules.normalized("   ") == nil)
        #expect(IgnoreRules.normalized("/") == nil)
    }
}
