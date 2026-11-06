import Foundation

/// Pure request/response shaping for the opt-in **cloud** Filing classifier (Anthropic Messages
/// API). In Sync with no networking so it's unit-testable; the app makes the HTTPS call with these
/// pieces. One request classifies a whole batch of files against the folder taxonomy, far cheaper
/// and more consistent than one call per file.
public enum CloudFilingProtocol {
    /// Default model, Haiku: capable for folder classification and roughly a penny a scan. Switch
    /// to Sonnet/Opus in Settings for harder cases.
    public static let defaultModel = "claude-haiku-4-5"

    /// The models Settings offers, cheapest first: id and the label the picker shows, in one list so
    /// the two can't drift apart and leave the picker blank. Labels name the generation, not just
    /// the family: this is the only place the app says which Claude a scan will run on.
    public static let selectableModelOptions: [(id: String, label: String)] = [
        ("claude-haiku-4-5", "Haiku 4.5 — cheapest (default)"),
        ("claude-sonnet-5", "Sonnet 5 — balanced"),
        ("claude-opus-5", "Opus 5 — best quality"),
    ]

    /// Just the ids, in the same order, for the family-resolution and validation paths.
    public static let selectableModels = selectableModelOptions.map(\.id)
    /// The version of the question asked about a file, not just of the words in this file.
    ///
    /// It is part of ``FilingVerdictKey``, so bumping it invalidates every cached verdict and the
    /// next scan re-asks. **Bump it whenever anything changes what the backend is shown or how its
    /// answer is judged**: the instruction block, the `input_schema`, which folders the menu
    /// carries, whether the file's text is included, or how a verdict is arbitrated. Several of
    /// these are assembled outside this file. A cached answer to the old question would silently
    /// keep the change from taking effect. Wording that can't change a verdict needs no bump; when
    /// unsure, bump: the cost is one scan's worth of re-asking.
    public static let promptVersion = 7

    public static let apiVersion = "2023-06-01"
    public static let endpoint = "https://api.anthropic.com/v1/messages"
    public static let toolName = "file_placements"

    static let maxSnippetChars = 800

    /// Maps a stored model ID onto the currently offered model of the same family. An older id (say
    /// `claude-opus-4-8`) would leave the Settings picker with no selection and pin every scan to a
    /// superseded model; resolved here, "the user picked Opus" keeps meaning today's Opus.
    ///
    /// A model outside the three families is left alone, as a deliberate hand-set choice. A dated
    /// snapshot within a family (`claude-haiku-4-5-20251001`) is still rewritten to the family's
    /// current alias, as `CloudFilingProtocolTests` pins.
    public static func currentModel(for stored: String) -> String {
        if selectableModels.contains(stored) { return stored }
        return selectableModels.first { current in
            // "claude-opus-4-8" and "claude-opus-5" share the "claude-opus" family prefix.
            let family = current.split(separator: "-").prefix(2).joined(separator: "-")
            return stored.hasPrefix(family + "-")
        } ?? stored
    }

    /// The JSON request body, a plain dictionary for `JSONSerialization`. Forces a single structured
    /// tool call so the response is the placement array.
    public static func requestBody(model: String = defaultModel, taxonomyFolders: [String],
                                   files: [FilingCandidateFile]) -> [String: Any] {
        let instructions = """
        You organize a user's files into their EXISTING folder structure. You will be given the \
        folders they already keep and a numbered list of files. For each file choose the single \
        best-fitting folder.

        Rules:
        • Strongly prefer an existing folder from the list — copy its relative path exactly.
        • When several folders on the list fit, choose the MOST SPECIFIC one — the deepest path that \
        is still right. A parent is the answer only when none of its children fit. If the list has \
        both "Immigration/Visa/US" and "Immigration/Visa/US/H-1B Visa/2024-2026" and the document is \
        an H-1B visa issued in that period, the answer is the second.
        • Only if nothing existing fits, propose a NEW subfolder under the most appropriate existing \
        parent (e.g. an existing "Documents/Vehicles" → "Documents/Vehicles/Tesla") — and say so by \
        setting createsNewFolder to true. Copying a path from the list means createsNewFolder is \
        false. Never append the file's own name, or any file name, as a folder.
        • Reason about meaning, people's names, vendors, and document type — not just matching words.
        • If a file lists "avoid" folders, the user already rejected those — never choose them; pick a genuinely different folder.
        • If you genuinely cannot tell, use the folder "none".
        Always answer with paths relative to the folder list — never absolute paths.
        """
        // The folder taxonomy is stable per provider, so it rides in a system block marked for
        // prompt caching. The breakpoint goes on the last system block: the cache prefix renders
        // tools → system → messages, so one marker there covers the tool schema too.
        //
        // A full 250-folder request is about 2,200 tokens, under Haiku 4.5's 4096-token minimum
        // (our `defaultModel`) but over Sonnet 5's and Opus 5's. So on the default model `usage`
        // reports zero cache tokens: the API declining a short prefix, not a bug. The TTL is
        // 5 minutes, so scans minutes apart mostly find a cold cache anyway.
        let folderBlock = "The user's existing folders (relative paths):\n"
            + taxonomyFolders.joined(separator: "\n")

        var userText = "Files to file:\n"
        for (i, f) in files.enumerated() {
            userText += "[\(i)] name: \(f.fileName) | type: \(f.ext.isEmpty ? "unknown" : f.ext)"
            if let year = f.year { userText += " | modified: \(year)" }
            userText += "\n"
            // Every excerpt the caller supplies is sent. The cost worth controlling is reading the
            // file, which the caller decides; filtering here again would throw away text the scan
            // already has and send the model a bare filename.
            if let snippet = f.contentSnippet, !snippet.isEmpty {
                userText += "    excerpt: \(String(snippet.prefix(maxSnippetChars)).replacingOccurrences(of: "\n", with: " "))\n"
            }
            if !f.excludedRelativePaths.isEmpty {
                userText += "    avoid: \(f.excludedRelativePaths.joined(separator: ", "))\n"
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
                                "createsNewFolder": ["type": "boolean", "description": "true ONLY if this folder does not exist yet and you are proposing it; false when copying a path from the list"],
                            ],
                            "required": ["index", "folder", "confidence", "reason", "createsNewFolder"],
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
            // Budget ~80 output tokens per placement (index + folder + confidence + one-sentence
            // reason). The ceiling covers a full maxFiles=150 batch (512 + 150*80 ≈ 12.5k) so
            // large scans don't hit stop_reason "max_tokens" and lose the tail; 16k stays well
            // under every configured model's output cap (Haiku 4.5 64k, Sonnet 5 / Opus 5 128k).
            "max_tokens": min(16384, 512 + files.count * 80),
            "system": [
                ["type": "text", "text": instructions],
                ["type": "text", "text": folderBlock, "cache_control": ["type": "ephemeral"]],
            ],
            "messages": [["role": "user", "content": userText]],
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": toolName],
        ]
    }

    /// Parses the Anthropic response into verdicts keyed by `filePath`. nil for an error or an
    /// unreadable shape, so the caller falls back to the on-device backend; an empty dictionary
    /// means the model placed nothing.
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
                reason: (reason?.isEmpty == false ? reason! : "Chosen by Claude"),
                proposesNewFolder: placement["createsNewFolder"] as? Bool ?? false)
        }
        return out
    }

    // MARK: Usage / cost accounting (for logging)

    /// Token usage reported by the API, split so cache reads/writes can be priced correctly.
    public struct Usage: Equatable, Sendable {
        public let inputTokens: Int          // uncached input, full rate
        public let outputTokens: Int
        public let cacheCreationTokens: Int  // written to cache (~1.25× input)
        public let cacheReadTokens: Int      // served from cache (~0.1× input)
        public var totalInputTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens }
        public init(inputTokens: Int, outputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int) {
            self.inputTokens = inputTokens; self.outputTokens = outputTokens
            self.cacheCreationTokens = cacheCreationTokens; self.cacheReadTokens = cacheReadTokens
        }
    }

    public static func parseUsage(responseData: Data) -> Usage? {
        guard let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { return nil }
        func n(_ key: String) -> Int { usage[key] as? Int ?? 0 }
        return Usage(inputTokens: n("input_tokens"), outputTokens: n("output_tokens"),
                     cacheCreationTokens: n("cache_creation_input_tokens"),
                     cacheReadTokens: n("cache_read_input_tokens"))
    }

    /// The response's `stop_reason` — "max_tokens" means placements were truncated.
    public static func stopReason(responseData: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])?["stop_reason"] as? String
    }

    /// The API error message, if the response is an error envelope.
    public static func errorMessage(responseData: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }
            .flatMap { $0["message"] as? String }
    }

    /// Approximate list price ($/million tokens) for a rough cost estimate; the Anthropic Console is
    /// the source of truth. nil for a model we have no rate for.
    ///
    /// Sonnet is priced by generation: Sonnet 5 is $2/$10, an older Sonnet id $3/$15 (only reached
    /// for such an id passed in directly; ``currentModel(for:)`` moves stored ones to Sonnet 5).
    /// These rates feed the spend caps as well as the log, so a family-wide rate would overcharge.
    public static func pricing(for model: String) -> (input: Double, output: Double)? {
        if model.hasPrefix("claude-opus") { return (5, 25) }
        if model.hasPrefix("claude-fable") || model.hasPrefix("claude-mythos") { return (10, 50) }
        if model == "claude-sonnet-5" || model.hasPrefix("claude-sonnet-5-") { return (2, 10) }
        if model.hasPrefix("claude-sonnet") { return (3, 15) }
        if model.hasPrefix("claude-haiku") { return (1, 5) }
        return nil
    }

    /// Estimated USD cost of a request from its usage, accounting for cache read/write rates.
    public static func estimatedCostUSD(model: String, usage: Usage) -> Double? {
        guard let price = pricing(for: model) else { return nil }
        let inPerToken = price.input / 1_000_000, outPerToken = price.output / 1_000_000
        return Double(usage.inputTokens) * inPerToken
            + Double(usage.cacheReadTokens) * inPerToken * 0.1
            + Double(usage.cacheCreationTokens) * inPerToken * 1.25
            + Double(usage.outputTokens) * outPerToken
    }

    // MARK: Pre-call estimate (for the spend guardrails / confirmation dialog)

    /// Rough fixed overhead (chars) for the parts of the request that don't vary with the input: the
    /// instruction block plus the tool schema JSON. The taxonomy and per-file lines are added on top.
    private static let requestOverheadChars = 1500

    /// A before-the-call token estimate for a batch, so the user sees a cost up front. Approximates
    /// the billable text `requestBody` assembles (the taxonomy plus one line per file, with every
    /// excerpt supplied) at ~4 chars/token, and reuses the body's `512 + files*80` output budget
    /// (capped at 16384). Deliberately a slight over-estimate (it ignores cache discounts), so it
    /// never undersells the cost.
    public static func estimateTokens(taxonomyFolders: [String], files: [FilingCandidateFile]) -> (input: Int, output: Int) {
        var chars = requestOverheadChars
        chars += "The user's existing folders (relative paths):\n".count
        for folder in taxonomyFolders { chars += folder.count + 1 }
        for f in files {
            // "[i] name: <name> | type: <ext>\n" scaffolding.
            chars += f.fileName.count + max(f.ext.count, "unknown".count) + 24
            if let year = f.year { chars += year.count + 14 }               // " | modified: <year>"
            if let snippet = f.contentSnippet, !snippet.isEmpty {
                chars += min(snippet.count, maxSnippetChars) + 14           // "    excerpt: …"
            }
            if !f.excludedRelativePaths.isEmpty {
                chars += f.excludedRelativePaths.joined(separator: ", ").count + 12   // "    avoid: …"
            }
        }
        let input = max(1, chars / 4)
        let output = min(16384, 512 + files.count * 80)
        return (input, output)
    }

    /// Estimated USD cost of a batch BEFORE it runs, from the pre-call token estimate at list prices.
    /// nil when the model has no known rate (so the caller shows "estimate unavailable" rather than a
    /// wrong number). No cache-rate adjustment: the estimate can't know what will be cache-hit.
    public static func estimatedCostUSD(model: String, taxonomyFolders: [String], files: [FilingCandidateFile]) -> Double? {
        guard let price = pricing(for: model) else { return nil }
        let est = estimateTokens(taxonomyFolders: taxonomyFolders, files: files)
        return Double(est.input) * price.input / 1_000_000
            + Double(est.output) * price.output / 1_000_000
    }
}
