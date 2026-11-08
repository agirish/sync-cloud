import Foundation

/// What a cloud (Claude) Filing classify would cost, shown before the call commits. The real cost
/// is known only after the API responds, so the confirmation dialog and budget gate use this
/// estimate. Pure data; the math lives in `FilingSpendBudget`.
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
    /// What `fileCount` counts: "file" for the filing refine, "folder name" for the mapping refine.
    /// The dialog pluralises it, so a payment prompt never says "24 files" for 24 names.
    public let unit: String
    /// How many of the files are cloud-only and will be downloaded, and kept, so their first page
    /// can be read. The estimate already prices their pages.
    public let downloadCount: Int

    public init(fileCount: Int, model: String, estInputTokens: Int, estOutputTokens: Int,
                estCostUSD: Double, monthlySpentUSD: Double, monthlyCapUSD: Double,
                totalSpentUSD: Double, totalCapUSD: Double, unit: String = "file",
                downloadCount: Int = 0) {
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
        self.downloadCount = downloadCount
    }

    /// True when the monthly cap is set (> 0) and running this call would push the month's spend past it.
    public var wouldExceedMonthlyCap: Bool {
        monthlyCapUSD > 0 && (monthlySpentUSD + estCostUSD) > monthlyCapUSD
    }

    /// True when the total (lifetime) cap is set (> 0) and running this call would push lifetime spend past it.
    public var wouldExceedTotalCap: Bool {
        totalCapUSD > 0 && (totalSpentUSD + estCostUSD) > totalCapUSD
    }

    /// True when running this call would breach either cap. A cap of 0 means unlimited, so a cap
    /// the user left off never blocks.
    public var wouldExceedCap: Bool {
        wouldExceedMonthlyCap || wouldExceedTotalCap
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
