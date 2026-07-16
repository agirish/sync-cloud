import Testing
import Foundation
@testable import Design

/// Direct coverage for the shared token-search core. The three grammars' full-grammar snapshot
/// suites (LogSearchTests / DifferenceSearchTests / DuplicateSearchTests) byte-pin the combined
/// parse↔chips contract; these tests pin the core's own primitives so a mechanics regression is
/// reported here, at the source, and not only through a grammar's snapshot.
@Suite struct TokenQueryTests {

    // A minimal chip for exercising the family-last-wins builder.
    private struct TestChip: Equatable, DimmableTokenChip {
        var raw: String
        var isActive: Bool = true
    }

    @Test func wordsSplitOnSpacesAndTabs() {
        #expect(TokenQuery.words("a b\tc") == ["a", "b", "c"])
        #expect(TokenQuery.words("  a   b  ") == ["a", "b"])
        #expect(TokenQuery.words("").isEmpty)
    }

    @Test func freeTextKeepsTheRawStringVerbatimWhenNothingIsConsumed() {
        // The backwards-compatibility rule: no token ⇒ the legacy substring search gets the raw
        // string exactly, spacing intact.
        #expect(TokenQuery.freeText("disk  full ") { _ in false } == "disk  full ")
    }

    @Test func freeTextJoinsUnconsumedWordsOnceAnyTokenMatches() {
        let text = TokenQuery.freeText("kind:pdf disk full") { $0.hasPrefix("kind:") }
        #expect(text == "disk full")
    }

    @Test func removingDropsEveryOccurrenceOfTheWordOnly() {
        #expect(TokenQuery.removing("a b a c", word: "a") == "b c")
        #expect(TokenQuery.removing("a b", word: "z") == "a b")
    }

    @Test func lastWinsChipsDimEarlierSameFamilyOccurrences() {
        let chips = TokenQuery.lastWinsChips("k:1 s:1 k:2 free") { word -> (chip: TestChip, family: String?)? in
            guard word.contains(":") else { return nil }
            return (TestChip(raw: word), String(word.prefix(1)))
        }
        #expect(chips == [
            TestChip(raw: "k:1", isActive: false),
            TestChip(raw: "s:1", isActive: true),
            TestChip(raw: "k:2", isActive: true),
        ])
    }

    @Test func nilFamilyChipsAreNeverSuperseded() {
        let chips = TokenQuery.lastWinsChips("a a") { word -> (chip: TestChip, family: String?)? in
            (TestChip(raw: word), nil)
        }
        #expect(chips.map(\.isActive) == [true, true])
    }

    @Test func parseSizeBytesUsesSIUnitsAndGuardsOverflow() {
        #expect(TokenQuery.parseSizeBytes("1024") == 1024)
        #expect(TokenQuery.parseSizeBytes("500kb") == 500_000)
        #expect(TokenQuery.parseSizeBytes("1.5gb") == 1_500_000_000)
        #expect(TokenQuery.parseSizeBytes("10zz") == nil)
        #expect(TokenQuery.parseSizeBytes("") == nil)
        #expect(TokenQuery.parseSizeBytes("99999999999gb") == nil)   // would trap Int(_: Double)
    }

    @Test func parseDurationSecondsKnowsTheLogUnits() {
        #expect(TokenQuery.parseDurationSeconds("45s") == 45)
        #expect(TokenQuery.parseDurationSeconds("30m") == 1800)
        #expect(TokenQuery.parseDurationSeconds("1h") == 3600)
        #expect(TokenQuery.parseDurationSeconds("2d") == 172_800)
        #expect(TokenQuery.parseDurationSeconds("soon") == nil)
        #expect(TokenQuery.parseDurationSeconds("") == nil)
    }
}
