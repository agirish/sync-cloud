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
    /// What cloud Filing has spent in total (lifetime), across every month.
    public let totalSpentUSD: Double
    /// The total (lifetime) budget cap. 0 = no cap (unlimited/off).
    public let totalCapUSD: Double
    /// What `fileCount` counts — "file" for the filing refine, "folder name" for §5.6's mapping
    /// refine. The dialog pluralises it; a prompt claiming "24 files" over a payload of 24 names
    /// would misstate exactly the thing a payment prompt exists to state.
    public let unit: String

    public init(fileCount: Int, model: String, estInputTokens: Int, estOutputTokens: Int,
                estCostUSD: Double, monthlySpentUSD: Double, monthlyCapUSD: Double,
                totalSpentUSD: Double, totalCapUSD: Double, unit: String = "file") {
        self.fileCount = fileCount
        self.model = model
        self.estInputTokens = estInputTokens
        self.estOutputTokens = estOutputTokens
        self.estCostUSD = estCostUSD
        self.monthlySpentUSD = monthlySpentUSD
        self.monthlyCapUSD = monthlyCapUSD
        self.totalSpentUSD = totalSpentUSD
        self.totalCapUSD = totalCapUSD
        self.unit = unit
    }

    /// True when the monthly cap is set (> 0) and running this call would push the month's spend past it.
    public var wouldExceedMonthlyCap: Bool {
        monthlyCapUSD > 0 && (monthlySpentUSD + estCostUSD) > monthlyCapUSD
    }

    /// True when the total (lifetime) cap is set (> 0) and running this call would push lifetime spend past it.
    public var wouldExceedTotalCap: Bool {
        totalCapUSD > 0 && (totalSpentUSD + estCostUSD) > totalCapUSD
    }

    /// True when running this call would breach EITHER the monthly or the total cap. A cap of 0 on a
    /// dimension means unlimited there, so an all-zero-cap preflight is never blocked — the user is
    /// never surprise-blocked by a dimension they left off.
    public var wouldExceedCap: Bool {
        wouldExceedMonthlyCap || wouldExceedTotalCap
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

    /// True when a cap is set (> 0) and `spent` has already reached or passed it. Used as a hard gate
    /// before a cloud call — at or over the cap, no further cloud calls run. Dimension-agnostic: pass
    /// this month's spend against the monthly cap, or lifetime spend against the total cap. A cap of 0
    /// means unlimited, so this is always false there.
    public static func isOverCap(spent: Double, capUSD: Double) -> Bool {
        capUSD > 0 && spent >= capUSD
    }
}
