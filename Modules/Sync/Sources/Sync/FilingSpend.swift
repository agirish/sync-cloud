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
    /// True when this scan's cost could NOT be derived — an unrecognised model id, which the price
    /// table answers `nil` for. `estimatedCostUSD` is then 0 because the call still has to be
    /// recorded, and the flag is what stops that 0 being read as "this scan was free".
    ///
    /// **The pre-flight path already handled the identical nil honestly** — its own comment says
    /// the caller shows "estimate unavailable" rather than a wrong number — while the post-flight
    /// path coerced it to `0`, and that is the number the budget caps enforce against. Reachable
    /// through a hand-set model id, which the code explicitly promises to honour.
    public let costUnpriced: Bool

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }

    public init(id: String = UUID().uuidString, timestamp: Date, model: String, fileCount: Int,
                placedCount: Int, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int,
                cacheCreationTokens: Int, estimatedCostUSD: Double, costUnpriced: Bool = false) {
        self.id = id; self.timestamp = timestamp; self.model = model
        self.fileCount = fileCount; self.placedCount = placedCount
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheCreationTokens = cacheCreationTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.costUnpriced = costUnpriced
    }

    /// Optional-with-default for the same reason ``FilingSpendTotals`` is: an entry written before
    /// a field existed must not throw, because a throw here empties the capped history the MONTHLY
    /// cap is summed from.
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
    }
}

/// Lifetime totals — never trimmed, so "total so far" stays accurate even after the history is capped.
public struct FilingSpendTotals: Codable, Equatable, Sendable {
    public var costUSD: Double
    public var tokens: Int
    public var scans: Int
    /// Scans whose cost could not be priced — an unrecognised model id. `costUSD` is then a FLOOR
    /// rather than a total, and the surfaces that show it say so.
    public var unpricedScans: Int

    public init(costUSD: Double = 0, tokens: Int = 0, scans: Int = 0, unpricedScans: Int = 0) {
        self.costUSD = costUSD; self.tokens = tokens; self.scans = scans
        self.unpricedScans = unpricedScans
    }

    /// **Every field optional-with-default, like every neighbouring store in this module.**
    /// `FilingVerdictCache`, `FilingMemory`, `PersonRegistry` and `PaneTabsStore` all decode this
    /// way precisely so that adding one field cannot make the decoder throw on every existing
    /// user's data — and a throw here is not a read failure, it is an erasure: `record` writes the
    /// zeroed value straight back over the lifetime total the budget cap is enforced against.
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

    /// How a spend read went. **Absent and unreadable are different facts, and for a MONEY store
    /// the difference is the whole thing.**
    ///
    /// Both used to answer "zero", and `record` then wrote that zero back: one unreadable payload
    /// erased the lifetime total, re-armed the $5 cap from scratch, and made the erasure permanent.
    /// Settings showed $0.00 lifetime with nothing to say why. The CAP side of this same feature
    /// was carefully defended against exactly this — `totalBudgetCap` distinguishes an absent key
    /// from a stored 0, and says so — while the SPENT side was not.
    public enum Read<T>: Sendable where T: Sendable {
        /// Nothing recorded yet. Zero is the honest answer.
        case absent
        /// A payload that could not be decoded. Nothing may be concluded about spend from it.
        case unreadable
        case loaded(T)

        /// The value, treating both failures as empty — for the display surfaces that genuinely
        /// have one answer for "nothing yet" and "cannot say". A caller enforcing a BUDGET, or
        /// about to write, must switch on the case instead.
        public func value(orEmpty empty: T) -> T {
            if case .loaded(let v) = self { return v }
            return empty
        }
    }

    static func read<T: Decodable & Sendable>(_ type: T.Type, key: String,
                                              defaults: UserDefaults) -> Read<T> {
        guard let data = defaults.data(forKey: key) else { return .absent }
        if let decoded = try? JSONDecoder().decode(type, from: data) { return .loaded(decoded) }
        // Kept, then never written over — see `recordLocked`. Read-and-compare so a repeated read
        // on a still-corrupt store does not rewrite the same payload.
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

    /// The locked read-modify-write half of `record`; the public entry posts `didChange` after
    /// the lock is released.
    private static func recordLocked(_ entry: FilingSpendEntry, defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        // **A payload this build could not read is never written over.** Adding to a list that
        // decoded as empty, or to a total that decoded as zero, is what turned one unreadable
        // value into a permanent erasure — and into a budget cap re-armed from scratch. The bytes
        // are preserved by `read` under a `.unreadable` sibling key; this refuses the write that
        // would otherwise land on top of them, and says so once per record.
        //
        // The last-scan snapshot is written regardless: it is display-only, it is a fresh value
        // rather than an accumulation, and nothing is enforced against it.
        let historyState = entriesRead(defaults: defaults)
        let totalsState = totalsRead(defaults: defaults)

        if let data = try? JSONEncoder().encode(entry) { defaults.set(data, forKey: lastKey) }

        switch historyState {
        case .unreadable:
            // `Logger.shared` is main-actor isolated on this line, and this runs off the main
            // actor — the hop is the same one `FileSyncManager+Scanning` uses for its own
            // off-actor logging. (On `main` the singleton is `nonisolated` and the hop is absent;
            // that change did not travel here.)
            Task { @MainActor in
            Logger.shared.error("Filing spend: the saved scan history could not be read, so this "
                                + "scan was NOT added to it — the unreadable copy is kept under "
                                + "\"\(historyKey).unreadable\". The monthly cap cannot be "
                                + "enforced until it is resolved, and cloud Filing stays paused.")
            }
        case .absent, .loaded:
            var list = historyState.value(orEmpty: [])
            list.append(entry)
            if list.count > maxEntries { list.removeFirst(list.count - maxEntries) }
            // Only write when encoding succeeds. `set(nil, forKey:)` REMOVES the key, so an encode
            // failure here would silently erase the whole capped history rather than no-op.
            if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: historyKey) }
        }

        switch totalsState {
        case .unreadable:
            Task { @MainActor in
            Logger.shared.error("Filing spend: the lifetime totals could not be read, so this "
                                + "scan was NOT added to them — the unreadable copy is kept under "
                                + "\"\(totalsKey).unreadable\". The lifetime cap cannot be "
                                + "enforced until it is resolved, and cloud Filing stays paused.")
            }
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
