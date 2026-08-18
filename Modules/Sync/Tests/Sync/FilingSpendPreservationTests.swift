import Foundation
import Testing
@testable import Sync

/// **A money store that cannot be read must not be written over.**
///
/// `entries()` and `totals()` answered "zero" both for "nothing recorded yet" and for a payload
/// they could not decode, and `record` then wrote that zero back. One unreadable value therefore
/// erased the lifetime total, re-armed the $5 lifetime cap from scratch, and made the erasure
/// permanent — with Settings showing $0.00 lifetime and nothing to say why.
///
/// The asymmetry is what makes it a defect rather than an oversight: the CAP side of this same
/// feature is carefully defended against exactly this, because `totalBudgetCap` distinguishes an
/// absent key from a stored 0 and says so in a comment. The SPENT side was not.
@Suite struct FilingSpendPreservationTests {

    private func suite() -> (UserDefaults, String) {
        let name = "FilingSpendPreserve-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func entry(cost: Double) -> FilingSpendEntry {
        FilingSpendEntry(timestamp: Date(timeIntervalSince1970: 1_720_000_000),
                         model: "claude-haiku-4-5", fileCount: 5, placedCount: 4,
                         inputTokens: 1000, outputTokens: 0, cacheReadTokens: 0,
                         cacheCreationTokens: 0, estimatedCostUSD: cost)
    }

    @Test func anUnreadableTotalIsNotOverwrittenByTheNextScan() throws {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        let corrupt = Data("{ \"costUSD\": 4.87, \"tok".utf8)   // a truncated write
        defaults.set(corrupt, forKey: FilingSpendStore.totalsKey)

        FilingSpendStore.record(entry(cost: 0.02), defaults: defaults)

        #expect(defaults.data(forKey: FilingSpendStore.totalsKey) == corrupt,
                "the lifetime total was overwritten by a scan recorded on top of a zero")
        #expect(defaults.data(forKey: FilingSpendStore.totalsKey + ".unreadable") == corrupt,
                "the unreadable value was not preserved")
    }

    /// The monthly cap is summed from the history, so the same rule applies to it.
    @Test func anUnreadableHistoryIsNotOverwrittenByTheNextScan() throws {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        let corrupt = Data("[{\"model\":\"claude".utf8)
        defaults.set(corrupt, forKey: FilingSpendStore.historyKey)

        FilingSpendStore.record(entry(cost: 0.02), defaults: defaults)

        #expect(defaults.data(forKey: FilingSpendStore.historyKey) == corrupt)
        #expect(defaults.data(forKey: FilingSpendStore.historyKey + ".unreadable") == corrupt)
    }

    /// And the ordinary path still accumulates — the refusal must not be "spend stopped recording".
    @Test func aReadableStoreStillAccumulates() throws {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        FilingSpendStore.record(entry(cost: 0.02), defaults: defaults)
        FilingSpendStore.record(entry(cost: 0.03), defaults: defaults)
        let totals = FilingSpendStore.totals(defaults: defaults)
        #expect(abs(totals.costUSD - 0.05) < 0.0001)
        #expect(totals.scans == 2)
        #expect(FilingSpendStore.entries(defaults: defaults).count == 2)
    }

    /// Absent is not unreadable: a first run records normally and leaves no backup behind.
    @Test func anAbsentStoreRecordsNormally() throws {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        FilingSpendStore.record(entry(cost: 0.02), defaults: defaults)
        #expect(FilingSpendStore.totals(defaults: defaults).scans == 1)
        #expect(defaults.data(forKey: FilingSpendStore.totalsKey + ".unreadable") == nil)
        #expect(FilingSpendStore.isUnreadable(defaults: defaults) == false)
    }

    /// The signal the budget backstop reads to fail closed.
    @Test func anUnreadableStoreReportsItself() throws {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        defaults.set(Data("{ nope".utf8), forKey: FilingSpendStore.totalsKey)
        #expect(FilingSpendStore.isUnreadable(defaults: defaults))
    }

    /// **Adding one field must not throw on every existing user's data**, which is the trigger the
    /// audit named: the fields decoded non-optionally, unlike every neighbouring store in the
    /// module. A payload written before `unpricedScans` existed still decodes.
    @Test func anOlderTotalsPayloadStillDecodes() throws {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        defaults.set(Data("{\"costUSD\":1.25,\"tokens\":900,\"scans\":3}".utf8),
                     forKey: FilingSpendStore.totalsKey)
        let totals = FilingSpendStore.totals(defaults: defaults)
        #expect(abs(totals.costUSD - 1.25) < 0.0001)
        #expect(totals.scans == 3)
        #expect(totals.unpricedScans == 0)
        #expect(!FilingSpendStore.isUnreadable(defaults: defaults),
                "an older payload must read as loaded, not as unreadable")
    }

    /// An entry written before `costUnpriced` existed decodes too — a throw there would empty the
    /// history the monthly cap is summed from.
    @Test func anOlderHistoryPayloadStillDecodes() throws {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        defaults.set(Data("""
        [{"id":"a","timestamp":760000000,"model":"claude-haiku-4-5","fileCount":2,"placedCount":2,
          "inputTokens":10,"outputTokens":1,"cacheReadTokens":0,"cacheCreationTokens":0,
          "estimatedCostUSD":0.01}]
        """.utf8), forKey: FilingSpendStore.historyKey)
        let entries = FilingSpendStore.entries(defaults: defaults)
        #expect(entries.count == 1)
        #expect(entries.first?.costUnpriced == false)
    }

    /// **An unpriced scan is counted as unpriced, not as free.** The post-flight path coerced an
    /// unknown model's nil cost to $0.00 while the pre-flight path reported it honestly.
    @Test func anUnpricedScanIsCountedSeparately() throws {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        FilingSpendStore.record(FilingSpendEntry(
            timestamp: Date(timeIntervalSince1970: 1_720_000_000), model: "some-new-model",
            fileCount: 1, placedCount: 1, inputTokens: 100, outputTokens: 10,
            cacheReadTokens: 0, cacheCreationTokens: 0,
            estimatedCostUSD: 0, costUnpriced: true), defaults: defaults)
        let totals = FilingSpendStore.totals(defaults: defaults)
        #expect(totals.unpricedScans == 1, "lifetime spend does not record that it is a floor")
        #expect(totals.scans == 1)
        #expect(totals.tokens == 110, "the tokens are real and must still be counted")
    }
}
