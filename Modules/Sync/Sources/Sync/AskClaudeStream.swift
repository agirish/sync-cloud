import Foundation

/// Turns the Messages API’s server-sent events into one finished response (RD69).
///
/// **It reads `data:` lines and nothing else.** Every Anthropic event carries its whole payload,
/// type included, on a single `data:` line, so the `event:` line and the blank line that ends an
/// event add nothing. Keying on the data line alone also keeps this correct when the line reader
/// drops blank lines, which a line-splitting byte stream is free to do.
///
/// **Blocks are kept as the API sent them**, every field included, because the next request must
/// send the assistant turn back unchanged: a thinking block’s signature, a fallback block, or a
/// block type this build has never heard of all have to survive the round trip. Only the deltas
/// this type knows how to apply are applied; everything else rides along untouched.
public struct AskClaudeStreamAccumulator: Sendable {

    /// What the panel can show while the response is still arriving.
    public enum Update: Equatable, Sendable {
        case text(String)
        case toolStarted(name: String)
        case thinking
    }

    public struct Failure: Error, Equatable, Sendable {
        public let type: String
        public let message: String
    }

    public private(set) var model: String?
    public private(set) var stopReason: String?
    public private(set) var usage = AskClaudeUsage()
    public private(set) var failure: Failure?
    public private(set) var finished = false
    /// Per-attempt usage when a fallback re-ran the request (`usage.iterations`): the top-level
    /// `usage` covers only the attempt that produced the message, so the cost reads these.
    public private(set) var iterations: [JSONFragment] = []
    /// Characters of text, thinking and tool input received, and whether the final usage (the
    /// `message_delta` that carries the output count) arrived: a stopped stream never gets it.
    public private(set) var streamedCharacters = 0
    public private(set) var hasFinalUsage = false

    private var blocks: [Int: [String: JSONFragment]] = [:]
    private var partialJSON: [Int: String] = [:]

    public init() {}

    /// Applies one line of the stream; returns what changed for the panel, if anything.
    public mutating func apply(line: String) -> Update? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, let data = payload.data(using: .utf8),
              let event = try? JSONFragment.decode(data) else { return nil }
        return apply(event: event)
    }

    public mutating func apply(event: JSONFragment) -> Update? {
        switch event["type"]?.stringValue {
        case "message_start":
            let message = event["message"]
            model = message?["model"]?.stringValue
            if let u = message?["usage"] { merge(usage: u) }
            return nil
        case "content_block_start":
            guard let index = event["index"]?.intValue, let block = event["content_block"]?.objectValue else { return nil }
            blocks[index] = block
            switch block["type"]?.stringValue {
            case "tool_use":
                partialJSON[index] = ""
                return .toolStarted(name: block["name"]?.stringValue ?? "a tool")
            case "thinking", "redacted_thinking":
                return .thinking
            case "text":
                let text = block["text"]?.stringValue ?? ""
                return text.isEmpty ? nil : .text(text)
            default:
                return nil
            }
        case "content_block_delta":
            guard let index = event["index"]?.intValue, let delta = event["delta"], var block = blocks[index] else { return nil }
            var update: Update?
            switch delta["type"]?.stringValue {
            case "text_delta":
                let piece = delta["text"]?.stringValue ?? ""
                streamedCharacters += piece.count
                block["text"] = .string((block["text"]?.stringValue ?? "") + piece)
                update = piece.isEmpty ? nil : .text(piece)
            case "thinking_delta":
                let piece = delta["thinking"]?.stringValue ?? ""
                streamedCharacters += piece.count
                block["thinking"] = .string((block["thinking"]?.stringValue ?? "") + piece)
            case "signature_delta":
                block["signature"] = .string((block["signature"]?.stringValue ?? "") + (delta["signature"]?.stringValue ?? ""))
            case "input_json_delta":
                let piece = delta["partial_json"]?.stringValue ?? ""
                streamedCharacters += piece.count
                partialJSON[index, default: ""] += piece
            default:
                break
            }
            blocks[index] = block
            return update
        case "content_block_stop":
            guard let index = event["index"]?.intValue, var block = blocks[index] else { return nil }
            if let json = partialJSON.removeValue(forKey: index) {
                // An empty string is a tool called with no arguments. Anything that doesn’t parse
                // is kept as an empty object: the tool’s own validation then refuses it and says
                // why, which is better than failing the whole turn.
                let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    block["input"] = .object([:])
                } else if let data = trimmed.data(using: .utf8), let input = try? JSONFragment.decode(data),
                          input.objectValue != nil {
                    block["input"] = input
                } else {
                    block["input"] = .object([:])
                }
            }
            blocks[index] = block
            return nil
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            if let u = event["usage"] {
                merge(usage: u)
                hasFinalUsage = true
            }
            return nil
        case "message_stop":
            finished = true
            return nil
        case "error":
            failure = Failure(type: event["error"]?["type"]?.stringValue ?? "error",
                              message: event["error"]?["message"]?.stringValue ?? "The stream reported an error.")
            return nil
        default:
            // `ping`, and any event type added after this was written.
            return nil
        }
    }

    /// For a round that ended before its final usage: the output it streamed, at about four
    /// characters a token, so a stopped answer's output still counts toward the limit.
    public mutating func estimateUnreportedOutput() {
        guard !hasFinalUsage else { return }
        usage.outputTokens = max(usage.outputTokens, streamedCharacters / 4)
    }

    private mutating func merge(usage u: JSONFragment) {
        usage.merge(u)
        if let list = u["iterations"]?.arrayValue { iterations = list }
    }

    /// The assistant turn’s content, in the order the API numbered it, ready to send back.
    ///
    /// **After a mid-answer fallback, the declined model's reasoning and tool calls are left out**:
    /// the API asks that `thinking`, `redacted_thinking` and `tool_use` blocks before the last
    /// `fallback` block not be echoed, and a tool call the declined model planned must not run.
    public var content: [JSONFragment] {
        let ordered = blocks.keys.sorted().compactMap { blocks[$0].map(JSONFragment.object) }
        guard let boundary = ordered.lastIndex(where: { $0["type"]?.stringValue == "fallback" }) else { return ordered }
        // Before it, only text echoes (and the marker itself): the declined model's thinking, its
        // tool calls and any block type this build doesn't know stay out, as the API asks.
        let echoed: Set<String> = ["text", "fallback"]
        return ordered.enumerated().compactMap { index, block in
            index < boundary && !echoed.contains(block["type"]?.stringValue ?? "") ? nil : block
        }
    }

    /// The tool calls in this turn.
    public var toolCalls: [AskClaudeToolCall] {
        content.compactMap { block in
            guard block["type"]?.stringValue == "tool_use",
                  let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return nil }
            return AskClaudeToolCall(id: id, name: name, input: block["input"] ?? .object([:]))
        }
    }

    /// The visible text of this turn, joined.
    public var text: String {
        content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
    }
}

/// One `tool_use` block, as the tool runner needs it.
public struct AskClaudeToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    public let input: JSONFragment

    public init(id: String, name: String, input: JSONFragment) {
        self.id = id
        self.name = name
        self.input = input
    }

    /// A string argument, if the call carries one.
    public func string(_ key: String) -> String? {
        input[key]?.stringValue
    }

    public func strings(_ key: String) -> [String]? {
        input[key]?.arrayValue?.compactMap(\.stringValue)
    }

    public func int(_ key: String) -> Int? {
        input[key]?.intValue
    }
}
