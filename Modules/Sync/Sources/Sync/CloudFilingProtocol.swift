import Foundation

/// Pure request/response shaping for the opt-in **cloud** Filing classifier (Anthropic Messages
/// API). Kept in Sync with no networking so it's unit-testable; the app performs the actual HTTPS
/// call with these pieces. One request classifies a whole batch of files against the folder
/// taxonomy — far cheaper and more consistent than one call per file.
public enum CloudFilingProtocol {
    /// Default model. Opus-tier for the accuracy the whole cloud pass exists to provide.
    public static let defaultModel = "claude-opus-4-8"
    public static let apiVersion = "2023-06-01"
    public static let endpoint = "https://api.anthropic.com/v1/messages"
    public static let toolName = "file_placements"

    private static let maxSnippetChars = 800

    /// The JSON request body (a plain dictionary ready for `JSONSerialization`). Forces a single
    /// structured tool call so the response is guaranteed to be the placement array.
    public static func requestBody(model: String = defaultModel, taxonomyFolders: [String],
                                   files: [FilingCandidateFile]) -> [String: Any] {
        let instructions = """
        You organize a user's files into their EXISTING folder structure. You will be given the \
        folders they already keep and a numbered list of files. For each file choose the single \
        best-fitting folder.

        Rules:
        • Strongly prefer an existing folder from the list — copy its relative path exactly.
        • Only if nothing existing fits, propose a NEW subfolder under the most appropriate existing \
        parent (e.g. an existing "Documents/Vehicles" → "Documents/Vehicles/Tesla").
        • Reason about meaning, people's names, vendors, and document type — not just matching words.
        • If you genuinely cannot tell, use the folder "none".
        Always answer with paths relative to the folder list — never absolute paths.
        """
        // The folder taxonomy is stable per provider — put it in a cached system block so repeated
        // scans reuse it at cache-read rates instead of re-billing the full list each time.
        let folderBlock = "The user's existing folders (relative paths):\n"
            + taxonomyFolders.joined(separator: "\n")

        var userText = "Files to file:\n"
        for (i, f) in files.enumerated() {
            userText += "[\(i)] name: \(f.fileName) | type: \(f.ext.isEmpty ? "unknown" : f.ext)"
            if let year = f.year { userText += " | modified: \(year)" }
            userText += "\n"
            // Spend tokens on a content excerpt ONLY when the filename says nothing (no salient
            // tokens). A meaningful name + the folder list is enough for the model to reason, and
            // excerpts otherwise dominate the request cost.
            if let snippet = f.contentSnippet, !snippet.isEmpty,
               !FilingEngine.canRemember(fileName: f.fileName) {
                userText += "    excerpt: \(String(snippet.prefix(maxSnippetChars)).replacingOccurrences(of: "\n", with: " "))\n"
            }
        }
        userText += "\nReturn one placement per file, keyed by its index."

        let tool: [String: Any] = [
            "name": toolName,
            "description": "Return the best destination folder for each file.",
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": [
                    "placements": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "index": ["type": "integer", "description": "the file's index from the list"],
                                "folder": ["type": "string", "description": "relative folder path exactly from the list, a new subpath under an existing parent, or the word none"],
                                "confidence": ["type": "integer", "description": "0 to 100"],
                                "reason": ["type": "string", "description": "one short sentence"],
                            ],
                            "required": ["index", "folder", "confidence", "reason"],
                            "additionalProperties": false,
                        ],
                    ],
                ],
                "required": ["placements"],
                "additionalProperties": false,
            ],
        ]

        return [
            "model": model,
            "max_tokens": min(8192, 512 + files.count * 80),
            "system": [
                ["type": "text", "text": instructions],
                ["type": "text", "text": folderBlock, "cache_control": ["type": "ephemeral"]],
            ],
            "messages": [["role": "user", "content": userText]],
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": toolName],
        ]
    }

    /// Parses the Anthropic response into verdicts keyed by `filePath`. Returns nil when the response
    /// is an error or an unreadable shape (so the caller falls back to the on-device backend); an
    /// empty dictionary means the model placed nothing.
    public static func parseVerdicts(responseData: Data, files: [FilingCandidateFile]) -> [String: FilingVerdict]? {
        guard let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else { return nil }
        if (root["type"] as? String) == "error" { return nil }
        guard let content = root["content"] as? [[String: Any]] else { return nil }
        guard let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" && ($0["name"] as? String) == toolName }),
              let input = toolUse["input"] as? [String: Any],
              let placements = input["placements"] as? [[String: Any]] else { return nil }

        var out: [String: FilingVerdict] = [:]
        for placement in placements {
            guard let index = placement["index"] as? Int, index >= 0, index < files.count else { continue }
            let folder = (placement["folder"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folder.isEmpty, folder.lowercased() != "none" else { continue }
            let score = max(0, min(100, placement["confidence"] as? Int ?? 0))
            let reason = (placement["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            out[files[index].filePath] = FilingVerdict(
                relativePath: folder,
                confidence: FilingVerdict.confidence(fromScore: score),
                reason: (reason?.isEmpty == false ? reason! : "Chosen by Claude"))
        }
        return out
    }
}
