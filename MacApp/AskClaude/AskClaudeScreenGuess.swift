import Foundation
import FoundationModels
import Events

/// Whether a question needs what is on screen, guessed by Apple's on-device model (TE347c,
/// decision NO). Eval on this Mac, 11-11, 60 questions: 1 of 30 about the screen guessed "no"
/// (Claude then asks for it), 3 of 30 others sent it anyway; 0.7 s a guess once loaded. Guessed while they type, so the answer is usually in by Send; Send waits a moment
/// at most, and without an answer the screen goes as it always did. A wrong "no" costs a round:
/// Claude asks for the screen with look_at_screen.
@MainActor
final class AskClaudeScreenGuess {
    static let shared = AskClaudeScreenGuess()

    /// What the guess sees besides the question: no names (V7).
    struct Context: Hashable {
        var workspace: String
        var fileOpen: Bool
    }

    /// How long Send waits for a guess still running (U1).
    static let wait: Duration = .milliseconds(300)

    static let instructions = """
    Decide whether answering a question needs what is on the person’s screen in SyncCloud, a Mac \
    file browser: the folder shown, its files and folders, what is selected, a file open in Edit, \
    the tabs, or two folders being compared. Anything about this, here, these, it, a file, a \
    folder, a document, a download, a photo, their cloud, or what they are looking at needs it, \
    and so does any request to show, find, open or check one of their files, or about either or \
    both of them. \
    Chit-chat, general knowledge, the weather, news, definitions, and how to use another app don’t. \
    When unsure, say it needs the screen.
    """

    @Generable
    struct Need {
        @Guide(description: "true when answering needs what is on their screen; true when unsure.")
        let needsScreen: Bool
    }

    private var known: [Key: Bool] = [:]
    private var running: (key: Key, task: Task<Void, Never>)?

    private struct Key: Hashable {
        var question: String
        var context: Context
    }

    /// Guesses `question` as it stands, replacing a guess still running for older words (V8).
    func start(_ question: String, context: Context) {
        let key = Key(question: Self.tidy(question), context: context)
        guard !key.question.isEmpty, known[key] == nil, running?.key != key else { return }
        running?.task.cancel()
        let task = Task { [weak self] in
            guard let needs = await Self.ask(key.question, context: context), !Task.isCancelled else { return }
            self?.keep(needs, for: key)
        }
        running = (key, task)
    }

    /// True only when the model said the question doesn't need the screen, in time.
    func withholds(_ question: String, context: Context) async -> Bool {
        let key = Key(question: Self.tidy(question), context: context)
        start(question, context: context)
        let deadline = ContinuousClock.now + Self.wait
        while known[key] == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let needs = known[key] else {
            Logger.shared.debug("Ask Claude: no screen guess within \(Self.wait); the screen goes")
            return false
        }
        return !needs
    }

    private func keep(_ needs: Bool, for key: Key) {
        if known.count > 200 { known.removeAll() }
        known[key] = needs
        if running?.key == key { running = nil }
    }

    private static func tidy(_ question: String) -> String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The model's answer, or nil when Apple Intelligence is off, it failed, or it was stopped.
    static func ask(_ question: String, context: Context) async -> Bool? {
        guard await AskClaudeOnDevice.availableOffMain() else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Workspace: \(context.workspace). A file is open in Edit: \(context.fileOpen ? "yes" : "no").\nQuestion: \(question)"
        do {
            return try await session.respond(to: prompt, generating: Need.self,
                                             options: GenerationOptions(samplingMode: .greedy)).content.needsScreen
        } catch {
            if !Task.isCancelled { Logger.shared.info("Ask Claude’s on-device model didn’t guess about the screen: \(error.localizedDescription)") }
            return nil
        }
    }
}
