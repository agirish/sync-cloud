import Foundation
import Sync
import Events
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which backend the hybrid Filing classifier runs a scan on, and — for the one case where the
/// user's expectation and the reality diverge — whether that divergence has to be reported.
enum FilingBackendRoute: Equatable {
    /// Cloud (Claude) Filing is on and a key is available: the cloud backend is primary.
    case cloud
    /// Cloud Filing is off: the on-device model is the intended backend, nothing to report.
    case onDevice
    /// Cloud Filing is ON but no usable API key could be read, so the scan silently downgrades
    /// to the on-device model. The user believes Claude is filing their documents — this case
    /// exists so that belief is corrected in the Activity Log rather than left standing.
    case onDeviceCloudKeyUnavailable
}

/// Picks the Filing backend for one scan. Split out of `SyncCloudApp`'s classifier closure so the
/// gate — and above all the downgrade breadcrumb — is testable: the pre-extraction closure fell
/// through to the on-device model with no log at all when the cloud toggle was on but the key was
/// missing or the Keychain locked, which is indistinguishable from a normal cloud run in the log.
enum FilingBackendRouter {

    /// The user-facing explanation of a cloud→on-device downgrade. Kept next to the route so the
    /// wording and the condition that emits it can't drift apart.
    static let missingKeyDowngradeMessage =
        "Cloud (Claude) Filing is enabled, but no API key could be read from the Keychain — "
        + "this scan used the free on-device model instead. Re-enter the key in Settings → Organize."

    /// Resolves the backend, reporting the silent downgrade through `logDowngrade` (which defaults
    /// to a real `Logger.shared` warning; tests inject a recorder so the pin doesn't depend on the
    /// process-wide log gate).
    ///
    /// `hasCloudKey` is an `@autoclosure` so that answering it stays as lazy as the `if` this
    /// routing replaced. The real argument is `AnthropicKeychain.hasKey`, a live Keychain query:
    /// evaluated eagerly it ran on EVERY Filing scan, including the common case where the user has
    /// cloud Filing switched off — and against a locked or denied item that query logs a warning
    /// and can raise an access prompt for a feature they deliberately disabled. The cloud toggle
    /// is the gate; nothing may ask about the key before it says yes.
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
/// Foundation Models — the ~3B on-device Apple Intelligence model — to *reason* about the user's
/// folder taxonomy and each file's name/contents and pick a home, instead of keyword overlap.
///
/// Everything stays on the Mac; nothing is sent anywhere. On macOS < 26 or a Mac without Apple
/// Intelligence, `classify` returns no verdicts and Filing falls back to the keyword engine.
enum OnDeviceFilingClassifier {

    /// Cap on files classified per scan, so a huge loose folder can't spin the model for minutes.
    /// On-device runs ~5s/file once warm, so this bounds a scan to a couple of minutes worst case.
    private static let maxFiles = 25
    /// Chars of a document excerpt included in the prompt — enough to judge, small enough to be fast.
    private static let maxSnippetChars = 1_200

    /// A retained session kept warm so the first real classification skips the ~cold-start model
    /// load (measured ~27s cold vs ~5s warm). Set by `prewarm()`. @MainActor-isolated: this was a
    /// `nonisolated(unsafe)` static — an unprotected global mutable that two concurrent prewarm
    /// calls could race — and nothing here needs it off the main actor (`classify` builds a fresh
    /// session per file and never reads it).
    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @MainActor private static var warmSession: LanguageModelSession? {
        get { _warmSession as? LanguageModelSession }
        set { _warmSession = newValue }
    }
    @MainActor private static var _warmSession: AnyObject?
    #endif

    /// Loads the on-device model in the background so a subsequent scan doesn't pay the cold start.
    /// Safe to call repeatedly; a no-op when the model isn't available. Callable from anywhere
    /// (the manager's prewarm seam is a @Sendable sync closure): the fire-and-forget hop puts the
    /// session touch on the main actor, where the storage lives.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return }
            Task { @MainActor in
                if warmSession == nil { warmSession = LanguageModelSession() }
                warmSession?.prewarm()
            }
        }
        #endif
    }

    // MARK: Pure prompt shaping / verdict mapping (unit-testable without the model)

    /// The system instructions handed to every on-device session. A stored constant (rather than a
    /// local in `classifyOnDevice`) so the prompt shaping is unit-testable without FoundationModels.
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
    parent (e.g. an existing "Documents/Vehicles" → "Documents/Vehicles/Tesla").
    • Reason about meaning, people's names, and document type — not just matching words.
    • If you genuinely cannot tell, answer with the folder "none".
    Always answer with a path relative to the folder list — never an absolute path.
    """

    /// How much of each input a prompt attempt is allowed. The on-device model's context window is
    /// small and shared with its output, so an attempt that does not fit is not an error to report —
    /// it is a budget to shrink.
    ///
    /// **A skip is the worst outcome, and it used to be the only one.** Once excerpts started being
    /// sent for files whose text was already in hand, a 244-folder menu plus a 1,200-character
    /// excerpt tipped a real T-Mobile bill over the window; the session threw, `pick` logged at
    /// debug and returned nil, and the file silently kept the filename-derived home the whole change
    /// existed to replace. Nothing above that line could tell "the model declined" from "the model
    /// was never asked".
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

    /// The per-file prompt `pick` sends to the model — pure string shaping (folder list, file
    /// facts, bounded content excerpt, rejected folders), extracted so it's unit-testable.
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

    /// Maps a model answer (folder / 0–100 confidence / reason) to a Sync verdict, or nil when it
    /// declined ("none"/empty). `FolderPick.asVerdict()` delegates here so the mapping is testable
    /// on any OS, without constructing a @Generable value.
    static func verdict(folder: String, confidence: Int, reason: String) -> FilingVerdict? {
        let cleaned = folder
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !cleaned.isEmpty, cleaned.lowercased() != "none" else { return nil }
        let score = max(0, min(100, confidence))
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return FilingVerdict(relativePath: cleaned,
                             confidence: FilingVerdict.confidence(fromScore: score),
                             reason: why.isEmpty ? "Chosen by on-device AI" : why)
    }

    /// Whether on-device classification can run right now (framework present, OS new enough, model
    /// downloaded and enabled). Cheap to call; used to gate the Settings toggle and injection.
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
        guard case .available = SystemLanguageModel.default.availability else { return [:] }
        guard !taxonomyFolders.isEmpty else { return [:] }

        let folderList = taxonomyFolders.joined(separator: "\n")
        let instructions = onDeviceInstructions

        var verdicts: [String: FilingVerdict] = [:]
        let batch = files.prefix(maxFiles)
        Logger.shared.info("On-device Filing: classifying \(batch.count) file(s) against \(taxonomyFolders.count) folders")
        for file in batch {
            if Task.isCancelled { break }
            guard let verdict = await pick(file: file, folderList: folderList, instructions: instructions) else { continue }
            verdicts[file.filePath] = verdict
        }
        Logger.shared.info("On-device Filing: model chose a home for \(verdicts.count) of \(batch.count) file(s)"
                           + (files.count > maxFiles ? " (capped from \(files.count))" : ""))
        return verdicts
    }

    @available(macOS 26.0, *)
    private static func pick(file: FilingCandidateFile, folderList: String, instructions: String) async -> FilingVerdict? {
        // Walk the budget ladder: a prompt that does not fit the context window is retried smaller
        // rather than abandoned. See ``PromptBudget`` for why abandoning it is the worst outcome.
        for (attempt, budget) in PromptBudget.ladder.enumerated() {
            do {
                // A fresh session per file keeps each decision independent (no transcript bleed).
                let session = LanguageModelSession(instructions: instructions)
                let prompt = promptText(for: file, folderList: folderList, budget: budget)
                let response = try await session.respond(to: prompt, generating: FolderPick.self)
                if attempt > 0 {
                    Logger.shared.info("On-device Filing: “\(file.fileName)” needed a smaller prompt "
                                       + "(\(budget.folders) folders, \(budget.snippetChars) excerpt chars)")
                }
                return response.content.asVerdict()
            } catch {
                guard isContextOverflow(error), attempt < PromptBudget.ladder.count - 1 else {
                    // Per-file, benign, and routine (the model declines some files) — a diagnostic
                    // detail, not an operational event. Debug keeps it out of the default log.
                    Logger.shared.debug("On-device Filing skipped “\(file.fileName)”: \(error.localizedDescription)")
                    return nil
                }
            }
        }
        return nil
    }

    /// Whether an error means "the prompt was too long" rather than "the model declined".
    ///
    /// Matched on the message rather than a typed case: the two are reported differently across
    /// OS updates, and the cost of being wrong in either direction is one retry with a smaller
    /// prompt — against silently keeping a wrong home, which is what the typed-case-only version
    /// did the day the window was first exceeded.
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
}

@available(macOS 26.0, *)
extension FolderPick {
    /// Maps the model's answer to a Sync verdict, or nil when it declined ("none"/empty).
    /// The mapping itself lives in `OnDeviceFilingClassifier.verdict` so it's unit-testable
    /// without FoundationModels.
    func asVerdict() -> FilingVerdict? {
        OnDeviceFilingClassifier.verdict(folder: folder, confidence: confidence, reason: reason)
    }
}
#endif
