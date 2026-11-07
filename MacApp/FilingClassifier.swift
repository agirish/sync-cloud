import Foundation
import Sync
import Events
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which backend the hybrid Filing classifier runs a scan on, and whether a divergence from what
/// the user expects has to be reported.
enum FilingBackendRoute: Equatable {
    /// Cloud (Claude) Filing is on and a key is available: the cloud backend is primary.
    case cloud
    /// Cloud Filing is off: the on-device model is the intended backend, nothing to report.
    case onDevice
    /// Cloud Filing is on but no usable API key could be read, so the scan falls back to the
    /// on-device model. The user believes Claude is filing, so this case is reported in the
    /// Activity Log.
    case onDeviceCloudKeyUnavailable
}

/// Picks the Filing backend for one scan. Kept out of `SyncCloudApp`'s classifier closure so the
/// gate and its downgrade log line can be tested: without that line, a missing key or locked
/// Keychain looks in the log like a normal cloud run.
enum FilingBackendRouter {

    /// The user-facing explanation of a cloud→on-device downgrade, kept next to the route so the
    /// wording and its condition can't drift apart.
    static let missingKeyDowngradeMessage =
        "Cloud (Claude) Filing is enabled, but no API key could be read from the Keychain — "
        + "this scan used the free on-device model instead. Re-enter the key in Settings ▸ Ask Claude."

    /// Resolves the backend, reporting a downgrade through `logDowngrade` (a `Logger.shared`
    /// warning by default; tests inject a recorder so they don't depend on the process-wide log
    /// gate).
    ///
    /// `hasCloudKey` is an `@autoclosure` so the Keychain is asked only once the cloud toggle says
    /// yes. The real argument, `AnthropicKeychain.hasKey`, is a live query that can log a warning
    /// or raise an access prompt, which must not happen for a feature the user switched off.
    static func route(
        cloudEnabled: Bool,
        hasCloudKey: @autoclosure () -> Bool,
        logDowngrade: (String) -> Void = { _ = Logger.shared.warning($0) }
    ) -> FilingBackendRoute {
        guard cloudEnabled else { return .onDevice }
        guard hasCloudKey() else {
            logDowngrade(missingKeyDowngradeMessage)
            return .onDeviceCloudKeyUnavailable
        }
        return .cloud
    }
}

/// On-device intelligent Filing backend (the on-device half of the hybrid). Uses Apple's
/// Foundation Models (the ~3B on-device Apple Intelligence model) to reason about the user's
/// folders and each file's name and contents and pick a home, instead of keyword overlap.
///
/// Everything stays on the Mac; nothing is sent anywhere. On macOS < 26 or a Mac without Apple
/// Intelligence, `classify` returns no verdicts and Filing falls back to the keyword engine.
enum OnDeviceFilingClassifier {

    /// Cap on files classified per scan, so a huge loose folder can't spin the model for minutes.
    /// On-device runs ~5s/file once warm, so this bounds a scan to a couple of minutes worst case.
    private static let maxFiles = 25
    /// Characters of a document excerpt in the prompt: enough to judge, small enough to be fast.
    private static let maxSnippetChars = 1_200

    /// A session kept warm so the first real classification skips the cold model load (about 27 s
    /// cold against 5 s warm). Set by `prewarm()`. Main-actor isolated so concurrent prewarms can't
    /// race on it; `classify` builds a fresh session per file and never reads it.
    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @MainActor private static var warmSession: LanguageModelSession? {
        get { _warmSession as? LanguageModelSession }
        set { _warmSession = newValue }
    }
    @MainActor private static var _warmSession: AnyObject?
    #endif

    /// Loads the on-device model in the background so a later scan doesn't pay the cold start.
    /// Safe to call repeatedly; a no-op when the model isn't available. Callable from anywhere (the
    /// manager's prewarm seam is a `@Sendable` sync closure); the hop puts the session on the main
    /// actor, where it lives.
    ///
    /// Availability is asked off the main thread, because the probe can block for seconds after a
    /// macOS update. `isAvailable` is the probe; tests pass their own and await the returned task.
    @discardableResult
    static func prewarm(isAvailable probe: @escaping @Sendable () -> Bool = { isAvailable })
        -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            guard probe() else { return }
            await warm()
        }
    }

    @MainActor private static func warm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if warmSession == nil { warmSession = LanguageModelSession() }
            warmSession?.prewarm()
        }
        #endif
    }

    // MARK: Pure prompt shaping / verdict mapping (unit-testable without the model)

    /// The system instructions handed to every on-device session. A stored constant, not a local in
    /// `classifyOnDevice`, so tests can check it without FoundationModels.
    static let onDeviceInstructions = """
    You organize a user's files into their EXISTING folder structure. You are given the list of \
    folders they already keep and one file. Choose the single best-fitting folder.

    Rules:
    • Strongly prefer an existing folder from the list — copy its path exactly.
    • When several folders on the list fit, choose the MOST SPECIFIC one — the deepest path that is \
    still right. A parent is the answer only when none of its children fit. If the list has both \
    "Immigration/Visa/US" and "Immigration/Visa/US/H-1B Visa/2024-2026" and the document is an H-1B \
    visa issued in that period, the answer is the second.
    • Only if nothing existing fits, propose a NEW subfolder under the most appropriate existing \
    parent (e.g. an existing "Documents/Vehicles" → "Documents/Vehicles/Car Two") — and say so by \
    setting createsNewFolder to true. Copying a path from the list means createsNewFolder is false. \
    Never append the file's own name, or any file name, as a folder.
    • Reason about meaning, people's names, and document type — not just matching words.
    • If you genuinely cannot tell, answer with the folder "none".
    Always answer with a path relative to the folder list — never an absolute path.
    """

    /// How much of each input a prompt attempt is allowed. The on-device model's context window is
    /// small and shared with its output, so an attempt that doesn't fit is a budget to shrink, not
    /// an error: a skip would silently leave the file on its filename-derived home.
    ///
    /// The folder list is ordered most-deserving-first by ``FilingEngine/classifierFolders``, so
    /// truncating it drops the least plausible destinations and keeps every router shortlist.
    struct PromptBudget: Sendable, Equatable {
        let folders: Int
        let snippetChars: Int

        /// Tried in order; the first that fits wins.
        static let ladder = [PromptBudget(folders: 160, snippetChars: 1_200),
                             PromptBudget(folders: 80, snippetChars: 400),
                             PromptBudget(folders: 40, snippetChars: 0)]
    }

    /// The per-file prompt `pick` sends to the model: pure string shaping (folder list, file facts,
    /// bounded excerpt, rejected folders), so tests can check it.
    static func promptText(for file: FilingCandidateFile, folderList: String,
                           budget: PromptBudget = PromptBudget.ladder[0]) -> String {
        let folders = folderList.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(budget.folders).joined(separator: "\n")
        var prompt = """
        Existing folders (relative paths):
        \(folders)

        File name: \(file.fileName)
        Type: \(file.ext.isEmpty ? "unknown" : file.ext)
        """
        if let year = file.year { prompt += "\nModified: \(year)" }
        if budget.snippetChars > 0, let snippet = file.contentSnippet, !snippet.isEmpty {
            prompt += "\n\nContent excerpt:\n\(String(snippet.prefix(min(budget.snippetChars, maxSnippetChars))))"
        }
        if !file.excludedRelativePaths.isEmpty {
            prompt += "\n\nThe user already rejected these folders — do NOT choose them, pick a different one: "
                + file.excludedRelativePaths.joined(separator: ", ")
        }
        prompt += "\n\nWhich folder should this file go in?"
        return prompt
    }

    /// Maps a model answer (folder, 0–100 confidence, reason) to a Sync verdict, or nil when it
    /// declined ("none" or empty). `FolderPick.asVerdict()` delegates here so the mapping can be
    /// tested on any OS without a `@Generable` value.
    static func verdict(folder: String, confidence: Int, reason: String,
                        proposesNewFolder: Bool = false) -> FilingVerdict? {
        let cleaned = folder
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !cleaned.isEmpty, cleaned.lowercased() != "none" else { return nil }
        let score = max(0, min(100, confidence))
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return FilingVerdict(relativePath: cleaned,
                             confidence: FilingVerdict.confidence(fromScore: score),
                             reason: why.isEmpty ? "Chosen by on-device AI" : why,
                             proposesNewFolder: proposesNewFolder)
    }

    /// Whether on-device classification can run right now (framework present, OS new enough, model
    /// downloaded and enabled). Not cheap: it can block for seconds after a macOS update, so ask it
    /// off the main thread, as the classifier's async closure and `prewarm()` do.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// The seam the manager injects. Returns a verdict per `filePath`; declines (omits) files it's
    /// unsure about so they keep their heuristic suggestion.
    static func classify(taxonomyFolders: [String], files: [FilingCandidateFile]) async -> [String: FilingVerdict] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await classifyOnDevice(taxonomyFolders: taxonomyFolders, files: files)
        }
        #endif
        return [:]
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func classifyOnDevice(taxonomyFolders: [String], files: [FilingCandidateFile]) async -> [String: FilingVerdict] {
        guard case .available = SystemLanguageModel.default.availability else {
            // The caller gates on `isAvailable`, so the model went away since. Every file is about
            // to get no answer for one reason, so log one line for the batch, naming the state.
            Logger.shared.warning("On-device Filing unavailable "
                                  + "(\(SystemLanguageModel.default.availability)) — skipping "
                                  + "\(files.count) file(s)")
            return [:]
        }
        guard !taxonomyFolders.isEmpty else { return [:] }

        let folderList = taxonomyFolders.joined(separator: "\n")
        let instructions = onDeviceInstructions

        var verdicts: [String: FilingVerdict] = [:]
        let batch = files.prefix(maxFiles)
        Logger.shared.info("On-device Filing: classifying \(batch.count) file(s) against \(taxonomyFolders.count) folder(s)")
        // Kept only to name a systemic cause below; `pick` reports each file's declination.
        var lastFailure: Error?
        var declined = 0
        for file in batch {
            if Task.isCancelled { break }
            let outcome = await pick(file: file, folderList: folderList, instructions: instructions)
            if let verdict = outcome.verdict {
                verdicts[file.filePath] = verdict
                continue
            }
            declined += 1
            lastFailure = outcome.failure ?? lastFailure
        }
        Logger.shared.info("On-device Filing: model chose a home for \(verdicts.count) of \(batch.count) file(s)"
                           + (files.count > maxFiles ? " (capped from \(files.count))" : ""))
        // One file declining is routine; every file declining is a fault. `pick` logs at debug,
        // which the default level drops, so name a systemic cause once for the batch. Not after a
        // cancel: the loop breaks on it, and the warning would blame the model for an interrupted
        // batch.
        if verdicts.isEmpty, declined > 0, !Task.isCancelled, let lastFailure {
            Logger.shared.warning("On-device Filing: the model placed none of \(declined) file(s) — "
                                  + "last cause: \(lastFailure.localizedDescription)")
        }
        return verdicts
    }

    /// One file's answer, plus the error behind a declination, so `classifyOnDevice` can tell a
    /// batch where every file was declined.
    ///
    /// A declination always carries its error: the last rung fails the `attempt < count - 1` guard
    /// and returns, and `ladder` is non-empty, so the tail after the loop is unreachable. If it
    /// ever became reachable, the batch warning would go quiet rather than wrong.
    @available(macOS 26.0, *)
    private static func pick(file: FilingCandidateFile, folderList: String,
                             instructions: String) async -> (verdict: FilingVerdict?, failure: Error?) {
        // Walk the budget ladder: a prompt that doesn't fit the context window is retried smaller,
        // not abandoned (see ``PromptBudget``).
        for (attempt, budget) in PromptBudget.ladder.enumerated() {
            do {
                // A fresh session per file keeps each decision independent (no transcript bleed).
                let session = LanguageModelSession(instructions: instructions)
                let prompt = promptText(for: file, folderList: folderList, budget: budget)
                let response = try await session.respond(to: prompt, generating: FolderPick.self)
                if attempt > 0 {
                    Logger.shared.info("On-device Filing: “\(file.fileName)” needed a smaller prompt "
                                       + "(\(budget.folders) folder(s), \(budget.snippetChars) excerpt chars)")
                }
                return (response.content.asVerdict(), nil)
            } catch {
                guard isContextOverflow(error), attempt < PromptBudget.ladder.count - 1 else {
                    // Per-file and routine (the model declines some files), so debug. The error
                    // travels back so a batch that declined every file can say why once.
                    Logger.shared.debug("On-device Filing skipped “\(file.fileName)”: \(error.localizedDescription)")
                    return (nil, error)
                }
            }
        }
        // Unreachable (see the note on this method), but the compiler can't prove it.
        return (nil, nil)
    }

    /// Whether an error means "the prompt was too long" rather than "the model declined". Matched
    /// on the message, not a typed case, because OS updates report it differently; a false match
    /// costs only one smaller retry, a miss silently keeps a wrong home.
    static func isContextOverflow(_ error: Error) -> Bool {
        let text = "\(error) \(error.localizedDescription)".lowercased()
        return text.contains("context window") || text.contains("context length")
            || text.contains("too many tokens")
    }
    #endif
}

#if canImport(FoundationModels)
/// The structured answer the model must produce (guided generation guarantees the shape).
@available(macOS 26.0, *)
@Generable
struct FolderPick {
    @Guide(description: "Destination folder as a relative path that exactly matches one from the folder list, OR a new subfolder path under an existing parent, OR the single word 'none' if you are unsure.")
    var folder: String
    @Guide(description: "Confidence from 0 to 100 that this is the correct folder.")
    var confidence: Int
    @Guide(description: "One short sentence explaining the choice.")
    var reason: String
    @Guide(description: "true ONLY if this folder does not exist yet and you are proposing it; false when copying a path from the list.")
    var createsNewFolder: Bool
}

@available(macOS 26.0, *)
extension FolderPick {
    /// Maps the model's answer to a Sync verdict, or nil when it declined ("none"/empty).
    /// The mapping itself lives in `OnDeviceFilingClassifier.verdict` so it's unit-testable
    /// without FoundationModels.
    func asVerdict() -> FilingVerdict? {
        OnDeviceFilingClassifier.verdict(folder: folder, confidence: confidence, reason: reason,
                                         proposesNewFolder: createsNewFolder)
    }
}
#endif
