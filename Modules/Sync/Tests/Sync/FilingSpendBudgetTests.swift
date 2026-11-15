import Foundation
import Testing
@testable import Sync

@Suite struct FilingSpendBudgetTests {

    private func entry(cost: Double, at timestamp: Date) -> FilingSpendEntry {
        FilingSpendEntry(timestamp: timestamp, model: "claude-haiku-4-5", fileCount: 5, placedCount: 4,
                         inputTokens: 1000, outputTokens: 200, cacheReadTokens: 0, cacheCreationTokens: 0,
                         estimatedCostUSD: cost)
    }

    // MARK: monthlySpend — only the current calendar month counts

    @Test func monthlySpendSumsOnlyTheCurrentMonth() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Pin "now" mid-month so ±days can't spill into an adjacent month.
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12)))
        let thisMonth = try #require(cal.date(from: DateComponents(year: 2026, month: 7, day: 3)))
        let alsoThisMonth = try #require(cal.date(from: DateComponents(year: 2026, month: 7, day: 28)))
        let lastMonth = try #require(cal.date(from: DateComponents(year: 2026, month: 6, day: 30)))
        let thisMonthLastYear = try #require(cal.date(from: DateComponents(year: 2025, month: 7, day: 15)))

        let entries = [
            entry(cost: 0.10, at: thisMonth),
            entry(cost: 0.05, at: alsoThisMonth),
            entry(cost: 1.00, at: lastMonth),           // excluded — different month
            entry(cost: 2.00, at: thisMonthLastYear),   // excluded — same month, different year
        ]
        let spend = FilingSpendBudget.monthlySpend(entries: entries, now: now, calendar: cal)
        #expect(abs(spend - 0.15) < 1e-9)               // only the two July-2026 entries
    }

    @Test func monthlySpendIsZeroForNoEntriesOrNoCurrentMonthEntries() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 7, day: 15)))
        #expect(FilingSpendBudget.monthlySpend(entries: [], now: now, calendar: cal) == 0)
        let lastMonth = try #require(cal.date(from: DateComponents(year: 2026, month: 6, day: 15)))
        #expect(FilingSpendBudget.monthlySpend(entries: [entry(cost: 5, at: lastMonth)], now: now, calendar: cal) == 0)
    }

    // MARK: FilingSpendPreflight.wouldExceedCap (the monthly cap)

    private func preflight(est: Double, monthlySpent: Double = 0, monthlyCap: Double = 0) -> FilingSpendPreflight {
        FilingSpendPreflight(fileCount: 10, model: "claude-haiku-4-5", estCostUSD: est,
                             monthlySpentUSD: monthlySpent, monthlyCapUSD: monthlyCap)
    }

    @Test func preflightWouldExceedMonthlyCapLogic() {
        // Cap 0 → never exceeds, regardless of spend/estimate.
        #expect(preflight(est: 100, monthlySpent: 100, monthlyCap: 0).wouldExceedMonthlyCap == false)
        // Spend + estimate stays under the cap → not exceeding.
        #expect(preflight(est: 0.02, monthlySpent: 1.00, monthlyCap: 5).wouldExceedMonthlyCap == false)
        // Right at the cap (spent + est == cap) → not exceeding (strict >).
        #expect(preflight(est: 1.00, monthlySpent: 4.00, monthlyCap: 5).wouldExceedMonthlyCap == false)
        // Spend + estimate goes over the cap → exceeding.
        #expect(preflight(est: 1.50, monthlySpent: 4.00, monthlyCap: 5).wouldExceedMonthlyCap == true)
    }

    @Test func preflightWouldExceedCapIsTheMonthlyCap() {
        // Cap not breached → allowed.
        #expect(preflight(est: 0.10, monthlySpent: 1, monthlyCap: 5).wouldExceedCap == false)
        // Monthly breached → blocked.
        #expect(preflight(est: 2.00, monthlySpent: 4.00, monthlyCap: 5).wouldExceedCap == true)
        // Cap off → never blocked.
        #expect(preflight(est: 1000, monthlySpent: 1000, monthlyCap: 0).wouldExceedCap == false)
    }
}
