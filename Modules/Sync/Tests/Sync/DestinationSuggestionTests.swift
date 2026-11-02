import Testing
@testable import Sync

/// The Move picker's one suggestion: the year folder the item's neighbours imply, and every case
/// where it must say nothing.
@Suite struct DestinationSuggestionTests {
    /// Travel › Trips › IN-US as it stood mid-reorganisation on 2026-11-01.
    let parent = "/d/Travel/Trips/IN-US"
    let years = ["2012", "2013", "2014", "2015", "2017", "2018", "2020", "2022", "2023", "2024", "2025"]
    var siblings: [String] { years + ["Family", "16. Sep 2026"] }

    @Test func testANewYearFolderIsSuggestedWhenTheNeighboursAreYears() throws {
        let found = try #require(DestinationSuggestions.yearFolder(
            for: ["\(parent)/16. Sep 2026"], in: parent, siblingFolders: siblings))
        #expect(found.path == "\(parent)/2026")
        #expect(found.name == "2026")
        #expect(found.isNew)
    }

    @Test func testAnExistingYearFolderIsSuggestedAsItIs() throws {
        let found = try #require(DestinationSuggestions.yearFolder(
            for: ["\(parent)/Air India Consent - Aug 2025.pdf"], in: parent, siblingFolders: siblings))
        #expect(found.path == "\(parent)/2025")
        #expect(!found.isNew)
    }

    /// Several items naming one year share one home.
    @Test func testASelectionNamingOneYearIsSuggestedOnce() {
        let items = ["\(parent)/April 2026", "\(parent)/16. Sep 2026"]
        #expect(DestinationSuggestions.yearFolder(for: items, in: parent, siblingFolders: siblings + ["April 2026"])?.name == "2026")
    }

    @Test func testNothingIsSuggestedWhenTheItemsNameDifferentYears() {
        let items = ["\(parent)/Dec 2025", "\(parent)/16. Sep 2026"]
        #expect(DestinationSuggestions.yearFolder(for: items, in: parent, siblingFolders: siblings) == nil)
    }

    @Test func testNothingIsSuggestedWhenTheItemNamesNoYear() {
        #expect(DestinationSuggestions.yearFolder(
            for: ["\(parent)/Boarding passes"], in: parent, siblingFolders: siblings) == nil)
    }

    /// Two years in one name is ambiguous, not a pick of the first.
    @Test func testNothingIsSuggestedWhenTheItemNamesTwoYears() {
        #expect(DestinationSuggestions.yearFolder(
            for: ["\(parent)/Visa 2024-2026"], in: parent, siblingFolders: siblings) == nil)
    }

    @Test func testAYearFolderIsNeverSuggestedForAYearFolder() {
        #expect(DestinationSuggestions.yearFolder(
            for: ["\(parent)/2025"], in: parent, siblingFolders: siblings) == nil)
    }

    /// Two year folders could be chance; and years must be most of the folders there.
    @Test func testTooFewOrTooMixedNeighboursSayNothing() {
        let item = ["\(parent)/16. Sep 2026"]
        #expect(DestinationSuggestions.yearFolder(for: item, in: parent, siblingFolders: ["2024", "2025", "Family"]) == nil)
        let mixed = ["2023", "2024", "2025", "India", "Mauritius", "Singapore", "United States"]
        #expect(DestinationSuggestions.yearFolder(for: item, in: parent, siblingFolders: mixed) == nil)
        // Control: the same item among three years and one other folder is a pattern.
        #expect(DestinationSuggestions.yearFolder(for: item, in: parent,
                                                  siblingFolders: ["2023", "2024", "2025", "Family"]) != nil)
    }

    /// Digits inside a longer number are not a year: an airline PNR file must say nothing.
    @Test func testDigitsInsideALongerNumberAreNotAYear() {
        #expect(DestinationSuggestions.years(in: "ai-9N8Z26-divit-abhishek-1756449254992-") == [])
        #expect(DestinationSuggestions.years(in: "16. Sep 2026") == ["2026"])
        #expect(DestinationSuggestions.years(in: "Trip_2019.pdf") == ["2019"])
        #expect(DestinationSuggestions.years(in: "Room 3000") == [])
    }
}
