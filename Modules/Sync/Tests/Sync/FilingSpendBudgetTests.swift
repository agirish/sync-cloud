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

    // MARK: isOverCap — boundary + cap-off behavior

    @Test func isOverCapHonorsTheBoundaryAndTreatsZeroAsUnlimited() {
        // Cap of 0 = unlimited — never over, whatever's been spent.
        #expect(FilingSpendBudget.isOverCap(monthlySpent: 0, capUSD: 0) == false)
        #expect(FilingSpendBudget.isOverCap(monthlySpent: 999, capUSD: 0) == false)
        // Under the cap → not over.
        #expect(FilingSpendBudget.isOverCap(monthlySpent: 4.99, capUSD: 5) == false)
        // At the cap → over (>=), so a call at the boundary is blocked.
        #expect(FilingSpendBudget.isOverCap(monthlySpent: 5.0, capUSD: 5) == true)
        // Past the cap → over.
        #expect(FilingSpendBudget.isOverCap(monthlySpent: 5.01, capUSD: 5) == true)
    }

    // MARK: FilingSpendPreflight.wouldExceedCap

    @Test func preflightWouldExceedCapLogic() {
        func preflight(est: Double, spent: Double, cap: Double) -> FilingSpendPreflight {
            FilingSpendPreflight(fileCount: 10, model: "claude-haiku-4-5", estInputTokens: 5000,
                                 estOutputTokens: 1000, estCostUSD: est, monthlySpentUSD: spent,
                                 monthlyCapUSD: cap)
        }
        // Cap 0 → never exceeds, regardless of spend/estimate.
        #expect(preflight(est: 100, spent: 100, cap: 0).wouldExceedCap == false)
        // Spend + estimate stays under the cap → not exceeding.
        #expect(preflight(est: 0.02, spent: 1.00, cap: 5).wouldExceedCap == false)
        // Right at the cap (spent + est == cap) → not exceeding (strict >).
        #expect(preflight(est: 1.00, spent: 4.00, cap: 5).wouldExceedCap == false)
        // Spend + estimate goes over the cap → exceeding.
        #expect(preflight(est: 1.50, spent: 4.00, cap: 5).wouldExceedCap == true)
    }
}
