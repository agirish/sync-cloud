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

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }

    public init(id: String = UUID().uuidString, timestamp: Date, model: String, fileCount: Int,
                placedCount: Int, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int,
                cacheCreationTokens: Int, estimatedCostUSD: Double) {
        self.id = id; self.timestamp = timestamp; self.model = model
        self.fileCount = fileCount; self.placedCount = placedCount
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheCreationTokens = cacheCreationTokens
        self.estimatedCostUSD = estimatedCostUSD
    }
}

/// Lifetime totals — never trimmed, so "total so far" stays accurate even after the history is capped.
public struct FilingSpendTotals: Codable, Equatable, Sendable {
    public var costUSD: Double
    public var tokens: Int
    public var scans: Int
    public init(costUSD: Double = 0, tokens: Int = 0, scans: Int = 0) {
        self.costUSD = costUSD; self.tokens = tokens; self.scans = scans
    }
}

/// Persists cloud Filing spend to UserDefaults: a capped scan history for display, a last-scan
/// snapshot, and never-trimmed lifetime totals. Recorded by the app after each cloud call; read by
/// the Filing UI.
public enum FilingSpendStore {
    static let historyKey = "tidyFilingSpendHistory"
    static let totalsKey = "tidyFilingSpendTotals"
    static let lastKey = "tidyFilingSpendLast"
    static let maxEntries = 500

    public static func entries(defaults: UserDefaults = .standard) -> [FilingSpendEntry] {
        guard let data = defaults.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([FilingSpendEntry].self, from: data) else { return [] }
        return decoded
    }

    public static func last(defaults: UserDefaults = .standard) -> FilingSpendEntry? {
        guard let data = defaults.data(forKey: lastKey) else { return nil }
        return try? JSONDecoder().decode(FilingSpendEntry.self, from: data)
    }

    public static func totals(defaults: UserDefaults = .standard) -> FilingSpendTotals {
        guard let data = defaults.data(forKey: totalsKey),
              let decoded = try? JSONDecoder().decode(FilingSpendTotals.self, from: data) else { return .init() }
        return decoded
    }

    public static func record(_ entry: FilingSpendEntry, defaults: UserDefaults = .standard) {
        var list = entries(defaults: defaults)
        list.append(entry)
        if list.count > maxEntries { list.removeFirst(list.count - maxEntries) }
        // Only write when encoding succeeds. `set(nil, forKey:)` REMOVES the key, so an encode
        // failure here would silently erase the whole capped history / totals rather than
        // no-op — leave the prior value intact instead.
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: historyKey) }
        if let data = try? JSONEncoder().encode(entry) { defaults.set(data, forKey: lastKey) }

        var t = totals(defaults: defaults)
        t.costUSD += entry.estimatedCostUSD
        t.tokens += entry.totalTokens
        t.scans += 1
        if let data = try? JSONEncoder().encode(t) { defaults.set(data, forKey: totalsKey) }
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: historyKey)
        defaults.removeObject(forKey: totalsKey)
        defaults.removeObject(forKey: lastKey)
    }
}

/// Compact formatting for Filing spend figures, shared by the Tidy lens and Settings.
public enum FilingSpendFormat {
    public static func cost(_ value: Double) -> String {
        value >= 0.01 ? String(format: "~$%.2f", value) : String(format: "~$%.4f", value)
    }
    public static func tokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk tok", Double(n) / 1000) : "\(n) tok"
    }
    public static func model(_ id: String) -> String {
        if id.contains("haiku") { return "Haiku" }
        if id.contains("sonnet") { return "Sonnet" }
        if id.contains("opus") { return "Opus" }
        if id.contains("fable") { return "Fable" }
        return id
    }
}
