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

    @Test func kindImageClassMatchesAnyImageExtension() {
        // `kind:image` is the same class alias the Tidy search resolves — one vocabulary across
        // surfaces (it used to be Tidy-only, so `kind:image` in Compare matched nothing).
        let query = DifferenceSearch.parse("kind:image")
        #expect(query.matches(diff("Photos/a.jpg")))
        #expect(query.matches(diff("Photos/a.PNG")))
        #expect(query.matches(diff("Photos/a.heic")))
        #expect(!query.matches(diff("Docs/a.pdf")))
        // No extension named "image" would ever match literally — the alias owns the word.
        #expect(!query.matches(diff("Docs/noext")))
    }

    @Test func kindClassTableIsSharedWithTheTidySearch() {
        // Both surfaces resolve `kind:` aliases through the same table; if they ever fork, the
        // "one vocabulary" promise (and the shared suggestion copy) silently breaks.
        #expect(DuplicateSearch.kindClasses == DifferenceSearch.kindClasses)
    }

    // MARK: kind: is last-wins

    @Test func repeatedKindTokensAreLastWins() {
        // A path has ONE extension, so two conjunctive kind: tokens are a guaranteed dead-end;
        // parse keeps only the last, like the Tidy and Log families.
        let query = DifferenceSearch.parse("kind:pdf kind:png")
        #expect(query.tokens == [.kind("png")])
        #expect(query.matches(diff("a.png")))
        #expect(!query.matches(diff("a.pdf")))
        // Size and only: stay conjunctive — ranges are legitimate.
        let range = DifferenceSearch.parse(">1mb <5mb")
        #expect(range.tokens == [.sizeAtLeast(1_000_000), .sizeAtMost(5_000_000)])
    }

    // MARK: chips

    @Test func chipsListTokenWordsAndSkipFreeText() {
        let chips = DifferenceSearch.chips("kind:PDF >10mb only:left budget")
        #expect(chips == [
            DifferenceSearch.Chip(raw: "kind:PDF", token: .kind("pdf")),
            DifferenceSearch.Chip(raw: ">10mb", token: .sizeAtLeast(10_000_000)),
            DifferenceSearch.Chip(raw: "only:left", token: .onlyLeft),
        ])
    }

    @Test func duplicateKindChipsMarkEarlierOnesInactive() {
        let chips = DifferenceSearch.chips("kind:pdf >10mb kind:png")
        #expect(chips.count == 3)
        #expect(chips[0].raw == "kind:pdf" && chips[0].isActive == false)
        #expect(chips[1].raw == ">10mb" && chips[1].isActive == true)
        #expect(chips[2].raw == "kind:png" && chips[2].isActive == true)
    }

    // MARK: removing

    @Test func removingDropsThatWordAndKeepsTheRest() {
        #expect(DifferenceSearch.removing("kind:pdf >10mb report", word: "kind:pdf") == ">10mb report")
        #expect(DifferenceSearch.removing("only:left report", word: "only:left") == "report")
        // An absent word leaves the query unchanged (whitespace normalized to single spaces).
        #expect(DifferenceSearch.removing("kind:pdf report", word: "only:right") == "kind:pdf report")
    }

    @Test func removingDropsEveryOccurrenceOfTheWord() {
        // Chips are keyed by raw text, so one ✕ must clear all duplicates of that word — removing
        // only the first would leave the effective filter unchanged (the survivor still parses).
        #expect(DifferenceSearch.removing("kind:pdf report kind:pdf", word: "kind:pdf") == "report")
    }

    // MARK: parse ↔ chips snapshot

    /// Full-grammar characterization, mirroring DuplicateSearchTests' snapshot: ONE composite
    /// query exercising every token family (`kind:` twice — the second being the `image` class
    /// alias — both size comparators, an only: side), multi-word free text — pinning the parsed
    /// query AND the chips() output (raw, token, isActive) together, so tokenization, the alias
    /// set, last-wins, size parsing, and chip marking can't drift apart unnoticed.
    @Test func fullGrammarSnapshotPinsParseAndChipsTogether() {
        let raw = "kind:JPG >500kb <2mb kind:image only:left draft copy"

        let query = DifferenceSearch.parse(raw)
        #expect(query == DifferenceSearch.Query(
            tokens: [.sizeAtLeast(500_000), .sizeAtMost(2_000_000), .kind("image"), .onlyLeft],
            freeText: "draft copy"
        ))

        #expect(DifferenceSearch.chips(raw) == [
            DifferenceSearch.Chip(raw: "kind:JPG", token: .kind("jpg"), isActive: false),
            DifferenceSearch.Chip(raw: ">500kb", token: .sizeAtLeast(500_000), isActive: true),
            DifferenceSearch.Chip(raw: "<2mb", token: .sizeAtMost(2_000_000), isActive: true),
            DifferenceSearch.Chip(raw: "kind:image", token: .kind("image"), isActive: true),
            DifferenceSearch.Chip(raw: "only:left", token: .onlyLeft, isActive: true),
        ])

        // The effective query behaves as the active chips read: the kind is the class alias (a
        // PNG matches — the superseded kind:JPG must not still filter), size bounds apply, the
        // side token maps to missing-on-right, and the free text matches the path.
        #expect(query.matches(diff("Photos/draft copy.png", type: .missingOnRight, leftSize: 1_000_000)))
        #expect(!query.matches(diff("Photos/draft copy.pdf", type: .missingOnRight, leftSize: 1_000_000)))  // not an image
        #expect(!query.matches(diff("Photos/draft copy.png", type: .missingOnRight, leftSize: 400_000)))    // below >500kb
        #expect(!query.matches(diff("Photos/draft copy.png", type: .missingOnLeft, leftSize: nil, rightSize: 1_000_000))) // wrong side
        #expect(!query.matches(diff("Photos/summary.png", type: .missingOnRight, leftSize: 1_000_000)))     // free text fails
    }
}
