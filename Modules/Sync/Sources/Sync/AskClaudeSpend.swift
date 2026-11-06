import Foundation

/// Ask Claude’s own monthly spending limit: $25 to start, a warning at 80%, and no new questions
/// once it’s reached, until the month turns.
///
/// Separate from Filing’s spend record: the two features have different limits and are read
/// separately in Settings; folding them into one would make either limit mean something else.
/// Estimates only, from list prices: what Anthropic bills is in the Console.
public enum AskClaudeSpend {

    public static let limitDefaultsKey = "askClaudeMonthlyLimitUSD"
    public static let defaultLimitUSD = 25.0
    /// The choices Settings offers. Zero means no limit.
    public static let limitChoices: [Double] = [5, 10, 25, 50, 100, 0]
    public static let warningFraction = 0.8

    public enum State: Equatable, Sendable {
        case ok
        case nearLimit(spent: Double, limit: Double)
        case overLimit(spent: Double, limit: Double)
    }

    /// Each month's spend is its own key, `askClaudeSpend.2026-11`.
    static let monthKeyPrefix = "askClaudeSpend."

    static func monthKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month], from: date)
        return monthKeyPrefix + String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    public static func limit(in defaults: UserDefaults) -> Double {
        defaults.object(forKey: limitDefaultsKey) == nil ? defaultLimitUSD : defaults.double(forKey: limitDefaultsKey)
    }

    public static func spent(in defaults: UserDefaults, now: Date = Date()) -> Double {
        defaults.double(forKey: monthKey(now))
    }

    public static func record(_ costUSD: Double, in defaults: UserDefaults, now: Date = Date()) {
        guard costUSD > 0 else { return }
        let key = monthKey(now)
        defaults.set(defaults.double(forKey: key) + costUSD, forKey: key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func state(in defaults: UserDefaults, now: Date = Date()) -> State {
        state(spent: spent(in: defaults, now: now), limit: limit(in: defaults))
    }

    public static func state(spent: Double, limit: Double) -> State {
        guard limit > 0 else { return .ok }
        if spent >= limit { return .overLimit(spent: spent, limit: limit) }
        if spent >= limit * warningFraction { return .nearLimit(spent: spent, limit: limit) }
        return .ok
    }

    /// The first day of next month, for "resets on …".
    public static func resetDate(after now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        return calendar.date(byAdding: .month, value: 1, to: start) ?? now
    }

    public static let didChange = Notification.Name("AskClaudeSpendDidChange")

    /// Dollars the way the panel shows them: cents below a dollar, two places above.
    public static func format(_ usd: Double) -> String {
        if usd > 0 && usd < 0.01 { return "under 1¢" }
        if usd < 1 { return "\(Int((usd * 100).rounded()))¢" }
        if usd == usd.rounded() { return "$\(Int(usd))" }
        return String(format: "$%.2f", usd)
    }
}
