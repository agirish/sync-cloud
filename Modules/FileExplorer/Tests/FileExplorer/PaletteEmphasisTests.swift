import Testing
@testable import FileExplorer

/// The display-side emphasis must come from the ranking's own matcher — `matchRange` is the
/// same lookup `match` tiers by, with the same fold options. These pin the seam the view leans
/// on: where the range falls, that it folds case and diacritics exactly as the ranking does,
/// and that keyword-only matches yield nil (no emphasis is honest when the visible text did
/// not match).
@Suite struct PaletteEmphasisTests {

    @Test func theRangeIsWhereTheMatchIs() throws {
        let range = try #require(PaletteRouter.matchRange("Family/Aditi", "aditi"))
        #expect(String("Family/Aditi"[range]) == "Aditi")
    }

    @Test func foldsMatchTheRankingsOwnRules() throws {
        // Case-insensitive and diacritic-insensitive, exactly like `match` — a display-side
        // tokenizer with different folds is the known two-tokenizers failure.
        let cafe = try #require(PaletteRouter.matchRange("Café Receipts", "cafe"))
        #expect(String("Café Receipts"[cafe]) == "Café")
        #expect(PaletteRouter.match("Café Receipts", "cafe") != .none)
    }

    @Test func noContainmentMeansNoRange() {
        // A row that matched via keywords ("history" → Activity Log) has nothing to embolden.
        #expect(PaletteRouter.matchRange("Activity Log", "history") == nil)
        #expect(PaletteRouter.matchRange("Activity Log", "") == nil)
    }
}
