import Testing
@testable import FileExplorer

/// The display-side emphasis must come from the ranking's own matcher: `matchRange` is the lookup
/// `match` tiers by, with the same fold options. Pins where the range falls, that it folds case and
/// diacritics as the ranking does, and that keyword-only matches yield nil, since the visible text
/// didn't match.
@Suite struct PaletteEmphasisTests {

    @Test func theRangeIsWhereTheMatchIs() throws {
        let range = try #require(PaletteRouter.matchRange("Family/Daughter", "daughter"))
        #expect(String("Family/Daughter"[range]) == "Daughter")
    }

    @Test func foldsMatchTheRankingsOwnRules() throws {
        // Case- and diacritic-insensitive, exactly like `match`: a display-side tokenizer with
        // different folds would embolden text the ranking didn't match.
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
