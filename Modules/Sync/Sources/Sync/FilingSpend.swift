import Foundation

/// One cloud (Claude) Filing classification call, recorded for the spend history.
public struct FilingSpendEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let model: String
    public let fileCount: Int
    public let placedCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let estimatedCostUSD: Double
    /// True when this scan's cost couldn't be derived (an unrecognised model id, which the price
    /// table answers `nil` for, reachable through a hand-set id). `estimatedCostUSD` is then 0
    /// because the call must still be recorded, and this flag stops that 0 reading as "free",
    /// including to the budget caps.
    public let costUnpriced: Bool
    /// What `fileCount` counts: nil (older entries) and "file" both mean the filing refine's files;
    /// the mapping refine records "folder name". Without it every history row would describe a
    /// mapping refine as "24 files · placed 24".
    public let unit: String?

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }

    public init(id: String = UUID().uuidString, timestamp: Date, model: String, fileCount: Int,
                placedCount: Int, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int,
                cacheCreationTokens: Int, estimatedCostUSD: Double, costUnpriced: Bool = false,
                unit: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.model = model
        self.fileCount = fileCount; self.placedCount = placedCount
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheCreationTokens = cacheCreationTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.costUnpriced = costUnpriced
        self.unit = unit
    }

    /// Optional-with-default, like ``FilingSpendTotals``: an older entry must not throw, because a
    /// throw here empties the capped history the monthly cap is summed from.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date(timeIntervalSince1970: 0)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        fileCount = try c.decodeIfPresent(Int.self, forKey: .fileCount) ?? 0
        placedCount = try c.decodeIfPresent(Int.self, forKey: .placedCount) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        estimatedCostUSD = try c.decodeIfPresent(Double.self, forKey: .estimatedCostUSD) ?? 0
        costUnpriced = try c.decodeIfPresent(Bool.self, forKey: .costUnpriced) ?? false
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
    }
}

/// Lifetime totals, never trimmed, so "total so far" stays accurate after the history is capped.
public struct FilingSpendTotals: Codable, Equatable, Sendable {
    public var costUSD: Double
    public var tokens: Int
    public var scans: Int
    /// Scans whose cost couldn't be priced (an unrecognised model id). `costUSD` is then a floor,
    /// not a total, and the surfaces that show it say so.
    public var unpricedScans: Int

    public init(costUSD: Double = 0, tokens: Int = 0, scans: Int = 0, unpricedScans: Int = 0) {
        self.costUSD = costUSD; self.tokens = tokens; self.scans = scans
        self.unpricedScans = unpricedScans
    }

    /// **Every field optional-with-default**, like the neighbouring stores, so adding a field can't
    /// make existing data throw. A throw here is not a read failure but an erasure: `record` would
    /// write the zeroed value over the lifetime total the budget cap is enforced against.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        scans = try c.decodeIfPresent(Int.self, forKey: .scans) ?? 0
        unpricedScans = try c.decodeIfPresent(Int.self, forKey: .unpricedScans) ?? 0
    }
}

/// What Refine's own spend record held before Ask Claude's one limit replaced it (TE335, E5): a
/// scan history, a last-scan snapshot and lifetime totals in UserDefaults. **Read only now.**
/// Nothing records to it; ``RefineSpendMigration`` reads it once at launch, carries this month into
/// Ask Claude's total, keeps what the notice needs, and deletes it.
public enum FilingSpendStore {
    static let historyKey = "tidyFilingSpendHistory"
    static let totalsKey = "tidyFilingSpendTotals"
    static let lastKey = "tidyFilingSpendLast"

    /// How a spend read went. **Absent and unreadable are different facts, and for a money store
    /// the difference is everything:** reading an unreadable payload as zero would carry nothing
    /// forward and then delete the record.
    public enum Read<T>: Sendable where T: Sendable {
        /// Nothing recorded. Zero is the honest answer.
        case absent
        /// A payload that could not be decoded. Nothing may be concluded about spend from it.
        case unreadable
        case loaded(T)

        public func value(orEmpty empty: T) -> T {
            if case .loaded(let v) = self { return v }
            return empty
        }
    }

    static func read<T: Decodable & Sendable>(_ type: T.Type, key: String,
                                              defaults: UserDefaults) -> Read<T> {
        guard let data = defaults.data(forKey: key) else { return .absent }
        if let decoded = try? JSONDecoder().decode(type, from: data) { return .loaded(decoded) }
        // Kept under a sibling key, so an unreadable record is never lost to a later write.
        let backupKey = key + ".unreadable"
        if defaults.data(forKey: backupKey) != data {
            defaults.set(data, forKey: backupKey)
        }
        return .unreadable
    }

    public static func entriesRead(defaults: UserDefaults = .standard) -> Read<[FilingSpendEntry]> {
        read([FilingSpendEntry].self, key: historyKey, defaults: defaults)
    }

    public static func totalsRead(defaults: UserDefaults = .standard) -> Read<FilingSpendTotals> {
        read(FilingSpendTotals.self, key: totalsKey, defaults: defaults)
    }

    /// True when either persisted figure is on disk and unreadable.
    public static func isUnreadable(defaults: UserDefaults = .standard) -> Bool {
        if case .unreadable = entriesRead(defaults: defaults) { return true }
        if case .unreadable = totalsRead(defaults: defaults) { return true }
        return false
    }

    public static func entries(defaults: UserDefaults = .standard) -> [FilingSpendEntry] {
        entriesRead(defaults: defaults).value(orEmpty: [])
    }

    public static func totals(defaults: UserDefaults = .standard) -> FilingSpendTotals {
        totalsRead(defaults: defaults).value(orEmpty: .init())
    }
}

/// Compact formatting for Refine's cost figures, in the spend dialog and the log.
public enum FilingSpendFormat {
    public static func cost(_ value: Double) -> String {
        value >= 0.01 ? String(format: "~$%.2f", value) : String(format: "~$%.4f", value)
    }
}
