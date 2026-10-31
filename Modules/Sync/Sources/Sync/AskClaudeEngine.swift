import Events
import Foundation

/// Sends a request and hands back the response’s status and its lines as they arrive.
public protocol AskClaudeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse
}

public struct AskClaudeTransportResponse: Sendable {
    public let status: Int
    public let retryAfter: String?
    public let lines: AsyncThrowingStream<String, Error>
    /// The API's `request-id`, for finding a failed request in the Console.
    public let requestID: String?

    public init(status: Int, retryAfter: String?, lines: AsyncThrowingStream<String, Error>, requestID: String? = nil) {
        self.status = status
        self.retryAfter = retryAfter
        self.lines = lines
        self.requestID = requestID
    }
}

/// The real transport: URLSession’s byte stream, read line by line.
public struct AskClaudeURLSessionTransport: AskClaudeTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> AskClaudeTransportResponse {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return AskClaudeTransportResponse(status: http?.statusCode ?? 0,
                                          retryAfter: http?.value(forHTTPHeaderField: "retry-after"),
                                          lines: lines, requestID: http?.value(forHTTPHeaderField: "request-id"))
    }
}

/// What a tool call came to.
public struct AskClaudeToolOutcome: Equatable, Sendable {
    /// What goes back to Claude.
    public let result: String
    public let isError: Bool
    /// What the panel shows as the step, e.g. "Listed Documents/Taxes · 14 items".
    public let step: String
    /// Set when the tool moved the person’s view (decision EB): "Moved you to Taxes".
    public let movedView: String?
    /// A passage the person may choose to send to Claude (decision DS), shown as a button.
    public let passage: AskClaudePassage?
    /// A cloud-only file the person may choose to download (TE258), shown as a card.
    public let download: AskClaudeDownload?
    /// Filing help's answer (TE255), shown as a card with Go to Folder.
    public let filing: AskClaudeFilingCard?

    public init(result: String, isError: Bool = false, step: String, movedView: String? = nil,
                passage: AskClaudePassage? = nil, download: AskClaudeDownload? = nil,
                filing: AskClaudeFilingCard? = nil) {
        self.result = result
        self.isError = isError
        self.step = step
        self.movedView = movedView
        self.passage = passage
        self.download = download
        self.filing = filing
    }
}

/// Runs Ask Claude’s tools against the app. The app implements it; tests use a stub.
@MainActor
public protocol AskClaudeToolRunning: AnyObject {
    func run(_ call: AskClaudeToolCall, handles: inout AskClaudeHandles) async -> AskClaudeToolOutcome
}

/// Why a question stopped, in words the panel shows (decision EA): what’s wrong, and the fix.
public struct AskClaudeProblem: Error, Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable {
        case noKey, keyRejected, creditUsedUp, limitReached, rateLimited, busy, offline, declined, failed
    }
    public let kind: Kind
    public let message: String
    /// Whether opening Settings ▸ Intelligence would fix it.
    public var opensSettings: Bool { kind == .noKey || kind == .keyRejected || kind == .limitReached }

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    /// Reads an HTTP error status and body.
    public static func from(status: Int, body: String, retryAfter: String?) -> AskClaudeProblem {
        let data = body.data(using: .utf8) ?? Data()
        let parsed = try? JSONFragment.decode(data)
        let type = parsed?["error"]?["type"]?.stringValue ?? ""
        let detail = parsed?["error"]?["message"]?.stringValue ?? ""
        // A chat the API can no longer continue (a turn it now refuses, or one grown too long):
        // only a new chat gets past it, so the message says so.
        let lowered = detail.lowercased()
        if status == 400, ["messages.", "tool_use", "tool_result", "thinking", "prompt is too long"].contains(where: lowered.contains) {
            return AskClaudeProblem(.failed, "Claude can’t continue this chat: \(detail) Start a new chat with the + button to go on.")
        }
        if status == 402 || detail.lowercased().contains("credit balance") {
            return AskClaudeProblem(.creditUsedUp, "Your API credit is used up. It refills with your plan’s next billing cycle, or you can add credit in the Claude Console.")
        }
        switch status {
        case 401:
            return AskClaudeProblem(.keyRejected, "Claude didn’t accept the API key. Check it in Settings ▸ Intelligence.")
        case 403:
            // A permission error, not a bad key: the key's workspace or region can't use this.
            let what = detail.isEmpty ? "" : " (\(detail))"
            return AskClaudeProblem(.failed, "This API key isn’t allowed to make this request\(what). Check its workspace in the Claude Console, or pick another model in Settings ▸ Intelligence.")
        case 429:
            let wait = retryAfter.flatMap(Int.init).map { " Try again in \($0) seconds." } ?? " Try again in a moment."
            return AskClaudeProblem(.rateLimited, "Claude is limiting how fast requests can come in." + wait)
        case 529:
            return AskClaudeProblem(.busy, "Claude is busy right now. Try again in a moment.")
        case 500...599:
            return AskClaudeProblem(.busy, "Claude had a problem on its side (\(status)). Try again in a moment.")
        default:
            let what = detail.isEmpty ? (type.isEmpty ? "status \(status)" : type) : detail
            return AskClaudeProblem(.failed, "Claude couldn’t take this question: \(what)")
        }
    }

    /// Reads a transport error.
    public static func from(_ error: Error) -> AskClaudeProblem {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotFindHost, .cannotConnectToHost:
                return AskClaudeProblem(.offline, "This Mac can’t reach Claude. Check the internet connection and try again.")
            case .timedOut:
                return AskClaudeProblem(.busy, "Claude took too long to answer. Try again.")
            default:
                break
            }
        }
        return AskClaudeProblem(.failed, "The question didn’t go through: \(error.localizedDescription)")
    }
}

/// What the panel hears while a question runs.
public enum AskClaudeEvent: Equatable, Sendable {
    case text(String)
    case thinking
    case step(String, isError: Bool)
    case movedView(String)
    case offer(AskClaudePassage)
    /// A cloud-only file offered for download (TE258).
    case offerDownload(AskClaudeDownload)
    /// Filing help's card (TE255).
    case filing(AskClaudeFilingCard)
    /// One round trip finished: its usage and estimated cost.
    case round(AskClaudeUsage, costUSD: Double, model: String)
    case finished(stopReason: String?)
    case problem(AskClaudeProblem)
    /// The answer streamed so far in this round is withdrawn (a refusal mid-answer).
    case retractAnswer
}

/// The conversation, and the loop that runs one question to its answer (RD69).
///
/// **The transcript is append-only.** Earlier turns are never edited: editing one would break the
/// cache and invalidate the thinking blocks the model signed. A user turn joins the transcript only
/// once the request carrying it succeeds, so a failed request leaves nothing half-sent behind.
@MainActor
public final class AskClaudeEngine {

    /// Tool rounds per question (decision DZ). After the last one, the tools answer that the budget
    /// is spent, and Claude answers with what it has.
    public static let maxToolRounds = 8

    public private(set) var transcript: [JSONFragment] = []
    public var handles = AskClaudeHandles()
    /// The last screen card sent, so an unchanged screen goes as one line.
    private var lastCard: String?
    /// Tool results owed to the transcript’s last assistant turn when a question stopped before
    /// sending them (stopped by the person, or past the tool limit). The API needs every tool call
    /// answered before anything else, so they lead the next question’s turn.
    private var owedResults: [JSONFragment] = []
    /// The model and answer style this transcript was started with. The system text names both,
    /// and changing it under replayed thinking blocks is refused by the API, so a chat keeps them;
    /// the chat starts a new one when the person changes either.
    public private(set) var setting: String?

    /// The `setting` a chat on this model and style has.
    ///
    /// It also carries a digest of the instructions and the tool list, which a new build can
    /// change: a chat restored after such an update would otherwise be refused on every question.
    public static func setting(model: AskClaudeModels.Option, detail: AskClaudeDetail) -> String {
        model.id + "|" + detail.rawValue + "|" + AskClaudeRequest.fixedDigest
    }

    private let transport: AskClaudeTransport
    private let defaults: UserDefaults
    private let now: () -> Date

    /// Everything a chat needs to carry on after the app quits (TE247).
    public struct Snapshot: Codable, Equatable, Sendable {
        public var transcript: [JSONFragment]
        public var handles: AskClaudeHandles
        public var lastCard: String?
        public var owedResults: [JSONFragment]
        public var setting: String?
    }

    public var snapshot: Snapshot {
        Snapshot(transcript: transcript, handles: handles, lastCard: lastCard, owedResults: owedResults, setting: setting)
    }

    public func restore(_ snapshot: Snapshot) {
        transcript = snapshot.transcript
        handles = snapshot.handles
        lastCard = snapshot.lastCard
        owedResults = snapshot.owedResults
        setting = snapshot.setting
    }

    public init(transport: AskClaudeTransport = AskClaudeURLSessionTransport(),
                defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.defaults = defaults
        self.now = now
    }

    /// The text of the screen block for this question: the full card, or one line when nothing
    /// changed since the last question.
    public func screenBlock(for card: String) -> String {
        card == lastCard ? "<screen unchanged/>" : card
    }

    /// Runs one question. `card` is the rendered screen; `onEvent` hears progress on the main actor.
    public func ask(_ question: String, card: String, key: String?, model: AskClaudeModels.Option,
                    detail chosenDetail: AskClaudeDetail? = nil,
                    tools: AskClaudeToolRunning, onEvent: (AskClaudeEvent) -> Void) async {
        // Every problem and the way the question ended go in the log as well as the panel: a
        // question that failed used to leave a summary line that read like a success.
        var ended = "none"
        func emit(_ event: AskClaudeEvent) {
            switch event {
            case .problem(let problem):
                ended = problem.kind.rawValue
                Logger.shared.warning("Ask Claude problem (\(problem.kind.rawValue)): \(problem.message)")
            case .finished(let reason):
                ended = reason ?? "end"
            default:
                break
            }
            onEvent(event)
        }
        guard let key, !key.isEmpty else {
            emit(.problem(AskClaudeProblem(.noKey, "Add your Claude API key in Settings ▸ Intelligence to ask questions.")))
            return
        }
        if case .overLimit(let spent, let limit) = AskClaudeSpend.state(in: defaults, now: now()) {
            let reset = AskClaudeSpend.resetDate(after: now()).formatted(.dateTime.month(.wide).day())
            emit(.problem(AskClaudeProblem(.limitReached,
                "Ask Claude has used \(AskClaudeSpend.format(spent)) of its \(AskClaudeSpend.format(limit)) monthly limit. It resets on \(reset), or you can raise the limit in Settings ▸ Intelligence.")))
            return
        }

        let screen = screenBlock(for: card)
        // Read once per question, so the system text can't change between its rounds.
        let detail = chosenDetail ?? AskClaudeDetail.stored(in: defaults)
        if transcript.isEmpty { setting = Self.setting(model: model, detail: detail) }
        var pending: JSONFragment = .object([
            "role": .string("user"),
            "content": .array(owedResults + [
                .object(["type": .string("text"), "text": .string(screen)]),
                .object(["type": .string("text"), "text": .string(question)]),
            ]),
        ])
        var round = 0
        let askedAt = Date()
        var spent = 0.0
        var used = AskClaudeUsage()
        var toolNames: [String] = []
        // One summary line per question, however it ends.
        defer {
            Logger.shared.info("Ask Claude question done: \(round) round(s) · \(Self.describe(used)) · \(AskClaudeSpend.format(spent)) · "
                + "tools: \(toolNames.isEmpty ? "none" : toolNames.joined(separator: ", ")) · \(Self.seconds(since: askedAt))"
                + (screen == card ? " · screen \(card.count) chars" : " · screen unchanged") + " · ended \(ended)")
        }
        while true {
            round += 1
            let body = AskClaudeRequest.body(model: model, detail: detail, messages: transcript + [pending])
            let roundAt = Date()
            var firstWordAt: Date?
            var accumulator = AskClaudeStreamAccumulator()
            do {
                let request = try AskClaudeRequest.urlRequest(body: body, key: key, model: model)
                try await stream(request, into: &accumulator) { event in
                    if firstWordAt == nil, case .text = event { firstWordAt = Date() }
                    emit(event)
                }
            } catch {
                // After the first round, `pending` holds tool results the transcript’s last turn is
                // waiting on; they lead the next question. The first round’s pending turn is the
                // question itself, which simply never happened.
                if round > 1 { owedResults = pending["content"]?.arrayValue ?? [] }
                // A round the API started is billed even when it doesn't finish: what it reported
                // so far counts toward the limit.
                if accumulator.model != nil {
                    accumulator.estimateUnreportedOutput()
                    let cost = Self.cost(of: accumulator, requested: model)
                    AskClaudeSpend.record(cost, in: defaults, now: now())
                    spent += cost
                    used = used + accumulator.usage
                    emit(.round(accumulator.usage, costUSD: cost, model: accumulator.model ?? model.id))
                }
                // Stopping ends the stream quietly or with a cancellation; either way it's a stop.
                if Task.isCancelled || error is CancellationError {
                    emit(.finished(stopReason: "canceled"))
                } else if let problem = error as? AskClaudeProblem {
                    emit(.problem(problem))
                } else {
                    emit(.problem(AskClaudeProblem.from(error)))
                }
                return
            }

            let served = AskClaudeModels.price(forServedModel: accumulator.model, requested: model)
            let cost = Self.cost(of: accumulator, requested: model)
            AskClaudeSpend.record(cost, in: defaults, now: now())
            spent += cost
            used = used + accumulator.usage
            toolNames += accumulator.toolCalls.map(\.name)
            // One line per round trip: enough to see where a question's tokens and time went.
            Logger.shared.info("Ask Claude round \(round): \(accumulator.model ?? model.id) · \(Self.describe(accumulator.usage)) · "
                + "\(AskClaudeSpend.format(cost)) · stop \(accumulator.stopReason ?? "none")"
                + (accumulator.toolCalls.isEmpty ? "" : " · calls \(accumulator.toolCalls.map(\.name).joined(separator: ", "))")
                + " · first word \(firstWordAt.map { Self.seconds($0.timeIntervalSince(roundAt)) } ?? "none") · \(Self.seconds(since: roundAt))")
            if !served.known {
                Logger.shared.warning("Ask Claude: no price for \(accumulator.model ?? "?"); estimated at \(model.id)’s rates")
            }
            emit(.round(accumulator.usage, costUSD: cost, model: accumulator.model ?? model.id))

            if accumulator.stopReason == "refusal" {
                // The refused turn doesn't join the transcript, and what it streamed is withdrawn.
                // Results a tool round produced are still owed to the turn before it.
                if round > 1 { owedResults = pending["content"]?.arrayValue ?? [] }
                emit(.retractAnswer)
                emit(.problem(AskClaudeProblem(.declined, "Claude declined to answer this one. Try asking it another way.")))
                return
            }
            // An empty turn can't be sent back (the API refuses empty content and empty text), so it
            // doesn't join the transcript: an empty text block is dropped, and a turn left with only
            // its thinking counts as empty. Checked before the first round's bookkeeping, so results
            // still owed stay owed and the screen Claude never got isn't taken as sent.
            let content = accumulator.content.filter { !($0["type"]?.stringValue == "text" && ($0["text"]?.stringValue ?? "").isEmpty) }
            guard content.contains(where: { !["thinking", "redacted_thinking"].contains($0["type"]?.stringValue ?? "") }) else {
                if round > 1 { owedResults = pending["content"]?.arrayValue ?? [] }
                emit(.finished(stopReason: accumulator.stopReason))
                return
            }
            if round == 1 {
                lastCard = card
                owedResults = []
            }
            transcript.append(pending)
            transcript.append(.object(["role": .string("assistant"), "content": .array(content)]))

            let calls = accumulator.toolCalls
            guard accumulator.stopReason == "tool_use", !calls.isEmpty else {
                // A turn cut off mid-call (max_tokens) still holds its tool_use blocks, and the
                // API wants each answered before anything else.
                owedResults = calls.map { Self.result(for: $0, text: "Not run: the answer was cut off before this call finished.", isError: true) }
                emit(.finished(stopReason: accumulator.stopReason))
                return
            }
            // The budget answer went back once and Claude still wants tools: stop here rather than
            // pay for more rounds that can only be refused.
            if round > Self.maxToolRounds + 1 {
                owedResults = calls.map { Self.result(for: $0, text: "Stopped: the tool limit for that question was reached.", isError: true) }
                emit(.problem(AskClaudeProblem(.failed, "Claude kept looking past the tool limit for one question. Try a narrower question.")))
                return
            }
            // Every result goes back in one user turn, as the API expects for parallel calls.
            var results: [JSONFragment] = []
            for call in calls {
                let outcome: AskClaudeToolOutcome
                if Task.isCancelled {
                    // Stopped: the calls not yet run are answered without running them, so the
                    // view doesn't move after the person pressed Stop.
                    outcome = AskClaudeToolOutcome(result: "Not run: they stopped the question.", isError: true,
                                                   step: "Stopped before \(call.name)")
                    Logger.shared.info("Ask Claude tool \(call.name): not run, the question was stopped")
                    emit(.step(outcome.step, isError: true))
                    results.append(Self.result(for: call, text: outcome.result, isError: true))
                    continue
                } else if round > Self.maxToolRounds {
                    outcome = AskClaudeToolOutcome(result: "The tool budget for this question is used up. Answer with what you have.",
                                                   isError: true, step: "Stopped looking: tool limit reached")
                } else {
                    // A local copy: a stored property can’t be held `inout` across a suspension.
                    var working = handles
                    outcome = await tools.run(call, handles: &working)
                    handles = working
                }
                // One line per tool call: what it did, or why not, and whether it moved their view.
                Logger.shared.info("Ask Claude tool \(call.name): \(outcome.step)" + (outcome.isError ? " (refused)" : "")
                    + (outcome.movedView.map { " · \($0)" } ?? ""))
                emit(.step(outcome.step, isError: outcome.isError))
                if let moved = outcome.movedView { emit(.movedView(moved)) }
                if let passage = outcome.passage { emit(.offer(passage)) }
                if let download = outcome.download { emit(.offerDownload(download)) }
                if let filing = outcome.filing { emit(.filing(filing)) }
                results.append(Self.result(for: call, text: outcome.result, isError: outcome.isError))
            }
            if Task.isCancelled {
                owedResults = results
                emit(.finished(stopReason: "canceled"))
                return
            }
            pending = .object(["role": .string("user"), "content": .array(results)])
        }
    }

    /// "300 new + 4.5K cached + 0 written in, 700 out".
    static func describe(_ u: AskClaudeUsage) -> String {
        func n(_ v: Int) -> String { v.formatted(.number.notation(.compactName)) }
        return "\(n(u.inputTokens)) new + \(n(u.cacheReadTokens)) cached + \(n(u.cacheWrite5mTokens + u.cacheWrite1hTokens)) written in, \(n(u.outputTokens)) out"
    }

    static func seconds(since start: Date) -> String { seconds(Date().timeIntervalSince(start)) }
    static func seconds(_ interval: TimeInterval) -> String { String(format: "%.1f s", interval) }

    static func result(for call: AskClaudeToolCall, text: String, isError: Bool) -> JSONFragment {
        var result: [String: JSONFragment] = [
            "type": .string("tool_result"),
            "tool_use_id": .string(call.id),
            "content": .string(text),
        ]
        if isError { result["is_error"] = .bool(true) }
        return .object(result)
    }

    /// A round's cost: per attempt when a fallback re-ran it (`usage.iterations`), each at the
    /// rates of the model that ran it; otherwise the top-level usage at the served model's rates.
    nonisolated static func cost(of accumulator: AskClaudeStreamAccumulator, requested: AskClaudeModels.Option) -> Double {
        let served = AskClaudeModels.price(forServedModel: accumulator.model, requested: requested).price
        let attempts = accumulator.iterations.compactMap { iteration -> Double? in
            var usage = AskClaudeUsage()
            usage.merge(iteration)
            guard usage.promptTokens + usage.outputTokens > 0 else { return nil }
            // An attempt that doesn't name its model: a fallback's is the served one's, any other
            // is the declined attempt on the model that was asked.
            let named = iteration["model"]?.stringValue
                ?? (iteration["type"]?.stringValue == "fallback_message" ? accumulator.model : requested.id)
            let price = named.map { AskClaudeModels.price(forServedModel: $0, requested: requested).price } ?? served
            return AskClaudeModels.cost(of: usage, at: price)
        }
        return attempts.count > 1 ? attempts.reduce(0, +) : AskClaudeModels.cost(of: accumulator.usage, at: served)
    }

    private func stream(_ request: URLRequest, into accumulator: inout AskClaudeStreamAccumulator,
                        onEvent: (AskClaudeEvent) -> Void) async throws {
        let response = try await transport.send(request)
        if response.status != 200 {
            var body = ""
            for try await line in response.lines { body += line }
            // The details for the Console; the problem itself is logged where it is shown.
            Logger.shared.info("Ask Claude HTTP \(response.status) · request \(response.requestID ?? "unknown") · \(body.prefix(300))")
            throw AskClaudeProblem.from(status: response.status, body: body, retryAfter: response.retryAfter)
        }
        for try await line in response.lines {
            try Task.checkCancellation()
            switch accumulator.apply(line: line) {
            case .text(let piece): onEvent(.text(piece))
            case .thinking: onEvent(.thinking)
            case .toolStarted, nil: break
            }
            if accumulator.finished { break }
        }
        // A cancelled stream can simply end, which would otherwise read as "cut off".
        try Task.checkCancellation()
        if let failure = accumulator.failure {
            throw failure.type == "overloaded_error"
                ? AskClaudeProblem(.busy, "Claude is busy right now. Try again in a moment.")
                : AskClaudeProblem(.failed, "Claude stopped partway: \(failure.message)")
        }
        guard accumulator.finished else {
            throw AskClaudeProblem(.failed, "The answer was cut off before it finished. Try again.")
        }
    }
}
