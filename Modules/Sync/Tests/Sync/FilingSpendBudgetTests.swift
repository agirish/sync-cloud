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
        #expect(FilingSpendBudget.isOverCap(spent: 0, capUSD: 0) == false)
        #expect(FilingSpendBudget.isOverCap(spent: 999, capUSD: 0) == false)
        // Under the cap → not over.
        #expect(FilingSpendBudget.isOverCap(spent: 4.99, capUSD: 5) == false)
        // At the cap → over (>=), so a call at the boundary is blocked.
        #expect(FilingSpendBudget.isOverCap(spent: 5.0, capUSD: 5) == true)
        // Past the cap → over.
        #expect(FilingSpendBudget.isOverCap(spent: 5.01, capUSD: 5) == true)
    }

    // MARK: FilingSpendPreflight.wouldExceedCap (monthly + total dimensions)

    private func preflight(est: Double, monthlySpent: Double = 0, monthlyCap: Double = 0,
                           totalSpent: Double = 0, totalCap: Double = 0) -> FilingSpendPreflight {
        FilingSpendPreflight(fileCount: 10, model: "claude-haiku-4-5", estInputTokens: 5000,
                             estOutputTokens: 1000, estCostUSD: est, monthlySpentUSD: monthlySpent,
                             monthlyCapUSD: monthlyCap, totalSpentUSD: totalSpent, totalCapUSD: totalCap)
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

    @Test func preflightWouldExceedTotalCapLogic() {
        // Total cap 0 → never exceeds.
        #expect(preflight(est: 100, totalSpent: 100, totalCap: 0).wouldExceedTotalCap == false)
        // Under → not exceeding.
        #expect(preflight(est: 0.50, totalSpent: 3.00, totalCap: 5).wouldExceedTotalCap == false)
        // At the boundary → not exceeding (strict >).
        #expect(preflight(est: 2.00, totalSpent: 3.00, totalCap: 5).wouldExceedTotalCap == false)
        // Over → exceeding.
        #expect(preflight(est: 2.50, totalSpent: 3.00, totalCap: 5).wouldExceedTotalCap == true)
    }

    @Test func preflightWouldExceedCapCombinesBothDimensions() {
        // Neither cap breached → allowed.
        #expect(preflight(est: 0.10, monthlySpent: 1, monthlyCap: 5, totalSpent: 1, totalCap: 5)
            .wouldExceedCap == false)
        // Monthly fine, TOTAL breached → blocked (the $5 lifetime backstop catches it even mid-month).
        #expect(preflight(est: 0.10, monthlySpent: 0.20, monthlyCap: 5, totalSpent: 4.99, totalCap: 5)
            .wouldExceedCap == true)
        // Total off (0), monthly breached → still blocked.
        #expect(preflight(est: 2.00, monthlySpent: 4.00, monthlyCap: 5, totalSpent: 100, totalCap: 0)
            .wouldExceedCap == true)
        // Both off → never blocked.
        #expect(preflight(est: 1000, monthlySpent: 1000, monthlyCap: 0, totalSpent: 1000, totalCap: 0)
            .wouldExceedCap == false)
    }

    // MARK: total cap default — absent key means the shipped $5, not UserDefaults.double's 0

    @Test func totalBudgetCapAppliesTheFiveDollarDefaultWhenUnset() {
        let d = UserDefaults(suiteName: "FilingSpendBudgetTests.totalCap.\(UUID().uuidString)")!
        // Absent → the shipped default ($5), NOT 0.
        #expect(FileSyncManager.totalBudgetCap(in: d) == FileSyncManager.defaultTotalBudgetCapUSD)
        #expect(FileSyncManager.defaultTotalBudgetCapUSD == 5.0)
        // Explicit 0 ("Off") is honored as off, not re-defaulted.
        d.set(0.0, forKey: FileSyncManager.totalBudgetCapKey)
        #expect(FileSyncManager.totalBudgetCap(in: d) == 0)
        // A chosen value is returned verbatim.
        d.set(25.0, forKey: FileSyncManager.totalBudgetCapKey)
        #expect(FileSyncManager.totalBudgetCap(in: d) == 25.0)
    }
}
