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
    // High enough that a single calendar month can't realistically trim its own entries — the
    // monthly cap sums the current-month entries from this history, so a cap smaller than a month's
    // worth of calls would under-enforce. (~2000 cloud classifies in one month is not humanly
    // reachable; the lifetime cap uses the never-trimmed `totals`, so it is unaffected regardless.)
    static let maxEntries = 2000

    /// Serializes the read-modify-write in `record`/`clear`. `record` runs off the main actor
    /// (called from `CloudFilingClassifier.classify`, a `nonisolated async` function), so two
    /// overlapping cloud calls — e.g. two quick "Try another folder" taps — would otherwise race
    /// the non-atomic UserDefaults RMW, dropping a spend increment and under-counting the total the
    /// budget cap is enforced against.
    private static let lock = NSLock()

    /// Posted after every `record` and `clear`, so a surface holding a cached copy of the figures
    /// can refresh without knowing who wrote. The posting `UserDefaults` rides as the
    /// notification's `object`: app observers pass no object and hear every write, while a test —
    /// whose suites run in parallel against private defaults — can scope its observer to its own
    /// instance instead of counting its neighbours' posts.
    ///
    /// This exists because per-surface refresh lists do not compose across windows: the Organize
    /// lens refreshed on its own three moments (appear, scan finish, its own history sheet
    /// closing) and was still left quoting an erased record when the SAME history view cleared
    /// spend from the Settings window — a fourth moment its list could not have named. Every
    /// cached reader now listens here instead of enumerating writers. Posted from whatever thread
    /// wrote (record runs off the main actor); observers hop to main themselves.
    public static let didChange = Notification.Name("com.synccloud.filing-spend-did-change")

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

    /// The locked read-modify-write half of `record`; the public entry posts `didChange` after
    /// the lock is released.
    private static func recordLocked(_ entry: FilingSpendEntry, defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
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

    public static func record(_ entry: FilingSpendEntry, defaults: UserDefaults = .standard) {
        recordLocked(entry, defaults: defaults)
        // Outside the lock — `post` delivers synchronously to same-thread observers, and an
        // observer that read the store back through a locked entry point would deadlock.
        NotificationCenter.default.post(name: didChange, object: defaults)
    }

    public static func clear(defaults: UserDefaults = .standard) {
        lock.lock()
        defaults.removeObject(forKey: historyKey)
        defaults.removeObject(forKey: totalsKey)
        defaults.removeObject(forKey: lastKey)
        lock.unlock()
        NotificationCenter.default.post(name: didChange, object: defaults)
    }
}

/// Compact formatting for Filing spend figures, shared by the Organize workspace and Settings.
public enum FilingSpendFormat {
    public static func cost(_ value: Double) -> String {
        value >= 0.01 ? String(format: "~$%.2f", value) : String(format: "~$%.4f", value)
    }
    public static func tokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk tok", Double(n) / 1000) : "\(n) tok"
    }
    /// "1 file" / "3 files" — both spend rows used to hard-code "\(n) files" and print "1 files".
    public static func files(_ n: Int) -> String {
        "\(n) file\(n == 1 ? "" : "s")"
    }
    public static func model(_ id: String) -> String {
        if id.contains("haiku") { return "Haiku" }
        if id.contains("sonnet") { return "Sonnet" }
        if id.contains("opus") { return "Opus" }
        if id.contains("fable") { return "Fable" }
        return id
    }
}
