import Testing
import Foundation
import Sync
@testable import FileExplorer

/// Coverage for the structured token search behind the Differences search field: size parsing,
/// tokenizing, matching, backward-compatible free text, and chip removal.
@Suite struct DifferenceSearchTests {

    private func diff(
        _ relativePath: String,
        type: FileDifference.DifferenceType = .missingOnRight,
        action: FileDifference.SyncAction = .copyToRight,
        leftSize: Int? = nil,
        rightSize: Int? = nil
    ) -> FileDifference {
        FileDifference(
            relativePath: relativePath,
            leftItemPath: "/l/\(relativePath)",
            rightItemPath: "/r/\(relativePath)",
            type: type,
            action: action,
            description: "t",
            leftFileSize: leftSize,
            rightFileSize: rightSize
        )
    }

    // MARK: parseSize

    @Test func parsesSizeUnitsAsSI() {
        #expect(DifferenceSearch.parseSize("1024") == 1024)          // bare number = bytes
        #expect(DifferenceSearch.parseSize("500kb") == 500_000)
        #expect(DifferenceSearch.parseSize("10mb") == 10_000_000)
        #expect(DifferenceSearch.parseSize("1.5gb") == 1_500_000_000)
        #expect(DifferenceSearch.parseSize("10zz") == nil)           // unknown unit
        #expect(DifferenceSearch.parseSize("") == nil)
        #expect(DifferenceSearch.parseSize("mb") == nil)             // no number
    }

    @Test func parseSizeRejectsOverflowingValuesWithoutCrashing() {
        // `Int(_: Double)` traps on out-of-range values; these must return nil, not crash.
        #expect(DifferenceSearch.parseSize("99999999999gb") == nil)          // ~1e20 bytes
        #expect(DifferenceSearch.parseSize("9999999999999999999") == nil)    // ~1e19 bytes > Int.max
        #expect(DifferenceSearch.parseSize(String(repeating: "9", count: 400)) == nil) // Double → inf
        // Large but in range still parses.
        #expect(DifferenceSearch.parseSize("9000000000") == 9_000_000_000)
        #expect(DifferenceSearch.parseSize("8gb") == 8_000_000_000)
    }

    @Test func overflowingSizeWordStaysFreeTextNotACrash() {
        // A `>`-word whose size overflows is not a valid token, so it falls through to free text.
        let query = DifferenceSearch.parse(">99999999999gb report")
        #expect(query.tokens.isEmpty)
        #expect(query.freeText == ">99999999999gb report")
    }

    // MARK: parse — legacy preservation

    @Test func noTokensPreservesRawFreeTextSpacing() {
        let query = DifferenceSearch.parse("my report")
        #expect(query.tokens.isEmpty)
        #expect(query.freeText == "my report")                       // phrase/spacing intact
    }

    @Test func invalidTokenishWordsStayFreeText() {
        // ">report" is not a valid size and "kind:" has no value → both are plain text, no tokens,
        // so the legacy substring search is preserved verbatim.
        let query = DifferenceSearch.parse(">report kind:")
        #expect(query.tokens.isEmpty)
        #expect(query.freeText == ">report kind:")
    }

    // MARK: parse — tokens

    @Test func parsesEachTokenKindAlongsideFreeText() {
        let query = DifferenceSearch.parse("kind:PDF >10mb only:left budget")
        #expect(query.tokens == [.kind("pdf"), .sizeAtLeast(10_000_000), .onlyLeft])
        #expect(query.freeText == "budget")
    }

    // MARK: matching

    @Test func kindMatchesExtensionCaseInsensitively() {
        let query = DifferenceSearch.parse("kind:pdf")
        #expect(query.matches(diff("Docs/a.PDF")))
        #expect(!query.matches(diff("Docs/a.txt")))
        #expect(!query.matches(diff("Docs/folder")))                 // no extension
    }

    @Test func sizeComparatorsUseDisplaySize() {
        // A missing-on-right item's shown size is its left size.
        #expect(DifferenceSearch.parse(">10mb").matches(diff("a", leftSize: 20_000_000)))
        #expect(!DifferenceSearch.parse(">10mb").matches(diff("a", leftSize: 5_000_000)))
        #expect(DifferenceSearch.parse("<1mb").matches(diff("a", leftSize: 500_000)))
        // A folder / unknown size never matches a size token.
        #expect(!DifferenceSearch.parse(">1kb").matches(diff("a", leftSize: nil)))
    }

    @Test func sideTokensMapToTheMissingSide() {
        #expect(DifferenceSearch.parse("only:left").matches(diff("a", type: .missingOnRight)))
        #expect(!DifferenceSearch.parse("only:left").matches(diff("a", type: .missingOnLeft)))
        #expect(DifferenceSearch.parse("only:right").matches(diff("a", type: .missingOnLeft)))
    }

    @Test func tokensAndFreeTextCombineWithAnd() {
        let query = DifferenceSearch.parse("kind:pdf report")
        #expect(query.matches(diff("Docs/report.pdf", leftSize: 1)))
        #expect(!query.matches(diff("Docs/summary.pdf", leftSize: 1)))   // free text "report" fails
        #expect(!query.matches(diff("Docs/report.txt", leftSize: 1)))    // kind fails
    }

    // MARK: removingToken

    @Test func removingTokenDropsThatWordAndKeepsTheRest() {
        #expect(DifferenceSearch.removingToken(.kind("pdf"), from: "kind:pdf >10mb report") == ">10mb report")
        #expect(DifferenceSearch.removingToken(.onlyLeft, from: "only:left report") == "report")
        // An absent token leaves the query unchanged (whitespace normalized to single spaces).
        #expect(DifferenceSearch.removingToken(.onlyRight, from: "kind:pdf report") == "kind:pdf report")
    }
}
