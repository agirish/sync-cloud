import Foundation
import Testing
@testable import Sync

/// The spend rows' number formatting. `files(_:)` makes the count and its noun agree in one place,
/// so no row prints "1 files".
@Suite struct FilingSpendFormatTests {

    @Test func oneFileIsSingular() {
        #expect(FilingSpendFormat.files(1) == "1 file")
    }

    @Test func otherCountsArePlural() {
        #expect(FilingSpendFormat.files(0) == "0 files")
        #expect(FilingSpendFormat.files(3) == "3 files")
    }
    /// The unit-aware spellings every spend row uses: a mapping refine's entry says "folder names ·
    /// answered", never "files · placed", and an entry with no unit reads as a filing refine.
    @Test func countedAndOutcomeFollowTheEntrysUnit() {
        func entry(_ count: Int, unit: String?) -> FilingSpendEntry {
            FilingSpendEntry(timestamp: Date(timeIntervalSince1970: 0), model: "m",
                             fileCount: count, placedCount: count, inputTokens: 0,
                             outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
                             estimatedCostUSD: 0, unit: unit)
        }
        #expect(FilingSpendFormat.counted(entry(24, unit: "folder name")) == "24 folder names")
        #expect(FilingSpendFormat.counted(entry(1, unit: "folder name")) == "1 folder name")
        #expect(FilingSpendFormat.counted(entry(12, unit: nil)) == "12 files")
        #expect(FilingSpendFormat.outcome(entry(3, unit: "folder name")) == "answered 3")
        #expect(FilingSpendFormat.outcome(entry(3, unit: nil)) == "placed 3")
    }

    /// The unit round-trips, and its absence decodes as nil. Older history must not throw: a throw
    /// empties the history the monthly cap is summed from.
    @Test func theUnitRoundTripsAndItsAbsenceDecodesQuietly() throws {
        let entry = FilingSpendEntry(timestamp: Date(timeIntervalSince1970: 5), model: "m",
                                     fileCount: 2, placedCount: 2, inputTokens: 1,
                                     outputTokens: 1, cacheReadTokens: 0, cacheCreationTokens: 0,
                                     estimatedCostUSD: 0.1, unit: "folder name")
        let decoded = try JSONDecoder().decode(FilingSpendEntry.self,
                                               from: JSONEncoder().encode(entry))
        #expect(decoded.unit == "folder name")

        let legacy = try JSONDecoder().decode(FilingSpendEntry.self, from: Data("{}".utf8))
        #expect(legacy.unit == nil)
    }
}
