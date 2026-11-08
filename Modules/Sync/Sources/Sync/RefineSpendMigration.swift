import Events
import Foundation

/// Refine's own spend and caps give way to Ask Claude's one monthly limit (TE335, E5; decisions JX-A,
/// KL-C and KZ-B). Once, at launch:
///
/// - this month's Refine spend joins Ask Claude's total, and Organize's share of it, so the limit
///   counts it from the first day;
/// - what the old caps and history said is kept in one notice, shown in Ask Claude ▸ Key & Spending
///   until it is dismissed, naming both old caps and what Refine had cost;
/// - the old history, totals, caps, model and switch are then deleted (KZ-B).
///
/// Stamped, and the stamp and the notice are kept by Reset All, so neither repeats nor vanishes.
/// A spend record that can't be read is left as it is, unstamped, to be tried again at the next
/// launch: carrying a month of spend from nothing would under-count it.
public enum RefineSpendMigration {

    public static let doneKey = "refineSpendCarriedOver"
    public static let noticeKey = "refineLimitNotice"

    // The old keys, by their strings: the symbols that named them are gone.
    static let monthlyCapKey = "tidyFilingMonthlyBudgetUSD"
    static let totalCapKey = "tidyFilingTotalBudgetUSD"
    static let modelKey = "tidyFilingCloudModel"
    static let switchKey = "tidyFilingUseCloud"
    /// The lifetime cap applied when nobody had chosen one.
    static let defaultTotalCapUSD = 5.0

    /// What the old caps and history said, for the notice.
    public struct Notice: Codable, Equatable, Sendable {
        /// The monthly cap, 0 for none.
        public var monthlyCapUSD: Double
        /// The lifetime cap, 0 for none (the default was $5).
        public var totalCapUSD: Double
        /// What Refine spent this month, now in Ask Claude's total.
        public var spentThisMonthUSD: Double
        /// What Refine spent in all, by its own record.
        public var spentTotalUSD: Double
        /// When its first recorded request was made.
        public var since: Date?
        public var requests: Int

        /// The notice's words: the old caps named, what happens now, and what Refine had cost.
        public var text: String {
            var caps: [String] = []
            if monthlyCapUSD > 0 { caps.append("\(AskClaudeSpend.format(monthlyCapUSD)) a month") }
            caps.append(totalCapUSD > 0 ? "\(AskClaudeSpend.format(totalCapUSD)) in total" : "no total limit")
            var out = "Refine had its own limits: " + caps.joined(separator: " and ") + ". "
                + "They are gone. Refine, Try Another and Refine Names now count against the one monthly limit below, "
                + "with the chat. Lower it if you want them to spend less."
            if spentTotalUSD > 0 {
                let when = since.map { " since " + $0.formatted(.dateTime.month(.wide).year()) } ?? ""
                out += " Refine had cost about \(AskClaudeSpend.format(spentTotalUSD))\(when)"
                    + (spentThisMonthUSD > 0 ? ", \(AskClaudeSpend.format(spentThisMonthUSD)) of it this month, which now counts toward the limit." : ".")
            }
            return out
        }
    }

    /// Runs once. Returns the log line when it did anything.
    @discardableResult
    public static func applyAtLaunch(defaults: UserDefaults = .standard, now: Date = Date()) -> String? {
        guard !defaults.bool(forKey: doneKey) else { return nil }
        if FilingSpendStore.isUnreadable(defaults: defaults) {
            return "Refine’s spend record couldn’t be read, so its spend wasn’t carried into Ask Claude’s limit; it will be tried again at the next launch"
        }
        let entries = FilingSpendStore.entries(defaults: defaults)
        let month = FilingSpendBudget.monthlySpend(entries: entries, now: now)
        let total = FilingSpendStore.totals(defaults: defaults).costUSD
        let monthlyCap = defaults.double(forKey: monthlyCapKey)
        let totalCap = defaults.object(forKey: totalCapKey) == nil ? defaultTotalCapUSD : defaults.double(forKey: totalCapKey)
        let chosenCaps = (defaults.object(forKey: monthlyCapKey) != nil && monthlyCap > 0) || defaults.object(forKey: totalCapKey) != nil

        AskClaudeSpend.recordOrganize(month, in: defaults, now: now)
        var line = "Refine’s own limits retired"
        if !entries.isEmpty || chosenCaps {
            let notice = Notice(monthlyCapUSD: monthlyCap, totalCapUSD: totalCap, spentThisMonthUSD: month,
                                spentTotalUSD: max(total, entries.reduce(0) { $0 + $1.estimatedCostUSD }),
                                since: entries.map(\.timestamp).min(), requests: entries.count)
            if let data = try? JSONEncoder().encode(notice) { defaults.set(data, forKey: noticeKey) }
            line += ": \(AskClaudeSpend.format(month)) of this month carried into Ask Claude’s total, notice pending"
        }
        for key in [FilingSpendStore.historyKey, FilingSpendStore.totalsKey, FilingSpendStore.lastKey,
                    monthlyCapKey, totalCapKey, modelKey, switchKey] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: doneKey)
        return line
    }

    /// The notice waiting to be read, or nil.
    public static func pendingNotice(in defaults: UserDefaults = .standard) -> Notice? {
        guard let data = defaults.data(forKey: noticeKey) else { return nil }
        return try? JSONDecoder().decode(Notice.self, from: data)
    }

    /// The person has read it.
    public static func dismissNotice(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: noticeKey)
    }
}
