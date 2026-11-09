import Foundation
import FoundationModels
import Sync
import Events

/// Asks Apple's on-device model which simple command a question is (TE338), on this Mac: nothing
/// is sent, nothing is billed. `AskClaudeQuickCommand` holds the prompt and turns the answer into
/// one of Ask Claude's tool calls; nil from here means ask Claude.
enum AskClaudeOnDevice {

    /// How long the model may take before the question goes to Claude after all. Loaded, a command
    /// took about 1.3 s in the eval, 3.5 s at the slowest. Cold, which it is after about 5 idle
    /// minutes, macOS loads a safety model and then the 3B one: on 11-09 that was past 5 s, and the
    /// limit cut it off and the cancel unloaded it again (`log show`, TokenGenerationInference).
    /// `prewarm` starts that load while they type; 8 s covers the rest of it. Only a cold model
    /// is ever slow, so the limit costs a question to Claude nothing once the model is loaded.
    static let timeout: Duration = .seconds(8)

    /// Apple Intelligence is on and its model ready. Read at each question: it can be switched
    /// off, or still be downloading. Can block for seconds after a macOS update, so it is asked
    /// off the main thread (`availableOffMain`), never from a click.
    nonisolated static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    nonisolated static func availableOffMain() async -> Bool {
        await Task.detached(priority: .userInitiated) { isAvailable }.value
    }

    /// A session made and prewarmed before Send, with the instructions it was made for. Taken by
    /// the next question whose instructions match, then gone: a session keeps its transcript, and
    /// each question starts clean.
    @MainActor private static var warm: (instructions: String, session: LanguageModelSession)?

    /// Loads the model, and the lane's instructions for what is on screen, before Send (the
    /// column opening, the first key of a question). Two commands on 11-09 found it cold, past
    /// the old 5 s limit, and went to Claude. A no-op when Apple Intelligence is off, or when a
    /// session for these instructions is already warm.
    static func prewarm(_ lists: AskClaudeQuickCommand.Lists) {
        let instructions = AskClaudeQuickCommand.instructions(lists)
        Task { @MainActor in
            guard warm?.instructions != instructions, await availableOffMain() else { return }
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm()
            warm = (instructions, session)
        }
    }

    /// The warm session for these instructions, or a new one.
    @MainActor private static func session(for instructions: String) -> LanguageModelSession {
        if let ready = warm, ready.instructions == instructions {
            warm = nil
            return ready.session
        }
        return LanguageModelSession(instructions: instructions)
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
    @MainActor static func route(_ question: String, lists: AskClaudeQuickCommand.Lists) async -> AskClaudeQuickCommand.Route? {
        guard await availableOffMain() else { return nil }
        let started = ContinuousClock.now
        let session = session(for: AskClaudeQuickCommand.instructions(lists))
        let answer: Answer? = await withTaskGroup(of: Answer?.self) { group in
            group.addTask {
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
        // The command, never the question's words; Info, so a slow answer shows its time.
        Logger.shared.info("Ask Claude’s on-device model picked \(answer.action.rawValue) in \(took.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
        return AskClaudeQuickCommand.Route(
            steps: answer.steps,
            action: AskClaudeQuickCommand.Action(rawValue: answer.action.rawValue) ?? .askClaude,
            target: answer.target,
            sort: AskClaudeQuickCommand.Sort(rawValue: answer.sort.rawValue) ?? .none,
            view: answer.view)
    }
}
