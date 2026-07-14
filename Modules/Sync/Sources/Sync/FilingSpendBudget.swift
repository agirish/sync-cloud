import Foundation

/// A pre-flight snapshot of what a cloud (Claude) Filing classify would cost, shown to the user
/// BEFORE the call commits — the actual cost is only known after the API responds, so this is the
/// estimate the confirmation dialog and budget gate reason about. Pure data; all math lives in
/// `FilingSpendBudget`.
public struct FilingSpendPreflight: Sendable, Equatable {
    /// How many files this batch would send to the cloud.
    public let fileCount: Int
    /// The model that would run (a model-ID string).
    public let model: String
    /// Estimated input tokens for the request (heuristic, from the request text size).
    public let estInputTokens: Int
    /// Estimated output tokens (the same `512 + files*80` budget the request body uses).
    public let estOutputTokens: Int
    /// Estimated USD cost of this call at list prices.
    public let estCostUSD: Double
    /// What cloud Filing has already spent so far THIS calendar month.
    public let monthlySpentUSD: Double
    /// The monthly budget cap. 0 = no cap (unlimited/off).
    public let monthlyCapUSD: Double

    public init(fileCount: Int, model: String, estInputTokens: Int, estOutputTokens: Int,
                estCostUSD: Double, monthlySpentUSD: Double, monthlyCapUSD: Double) {
        self.fileCount = fileCount
        self.model = model
        self.estInputTokens = estInputTokens
        self.estOutputTokens = estOutputTokens
        self.estCostUSD = estCostUSD
        self.monthlySpentUSD = monthlySpentUSD
        self.monthlyCapUSD = monthlyCapUSD
    }

    /// True when a cap is set (> 0) and running this call would push the month's spend past it.
    /// A cap of 0 means unlimited, so this is always false there — the user is never surprise-blocked.
    public var wouldExceedCap: Bool {
        monthlyCapUSD > 0 && (monthlySpentUSD + estCostUSD) > monthlyCapUSD
    }
}

/// Pure month-accounting and cap math for cloud Filing spend. Kept separate from `FilingSpendStore`
/// (which only tracks lifetime totals) so the monthly-window logic is unit-testable without touching
/// UserDefaults.
public enum FilingSpendBudget {

    /// Sums `estimatedCostUSD` of the entries whose `timestamp` falls in the same calendar
    /// month + year as `now`. Everything outside the current month (last month, this month a year
    /// ago) is excluded — the cap is a rolling per-calendar-month budget.
    public static func monthlySpend(entries: [FilingSpendEntry], now: Date, calendar: Calendar = .current) -> Double {
        let nowComps = calendar.dateComponents([.year, .month], from: now)
        return entries.reduce(0) { running, entry in
            let comps = calendar.dateComponents([.year, .month], from: entry.timestamp)
            guard comps.year == nowComps.year, comps.month == nowComps.month else { return running }
            return running + entry.estimatedCostUSD
        }
    }

    /// True when a cap is set (> 0) and the month's spend has already reached or passed it. Used as a
    /// hard gate before a cloud call: at or over the cap, no further cloud calls run this month. A cap
    /// of 0 means unlimited, so this is always false.
    public static func isOverCap(monthlySpent: Double, capUSD: Double) -> Bool {
        capUSD > 0 && monthlySpent >= capUSD
    }
}
