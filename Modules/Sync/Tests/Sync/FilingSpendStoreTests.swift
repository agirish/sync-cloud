import Foundation
import Testing
@testable import Sync

@Suite struct FilingSpendStoreTests {

    private func suite() -> (UserDefaults, String) {
        let name = "FilingSpend-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func entry(cost: Double, tokens: Int) -> FilingSpendEntry {
        FilingSpendEntry(timestamp: Date(timeIntervalSince1970: 1_720_000_000), model: "claude-haiku-4-5",
                         fileCount: 5, placedCount: 4, inputTokens: tokens, outputTokens: 0,
                         cacheReadTokens: 0, cacheCreationTokens: 0, estimatedCostUSD: cost)
    }

    @Test func concurrentRecordsLoseNoIncrements() {
        // `record` runs off the main actor (from CloudFilingClassifier.classify) and does a
        // non-atomic read-modify-write of UserDefaults; two overlapping cloud calls would otherwise
        // drop a spend increment and under-count the total the budget cap is enforced against. The
        // lock must serialize them so every record lands.
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }

        let iterations = 100
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            FilingSpendStore.record(entry(cost: 0.01, tokens: 10), defaults: defaults)
        }

        let totals = FilingSpendStore.totals(defaults: defaults)
        #expect(totals.scans == iterations)                                  // no lost increment
        #expect(totals.tokens == iterations * 10)
        #expect(abs(totals.costUSD - Double(iterations) * 0.01) < 1e-6)
        #expect(FilingSpendStore.entries(defaults: defaults).count == iterations)
    }

    @Test func recordAccumulatesTotalsAndTracksLast() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }

        FilingSpendStore.record(entry(cost: 0.01, tokens: 1000), defaults: defaults)
        FilingSpendStore.record(entry(cost: 0.02, tokens: 3000), defaults: defaults)

        let totals = FilingSpendStore.totals(defaults: defaults)
        #expect(abs(totals.costUSD - 0.03) < 1e-9)          // lifetime sum
        #expect(totals.tokens == 4000)
        #expect(totals.scans == 2)
        #expect(FilingSpendStore.entries(defaults: defaults).count == 2)
        #expect(FilingSpendStore.last(defaults: defaults)?.inputTokens == 3000)   // most recent
    }

    @Test func lifetimeTotalsSurviveHistoryCap() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }

        for _ in 0..<(FilingSpendStore.maxEntries + 20) {
            FilingSpendStore.record(entry(cost: 0.001, tokens: 100), defaults: defaults)
        }
        // History is capped…
        #expect(FilingSpendStore.entries(defaults: defaults).count == FilingSpendStore.maxEntries)
        // …but the lifetime scan count and cost still reflect every recorded scan.
        let totals = FilingSpendStore.totals(defaults: defaults)
        #expect(totals.scans == FilingSpendStore.maxEntries + 20)
        #expect(abs(totals.costUSD - Double(FilingSpendStore.maxEntries + 20) * 0.001) < 1e-9)
    }

    @Test func clearResetsEverything() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        FilingSpendStore.record(entry(cost: 0.5, tokens: 10), defaults: defaults)
        FilingSpendStore.clear(defaults: defaults)
        #expect(FilingSpendStore.entries(defaults: defaults).isEmpty)
        #expect(FilingSpendStore.last(defaults: defaults) == nil)
        #expect(FilingSpendStore.totals(defaults: defaults) == FilingSpendTotals())
    }
}
