import Foundation

/// The models Ask Claude offers, what each costs, and how a response’s `usage` turns into a cost
/// estimate.
///
/// Its own table, not `CloudFilingProtocol`’s: Filing prices by family prefix and forces one
/// tool, which the 5.5 models refuse (a forced `tool_choice` is a 400 on Opus 5.5 and Sonnet 5.5).
/// Ask Claude lets the model choose its tools, so it can offer the current models; the two pickers
/// stay separate rows in Settings ▸ Intelligence and share only the key.
public enum AskClaudeModels {

    /// List prices in US dollars per million tokens. The Console is authoritative; these only feed
    /// the per-reply estimate and the monthly limit.
    public struct Price: Equatable, Sendable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double
        /// Above `longPromptThreshold` prompt tokens, where a model has a higher tier (Haiku 5.5:
        /// above 100K, five times the rate), every rate is multiplied by `longPromptMultiplier`.
        public var longPromptThreshold: Int?
        public var longPromptMultiplier = 1.0

        public init(input: Double, output: Double, cacheRead: Double, longPromptThreshold: Int? = nil, longPromptMultiplier: Double = 1) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.longPromptThreshold = longPromptThreshold
            self.longPromptMultiplier = longPromptMultiplier
        }

        /// The rate a prompt of this size is billed at.
        public func forPrompt(_ tokens: Int) -> Price {
            guard let longPromptThreshold, tokens > longPromptThreshold else { return self }
            return Price(input: input * longPromptMultiplier, output: output * longPromptMultiplier,
                         cacheRead: cacheRead * longPromptMultiplier)
        }

        /// Writing a cache entry costs a multiple of the input price: 1.25× for the 5-minute TTL,
        /// 2× for the 1-hour TTL Ask Claude asks for.
        public static let fiveMinuteWriteMultiplier = 1.25
        public static let oneHourWriteMultiplier = 2.0
    }

    public struct Option: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        /// How the model names itself when asked which one it is.
        public var displayName: String { "Claude " + name }
        /// The short name the chat's menu shows: "Sonnet 5.5".
        public var name: String { label.components(separatedBy: " — ").first ?? id }
        /// The menu's second line: what it is for, and what a typical question costs.
        public let menuLine: String
        public let price: Price
        /// Whether to send `fallbacks: "default"`, which re-runs a declined request on another
        /// model server-side. Haiku 5.5 has no server-side fallback: with `"default"` a declined
        /// request just stays declined, so it is not sent.
        public let sendsFallbacks: Bool
    }

    public static let sonnet = Option(id: "claude-sonnet-5-5", label: "Sonnet 5.5 — balanced (default)",
                                      menuLine: "Balanced · about 1¢ a question",
                                      price: Price(input: 2, output: 10, cacheRead: 0.20), sendsFallbacks: true)
    public static let opus = Option(id: "claude-opus-5-5", label: "Opus 5.5 — strongest, about twice the cost",
                                    menuLine: "Strongest · about 2¢ a question",
                                    price: Price(input: 4, output: 20, cacheRead: 0.20), sendsFallbacks: true)
    /// Haiku 5.5’s cache-read price is not in the table this was written from; a tenth of input is
    /// the usual ratio, and at $0.01 per million the estimate cannot be wrong by anything visible.
    /// Above 100K prompt tokens it costs five times as much, which a long chat can reach.
    public static let haiku = Option(id: "claude-haiku-5-5", label: "Haiku 5.5 — fastest and cheapest",
                                     menuLine: "Fastest · under 1¢ a question",
                                     price: Price(input: 0.10, output: 0.50, cacheRead: 0.01,
                                                  longPromptThreshold: 100_000, longPromptMultiplier: 5),
                                     sendsFallbacks: false)

    /// What Settings offers, default first.
    public static let options: [Option] = [sonnet, opus, haiku]
    public static let defaultModel = sonnet

    public static let defaultsKey = "askClaudeModel"

    /// The option for a stored id; an id this build doesn’t offer falls back to the default rather
    /// than sending a model the picker cannot show.
    public static func option(for id: String?) -> Option {
        options.first { $0.id == id } ?? defaultModel
    }

    /// The price for whichever model actually answered. With fallbacks on, a declined request can
    /// be served by another model, and the response’s `model` says which. Sonnet 5, Opus 5 and
    /// Opus 4.8 are the documented fallback targets, so they are priced too; anything else is
    /// priced as the model that was asked, and the caller logs it.
    public static func price(forServedModel model: String?, requested: Option) -> (price: Price, known: Bool) {
        guard let model else { return (requested.price, true) }
        if let option = options.first(where: { $0.id == model }) { return (option.price, true) }
        switch model {
        case "claude-sonnet-5": return (Price(input: 2, output: 10, cacheRead: 0.20), true)
        case "claude-opus-5", "claude-opus-4-8": return (Price(input: 5, output: 25, cacheRead: 0.50), true)
        default: return (requested.price, false)
        }
    }

    /// The short name of whichever model answered: an offered one by its name, a documented
    /// fallback target by its own ("Opus 5"), anything else by its id.
    public static func name(ofServed model: String) -> String {
        if let option = options.first(where: { $0.id == model }) { return option.name }
        switch model {
        case "claude-sonnet-5": return "Sonnet 5"
        case "claude-opus-5": return "Opus 5"
        case "claude-opus-4-8": return "Opus 4.8"
        default: return model
        }
    }

    /// Tokens a question adds on top of the chat: a full screen card and the question, generously.
    static let nextQuestionAllowance = 10_000

    /// What the first answer on `target` costs to catch up on a chat of `contextTokens`:
    /// each model keeps its own cache, so the whole chat is written into `target`'s at the 1-hour
    /// rate. "Up to": a cache `target` wrote in the last hour, or thinking it can't read (dropped
    /// unbilled), makes it less. The long-prompt tier is judged with room for the next screen and
    /// question, which go out in the same request.
    public static func catchUpCost(contextTokens: Int, to target: Option) -> Double {
        let price = target.price.forPrompt(contextTokens + nextQuestionAllowance)
        return Double(contextTokens) * price.input * Price.oneHourWriteMultiplier / 1_000_000
    }

    /// Estimated cost of one response in US dollars.
    public static func cost(of usage: AskClaudeUsage, at basePrice: Price) -> Double {
        let price = basePrice.forPrompt(usage.promptTokens)
        let perToken = 1.0 / 1_000_000
        let writes = Double(usage.cacheWrite5mTokens) * price.input * Price.fiveMinuteWriteMultiplier
            + Double(usage.cacheWrite1hTokens) * price.input * Price.oneHourWriteMultiplier
        return (Double(usage.inputTokens) * price.input
                + Double(usage.cacheReadTokens) * price.cacheRead
                + writes
                + Double(usage.outputTokens) * price.output) * perToken
    }
}

/// Token counts from one response’s `usage`, merged across the stream’s `message_start` and
/// `message_delta` events.
public struct AskClaudeUsage: Equatable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWrite5mTokens = 0
    public var cacheWrite1hTokens = 0

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0,
                cacheWrite5mTokens: Int = 0, cacheWrite1hTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
    }

    /// Everything the request sent, cached or not.
    public var promptTokens: Int { inputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens }

    public static func + (lhs: AskClaudeUsage, rhs: AskClaudeUsage) -> AskClaudeUsage {
        AskClaudeUsage(inputTokens: lhs.inputTokens + rhs.inputTokens,
                       outputTokens: lhs.outputTokens + rhs.outputTokens,
                       cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
                       cacheWrite5mTokens: lhs.cacheWrite5mTokens + rhs.cacheWrite5mTokens,
                       cacheWrite1hTokens: lhs.cacheWrite1hTokens + rhs.cacheWrite1hTokens)
    }

    /// Folds a `usage` object in. Each field the object carries replaces the one held, because the
    /// stream reports running totals: `message_delta`’s `output_tokens` is the count so far, not an
    /// increment. A cache write with no TTL breakdown is counted at the 1-hour rate, the only TTL
    /// Ask Claude asks for.
    mutating func merge(_ usage: JSONFragment) {
        if let v = usage["input_tokens"]?.intValue { inputTokens = v }
        if let v = usage["output_tokens"]?.intValue { outputTokens = v }
        if let v = usage["cache_read_input_tokens"]?.intValue { cacheReadTokens = v }
        if let breakdown = usage["cache_creation"], breakdown.objectValue != nil {
            if let v = breakdown["ephemeral_5m_input_tokens"]?.intValue { cacheWrite5mTokens = v }
            if let v = breakdown["ephemeral_1h_input_tokens"]?.intValue { cacheWrite1hTokens = v }
        } else if let v = usage["cache_creation_input_tokens"]?.intValue {
            cacheWrite5mTokens = 0
            cacheWrite1hTokens = v
        }
    }
}

// MARK: - Reading JSON fragments

extension JSONFragment {
    public subscript(key: String) -> JSONFragment? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var objectValue: [String: JSONFragment]? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var arrayValue: [JSONFragment]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .integer(let v): return v
        case .unsignedInteger(let v): return Int(exactly: v)
        case .number(let v): return Int(exactly: v)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public static func decode(_ data: Data) throws -> JSONFragment {
        try JSONDecoder().decode(JSONFragment.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
