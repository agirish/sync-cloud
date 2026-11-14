import Foundation
import Testing
@testable import Sync

/// Refine's old spend record is read once and never written over. An undecodable
/// payload must read as unreadable, not as zero: reading it as zero would carry nothing into Ask
/// Claude's total and then delete the only copy.
@Suite struct FilingSpendPreservationTests {

    @Test func anUnreadableTotalIsKeptAndReportsItself() throws {
        let defaults = ScratchDefaults("FilingSpendPreserve")
        let corrupt = Data("{ \"costUSD\": 4.87, \"tok".utf8)   // a truncated write
        defaults.set(corrupt, forKey: FilingSpendStore.totalsKey)

        #expect(FilingSpendStore.isUnreadable(defaults: defaults))
        #expect(defaults.data(forKey: FilingSpendStore.totalsKey) == corrupt, "reading must not rewrite")
        #expect(defaults.data(forKey: FilingSpendStore.totalsKey + ".unreadable") == corrupt,
                "the unreadable value was not preserved")
    }

    @Test func anUnreadableHistoryIsKeptAndReportsItself() throws {
        let defaults = ScratchDefaults("FilingSpendPreserve")
        let corrupt = Data("[{\"model\":\"claude".utf8)
        defaults.set(corrupt, forKey: FilingSpendStore.historyKey)

        #expect(FilingSpendStore.isUnreadable(defaults: defaults))
        #expect(defaults.data(forKey: FilingSpendStore.historyKey) == corrupt)
        #expect(defaults.data(forKey: FilingSpendStore.historyKey + ".unreadable") == corrupt)
    }

    /// Absent is not unreadable: nothing recorded, and no backup left behind.
    @Test func anAbsentStoreIsAbsentNotUnreadable() throws {
        let defaults = ScratchDefaults("FilingSpendPreserve")
        if case .absent = FilingSpendStore.totalsRead(defaults: defaults) {} else { Issue.record("not absent") }
        if case .absent = FilingSpendStore.entriesRead(defaults: defaults) {} else { Issue.record("not absent") }
        #expect(defaults.data(forKey: FilingSpendStore.totalsKey + ".unreadable") == nil)
        #expect(FilingSpendStore.isUnreadable(defaults: defaults) == false)
    }

    /// Adding a field must not throw on existing data: a payload without `unpricedScans` still
    /// decodes, as loaded.
    @Test func anOlderTotalsPayloadStillDecodes() throws {
        let defaults = ScratchDefaults("FilingSpendPreserve")
        defaults.set(Data("{\"costUSD\":1.25,\"tokens\":900,\"scans\":3}".utf8),
                     forKey: FilingSpendStore.totalsKey)
        let totals = FilingSpendStore.totals(defaults: defaults)
        #expect(abs(totals.costUSD - 1.25) < 0.0001)
        #expect(totals.scans == 3)
        #expect(totals.unpricedScans == 0)
        #expect(!FilingSpendStore.isUnreadable(defaults: defaults),
                "an older payload must read as loaded, not as unreadable")
    }

    /// An entry without `costUnpriced` decodes too.
    @Test func anOlderHistoryPayloadStillDecodes() throws {
        let defaults = ScratchDefaults("FilingSpendPreserve")
        defaults.set(Data("""
        [{"id":"a","timestamp":760000000,"model":"claude-haiku-4-5","fileCount":2,"placedCount":2,
          "inputTokens":10,"outputTokens":1,"cacheReadTokens":0,"cacheCreationTokens":0,
          "estimatedCostUSD":0.01}]
        """.utf8), forKey: FilingSpendStore.historyKey)
        let entries = FilingSpendStore.entries(defaults: defaults)
        #expect(entries.count == 1)
        #expect(entries.first?.costUnpriced == false)
        #expect(!FilingSpendStore.isUnreadable(defaults: defaults))
    }
}
