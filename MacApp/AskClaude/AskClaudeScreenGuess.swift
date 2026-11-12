import Foundation
import FoundationModels
import Events

/// Whether a question needs what is on screen, guessed by Apple's on-device model (TE347c,
/// decision NO). Eval on this Mac, 11-11, 60 questions: 1 of 30 about the screen guessed "no"
/// (Claude then asks for it), 3 of 30 others sent it anyway; 0.7 s a guess once loaded.
/// Guessed while they type, so the answer is often in by Send; Send waits for it a moment at
/// most, and without an answer the screen goes as it always did. A wrong "no" costs a round:
/// Claude asks for the screen with look_at_screen.
@MainActor
final class AskClaudeScreenGuess {
    static let shared = AskClaudeScreenGuess()

    /// What the guess sees besides the question: no names (V7).
    struct Context: Hashable {
        var workspace: String
        var fileOpen: Bool
    }

    /// How long Send waits for a guess still running. A guess takes about 0.7 s once the model is
    /// loaded, so a question said aloud, or sent the moment it's typed, has one in time; a cold
    /// model, or none, sends the screen (TE347 review; U1 had 0.3 s, which only a pause beat).
    static let wait: Duration = .milliseconds(800)

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

    /// Each guess made: whether it needs the screen, or nil when the model gave no answer (Apple
    /// Intelligence off, a failure), which ends Send's wait at once instead of at the deadline.
    private var known: [Key: Bool?] = [:]
    private var running: (key: Key, task: Task<Void, Never>)?
    private let asker: (String, Context) async -> Bool?
    private let wait: Duration

    init(wait: Duration = AskClaudeScreenGuess.wait,
         asker: @escaping (String, Context) async -> Bool? = { await AskClaudeScreenGuess.ask($0, context: $1) }) {
        self.wait = wait
        self.asker = asker
    }

    private struct Key: Hashable {
        var question: String
        var context: Context
    }

    /// Guesses `question` as it stands, replacing a guess still running for older words (V8).
    func start(_ question: String, context: Context) {
        let key = Key(question: Self.tidy(question), context: context)
        // A guess that gave no answer is asked again: the model may have loaded since.
        let unanswered = known[key].map { $0 == nil } ?? true
        guard !key.question.isEmpty, unanswered, running?.key != key else { return }
        running?.task.cancel()
        known.removeValue(forKey: key)
        let asker = asker
        let task = Task { [weak self] in
            let needs = await asker(key.question, context)
            guard !Task.isCancelled else { return }
            self?.keep(needs, for: key)
        }
        running = (key, task)
    }

    /// True only when the model said the question doesn't need the screen, in time.
    func withholds(_ question: String, context: Context) async -> Bool {
        let key = Key(question: Self.tidy(question), context: context)
        start(question, context: context)
        let deadline = ContinuousClock.now + wait
        while known[key] == nil, ContinuousClock.now < deadline {
            // Stopped: a cancelled sleep returns at once, so this would spin to the deadline.
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let answer = known[key], let needs = answer else {
            Logger.shared.debug("Ask Claude: no screen guess for this question; the screen goes")
            return false
        }
        return !needs
    }

    private func keep(_ needs: Bool?, for key: Key) {
        if known.count > 200 { known.removeAll() }
        // `.some`: a plain nil here would remove the entry, and "no answer" must be kept.
        known[key] = .some(needs)
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
