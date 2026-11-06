import Events
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

/// Persists cloud Filing spend to UserDefaults: a capped scan history for display, a last-scan
/// snapshot, and never-trimmed lifetime totals. Recorded by the app after each cloud call; read by
/// the Filing UI.
public enum FilingSpendStore {
    static let historyKey = "tidyFilingSpendHistory"
    static let totalsKey = "tidyFilingSpendTotals"
    static let lastKey = "tidyFilingSpendLast"
    // High enough that one month can't trim its own entries: the monthly cap sums this month's
    // entries from the history, so a smaller cap would under-enforce. The lifetime cap uses the
    // never-trimmed `totals`.
    static let maxEntries = 2000

    /// Serializes the read-modify-write in `record` and `clear`. `record` runs off the main actor
    /// (from `CloudFilingClassifier.classify`), so two overlapping cloud calls, such as two quick
    /// "Try another folder" taps, would race the non-atomic UserDefaults update and under-count the
    /// total the budget cap is enforced against.
    private static let lock = NSLock()

    /// Posted after every `record` and `clear`, so any surface caching the figures can refresh
    /// without knowing who wrote; per-surface refresh lists can't see a clear from another window.
    /// The posting `UserDefaults` is the `object`: app observers pass none and hear every write,
    /// while a test on private defaults (suites run in parallel) scopes to its own instance. Posted
    /// from whatever thread wrote (`record` runs off the main actor); observers hop to main
    /// themselves.
    public static let didChange = Notification.Name("com.synccloud.filing-spend-did-change")

    /// How a spend read went. **Absent and unreadable are different facts, and for a money store
    /// the difference is everything:** reading an unreadable payload as zero and writing it back
    /// would erase the lifetime total and re-arm the cap from scratch, silently and for good.
    public enum Read<T>: Sendable where T: Sendable {
        /// Nothing recorded yet. Zero is the honest answer.
        case absent
        /// A payload that could not be decoded. Nothing may be concluded about spend from it.
        case unreadable
        case loaded(T)

        /// The value, treating both failures as empty, for display surfaces with one answer for
        /// "nothing yet" and "can't say". A caller enforcing a budget, or about to write, must
        /// switch on the case.
        public func value(orEmpty empty: T) -> T {
            if case .loaded(let v) = self { return v }
            return empty
        }
    }

    static func read<T: Decodable & Sendable>(_ type: T.Type, key: String,
                                              defaults: UserDefaults) -> Read<T> {
        guard let data = defaults.data(forKey: key) else { return .absent }
        if let decoded = try? JSONDecoder().decode(type, from: data) { return .loaded(decoded) }
        // Kept, then never written over (see `recordLocked`). Compared first so a repeated read of
        // a still-corrupt store doesn't rewrite the same payload.
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

    /// True when either persisted figure is on disk and unreadable, so no budget may be enforced
    /// against what this store can currently say.
    public static func isUnreadable(defaults: UserDefaults = .standard) -> Bool {
        if case .unreadable = entriesRead(defaults: defaults) { return true }
        if case .unreadable = totalsRead(defaults: defaults) { return true }
        return false
    }

    public static func entries(defaults: UserDefaults = .standard) -> [FilingSpendEntry] {
        entriesRead(defaults: defaults).value(orEmpty: [])
    }

    public static func last(defaults: UserDefaults = .standard) -> FilingSpendEntry? {
        guard let data = defaults.data(forKey: lastKey) else { return nil }
        return try? JSONDecoder().decode(FilingSpendEntry.self, from: data)
    }

    public static func totals(defaults: UserDefaults = .standard) -> FilingSpendTotals {
        totalsRead(defaults: defaults).value(orEmpty: .init())
    }

    /// The locked read-modify-write half of `record`; the public entry posts `didChange` after the
    /// lock is released.
    private static func recordLocked(_ entry: FilingSpendEntry, defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        // **A payload this build couldn't read is never written over.** Adding to a list read as
        // empty, or a total read as zero, would make one unreadable value a permanent erasure and
        // re-arm the cap. `read` keeps the bytes under a `.unreadable` sibling key; this refuses
        // the write on top of them and logs it. The last-scan snapshot is written regardless:
        // display-only, a fresh value, and nothing is enforced against it.
        let historyState = entriesRead(defaults: defaults)
        let totalsState = totalsRead(defaults: defaults)

        if let data = try? JSONEncoder().encode(entry) { defaults.set(data, forKey: lastKey) }

        switch historyState {
        case .unreadable:
            Logger.shared.error("Filing spend: the saved scan history could not be read, so this "
                                + "scan was NOT added to it — the unreadable copy is kept under "
                                + "\"\(historyKey).unreadable\". The monthly cap cannot be "
                                + "enforced until it is resolved, and cloud Filing stays paused.")
        case .absent, .loaded:
            var list = historyState.value(orEmpty: [])
            list.append(entry)
            if list.count > maxEntries { list.removeFirst(list.count - maxEntries) }
            // Only write when encoding succeeds: `set(nil, forKey:)` removes the key, so a failed
            // encode would erase the whole history.
            if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: historyKey) }
        }

        switch totalsState {
        case .unreadable:
            Logger.shared.error("Filing spend: the lifetime totals could not be read, so this "
                                + "scan was NOT added to them — the unreadable copy is kept under "
                                + "\"\(totalsKey).unreadable\". The lifetime cap cannot be "
                                + "enforced until it is resolved, and cloud Filing stays paused.")
        case .absent, .loaded:
            var t = totalsState.value(orEmpty: .init())
            t.costUSD += entry.estimatedCostUSD
            t.tokens += entry.totalTokens
            t.scans += 1
            if entry.costUnpriced { t.unpricedScans += 1 }
            if let data = try? JSONEncoder().encode(t) { defaults.set(data, forKey: totalsKey) }
        }
    }

    public static func record(_ entry: FilingSpendEntry, defaults: UserDefaults = .standard) {
        recordLocked(entry, defaults: defaults)
        // Outside the lock: `post` delivers synchronously to same-thread observers, and one that
        // read the store back through a locked entry point would deadlock.
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

    /// The clear gesture as one step: ask, and only then clear. What it resets is what the caps
    /// count against (the total cap is the $5 safety backstop), so taking the confirmer here means
    /// neither Clear button can wipe on a stray click. The alert is the app's; `clearPrompt` is its
    /// words.
    /// - Returns: Whether the spend was cleared.
    @discardableResult
    public static func clearIfConfirmed(defaults: UserDefaults = .standard,
                                        confirm: () -> Bool) -> Bool {
        guard confirm() else { return false }
        clear(defaults: defaults)
        return true
    }

    /// What the confirmation says, shared by Settings ▸ Intelligence and the Organize lens's
    /// history sheet so the two Clear buttons ask the same question.
    public static let clearPrompt = (
        messageText: "Clear the recorded Claude spend?",
        informativeText: "This deletes the spend history and totals, so both the monthly and the "
            + "total cap count from zero again. What Anthropic has billed is unchanged, and this "
            + "can’t be undone.",
        confirmTitle: "Clear Spend")
}

/// Compact formatting for Filing spend figures, shared by the Organize workspace and Settings.
public enum FilingSpendFormat {
    public static func cost(_ value: Double) -> String {
        value >= 0.01 ? String(format: "~$%.2f", value) : String(format: "~$%.4f", value)
    }
    public static func tokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk tok", Double(n) / 1000) : "\(n) tok"
    }
    /// "1 file" / "3 files".
    public static func files(_ n: Int) -> String {
        "\(n) file\(n == 1 ? "" : "s")"
    }
    /// The unit-aware count: "24 files" for the filing refine, "24 folder names" for the mapping
    /// refine. Every row that renders a spend entry goes through this, or the history misdescribes
    /// whichever pass wrote it.
    public static func counted(_ entry: FilingSpendEntry) -> String {
        let unit = entry.unit ?? "file"
        return "\(entry.fileCount) \(unit)\(entry.fileCount == 1 ? "" : "s")"
    }
    /// What `placedCount` was: placements for a filing refine, answered rows for a mapping refine.
    public static func outcome(_ entry: FilingSpendEntry) -> String {
        (entry.unit ?? "file") == "file"
            ? "placed \(entry.placedCount)" : "answered \(entry.placedCount)"
    }
    public static func model(_ id: String) -> String {
        if id.contains("haiku") { return "Haiku" }
        if id.contains("sonnet") { return "Sonnet" }
        if id.contains("opus") { return "Opus" }
        if id.contains("fable") { return "Fable" }
        return id
    }
}
