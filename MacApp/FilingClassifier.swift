import Foundation
import Sync
import Events
#if canImport(FoundationModels)
import FoundationModels
#endif

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
    /// load (measured ~27s cold vs ~5s warm). Set by `prewarm()`.
    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static var warmSession: LanguageModelSession? {
        get { _warmSession as? LanguageModelSession }
        set { _warmSession = newValue }
    }
    nonisolated(unsafe) private static var _warmSession: AnyObject?
    #endif

    /// Loads the on-device model in the background so a subsequent scan doesn't pay the cold start.
    /// Safe to call repeatedly; a no-op when the model isn't available.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return }
            if warmSession == nil { warmSession = LanguageModelSession() }
            warmSession?.prewarm()
        }
        #endif
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
        let instructions = """
        You organize a user's files into their EXISTING folder structure. You are given the list of \
        folders they already keep and one file. Choose the single best-fitting folder.

        Rules:
        • Strongly prefer an existing folder from the list — copy its path exactly.
        • Only if nothing existing fits, propose a NEW subfolder under the most appropriate existing \
        parent (e.g. an existing "Documents/Vehicles" → "Documents/Vehicles/Tesla").
        • Reason about meaning, people's names, and document type — not just matching words.
        • If you genuinely cannot tell, answer with the folder "none".
        Always answer with a path relative to the folder list — never an absolute path.
        """

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
        var prompt = """
        Existing folders (relative paths):
        \(folderList)

        File name: \(file.fileName)
        Type: \(file.ext.isEmpty ? "unknown" : file.ext)
        """
        if let year = file.year { prompt += "\nModified: \(year)" }
        if let snippet = file.contentSnippet, !snippet.isEmpty {
            prompt += "\n\nContent excerpt:\n\(String(snippet.prefix(maxSnippetChars)))"
        }
        if !file.excludedRelativePaths.isEmpty {
            prompt += "\n\nThe user already rejected these folders — do NOT choose them, pick a different one: "
                + file.excludedRelativePaths.joined(separator: ", ")
        }
        prompt += "\n\nWhich folder should this file go in?"

        do {
            // A fresh session per file keeps each decision independent (no transcript bleed).
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: FolderPick.self)
            return response.content.asVerdict()
        } catch {
            Logger.shared.info("On-device Filing skipped “\(file.fileName)”: \(error.localizedDescription)")
            return nil
        }
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
    func asVerdict() -> FilingVerdict? {
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
}
#endif
