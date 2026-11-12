import Foundation
import Sync

/// The on-device model's starter per screen (TE347b), so coming back to a folder doesn't write
/// one again. "None" is kept too: a failed or refused answer isn't asked for again on every
/// visit. Kept for the app's run, a few dozen at most.
@MainActor
final class AskClaudeStarterCache {
    static let shared = AskClaudeStarterCache()
    private static let limit = 40

    private var answers: [String: String?] = [:]
    private var order: [String] = []

    /// nil: never asked; `.some(nil)`: asked, no starter.
    func answer(for key: String) -> String?? { answers[key] }

    func keep(_ question: String?, for key: String) {
        if answers.updateValue(question, forKey: key) == nil { order.append(key) }
        while order.count > Self.limit { answers.removeValue(forKey: order.removeFirst()) }
    }
}

/// What a new chat's rows say, worked out at most once every two seconds for one folder and
/// selection (TE347 review): the panel asks on every redraw, every key typed included, and a
/// big folder's rows are each checked against the hidden list.
@MainActor
final class AskClaudeStarterSignalsCache {
    static let shared = AskClaudeStarterSignalsCache()
    static let fresh: TimeInterval = 2

    private var kept: (key: Key, at: Date, signals: AskClaudeStarters.Signals)?

    struct Key: Equatable {
        var folder: String
        var count: Int
        var selection: Set<String>
        var hidden: [String]
    }

    func signals(for key: Key, now: Date = Date(), work: () -> AskClaudeStarters.Signals) -> AskClaudeStarters.Signals {
        if let kept, kept.key == key, now.timeIntervalSince(kept.at) < Self.fresh { return kept.signals }
        let signals = work()
        kept = (key, now, signals)
        return signals
    }
}
