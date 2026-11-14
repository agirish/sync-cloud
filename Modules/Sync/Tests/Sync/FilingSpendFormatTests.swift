import Foundation
import Testing
@testable import Sync

/// What is left of Refine's own spend record after TE335 (E5): its number formatting, and the
/// decoders that read the old record once so ``RefineSpendMigration`` can carry it forward.
@Suite struct FilingSpendFormatTests {

    @Test func costShowsFourPlacesBelowOneCent() {
        #expect(FilingSpendFormat.cost(0.0042) == "~$0.0042")
        #expect(FilingSpendFormat.cost(0.04) == "~$0.04")
        #expect(FilingSpendFormat.cost(0.01) == "~$0.01")
    }

    /// The unit round-trips, and its absence decodes as nil. An older entry must not throw: a throw
    /// would read as an unreadable record, and the migration would then leave it for the next launch.
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
