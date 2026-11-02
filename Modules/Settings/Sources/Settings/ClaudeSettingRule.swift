import Foundation
import Sync

/// Which changes Claude may make itself, with the settings tool's `set` (TE290 step 4c). Every
/// other change is their click on a card.
///
/// **Look-and-feel, or tightening its own reach.** A Direct setting changes either way. A Direct
/// when tightening one changes only the way that lowers Claude's spending or access — reading
/// off, a lower limit — and never to a limit at or below what is already spent, which would stop
/// it at once: that is turning it off, and turning off is theirs. Raising is always their click.
public enum ClaudeSettingRule {

    /// Why Claude may not change `entry` from `current` to `value` itself, or nil when it may.
    @MainActor
    public static func refusal(_ entry: SettingEntry, from current: SettingValue?, to value: SettingValue,
                               defaults: UserDefaults, now: Date = Date()) -> String? {
        switch entry.tier {
        case .direct:
            return nil
        case .directWhenTightening:
            // Lowering is the one way: the change back would raise. Without a known value now,
            // which way it goes can't be told.
            guard entry.raises(from: value, to: current ?? value), !entry.raises(from: current, to: value) else {
                return "\(entry.label) to that raises Claude’s spending or access, which takes their click."
            }
            if let spent = spent(entry.id, defaults: defaults, now: now), let limit = number(value), limit <= spent {
                return "\(entry.label) at \(AskClaudeSpend.format(limit)) is at or below the \(AskClaudeSpend.format(spent)) already spent, so it would stop at once; that takes their click."
            }
            return nil
        default:
            return "\(entry.label) changes with their click, not yours."
        }
    }

    /// What has been spent against the limit `id` sets, for limits that have one.
    static func spent(_ id: String, defaults: UserDefaults, now: Date) -> Double? {
        switch id {
        case "intelligence.monthlyLimit":
            AskClaudeSpend.spent(in: defaults, now: now)
        case "intelligence.monthlyCap":
            FilingSpendBudget.monthlySpend(entries: FilingSpendStore.entries(defaults: defaults), now: now)
        case "intelligence.totalCap":
            FilingSpendStore.totals(defaults: defaults).costUSD
        default:
            nil
        }
    }

    private static func number(_ value: SettingValue) -> Double? {
        switch value {
        case .int(let x): Double(x)
        case .double(let x): x
        default: nil
        }
    }
}
