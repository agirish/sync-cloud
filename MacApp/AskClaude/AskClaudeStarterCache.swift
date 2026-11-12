import Foundation

/// The on-device model's starter per screen (TE347b), so coming back to a folder doesn't write
/// one again. Kept for the app's run, a few dozen at most.
@MainActor
final class AskClaudeStarterCache {
    static let shared = AskClaudeStarterCache()
    private static let limit = 40

    private var questions: [String: String] = [:]
    private var order: [String] = []

    func question(for key: String) -> String? { questions[key] }

    func keep(_ question: String, for key: String) {
        if questions.updateValue(question, forKey: key) == nil { order.append(key) }
        while order.count > Self.limit { questions[order.removeFirst()] = nil }
    }
}
