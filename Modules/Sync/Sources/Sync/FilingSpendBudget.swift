import Foundation

/// What a cloud (Claude) Filing classify would cost, shown before the call commits. The real cost
/// is known only after the API responds, so the confirmation dialog and budget gate use this
/// estimate. Pure data; the math lives in `FilingSpendBudget`.
public struct FilingSpendPreflight: Sendable, Equatable {
    /// How many files this batch would send to the cloud.
    public let fileCount: Int
    /// The model that would run (a model-ID string).
    public let model: String
    /// Estimated USD cost of this call at list prices.
    public let estCostUSD: Double
    /// What cloud Filing has already spent so far THIS calendar month.
    public let monthlySpentUSD: Double
    /// The monthly budget cap. 0 = no cap (unlimited/off).
    public let monthlyCapUSD: Double
    /// How many of the files are cloud-only and will be downloaded, and kept, so their first page
    /// can be read. The estimate already prices their pages.
    public let downloadCount: Int

    public init(fileCount: Int, model: String, estCostUSD: Double, monthlySpentUSD: Double,
                monthlyCapUSD: Double, downloadCount: Int = 0) {
        self.fileCount = fileCount
        self.model = model
        self.estCostUSD = estCostUSD
        self.monthlySpentUSD = monthlySpentUSD
        self.monthlyCapUSD = monthlyCapUSD
        self.downloadCount = downloadCount
    }

    /// True when the monthly cap is set (> 0) and running this call would push the month's spend past it.
    public var wouldExceedMonthlyCap: Bool {
        monthlyCapUSD > 0 && (monthlySpentUSD + estCostUSD) > monthlyCapUSD
    }

    /// True when running this call would breach the monthly cap. A cap of 0 means unlimited, so a
    /// cap the user left off never blocks.
    public var wouldExceedCap: Bool {
        wouldExceedMonthlyCap
    }
}

/// Month accounting over Refine's retired spend record, so ``RefineSpendMigration`` can carry this
/// month into Ask Claude's total. Pure, so it needs no UserDefaults to test.
public enum FilingSpendBudget {

    /// Sums `estimatedCostUSD` over entries in the same calendar month and year as `now`: the cap
    /// is a per-calendar-month budget, so last month and the same month a year ago don't count.
    public static func monthlySpend(entries: [FilingSpendEntry], now: Date, calendar: Calendar = .current) -> Double {
        let nowComps = calendar.dateComponents([.year, .month], from: now)
        return entries.reduce(0) { running, entry in
            let comps = calendar.dateComponents([.year, .month], from: entry.timestamp)
            guard comps.year == nowComps.year, comps.month == nowComps.month else { return running }
            return running + entry.estimatedCostUSD
        }
    }
}
