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
        defer { wipeDefaultsSuite(name) }

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

    @Test func everyWritePostsTheChangeSignal() {
        // The signal exists because per-surface refresh lists do not compose across windows: the
        // Organize lens enumerated its own three refresh moments and was still left quoting an
        // erased record when the SAME history view cleared spend from the Settings window. Both
        // writers must post, or a cached reader is exactly one unlisted writer away from stale.
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let posts = Counter()
        // Scoped to THIS test's defaults instance: the suite runs in parallel and the center is
        // process-wide, so an unscoped observer counts the other tests' posts too — measured, it
        // read 6 where this test wrote 2.
        let observer = NotificationCenter.default.addObserver(
            forName: FilingSpendStore.didChange, object: defaults, queue: nil) { _ in posts.bump() }
        defer { NotificationCenter.default.removeObserver(observer) }

        FilingSpendStore.record(entry(cost: 0.01, tokens: 10), defaults: defaults)
        #expect(posts.value == 1, "record must announce itself")
        FilingSpendStore.clear(defaults: defaults)
        #expect(posts.value == 2, "clear must announce itself — it is the writer that got missed")
    }

    @Test func recordAccumulatesTotalsAndTracksLast() {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }

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
        defer { wipeDefaultsSuite(name) }

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
        defer { wipeDefaultsSuite(name) }
        FilingSpendStore.record(entry(cost: 0.5, tokens: 10), defaults: defaults)
        FilingSpendStore.clear(defaults: defaults)
        #expect(FilingSpendStore.entries(defaults: defaults).isEmpty)
        #expect(FilingSpendStore.last(defaults: defaults) == nil)
        #expect(FilingSpendStore.totals(defaults: defaults) == FilingSpendTotals())
    }
}
