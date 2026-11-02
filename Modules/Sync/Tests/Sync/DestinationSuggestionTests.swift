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
            for: ["\(parent)/16. Sep 2026"], in: parent, siblingFolders: siblings, latestYear: 2031))
        #expect(found.path == "\(parent)/2026")
        #expect(found.name == "2026")
        #expect(found.isNew)
    }

    @Test func testAnExistingYearFolderIsSuggestedAsItIs() throws {
        let found = try #require(DestinationSuggestions.yearFolder(
            for: ["\(parent)/Air India Consent - Aug 2025.pdf"], in: parent, siblingFolders: siblings, latestYear: 2031))
        #expect(found.path == "\(parent)/2025")
        #expect(!found.isNew)
    }

    /// Several items naming one year share one home.
    @Test func testASelectionNamingOneYearIsSuggestedOnce() {
        let items = ["\(parent)/April 2026", "\(parent)/16. Sep 2026"]
        #expect(DestinationSuggestions.yearFolder(for: items, in: parent, siblingFolders: siblings + ["April 2026"], latestYear: 2031)?.name == "2026")
    }

    @Test func testNothingIsSuggestedWhenTheItemsNameDifferentYears() {
        let items = ["\(parent)/Dec 2025", "\(parent)/16. Sep 2026"]
        #expect(DestinationSuggestions.yearFolder(for: items, in: parent, siblingFolders: siblings, latestYear: 2031) == nil)
    }

    @Test func testNothingIsSuggestedWhenTheItemNamesNoYear() {
        #expect(DestinationSuggestions.yearFolder(
            for: ["\(parent)/Boarding passes"], in: parent, siblingFolders: siblings, latestYear: 2031) == nil)
    }

    /// Two years in one name is ambiguous, not a pick of the first.
    @Test func testNothingIsSuggestedWhenTheItemNamesTwoYears() {
        #expect(DestinationSuggestions.yearFolder(
            for: ["\(parent)/Visa 2024-2026"], in: parent, siblingFolders: siblings, latestYear: 2031) == nil)
    }

    @Test func testAYearFolderIsNeverSuggestedForAYearFolder() {
        #expect(DestinationSuggestions.yearFolder(
            for: ["\(parent)/2025"], in: parent, siblingFolders: siblings, latestYear: 2031) == nil)
    }

    /// Two year folders could be chance; and years must be most of the folders there.
    @Test func testTooFewOrTooMixedNeighboursSayNothing() {
        let item = ["\(parent)/16. Sep 2026"]
        #expect(DestinationSuggestions.yearFolder(for: item, in: parent, siblingFolders: ["2024", "2025", "Family"], latestYear: 2031) == nil)
        let mixed = ["2023", "2024", "2025", "India", "Mauritius", "Singapore", "United States"]
        #expect(DestinationSuggestions.yearFolder(for: item, in: parent, siblingFolders: mixed, latestYear: 2031) == nil)
        // Control: the same item among three years and one other folder is a pattern.
        #expect(DestinationSuggestions.yearFolder(for: item, in: parent,
                                                  siblingFolders: ["2023", "2024", "2025", "Family"], latestYear: 2031) != nil)
    }

    /// Digits inside a longer number are not a year: an airline PNR file must say nothing.
    @Test func testDigitsInsideALongerNumberAreNotAYear() {
        #expect(years("ai-9N8Z26-divit-abhishek-1756449254992-") == [])
        #expect(years("16. Sep 2026") == ["2026"])
        #expect(years("Trip 2019.pdf") == ["2019"])
        #expect(years("Room 3000") == [])
    }

    /// A year is a word on its own. A camera counter, a resolution or a flight number that falls
    /// in range is not one — these were all "years" until the review of 2026-11-01.
    @Test func testCountersAndCodesAreNotYears() {
        for name in ["IMG_2047.HEIC", "DSC_1999.JPG", "wallpaper-1920x1080.jpg", "Boarding AI2016.pdf",
                     "Trip_2019.pdf", "2019a"] {
            #expect(years(name) == [], "\(name) named a year: \(years(name))")
        }
    }

    /// Dates written with dots or dashes still name their year — the last dot is not an extension.
    @Test func testDottedAndDashedDatesNameTheirYear() {
        for name in ["16.09.2026", "Trip.2026", "Q3.2026", "2026-09-16 Flight", "Sep-2026"] {
            #expect(years(name) == ["2026"], "\(name): \(years(name))")
        }
        let found = DestinationSuggestions.yearFolder(for: ["\(parent)/16.09.2026"], in: parent, siblingFolders: siblings,
                                                      latestYear: 2031)
        #expect(found?.name == "2026")
    }

    /// A span names both its years, so it has no single home.
    @Test func testASpanOfTwoYearsIsNotOneYear() {
        #expect(years("ITR FY 2025-26") == ["2025", "2026"])
        #expect(years("Season 2025–26") == ["2025", "2026"])
        #expect(DestinationSuggestions.yearFolder(for: ["\(parent)/ITR FY 2025-26"], in: parent, siblingFolders: siblings,
                                                  latestYear: 2031) == nil)
        // Control: an ISO date's month is not a span.
        #expect(years("2026-09-16") == ["2026"])
    }

    /// Years past the horizon are not years yet (a part number 2087 among 2012…2025).
    @Test func testAYearFarInTheFutureIsNotAYear() {
        #expect(DestinationSuggestions.years(in: "Part 2087", latestYear: 2031) == [])
        #expect(DestinationSuggestions.years(in: "Part 2031", latestYear: 2031) == ["2031"])
    }

    /// The items' own names are not peers: three years, two other folders and the item itself is
    /// NOT a majority of years once the item is left out — it is 3 of 5.
    @Test func testTheItemsOwnNameIsNotCountedAsAPeer() {
        let item = "\(parent)/Visa 2026"
        // 3 years of 6 folders counting the item, 3 of 5 without it: offered only when left out.
        #expect(DestinationSuggestions.yearFolder(for: [item], in: parent,
                                                  siblingFolders: ["2023", "2024", "2025", "A", "B", "Visa 2026"],
                                                  latestYear: 2031)?.name == "2026")
    }

    /// Exactly half is not a majority.
    @Test func testHalfYearsIsNotAPattern() {
        let item = ["\(parent)/16. Sep 2026"]
        #expect(DestinationSuggestions.yearFolder(for: item, in: parent,
                                                  siblingFolders: ["2023", "2024", "2025", "A", "B", "C"],
                                                  latestYear: 2031) == nil)
        #expect(DestinationSuggestions.yearFolder(for: item, in: parent,
                                                  siblingFolders: ["2023", "2024", "2025", "A", "B"],
                                                  latestYear: 2031) != nil)
    }

    private func years(_ text: String) -> [String] { DestinationSuggestions.years(in: text, latestYear: 2031) }
}
