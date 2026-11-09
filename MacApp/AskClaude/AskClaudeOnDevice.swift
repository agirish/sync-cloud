import Foundation
import FoundationModels
import Sync
import Events

/// Asks Apple's on-device model which simple command a question is (TE338), on this Mac: nothing
/// is sent, nothing is billed. `AskClaudeQuickCommand` holds the prompt and turns the answer into
/// one of Ask Claude's tool calls; nil from here means ask Claude.
enum AskClaudeOnDevice {

    /// How long the model may take before the question goes to Claude after all. A command took
    /// about 1.3 s in the eval, 3.5 s at the slowest; a cold model's first answer runs longer.
    static let timeout: Duration = .seconds(5)

    /// Apple Intelligence is on and its model ready. Read at each question: it can be switched
    /// off, or still be downloading.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @Generable
    enum Action: String, CaseIterable {
        case eject, goTo, showHiddenFiles, hideHiddenFiles, openSettings, sortBy, switchView, askClaude
    }

    @Generable
    enum Sort: String, CaseIterable {
        case none, name, kind, date, size
    }

    /// The eval's second schema: typed sort and view, and a step count, took it from 40 to 45 of 52.
    @Generable
    struct Answer {
        @Guide(description: "How many separate things the request asks for. 2 or more means askClaude.")
        let steps: Int
        @Guide(description: "The one command this request is, or askClaude for anything else.")
        let action: Action
        @Guide(description: "For eject, goTo and openSettings only: the disk, folder, source or settings tab it names, copied exactly from the lists above. Empty for every other command, and when it doesn’t name exactly one.")
        let target: String
        @Guide(description: "For sortBy only: what to sort by. none for every other command.")
        let sort: Sort
        @Guide(description: "For switchView only: list or columns. Empty otherwise.")
        let view: String
    }

    /// The route the model picks, or nil: unavailable, too slow, or it failed.
    static func route(_ question: String, lists: AskClaudeQuickCommand.Lists) async -> AskClaudeQuickCommand.Route? {
        guard isAvailable else { return nil }
        let instructions = AskClaudeQuickCommand.instructions(lists)
        let started = ContinuousClock.now
        let answer: Answer? = await withTaskGroup(of: Answer?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                do {
                    return try await session.respond(to: question, generating: Answer.self,
                                                     options: GenerationOptions(samplingMode: .greedy)).content
                } catch {
                    Logger.shared.info("Ask Claude’s on-device model didn’t route a question: \(error.localizedDescription)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let took = ContinuousClock.now - started
        guard let answer else {
            if took >= timeout { Logger.shared.info("Ask Claude’s on-device model took over \(timeout); asking Claude") }
            return nil
        }
        // The command, never the question's words.
        Logger.shared.debug("Ask Claude’s on-device model picked \(answer.action.rawValue) in \(took)")
        return AskClaudeQuickCommand.Route(
            steps: answer.steps,
            action: AskClaudeQuickCommand.Action(rawValue: answer.action.rawValue) ?? .askClaude,
            target: answer.target,
            sort: AskClaudeQuickCommand.Sort(rawValue: answer.sort.rawValue) ?? .none,
            view: answer.view)
    }
}
